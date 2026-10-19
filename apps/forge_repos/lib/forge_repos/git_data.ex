defmodule ForgeRepos.GitData do
  @moduledoc "Authorized Git-data operations; storage is resolved only after domain and PAT checks."
  alias ForgeAccounts.{APIScope, User}
  alias Fornacast.{Page, Repo}

  def authorize_read_target(actor, key, owner, repo, _metadata) do
    with {:ok, actor} <- canonical_actor(actor),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read),
         :ok <- scope(key, :repository_read, repository.visibility) do
      {:ok, repository}
    end
  end

  def authorize_mutation_target(nil, _key, _owner, _repo, _metadata),
    do: {:error, :requires_authentication}

  def authorize_mutation_target(actor, key, owner, repo, metadata) do
    with {:ok, repository} <- authorize_read_target(actor, key, owner, repo, metadata),
         :ok <- scope(key, :repository_mutation, repository.visibility),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_write) do
      {:ok, repository}
    end
  end

  def list_branches(actor, key, owner, repo, filters, metadata) do
    read(actor, key, owner, repo, metadata, fn _repository, path, opts ->
      with {:ok, options} <- list_options(filters),
           {:ok, protected} <- protected_filter(filters),
           {:ok, page} <- GitCore.branch_page(path, Keyword.merge(opts, options)) do
        if protected == true,
          do: {:ok, %Page{entries: [], total: 0, page: page.page, per_page: page.per_page}},
          else: {:ok, struct!(Page, page)}
      end
    end)
  end

  def get_branch(actor, key, owner, repo, name, metadata) do
    read(actor, key, owner, repo, metadata, fn _repository, path, opts ->
      with {:ok, ref} <- branch_ref(name),
           {:ok, commit} <- GitCore.GitData.commit_value(path, ref, opts) do
        {:ok, %{name: name, ref: ref, oid: commit.oid, protected: false, commit: commit}}
      end
    end)
  end

  def get_ref(actor, key, owner, repo, name, metadata) do
    read(actor, key, owner, repo, metadata, fn _repository, path, opts ->
      ref = if String.starts_with?(name, "refs/"), do: name, else: "refs/" <> name

      with {:ok, refs} <- GitCore.GitData.refs(path, opts) do
        case Enum.find(refs, fn {full, _, _} -> full == ref end) do
          {^ref, oid, kind} -> {:ok, %{ref: ref, oid: oid, kind: kind}}
          nil -> {:error, :not_found}
        end
      end
    end)
  end

  def list_commits(actor, key, owner, repo, filters, metadata) do
    read(actor, key, owner, repo, metadata, fn repository, path, opts ->
      with {:ok, page} <- list_options(filters),
           {:ok, since} <- timestamp(filters["since"], "since"),
           {:ok, until} <- timestamp(filters["until"], "until"),
           {:ok, sha} <- optional_string(filters, "sha", repository.default_branch),
           {:ok, filter_path} <- optional_string(filters, "path", ""),
           {:ok, author} <- optional_string(filters, "author", nil),
           :ok <- valid_path(filter_path, true),
           {:ok, result} <-
             GitCore.commit_page(
               path,
               Keyword.merge(
                 opts,
                 page ++
                   [
                     sha: sha,
                     path: filter_path,
                     author: author_email(author),
                     since: since,
                     until: until
                   ]
               )
             ) do
        {:ok, struct!(Page, result)}
      end
    end)
  end

  def get_commit(actor, key, owner, repo, ref, metadata) do
    read(actor, key, owner, repo, metadata, fn _repository, path, opts ->
      GitCore.commit_detail(path, ref, opts)
    end)
  end

  def get_content(actor, key, owner, repo, content_path, filters, metadata) do
    read(actor, key, owner, repo, metadata, fn repository, path, opts ->
      with :ok <- valid_path(content_path, true),
           {:ok, ref} <- optional_string(filters, "ref", repository.default_branch),
           do: GitCore.content(path, ref, content_path, opts)
    end)
  end

  def scope(nil, :repository_read, :public), do: :ok
  def scope(nil, _, _), do: {:error, :requires_authentication}

  def scope(key, action, visibility) do
    case APIScope.authorize(key, action, visibility) do
      :ok ->
        :ok

      {:error, :insufficient_scope} ->
        {:error, {:insufficient_scope, APIScope.accepted_scopes(action, visibility)}}
    end
  end

  def branch_ref(name) when is_binary(name) do
    ref = if String.starts_with?(name, "refs/heads/"), do: name, else: "refs/heads/" <> name
    if valid_ref?(ref), do: {:ok, ref}, else: invalid("Reference", "ref")
  end

  def branch_ref(_), do: invalid("Reference", "ref")

  def valid_ref?(ref) do
    is_binary(ref) and byte_size(ref) <= 255 and String.starts_with?(ref, "refs/heads/") and
      not String.ends_with?(ref, [".", "/", ".lock"]) and
      not String.contains?(ref, ["..", "@{", "\\", "%"]) and
      not Regex.match?(~r/[\x00-\x20\x7f~^:?*\[]/, ref) and
      Enum.all?(
        String.split(ref, "/"),
        &(&1 != "" and not String.starts_with?(&1, ".") and not String.ends_with?(&1, ".lock"))
      )
  end

  def valid_path(value, root \\ false) do
    if is_binary(value) and String.valid?(value) and value == String.normalize(value, :nfc) and
         byte_size(value) <= 4096 and not String.contains?(value, ["\\", <<0>>]) and
         ((value == "" and root) or
            (length(String.split(value, "/")) <= 256 and
               Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", ".."])))),
       do: :ok,
       else: invalid("Content", "path")
  end

  def normalize({:error, %GitCore.Error{kind: kind}})
      when kind in [:ref_not_found, :commit_not_found, :path_not_found, :empty_repository],
      do: {:error, :not_found}

  def normalize({:error, %GitCore.Error{kind: :blob_too_large}}),
    do: {:error, {:payload_too_large, :blob}}

  def normalize({:error, %GitCore.Error{kind: kind}}), do: {:error, {:unavailable, kind}}
  def normalize(value), do: value

  def invalid(resource, field, code \\ :invalid),
    do: {:error, {:validation, [%{resource: resource, field: field, code: code}]}}

  defp read(actor, key, owner, repo, metadata, operation) do
    with {:ok, repository} <- authorize_read_target(actor, key, owner, repo, metadata) do
      deadline = System.monotonic_time(:millisecond) + GitCore.Limits.get(:scan_deadline_ms)

      ForgeRepos.with_repository_read(repository, deadline, fn handle ->
        with {:ok, current} <- authorize_read_target(actor, key, owner, repo, metadata),
             true <- current.id == repository.id and current.generation == repository.generation do
          operation.(current, ForgeRepos.repository_read_path(handle),
            deadline: deadline,
            deadline_ms: max(deadline - System.monotonic_time(:millisecond), 0)
          )
        else
          false -> {:error, :not_found}
          error -> error
        end
      end)
      |> normalize()
    end
  end

  defp canonical_actor(nil), do: {:ok, nil}

  defp canonical_actor(%User{id: id}) do
    case Repo.get_by(User, id: id, kind: :user, state: :active) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :forbidden}
    end
  end

  defp canonical_actor(_), do: {:error, :forbidden}

  defp list_options(filters) do
    with {:ok, page} <- positive(filters["page"], 1, 18_446_744_073_709_551_615),
         {:ok, per_page} <- positive(filters["per_page"], 30, 100),
         do: {:ok, [page: page, per_page: per_page]}
  end

  defp positive(nil, default, _), do: {:ok, default}

  defp positive(value, _, maximum) when is_binary(value) do
    field = if maximum == 100, do: "per_page", else: "page"

    if Regex.match?(~r/\A[0-9]+\z/, value) do
      case Integer.parse(value) do
        {number, ""} when number > 0 and number <= maximum -> {:ok, number}
        _ -> invalid("Pagination", field)
      end
    else
      invalid("Pagination", field)
    end
  end

  defp positive(_, _, _), do: invalid("Pagination", "page")
  defp protected_filter(%{"protected" => "true"}), do: {:ok, true}
  defp protected_filter(%{"protected" => "false"}), do: {:ok, false}
  defp protected_filter(%{"protected" => _}), do: invalid("Branch", "protected")
  defp protected_filter(_), do: {:ok, nil}

  defp optional_string(filters, field, default) do
    case Map.get(filters, field, default) do
      nil -> {:ok, nil}
      value when is_binary(value) and byte_size(value) <= 4096 -> {:ok, value}
      _ -> invalid("Repository", field)
    end
  end

  defp timestamp(nil, _), do: {:ok, nil}

  defp timestamp(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, DateTime.to_unix(dt)}
      _ -> invalid("Commit", field)
    end
  end

  defp timestamp(_, field), do: invalid("Commit", field)
  defp author_email(nil), do: nil

  defp author_email(value) do
    case ForgeAccounts.get_user_by_username(value) do
      %User{email: email} -> email
      _ -> value
    end
  end
end
