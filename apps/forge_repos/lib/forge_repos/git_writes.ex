defmodule ForgeRepos.GitWrites do
  @moduledoc "Durable object ingestion, exact ref publication and recoverable bookkeeping."
  alias ForgeRepos.{GitData, GitWriteOperation, GitWriteRecovery}
  alias Fornacast.{OperationLease, Repo}

  if Mix.env() == :test do
    @before_publish_hook {__MODULE__, :before_publish_hook}
    @doc false
    def with_test_before_publish_hook(hook, fun)
        when is_function(hook, 0) and is_function(fun, 0) do
      previous = Process.get(@before_publish_hook)
      Process.put(@before_publish_hook, hook)

      try do
        fun.()
      after
        if previous,
          do: Process.put(@before_publish_hook, previous),
          else: Process.delete(@before_publish_hook)
      end
    end

    defp before_publish, do: Process.get(@before_publish_hook, fn -> :ok end).()
  else
    defp before_publish, do: :ok
  end

  def create_ref(actor, key, repository, attrs, metadata) do
    with :ok <- mutation_scope(actor, key, repository),
         ref when is_binary(ref) <- attrs["ref"],
         true <- GitData.valid_ref?(ref),
         {:ok, oid} <- oid(attrs["sha"]) do
      fenced(
        repository,
        :ref,
        fn path, deadline ->
          with :ok <- mutation_scope(actor, key, repository),
               {:ok, nil} <- GitCore.exact_ref(path, ref, deadline_ms: remaining(deadline)),
               {:ok, _commit} <-
                 GitCore.GitData.commit_value(path, oid, deadline_ms: remaining(deadline)),
               :ok <-
                 persist(
                   actor,
                   repository,
                   :ref_create,
                   ref,
                   nil,
                   oid,
                   nil,
                   metadata,
                   path,
                   deadline,
                   fn -> mutation_scope(actor, key, repository) end
                 ) do
            {:ok, %{ref: ref, oid: oid, kind: "commit"}}
          else
            {:ok, _existing} -> GitData.invalid("Reference", "ref", :already_exists)
            error -> error
          end
        end,
        &write_error/1
      )
    else
      {:error, _} = error -> error
      _ -> GitData.invalid("Reference", "ref")
    end
  end

  def update_ref(actor, key, repository, name, attrs, metadata) do
    ref = if String.starts_with?(name, "refs/"), do: name, else: "refs/" <> name

    with :ok <- mutation_scope(actor, key, repository),
         true <- GitData.valid_ref?(ref),
         true <- Map.get(attrs, "force", false) == false,
         {:ok, proposed} <- oid(attrs["sha"]) do
      fenced(
        repository,
        :ref,
        fn path, deadline ->
          with :ok <- mutation_scope(actor, key, repository),
               {:ok, expected} when not is_nil(expected) <-
                 GitCore.exact_ref(path, ref, deadline_ms: remaining(deadline)),
               {:ok, _commit} <-
                 GitCore.GitData.commit_value(path, proposed, deadline_ms: remaining(deadline)),
               {:ok, true} <-
                 GitCore.is_ancestor(path, expected, proposed, deadline_ms: remaining(deadline)),
               :ok <-
                 persist(
                   actor,
                   repository,
                   :ref_update,
                   ref,
                   expected,
                   proposed,
                   nil,
                   metadata,
                   path,
                   deadline,
                   fn -> mutation_scope(actor, key, repository) end
                 ) do
            {:ok, %{ref: ref, oid: proposed, kind: "commit"}}
          else
            {:ok, false} -> {:error, {:conflict, :non_fast_forward}}
            {:ok, nil} -> GitData.invalid("Reference", "ref")
            error -> error
          end
        end,
        &write_error/1
      )
    else
      {:error, _} = error -> error
      _ -> GitData.invalid("Reference", "ref")
    end
  end

  def put_content(actor, key, repository, content_path, attrs, metadata) do
    with :ok <- mutation_scope(actor, key, repository),
         do:
           content(actor, repository, content_path, attrs, metadata, :put, fn ->
             mutation_scope(actor, key, repository)
           end)
  end

  def delete_content(actor, key, repository, content_path, attrs, metadata) do
    with :ok <- mutation_scope(actor, key, repository),
         do:
           content(actor, repository, content_path, attrs, metadata, :delete, fn ->
             mutation_scope(actor, key, repository)
           end)
  end

  def initialize_repository(actor, repository, metadata) do
    content(
      actor,
      repository,
      "README.md",
      %{"message" => "Initial commit", "decoded_content" => "# " <> repository.name <> "\n"},
      metadata,
      :initialize,
      fn ->
        case ForgeRepos.fetch_authorized_repository_by_id(actor, repository.id, :repository_write) do
          {:ok, _} -> :ok
          error -> error
        end
      end
    )
    |> case do
      {:ok, _, _, _} -> {:ok, Repo.get!(ForgeRepos.Repository, repository.id)}
      {:error, _} = error -> error
    end
  end

  defp content(actor, repository, content_path, attrs, metadata, mode, authorize) do
    with :ok <- GitData.valid_path(content_path),
         {:ok, ref} <- GitData.branch_ref(Map.get(attrs, "branch", repository.default_branch)),
         {:ok, author} <- signature(actor, attrs["author"]),
         {:ok, committer} <- signature(actor, attrs["committer"]) do
      fenced(
        repository,
        :content,
        fn path, deadline ->
          with :ok <- authorize.(),
               {:ok, expected} <- GitCore.exact_ref(path, ref, deadline_ms: remaining(deadline)),
               :ok <- require_branch(expected, mode),
               {:ok, action, old_blob} <-
                 content_action(path, expected, content_path, attrs["sha"], mode, deadline),
               {:ok, plan} <-
                 GitCore.plan_content_change(
                   path,
                   %{
                     action: action,
                     ref: ref,
                     path: content_path,
                     expected_ref_oid: expected,
                     expected_blob_oid: old_blob,
                     content: Map.get(attrs, "decoded_content", ""),
                     message: attrs["message"],
                     author: author,
                     committer: committer
                   },
                   deadline_ms: remaining(deadline)
                 ),
               :ok <-
                 persist(
                   actor,
                   repository,
                   content_kind(action),
                   ref,
                   expected,
                   plan.proposed_commit_oid,
                   plan,
                   metadata,
                   path,
                   deadline,
                   authorize
                 ),
               {:ok, commit} <-
                 GitCore.GitData.commit_value(path, plan.proposed_commit_oid,
                   deadline_ms: remaining(deadline)
                 ) do
            entry =
              if action == :delete,
                do: nil,
                else: %GitCore.ContentEntry{
                  type: "file",
                  name: Path.basename(content_path),
                  path: content_path,
                  oid: plan.proposed_blob_oid,
                  size: byte_size(attrs["decoded_content"]),
                  mode: "100644"
                }

            {:ok, if(action == :create, do: :created, else: :updated), entry, commit}
          end
        end,
        &write_error/1
      )
    end
  end

  defp content_action(_path, nil, _content_path, nil, :initialize, _deadline),
    do: {:ok, :create, nil}

  defp content_action(path, expected, content_path, supplied, mode, deadline) do
    case GitCore.GitData.content_metadata(path, expected, content_path,
           deadline_ms: remaining(deadline)
         ) do
      {:ok, false, [%GitCore.ContentEntry{type: "file", oid: blob}]} ->
        cond do
          is_nil(supplied) -> GitData.invalid("Content", "sha", :missing_field)
          String.downcase(supplied) != blob -> {:error, {:conflict, :sha_mismatch}}
          true -> {:ok, if(mode == :delete, do: :delete, else: :update), blob}
        end

      {:error, %GitCore.Error{kind: :path_not_found}} when mode != :delete ->
        if is_nil(supplied), do: {:ok, :create, nil}, else: GitData.invalid("Content", "sha")

      {:ok, _, _} ->
        GitData.invalid("Content", "path")

      error ->
        GitData.normalize(error)
    end
  end

  defp persist(
         actor,
         repository,
         kind,
         ref,
         expected,
         proposed,
         plan,
         metadata,
         path,
         deadline,
         authorize
       ) do
    request_id =
      :crypto.hash(:sha256, [
        to_string(actor.id),
        ":",
        to_string(repository.id),
        ":",
        metadata[:request_id] || Ecto.UUID.generate()
      ])
      |> Base.url_encode64(padding: false)

    with {:ok, operation} <-
           %GitWriteOperation{}
           |> GitWriteOperation.changeset(%{
             repository_id: repository.id,
             actor_user_id: actor.id,
             request_id: request_id,
             kind: kind,
             state: :prepared,
             target_ref: ref,
             expected_oid: expected,
             proposed_oid: proposed
           })
           |> Repo.insert(),
         owner = "git_data:" <> Ecto.UUID.generate(),
         {:ok, claimed} <- OperationLease.claim(GitWriteOperation, operation.id, owner, now(), 65) do
      try do
        with :ok <- check_deadline(deadline),
             :ok <- authorize.(),
             :ok <- ingest(path, plan, deadline),
             {:ok, written} <-
               OperationLease.update_owned(GitWriteOperation, claimed, object_written(plan),
                 now: now(),
                 lease_seconds: 65
               ),
             :ok <- check_deadline(deadline),
             :ok <- authorize.(),
             :ok <- before_publish(),
             {:ok, ^proposed} <- publish_ref(path, ref, expected, proposed, written, deadline),
             {:ok, _advanced} <-
               OperationLease.update_owned(GitWriteOperation, written, state: :ref_advanced),
             :ok <- GitWriteRecovery.reconcile_repository_locked(repository, path, deadline),
             %GitWriteOperation{state: :bookkeeping_complete} <-
               Repo.get(GitWriteOperation, operation.id) do
          :ok
        else
          {:error, _} = error -> error
          _ -> {:error, {:unavailable, :git_write}}
        end
      after
        case Repo.get(GitWriteOperation, operation.id) do
          %GitWriteOperation{lease_owner: ^owner} = current ->
            OperationLease.release(GitWriteOperation, current)

          _ ->
            :ok
        end
      end
    else
      _ -> {:error, {:unavailable, :git_write}}
    end
  end

  defp publish_ref(path, ref, expected, proposed, operation, deadline) do
    case GitCore.compare_and_swap_ref(path, ref, expected, proposed, :fast_forward,
           deadline_ms: remaining(deadline)
         ) do
      {:error, %GitCore.Error{kind: kind}} = error
      when kind in [:stale_ref, :non_fast_forward, :ref_exists] ->
        # These native errors prove this CAS never published. Unknown outcomes
        # retain their evidence for reconciliation instead of claiming failure.
        reason = if kind == :non_fast_forward, do: "non_fast_forward", else: "cas_conflict"

        case OperationLease.update_owned(GitWriteOperation, operation,
               state: :failed,
               failure_reason: reason
             ) do
          {:ok, _failed} -> error
          _ -> {:error, {:unavailable, :git_write}}
        end

      result ->
        result
    end
  end

  defp ingest(_path, nil, _deadline), do: :ok

  defp ingest(path, plan, deadline) do
    with {:ok, _} <- GitCore.write_content_change(path, plan, deadline_ms: remaining(deadline)),
         do: :ok
  end

  defp object_written(nil), do: [state: :object_written]
  defp object_written(%{action: :delete}), do: [state: :object_written]
  defp object_written(plan), do: [state: :object_written, result_blob_oid: plan.proposed_blob_oid]
  defp content_kind(:create), do: :content_create
  defp content_kind(:update), do: :content_update
  defp content_kind(:delete), do: :content_delete
  defp require_branch(nil, :initialize), do: :ok
  defp require_branch(nil, _), do: GitData.invalid("Content", "branch")
  defp require_branch(_, _), do: :ok

  defp fenced(repository, kind, operation, error_mapper) do
    ForgeRepos.with_write_fence(repository, kind, fn path, remaining ->
      operation.(path, System.monotonic_time(:millisecond) + remaining)
    end)
    |> case do
      {:ok, _, _, _} = result -> result
      {:ok, _} = result -> result
      error -> error_mapper.(error)
    end
  end

  defp mutation_scope(actor, key, repository) do
    with {:ok, current} <-
           ForgeRepos.fetch_authorized_repository_by_id(actor, repository.id, :repository_write),
         do: GitData.scope(key, :repository_mutation, current.visibility)
  end

  defp oid(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\z/, value),
      do: {:ok, String.downcase(value)},
      else: GitData.invalid("Reference", "sha")
  end

  defp oid(_), do: GitData.invalid("Reference", "sha")

  defp signature(actor, nil) do
    {:ok,
     %GitCore.Signature{
       name: actor.display_name || actor.username,
       email: actor.email,
       seconds: DateTime.to_unix(DateTime.utc_now()),
       offset_minutes: 0
     }}
  end

  defp signature(_actor, value) when is_map(value) do
    with name when is_binary(name) <- value["name"],
         email when is_binary(email) <- value["email"],
         true <- byte_size(name) in 1..255 and byte_size(email) in 1..320,
         false <- String.contains?(name <> email, [<<0>>, "\r", "\n", "<", ">"]),
         {:ok, date} <- signature_date(value["date"]) do
      {:ok,
       %GitCore.Signature{
         name: name,
         email: email,
         seconds: DateTime.to_unix(date),
         offset_minutes: 0
       }}
    else
      _ -> GitData.invalid("Content", "author")
    end
  end

  defp signature(_, _), do: GitData.invalid("Content", "author")
  defp signature_date(nil), do: {:ok, DateTime.utc_now()}

  defp signature_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp signature_date(_), do: :error

  defp write_error({:error, %GitCore.Error{kind: kind}})
       when kind in [:stale_ref, :non_fast_forward], do: {:error, {:conflict, kind}}

  defp write_error({:error, %GitCore.Error{kind: kind}})
       when kind in [
              :ref_exists,
              :invalid_ref,
              :invalid_oid,
              :target_not_commit,
              :invalid_input,
              :commit_not_found
            ],
       do: GitData.invalid("Reference", "sha")

  defp write_error({:ok, false}), do: {:error, {:conflict, :non_fast_forward}}
  defp write_error({:ok, nil}), do: GitData.invalid("Reference", "ref")
  defp write_error(value), do: GitData.normalize(value)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp check_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, {:unavailable, :deadline}})
end
