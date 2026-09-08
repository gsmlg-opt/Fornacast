defmodule ForgeMirrors.ResourceInventory do
  @moduledoc """
  Bounded, read-only enumeration of provider-bound metadata mappings.

  The first page pins a mapping-ID high-water mark. Continuations retain that
  mark and their repository/kind scope, so new mappings cannot indefinitely
  extend a sweep. Returned timestamps are hints, not provider observations:
  the worker must fetch each current remote resource before reconciling it.

  Confirmed mappings and unfinished provider-bound mappings are eligible.
  Local-only pending rows, tombstones, conflicts and unsupported resources are
  not remote discovery candidates. The coordinator owns authorization, leases
  and durable checkpointing; this module performs no mutations or HTTP calls.
  """
  import Ecto.Query
  alias ForgeMirrors.{MirrorResourceState, RepositoryMirror}
  alias Fornacast.Repo

  @max_id 9_223_372_036_854_775_807
  @epoch ~U[1970-01-01 00:00:00Z]
  defguardp valid_id(id) when is_integer(id) and id > 0 and id <= @max_id
  defguardp valid_cursor_id(id) when is_integer(id) and id >= 0 and id <= @max_id

  @spec page(pos_integer(), :issue | :issue_comment, map() | nil, 1..100) ::
          {:ok, %{observations: [map()], next_cursor: map() | nil}}
          | {:error, :invalid_argument | :unbound_repository | :invalid_mapping}
  def page(repository_mirror_id, kind, cursor \\ nil, limit \\ 100)

  def page(repository_mirror_id, kind, cursor, limit)
      when valid_id(repository_mirror_id) and kind in [:issue, :issue_comment] and
             is_integer(limit) and limit in 1..100 do
    with {:ok, {after_id, through_id}} <- bounds(cursor, repository_mirror_id, kind),
         %RepositoryMirror{repository_id: repository_id} when valid_id(repository_id) <-
           Repo.get(RepositoryMirror, repository_mirror_id) do
      query =
        from mapping in MirrorResourceState,
          as: :mapping,
          where:
            mapping.repository_mirror_id == ^repository_mirror_id and
              mapping.resource_kind == ^kind,
          where:
            mapping.state == :confirmed or
              (mapping.state == :pending and not is_nil(mapping.github_object_id))

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
                :confirmed_remote_updated_at
              ])
        )

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

        {:ok, %{observations: Enum.map(entries, &observation/1), next_cursor: next_cursor}}
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
    valid_id(mapping.github_object_id) and valid_id(mapping.github_number) and
      valid_local_identity?(mapping, kind) and
      valid_timestamp?(mapping.confirmed_remote_updated_at)
  end

  defp valid_local_identity?(%{state: :pending, local_resource_id: nil} = mapping, kind),
    do: mapping.local_resource_type in [nil, local_type(kind)]

  defp valid_local_identity?(mapping, kind),
    do: valid_id(mapping.local_resource_id) and mapping.local_resource_type == local_type(kind)

  defp local_type(:issue), do: "ForgeIssues.Issue"
  defp local_type(:issue_comment), do: "ForgeIssues.Comment"
  defp valid_timestamp?(nil), do: true
  defp valid_timestamp?(%DateTime{utc_offset: 0, std_offset: 0}), do: true
  defp valid_timestamp?(_), do: false

  defp observation(mapping),
    do: %{
      github_object_id: mapping.github_object_id,
      github_number: mapping.github_number,
      github_issue_id: nil,
      remote_updated_at: mapping.confirmed_remote_updated_at || @epoch
    }
end
