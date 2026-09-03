defmodule ForgeImports.GitHub.MetadataMapper do
  @moduledoc "Pure GitHub metadata normalization and skip classification for imports."

  alias ForgeImports.GitHub.User

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
    if Map.has_key?(payload, "pull_request") and not is_nil(payload["pull_request"]) do
      {:skip, :pull_request_issue, %{number: payload["number"]}}
    else
      map_issue(payload)
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
  def pull(%{} = payload, source_repository_id, opts \\ []) when is_integer(source_repository_id) do
    staged_refs = Keyword.get(opts, :staged_refs, %{})

    with :ok <- classify_pull_shape(payload, source_repository_id),
         {:ok, head_ref} <- branch_ref(payload["head"]["ref"]),
         {:ok, base_ref} <- branch_ref(payload["base"]["ref"]),
         {:ok, head_sha} <- oid(payload["head"]["sha"]),
         {:ok, base_sha} <- oid(payload["base"]["sha"]),
         :ok <- validate_staged_refs(staged_refs, head_ref, base_ref, head_sha, base_sha),
         {:ok, normalized} <- map_pull(payload, head_ref, base_ref, head_sha, base_sha) do
      {:ok, normalized}
    else
      {:skip, code, details} -> {:skip, code, details}
      {:error, code} -> {:error, code}
      _ -> {:error, :invalid_pull}
    end
  end

  def pull(_payload, _source_repository_id, _opts), do: {:error, :invalid_pull}

  defp map_issue(payload) do
    with {:ok, github_id} <- User.id(payload["id"]),
         {:ok, number} <- User.id(payload["number"]),
         {:ok, title} <- User.string(payload["title"], 256, required?: true),
         {:ok, body} <- User.string(payload["body"], 65_536),
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
         {:ok, number} <- User.id(payload["number"]),
         {:ok, title} <- User.string(payload["title"], 256, required?: true),
         {:ok, body} <- User.string(payload["body"], 65_536),
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

  defp classify_pull_shape(payload, source_repository_id) do
    cond do
      payload["draft"] == true ->
        {:skip, :draft_pull, %{number: payload["number"]}}

      repo_id(payload["head"]) != source_repository_id or
          repo_id(payload["base"]) != source_repository_id ->
        {:skip, :cross_repository_pull, %{number: payload["number"]}}

      true ->
        :ok
    end
  end

  defp validate_staged_refs(staged_refs, head_ref, base_ref, head_sha, base_sha) do
    cond do
      not Map.has_key?(staged_refs, head_ref) or not Map.has_key?(staged_refs, base_ref) ->
        {:skip, :deleted_branch, %{head_ref: head_ref, base_ref: base_ref}}

      Map.fetch!(staged_refs, head_ref) != head_sha ->
        {:skip, :source_drift, %{ref: head_ref, expected: head_sha, observed: Map.fetch!(staged_refs, head_ref)}}

      Map.fetch!(staged_refs, base_ref) != base_sha ->
        {:skip, :source_drift, %{ref: base_ref, expected: base_sha, observed: Map.fetch!(staged_refs, base_ref)}}

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
