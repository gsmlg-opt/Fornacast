defmodule ForgeMirrors.ResourceInventory do
  @moduledoc """
  Bounded, read-only enumeration of provider-bound metadata mappings.

  The first page pins a mapping-ID high-water mark. Continuations retain that
  mark and their repository/kind scope, so new mappings cannot indefinitely
  extend a sweep. Returned timestamps are hints, not provider observations:
  the worker must fetch each current remote resource before reconciling it.

  Confirmed mappings and unfinished provider-bound mappings are eligible.
  Local-only pending rows, tombstones, conflicts and unsupported resources are
  not remote discovery candidates for issues and comments. Pull reconciliation
  revisits confirmed and unfinished provider-bound mappings as well as unsupported
  heads. The coordinator owns authorization, leases
  and durable checkpointing; this module performs no mutations or HTTP calls.
  """
  import Ecto.Query
  alias ForgeMirrors.{MirrorResourceState, RepositoryMirror}
  alias Fornacast.Repo

  @max_id 9_223_372_036_854_775_807
  @epoch ~U[1970-01-01 00:00:00Z]
  defguardp valid_id(id) when is_integer(id) and id > 0 and id <= @max_id
  defguardp valid_cursor_id(id) when is_integer(id) and id >= 0 and id <= @max_id

  @spec page(pos_integer(), :issue | :issue_comment | :pull | :release, map() | nil, 1..100) ::
          {:ok, %{observations: [map()], next_cursor: map() | nil}}
          | {:error, :invalid_argument | :unbound_repository | :invalid_mapping}
  def page(repository_mirror_id, kind, cursor \\ nil, limit \\ 100)

  def page(repository_mirror_id, kind, cursor, limit)
      when valid_id(repository_mirror_id) and kind in [:issue, :issue_comment, :pull, :release] and
             is_integer(limit) and limit in 1..100 do
    with {:ok, {after_id, through_id}} <- bounds(cursor, repository_mirror_id, kind),
         %RepositoryMirror{repository_id: repository_id} when valid_id(repository_id) <-
           Repo.get(RepositoryMirror, repository_mirror_id) do
      query =
        from mapping in MirrorResourceState,
          as: :mapping,
          where:
            mapping.repository_mirror_id == ^repository_mirror_id and
              mapping.resource_kind == ^kind

      query =
        if kind == :pull do
          from mapping in query,
            where:
              mapping.state in [:confirmed, :unsupported] or
                (mapping.state == :pending and not is_nil(mapping.github_object_id))
        else
          from mapping in query,
            where:
              mapping.state == :confirmed or
                (mapping.state == :pending and not is_nil(mapping.github_object_id))
        end

      query =
        if kind == :issue do
          from mapping in query,
            where:
              not exists(
                from issue in "issues",
                  where:
                    issue.id == parent_as(:mapping).local_resource_id and
                      issue.repository_id == ^repository_id and issue.kind == "pull_request",
                  select: 1
              )
        else
          query
        end

      through_id = through_id || Repo.one(from mapping in query, select: max(mapping.id)) || 0

      rows =
        Repo.all(
          from mapping in query,
            where: mapping.id > ^after_id and mapping.id <= ^through_id,
            order_by: mapping.id,
            limit: ^(limit + 1),
            select:
              map(mapping, [
                :id,
                :state,
                :local_resource_type,
                :local_resource_id,
                :github_object_id,
                :github_number,
                :confirmed_remote_updated_at,
                :confirmed_snapshot
              ])
        )
        |> enrich_release_inventory(kind, repository_id)

      if Enum.all?(rows, &valid_mapping?(&1, kind)) do
        entries = Enum.take(rows, limit)

        next_cursor =
          if length(rows) > limit do
            %{
              "repository_mirror_id" => repository_mirror_id,
              "resource_kind" => Atom.to_string(kind),
              "after_id" => List.last(entries).id,
              "through_id" => through_id
            }
          end

        {:ok,
         %{observations: Enum.map(entries, &observation(&1, kind)), next_cursor: next_cursor}}
      else
        {:error, :invalid_mapping}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unbound_repository}
    end
  end

  def page(_, _, _, _), do: {:error, :invalid_argument}

  defp bounds(nil, _repository_mirror_id, _kind), do: {:ok, {0, nil}}

  defp bounds(
         %{
           "repository_mirror_id" => repository_mirror_id,
           "resource_kind" => cursor_kind,
           "after_id" => after_id,
           "through_id" => through_id
         } = cursor,
         repository_mirror_id,
         kind
       )
       when map_size(cursor) == 4 and valid_cursor_id(after_id) and valid_cursor_id(through_id) and
              after_id <= through_id do
    if cursor_kind == Atom.to_string(kind),
      do: {:ok, {after_id, through_id}},
      else: {:error, :invalid_argument}
  end

  defp bounds(_, _, _), do: {:error, :invalid_argument}

  defp valid_mapping?(mapping, kind) do
    valid_id(mapping.github_object_id) and valid_remote_identity?(mapping, kind) and
      valid_local_identity?(mapping, kind) and
      valid_timestamp?(mapping.confirmed_remote_updated_at)
  end

  defp valid_remote_identity?(mapping, :release) do
    valid_tag_name?(mapping[:inventory_tag_name])
  end

  defp valid_remote_identity?(mapping, _kind), do: valid_id(mapping.github_number)

  defp valid_local_identity?(%{state: :pending, local_resource_id: nil} = mapping, kind),
    do: mapping.local_resource_type in [nil, local_type(kind)]

  defp valid_local_identity?(mapping, kind),
    do: valid_id(mapping.local_resource_id) and mapping.local_resource_type == local_type(kind)

  defp local_type(:issue), do: "ForgeIssues.Issue"
  defp local_type(:issue_comment), do: "ForgeIssues.Comment"
  defp local_type(:pull), do: "ForgePulls.PullRequest"
  defp local_type(:release), do: "ForgeReleases.Release"

  defp valid_tag_name?(value) do
    is_binary(value) and String.valid?(value) and String.length(value) in 1..255 and
      value == String.trim(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp enrich_release_inventory(rows, :release, repository_id) do
    local_ids =
      rows
      |> Enum.map(& &1.local_resource_id)
      |> Enum.filter(&valid_local_id?/1)

    local_tags =
      Repo.all(
        from release in "releases",
          where: release.repository_id == ^repository_id and release.id in ^local_ids,
          select: {release.id, release.tag_name}
      )
      |> Map.new()

    Enum.map(rows, fn mapping ->
      snapshot_tag = get_in(mapping.confirmed_snapshot || %{}, ["tag_name"])
      Map.put(mapping, :inventory_tag_name, snapshot_tag || local_tags[mapping.local_resource_id])
    end)
  end

  defp enrich_release_inventory(rows, _kind, _repository_id), do: rows

  defp valid_local_id?(id), do: is_integer(id) and id > 0 and id <= @max_id

  defp valid_timestamp?(nil), do: true
  defp valid_timestamp?(%DateTime{utc_offset: 0, std_offset: 0}), do: true
  defp valid_timestamp?(_), do: false

  defp observation(mapping, :release),
    do: %{
      github_object_id: mapping.github_object_id,
      tag_name: mapping.inventory_tag_name,
      remote_updated_at: mapping.confirmed_remote_updated_at || @epoch
    }

  defp observation(mapping, _kind),
    do: %{
      github_object_id: mapping.github_object_id,
      github_number: mapping.github_number,
      github_issue_id: nil,
      remote_updated_at: mapping.confirmed_remote_updated_at || @epoch
    }
end
