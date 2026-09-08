defmodule ForgeImports.GitHub.MetadataMapper do
  @moduledoc "Pure GitHub metadata normalization and skip classification for imports."

  alias ForgeGitHub.User

  @spec label(term()) :: {:ok, map()} | {:error, atom()}
  def label(%{} = payload) do
    with {:ok, github_id} <- User.id(payload["id"]),
         {:ok, name} <- User.string(payload["name"], 255, required?: true),
         {:ok, color} <- color(payload["color"]),
         {:ok, description} <- User.string(payload["description"], 2_048) do
      {:ok,
       %{
         github_id: github_id,
         name: name,
         color: color,
         description: description
       }}
    else
      _ -> {:error, :invalid_label}
    end
  end

  def label(_payload), do: {:error, :invalid_label}

  @spec issue(term()) :: {:ok, map()} | {:skip, atom(), map()} | {:error, atom()}
  def issue(%{} = payload) do
    case payload["pull_request"] do
      nil ->
        map_issue(payload)

      %{} ->
        with {:ok, id} <- User.id(payload["id"]),
             {:ok, number} <- User.id(payload["number"]) do
          {:skip, :pull_request_issue, %{number: number, github_issue_id: id}}
        else
          _ -> {:error, :invalid_issue}
        end

      _ ->
        {:error, :invalid_issue}
    end
  end

  def issue(_payload), do: {:error, :invalid_issue}

  @spec comment(term()) :: {:ok, map()} | {:error, atom()}
  def comment(%{} = payload) do
    with {:ok, github_id} <- User.id(payload["id"]),
         {:ok, body} <- User.string(payload["body"], 65_536, required?: true),
         {:ok, inserted_at} <- User.datetime(payload["created_at"]),
         {:ok, updated_at} <- User.datetime(payload["updated_at"]),
         {:ok, author} <- author_identity(payload["user"]) do
      {:ok,
       %{
         github_id: github_id,
         body: body,
         inserted_at: inserted_at,
         updated_at: updated_at,
         author_github_user_id: author.github_user_id,
         author_deleted: author.deleted?
       }}
    else
      _ -> {:error, :invalid_comment}
    end
  end

  def comment(_payload), do: {:error, :invalid_comment}

  @spec pull(term(), pos_integer(), keyword()) ::
          {:ok, map()} | {:skip, atom(), map()} | {:error, atom()}
  def pull(payload, source_repository_id, opts \\ [])

  def pull(%{} = payload, source_repository_id, opts) when is_integer(source_repository_id) do
    staged_refs = Keyword.get(opts, :staged_refs, %{})

    with :ok <- classify_pull_shape(payload, source_repository_id),
         {:ok, head_ref} <- branch_ref(payload["head"]["ref"]),
         {:ok, base_ref} <- branch_ref(payload["base"]["ref"]),
         {:ok, head_sha} <- oid(payload["head"]["sha"]),
         {:ok, base_sha} <- oid(payload["base"]["sha"]),
         :ok <-
           validate_pull_refs(
             payload,
             source_repository_id,
             staged_refs,
             head_ref,
             base_ref,
             head_sha,
             base_sha
           ),
         {:ok, normalized} <- map_pull(payload, head_ref, base_ref, head_sha, base_sha) do
      {:ok, normalized}
    else
      {:skip, code, details} -> {:skip, code, details}
      {:error, code} -> {:error, code}
      _ -> {:error, :invalid_pull}
    end
  end

  def pull(_payload, _source_repository_id, _opts), do: {:error, :invalid_pull}

  @spec pull_observation(term(), term(), pos_integer(), keyword()) ::
          {:ok, map()}
          | {:skip, atom(), map()}
          | {:error, :invalid_pull | :pull_issue_identity_mismatch}
  def pull_observation(pull, issue, source_repository_id, opts \\ [])

  def pull_observation(%{} = pull, %{} = issue, source_repository_id, opts)
      when is_integer(source_repository_id) and is_list(opts) do
    with {:ok, expected_issue_id} <- expected_issue_id(opts),
         {:ok, source_full_name} <- source_full_name(opts),
         {:ok, mapped} <- pull(pull, source_repository_id, opts),
         {:ok, identity} <-
           pull_issue_identity(
             pull,
             issue,
             mapped,
             expected_issue_id,
             source_repository_id,
             source_full_name
           ) do
      {:ok,
       mapped
       |> Map.merge(identity)
       |> Map.put(:title, identity.issue_title)
       |> Map.put(:body, identity.issue_body)
       |> Map.put(:state, identity.issue_state)
       |> Map.put(:state_reason, identity.issue_state_reason)
       |> Map.put(:updated_at, identity.remote_updated_at)
       |> Map.drop([:issue_title, :issue_body, :issue_state, :issue_state_reason])}
    else
      {:skip, _, _} = skipped -> skipped
      {:error, :invalid_pull} = error -> error
      _invalid -> {:error, :pull_issue_identity_mismatch}
    end
  end

  def pull_observation(_pull, _issue, _source_repository_id, _opts),
    do: {:error, :invalid_pull}

  defp map_issue(payload) do
    with {:ok, github_id} <- User.id(payload["id"]),
         {:ok, number} <- User.id(payload["number"]),
         {:ok, title} <- User.string(payload["title"], 256, required?: true),
         {:ok, body} <- issue_body(payload["body"]),
         {:ok, state} <- issue_state(payload["state"]),
         {:ok, state_reason} <- issue_state_reason(payload, state),
         {:ok, inserted_at} <- User.datetime(payload["created_at"]),
         {:ok, updated_at} <- User.datetime(payload["updated_at"]),
         {:ok, closed_at} <- User.datetime(payload["closed_at"]),
         {:ok, author} <- author_identity(payload["user"]) do
      {:ok,
       %{
         github_id: github_id,
         number: number,
         kind: :issue,
         title: title,
         body: body,
         state: state,
         state_reason: state_reason,
         closed_at: closed_at,
         inserted_at: inserted_at,
         updated_at: updated_at,
         author_github_user_id: author.github_user_id,
         author_deleted: author.deleted?,
         unsupported: unsupported_issue_categories(payload)
       }}
    else
      _ -> {:error, :invalid_issue}
    end
  end

  defp map_pull(payload, head_ref, base_ref, head_sha, base_sha) do
    with {:ok, github_id} <- User.id(payload["id"]),
         {:ok, head_node_id} <- User.string(get_in(payload, ["head", "repo", "node_id"]), 255),
         {:ok, number} <- User.id(payload["number"]),
         {:ok, title} <- User.string(payload["title"], 256, required?: true),
         {:ok, body} <- issue_body(payload["body"]),
         {:ok, state} <- issue_state(payload["state"]),
         {:ok, inserted_at} <- User.datetime(payload["created_at"]),
         {:ok, updated_at} <- User.datetime(payload["updated_at"]),
         {:ok, author} <- author_identity(payload["user"]),
         {:ok, merged_fields} <- merged_fields(payload),
         {:ok, merger} <- merger_identity(payload["merged_by"]) do
      {:ok,
       %{
         github_id: github_id,
         number: number,
         kind: :pull_request,
         draft: payload["draft"],
         head_github_repository_id: repo_id(payload["head"]),
         head_github_node_id: head_node_id,
         title: title,
         body: body,
         state: state,
         inserted_at: inserted_at,
         updated_at: updated_at,
         author_github_user_id: author.github_user_id,
         author_deleted: author.deleted?,
         head_ref: head_ref,
         base_ref: base_ref,
         head_sha: head_sha,
         base_sha: base_sha,
         merged_at: merged_fields.merged_at,
         merge_commit_sha: merged_fields.merge_commit_sha,
         merger_github_user_id: merger.github_user_id,
         merger_deleted: merger.deleted?,
         unsupported: unsupported_pull_categories(payload)
       }}
    else
      _ -> {:error, :invalid_pull}
    end
  end

  defp pull_issue_identity(
         pull,
         issue,
         mapped,
         expected_issue_id,
         source_repository_id,
         source_full_name
       ) do
    expected_url =
      "https://api.github.com/repos/#{source_full_name}/pulls/#{mapped.number}"

    with {:ok, pull_node_id} <- User.string(pull["node_id"], 255, required?: true),
         {:ok, issue_id} <- User.id(issue["id"]),
         true <- issue_id == expected_issue_id,
         {:ok, issue_node_id} <- User.string(issue["node_id"], 255, required?: true),
         {:ok, issue_number} <- User.id(issue["number"]),
         true <- issue_number == mapped.number,
         true <- get_in(issue, ["pull_request", "url"]) == expected_url,
         {:ok, issue_title} <- User.string(issue["title"], 256, required?: true),
         {:ok, issue_body} <- issue_body(issue["body"]),
         {:ok, issue_state} <- issue_state(issue["state"]),
         {:ok, issue_state_reason} <- issue_state_reason(issue, issue_state),
         {:ok, label_github_ids} <- relationship_ids(issue["labels"]),
         {:ok, assignee_github_ids} <- relationship_ids(issue["assignees"]),
         true <-
           issue_title == mapped.title and
             normalize_body(issue_body) == normalize_body(mapped.body) and
             issue_state == mapped.state,
         {:ok, %DateTime{} = remote_updated_at} <- User.datetime(issue["updated_at"]),
         {:ok, head_repository} <- repository_identity(pull["head"]),
         {:ok, base_repository} <- repository_identity(pull["base"]),
         true <- base_repository.id == source_repository_id,
         true <- base_repository.full_name == source_full_name,
         true <- consistent_repository_identities?(head_repository, base_repository) do
      issue_body = normalize_body(issue_body)
      issue_state_reason = if(issue_state_reason, do: Atom.to_string(issue_state_reason))

      snapshot = %{
        "title" => issue_title,
        "body" => issue_body,
        "state" => Atom.to_string(issue_state),
        "state_reason" => issue_state_reason,
        "draft" => mapped.draft,
        "head_ref" => mapped.head_ref,
        "head_sha" => mapped.head_sha,
        "base_ref" => mapped.base_ref,
        "base_sha" => mapped.base_sha
      }

      issue_snapshot = %{
        "title" => issue_title,
        "body" => issue_body,
        "state" => Atom.to_string(issue_state),
        "state_reason" => issue_state_reason,
        "label_github_ids" => label_github_ids,
        "assignee_github_ids" => assignee_github_ids
      }

      merge_state = %{
        "merged_at" => datetime_value(mapped.merged_at),
        "merge_commit_sha" => mapped.merge_commit_sha
      }

      provider_identity = %{
        "github_issue_object_id" => issue_id,
        "github_issue_node_id" => issue_node_id,
        "github_number" => issue_number,
        "head_repository" => Map.take(head_repository, [:id, :node_id]) |> stringify_keys(),
        "base_repository" => Map.take(base_repository, [:id, :node_id]) |> stringify_keys()
      }

      {:ok,
       %{
         github_node_id: pull_node_id,
         github_issue_id: issue_id,
         github_issue_node_id: issue_node_id,
         issue_title: issue_title,
         issue_body: issue_body,
         issue_state: issue_state,
         issue_state_reason: issue_state_reason,
         remote_updated_at: remote_updated_at,
         snapshot: snapshot,
         issue_snapshot: issue_snapshot,
         merge_state: merge_state,
         provider_identity: provider_identity,
         base_github_repository_id: base_repository.id,
         base_github_node_id: base_repository.node_id
       }}
    else
      _invalid -> {:error, :pull_issue_identity_mismatch}
    end
  end

  defp repository_identity(%{
         "repo" => %{"id" => id, "node_id" => node_id, "full_name" => full_name}
       }) do
    with {:ok, id} <- User.id(id),
         {:ok, node_id} <- User.string(node_id, 255, required?: true),
         {:ok, full_name} <- User.string(full_name, 255, required?: true),
         [owner, repository] <- String.split(full_name, "/", parts: 2),
         true <- valid_repository_part?(owner) and valid_repository_part?(repository) do
      {:ok, %{id: id, node_id: node_id, full_name: full_name}}
    else
      _invalid -> {:error, :invalid_repository_identity}
    end
  end

  defp repository_identity(_side), do: {:error, :invalid_repository_identity}

  defp consistent_repository_identities?(%{id: id} = head, %{id: id} = base),
    do: head.node_id == base.node_id and head.full_name == base.full_name

  defp consistent_repository_identities?(_head, _base), do: true

  defp relationship_ids(values) when is_list(values) and length(values) <= 512 do
    values
    |> Enum.reduce_while({:ok, []}, fn
      %{"id" => id}, {:ok, ids} ->
        case User.id(id) do
          {:ok, id} -> {:cont, {:ok, [id | ids]}}
          _invalid -> {:halt, {:error, :invalid_relationships}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_relationships}}
    end)
    |> case do
      {:ok, ids} ->
        ids = Enum.sort(ids)

        if length(ids) == length(Enum.uniq(ids)),
          do: {:ok, ids},
          else: {:error, :invalid_relationships}

      {:error, _} = error ->
        error
    end
  end

  defp relationship_ids(_values), do: {:error, :invalid_relationships}

  defp expected_issue_id(opts) do
    opts
    |> Keyword.get(:expected_issue_id)
    |> User.id()
  end

  defp source_full_name(opts) do
    with value when is_binary(value) <- Keyword.get(opts, :source_full_name),
         [owner, repository] <- String.split(value, "/", parts: 2),
         true <- valid_repository_part?(owner) and valid_repository_part?(repository) do
      {:ok, value}
    else
      _invalid -> {:error, :invalid_source_repository}
    end
  end

  defp valid_repository_part?(value) do
    value != "" and byte_size(value) <= 100 and
      String.match?(value, ~r/^[A-Za-z0-9_.-]+$/)
  end

  defp stringify_keys(map),
    do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp normalize_body(nil), do: nil
  defp normalize_body(""), do: nil
  defp normalize_body(body), do: body

  defp issue_body(nil), do: {:ok, nil}

  defp issue_body(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= 262_144 and
         :binary.match(value, <<0>>) == :nomatch and length(String.codepoints(value)) <= 65_536,
       do: {:ok, value},
       else: :error
  end

  defp issue_body(_value), do: :error

  defp datetime_value(nil), do: nil
  defp datetime_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp classify_pull_shape(payload, source_repository_id) do
    with {:ok, _} <- User.boolean(payload["draft"]),
         {:ok, _} <- User.id(repo_id(payload["head"])),
         {:ok, ^source_repository_id} <- User.id(repo_id(payload["base"])) do
      :ok
    else
      _ -> {:error, :invalid_pull}
    end
  end

  defp validate_pull_refs(payload, source_id, refs, head, base, head_sha, base_sha) do
    if repo_id(payload["head"]) == source_id,
      do: validate_staged_refs(refs, head, base, head_sha, base_sha),
      else: validate_staged_refs(refs, base, base, base_sha, base_sha)
  end

  defp validate_staged_refs(staged_refs, head_ref, base_ref, head_sha, base_sha) do
    cond do
      not Map.has_key?(staged_refs, head_ref) or not Map.has_key?(staged_refs, base_ref) ->
        {:skip, :deleted_branch, %{head_ref: head_ref, base_ref: base_ref}}

      Map.fetch!(staged_refs, head_ref) != head_sha ->
        {:skip, :source_drift,
         %{ref: head_ref, expected: head_sha, observed: Map.fetch!(staged_refs, head_ref)}}

      Map.fetch!(staged_refs, base_ref) != base_sha ->
        {:skip, :source_drift,
         %{ref: base_ref, expected: base_sha, observed: Map.fetch!(staged_refs, base_ref)}}

      true ->
        :ok
    end
  end

  defp merged_fields(%{"merged" => true} = payload) do
    with {:ok, merged_at} <- User.datetime(payload["merged_at"]),
         {:ok, merge_commit_sha} <- oid(payload["merge_commit_sha"]) do
      {:ok, %{merged_at: merged_at, merge_commit_sha: merge_commit_sha}}
    else
      _ -> {:error, :invalid_pull}
    end
  end

  defp merged_fields(_payload), do: {:ok, %{merged_at: nil, merge_commit_sha: nil}}

  defp author_identity(nil), do: {:ok, %{github_user_id: nil, deleted?: true}}

  defp author_identity(%{"id" => id} = user) when is_integer(id) and id > 0 do
    with {:ok, github_user_id} <- User.id(id),
         {:ok, _login} <- User.string(user["login"], 255, required?: true) do
      {:ok, %{github_user_id: github_user_id, deleted?: false}}
    else
      _ -> {:error, :invalid_author}
    end
  end

  defp author_identity(_user), do: {:ok, %{github_user_id: nil, deleted?: true}}

  defp merger_identity(nil), do: {:ok, %{github_user_id: nil, deleted?: false}}

  defp merger_identity(user), do: author_identity(user)

  defp repo_id(%{"repo" => %{"id" => id}}), do: id
  defp repo_id(_), do: nil

  defp branch_ref(ref) when is_binary(ref) do
    case ref do
      "refs/heads/" <> _ -> {:ok, ref}
      name when byte_size(name) > 0 -> {:ok, "refs/heads/#{name}"}
      _ -> :error
    end
  end

  defp branch_ref(_), do: :error

  defp oid(value) when is_binary(value) and byte_size(value) == 40,
    do: if(String.match?(value, ~r/^[0-9a-f]{40}$/), do: {:ok, value}, else: :error)

  defp oid(_value), do: :error

  defp color(value) when is_binary(value) and byte_size(value) == 6,
    do: if(String.match?(value, ~r/^[0-9a-f]{6}$/), do: {:ok, value}, else: :error)

  defp color(_value), do: :error

  defp issue_state("open"), do: {:ok, :open}
  defp issue_state("closed"), do: {:ok, :closed}
  defp issue_state(_value), do: :error

  defp issue_state_reason(_payload, :open), do: {:ok, nil}

  defp issue_state_reason(payload, :closed) do
    case payload["state_reason"] do
      "completed" -> {:ok, :completed}
      "not_planned" -> {:ok, :not_planned}
      "reopened" -> {:ok, :reopened}
      nil -> {:ok, :completed}
      _ -> :error
    end
  end

  defp unsupported_issue_categories(payload) do
    categories = []

    categories =
      if payload["locked"] == true,
        do: ["locking" | categories],
        else: categories

    categories =
      if not is_nil(payload["milestone"]),
        do: ["milestones" | categories],
        else: categories

    categories
  end

  defp unsupported_pull_categories(payload) do
    unsupported_issue_categories(payload)
  end
end
