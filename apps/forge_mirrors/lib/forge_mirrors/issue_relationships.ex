defmodule ForgeMirrors.IssueRelationships do
  @moduledoc "Read-only, repository-scoped identity resolution for issue relationship membership."
  import Ecto.Query
  alias ForgeAccounts.GitHubIdentity
  alias ForgeMirrors.{MirrorResourceState, RepositoryMirror}
  alias Fornacast.Repo

  def resolve(id, direction, labels, assignees)
      when is_integer(id) and id > 0 and direction in [:local, :remote] and
             is_list(labels) and length(labels) <= 512 and is_list(assignees) and
             length(assignees) <= 512 do
    with %RepositoryMirror{repository_id: repository_id} when is_integer(repository_id) <-
           Repo.get(RepositoryMirror, id),
         {:ok, labels} <- labels(id, repository_id, direction, labels),
         {:ok, assignees} <- assignees(direction, assignees) do
      {:ok, %{labels: labels, assignees: assignees}}
    else
      nil -> {:error, :unbound_repository}
      %RepositoryMirror{} -> {:error, :unbound_repository}
      {:error, _} = error -> error
    end
  end

  def resolve(_, _, _, _), do: {:error, :invalid_relationships}

  defp labels(mirror_id, repository_id, direction, values) do
    ids = if direction == :local, do: values, else: Enum.map(values, &provider_id/1)

    names_valid =
      direction == :local or
        Enum.all?(values, fn
          %{"name" => name} when is_binary(name) ->
            byte_size(name) in 1..1020 and String.valid?(name) and
              :binary.match(name, <<0>>) == :nomatch and length(String.codepoints(name)) <= 255

          _invalid ->
            false
        end)

    if Enum.all?(ids, &id?/1) and length(ids) == length(Enum.uniq(ids)) and names_valid do
      query =
        from m in MirrorResourceState,
          join: l in "repository_labels",
          on: l.id == m.local_resource_id,
          where:
            m.repository_mirror_id == ^mirror_id and m.resource_kind == :label and
              m.local_resource_type == "ForgeIssues.Label" and m.state == :confirmed and
              l.repository_id == ^repository_id and not is_nil(m.github_object_id),
          select: %{github_object_id: m.github_object_id, local_label_id: l.id, name: l.name}

      query =
        if direction == :local,
          do: where(query, [m], m.local_resource_id in ^ids),
          else: where(query, [m], m.github_object_id in ^ids)

      rows = Repo.all(query)

      rows =
        if direction == :remote do
          names = Map.new(values, &{&1["id"], &1["name"]})
          Enum.map(rows, &Map.put(&1, :name, Map.fetch!(names, &1.github_object_id)))
        else
          rows
        end

      if length(rows) == length(ids) do
        {:ok, Enum.sort_by(rows, & &1.github_object_id)}
      else
        mapped_ids =
          Enum.map(rows, fn row ->
            if direction == :local, do: row.local_label_id, else: row.github_object_id
          end)

        first_missing = ids |> Enum.sort() |> Enum.find(&(&1 not in mapped_ids))
        missing_label_candidate(repository_id, direction, first_missing, values)
      end
    else
      {:error, :invalid_relationships}
    end
  end

  defp missing_label_candidate(repository_id, :local, id, _values) do
    label =
      Repo.one(
        from label in "repository_labels",
          where: label.repository_id == ^repository_id and label.id == ^id,
          select: %{
            local_label_id: label.id,
            name: label.name,
            color: label.color,
            description: label.description,
            local_version: label.sync_version
          }
      )

    case label do
      %{local_version: version} when is_integer(version) and version > 0 ->
        bounded_label_candidate(label)

      _ ->
        {:error, :unmapped_label}
    end
  end

  defp missing_label_candidate(_repository_id, :remote, id, values) do
    label = Enum.find(values, &(&1["id"] == id))

    if text?(label["node_id"], 255) and label["node_id"] != "" do
      bounded_label_candidate(%{
        github_object_id: id,
        node_id: label["node_id"],
        name: label["name"],
        color: label["color"],
        description: label["description"]
      })
    else
      {:error, :invalid_relationships}
    end
  end

  defp bounded_label_candidate(candidate) do
    if text?(candidate.name, 255) and String.trim(candidate.name) != "" and
         is_binary(candidate.color) and Regex.match?(~r/^[0-9a-fA-F]{6}$/, candidate.color) and
         (is_nil(candidate.description) or text?(candidate.description, 100)) do
      candidate = %{
        candidate
        | color: String.downcase(candidate.color),
          description: if(candidate.description == "", do: nil, else: candidate.description)
      }

      {:error, {:unmapped_label, candidate}}
    else
      {:error, :invalid_relationships}
    end
  end

  defp text?(value, maximum) when is_binary(value),
    do:
      byte_size(value) <= maximum * 4 and
        String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
        length(String.codepoints(value)) <= maximum

  defp text?(_, _), do: false

  defp assignees(:local, refs) do
    if Enum.all?(refs, &ref?/1) do
      user_ids = for %{kind: :local_user, id: id} <- refs, do: id
      identity_ids = for %{kind: :github_identity, id: id} <- refs, do: id

      identities =
        Repo.all(
          from i in GitHubIdentity,
            where:
              i.kind == :user and
                (i.local_user_id in ^user_ids or i.id in ^identity_ids)
        )

      refs
      |> Enum.sort_by(fn ref -> if ref.kind == :local_user, do: 0, else: 1 end)
      |> collect(fn ref ->
        matches =
          Enum.filter(identities, fn identity ->
            if ref.kind == :local_user,
              do: identity.local_user_id == ref.id,
              else: identity.id == ref.id
          end)

        case {ref.kind, matches} do
          {:local_user, []} -> {:ok, nil}
          {_, [identity]} -> {:ok, assignee(identity, ref)}
          {_, []} -> {:error, :unmapped_assignee}
          _ -> {:error, :ambiguous_assignee_identity}
        end
      end)
    else
      {:error, :invalid_relationships}
    end
  end

  defp assignees(:remote, users) do
    ids = Enum.map(users, &provider_id/1)

    if Enum.all?(ids, &id?/1) and length(ids) == length(Enum.uniq(ids)) do
      identities =
        Repo.all(from i in GitHubIdentity, where: i.kind == :user and i.github_user_id in ^ids)

      linked_ids = identities |> Enum.map(& &1.local_user_id) |> Enum.reject(&is_nil/1)

      link_counts =
        Repo.all(
          from i in GitHubIdentity,
            where: i.kind == :user and i.local_user_id in ^linked_ids,
            group_by: i.local_user_id,
            select: {i.local_user_id, count(i.id)}
        )
        |> Map.new()

      collect(ids, fn id ->
        case Enum.find(identities, &(&1.github_user_id == id)) do
          nil ->
            {:error, :unmapped_assignee}

          identity ->
            ref =
              if identity.local_user_id && link_counts[identity.local_user_id] == 1,
                do: %{kind: :local_user, id: identity.local_user_id},
                else: %{kind: :github_identity, id: identity.id}

            {:ok, assignee(identity, ref)}
        end
      end)
    else
      {:error, :invalid_relationships}
    end
  end

  defp collect(values, mapper) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        {:ok, entries |> Enum.uniq_by(& &1.github_user_id) |> Enum.sort_by(& &1.github_user_id)}

      error ->
        error
    end
  end

  defp assignee(identity, ref),
    do: %{github_user_id: identity.github_user_id, login: identity.login, ref: ref}

  defp provider_id(%{"id" => id}), do: id
  defp provider_id(_), do: nil
  defp id?(id), do: is_integer(id) and id in 1..9_223_372_036_854_775_807

  defp ref?(%{kind: kind, id: id} = ref),
    do: kind in [:local_user, :github_identity] and id?(id) and map_size(ref) == 2

  defp ref?(_), do: false
end
