defmodule ForgeGitHub.PullMergeAdmission do
  @moduledoc """
  Atomic admission and bounded completion wait for mirror-owned pull merges.

  Admission performs no Git or provider effects. One transaction stores the
  scheduler operation, coordinated domain intent, and exact preparation proof.
  The separately supervised merge worker owns every later side effect.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState, PullEligibility, PullMergeBoundary}
  alias ForgePulls.{MergeOperation, PullRequest}
  alias Fornacast.Repo

  @default_await_timeout_ms 15_000
  @maximum_await_timeout_ms 25_000
  @poll_interval_ms 250
  @test_callbacks Mix.env() == :test

  def merge(repository, pull, actor, attrs, request_metadata),
    do: merge(repository, pull, actor, attrs, request_metadata, [])

  @doc false
  def merge(repository, pull, actor, attrs, request_metadata, options)
      when is_list(options) do
    case repository_binding(repository) do
      nil ->
        callback(options, :standalone_merge, &ForgePulls.merge/5).(
          repository,
          pull,
          actor,
          attrs,
          request_metadata
        )

      _binding ->
        with :ok <- worker_available(options),
             {:ok, admission} <- admit(repository, pull, actor, attrs, request_metadata, options),
             :ok <- wake_worker(options) do
          await(admission, options)
        else
          {:error, reason} -> {:error, public_error(reason)}
        end
    end
  end

  @doc false
  def admit(repository, pull, actor, attrs, request_metadata, options \\ [])

  def admit(
        %ForgeRepos.Repository{} = repository,
        %PullRequest{} = pull,
        %ForgeAccounts.User{} = actor,
        attrs,
        request_metadata,
        options
      )
      when is_map(attrs) and is_map(request_metadata) and is_list(options) do
    now = callback(options, :now, fn -> DateTime.utc_now(:second) end).()

    with %DateTime{} <- now,
         %ForgeMirrors.RepositoryMirror{} = binding <- repository_binding(repository),
         true <- repository.allow_merge_commit,
         true <- pull.repository_id == repository.id do
      Repo.transaction(fn ->
        with {:ok, dedupe_key} <- merge_dedupe_key(binding, pull, actor, request_metadata),
             {:ok, request_fingerprint} <-
               ForgePulls.coordinated_merge_request_fingerprint(attrs, request_metadata) do
          case Repo.get_by(MirrorOperation, dedupe_key: dedupe_key) do
            %MirrorOperation{state: state} = operation
            when state in [:processing, :effect_pending, :completed, :failed] ->
              resume_existing(
                operation,
                binding,
                pull,
                actor,
                request_metadata,
                request_fingerprint
              )

            _ ->
              admit_pending(
                binding,
                repository,
                pull,
                actor,
                attrs,
                request_metadata,
                now,
                dedupe_key,
                request_fingerprint
              )
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      false when not repository.allow_merge_commit -> {:error, :merge_commits_disabled}
      false -> {:error, :forbidden}
      nil -> {:error, {:unavailable, :mirror_merge_coordinator}}
      _ -> {:error, {:unavailable, :mirror_merge_coordinator}}
    end
  rescue
    _exception -> {:error, {:unavailable, :mirror_merge_coordinator}}
  catch
    _kind, _reason -> {:error, {:unavailable, :mirror_merge_coordinator}}
  end

  def admit(_repository, _pull, _actor, _attrs, _request_metadata, _options),
    do: {:error, :forbidden}

  defp admit_pending(
         binding,
         repository,
         pull,
         actor,
         attrs,
         request_metadata,
         now,
         dedupe_key,
         request_fingerprint
       ) do
    with {:ok, projection} <- ForgePulls.sync_projection(repository.id, :pull, pull.id),
         :ok <- exact_pull(pull, projection),
         %MirrorResourceState{} = mapping <- pull_mapping(binding.id, pull.id),
         {:ok, proof} <-
           PullEligibility.check(
             binding.id,
             pull.head_repository_id,
             Map.take(pull, [:base_ref, :head_ref, :base_sha, :head_sha])
           ),
         expected <- expected(projection, mapping, proof),
         {:ok, operation} <- enqueue(binding, projection, dedupe_key, now),
         {:ok, admission} <-
           prepare(
             operation,
             expected,
             projection,
             repository,
             actor,
             attrs,
             request_metadata,
             now,
             request_fingerprint
           ) do
      admission
    else
      {:error, reason} -> Repo.rollback(reason)
      nil -> Repo.rollback(:stale_baseline)
      false -> Repo.rollback(:stale_baseline)
      _ -> Repo.rollback(:stale_baseline)
    end
  end

  defp resume_existing(
         operation,
         binding,
         pull,
         actor,
         request_metadata,
         request_fingerprint
       ) do
    with true <-
           operation.organization_mirror_id == binding.organization_mirror_id and
             operation.repository_mirror_id == binding.id and operation.kind == "merge.pull" and
             operation.cursor["pull_id"] == pull.id and
             operation.cursor["issue_id"] == pull.issue_id,
         %MergeOperation{} = intent <-
           Repo.get_by(MergeOperation, coordinator_operation_id: operation.id),
         :ok <- authorize_replay(actor.id, binding.repository_id),
         true <-
           replay_identity?(
             intent,
             operation,
             actor,
             request_metadata,
             request_fingerprint
           ) do
      %{operation: operation, intent: intent}
    else
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:merge_intent_conflict)
    end
  end

  defp prepare(
         operation,
         expected,
         projection,
         repository,
         actor,
         attrs,
         request_metadata,
         now,
         request_fingerprint
       ) do
    case operation.state do
      :pending ->
        signature_time = persisted_signature_time(operation.id) || now

        with {:ok, intent_request} <-
               ForgePulls.coordinated_merge_request(
                 projection,
                 actor,
                 attrs,
                 request_metadata,
                 signature_time
               ) do
          request = %{
            repository_id: repository.id,
            resource_kind: :pull,
            local_resource_id: expected.pull_id,
            expected_local_version: expected.local_version,
            expected_fields: expected.fields,
            expected_merge_state: %{merged_at: nil, merge_commit_sha: nil},
            expected_head_repository_id: expected.pull_eligibility_proof["head"]["repository_id"],
            coordinator_operation_id: operation.id,
            actor_user_id: actor.id,
            request_id: intent_request.request_id,
            commit_intent: intent_request.commit_intent
          }

          domain =
            Multi.new()
            |> ForgePulls.append_prepare_coordinated_merge(:intent, request)

          case Multi.new()
               |> PullMergeBoundary.append_admit(
                 :intent,
                 operation,
                 now,
                 expected,
                 request_fingerprint,
                 domain
               )
               |> Repo.transaction() do
            {:ok, %{intent: intent}} ->
              {:ok, %{operation: Repo.get!(MirrorOperation, operation.id), intent: intent}}

            {:error, _step, reason, _changes} ->
              {:error, reason}
          end
        end

      state when state in [:processing, :effect_pending, :completed, :failed] ->
        with %MergeOperation{} = intent <-
               Repo.get_by(MergeOperation, coordinator_operation_id: operation.id),
             true <-
               replay_identity?(
                 intent,
                 operation,
                 actor,
                 request_metadata,
                 request_fingerprint
               ) do
          {:ok, %{operation: operation, intent: intent}}
        else
          _ -> {:error, :merge_intent_conflict}
        end
    end
  end

  defp enqueue(binding, projection, dedupe_key, now) do
    ForgeMirrors.enqueue_operation(%{
      organization_mirror_id: binding.organization_mirror_id,
      repository_mirror_id: binding.id,
      kind: "merge.pull",
      dedupe_key: dedupe_key,
      cursor: %{
        "issue_id" => projection.issue_id,
        "pull_id" => projection.local_resource_id
      },
      next_attempt_at: now
    })
  end

  defp merge_dedupe_key(binding, pull, actor, request_metadata) do
    safe = ForgePulls.Mutations.safe_request_metadata(request_metadata)

    case safe[:request_id] do
      request_id when is_binary(request_id) and byte_size(request_id) in 1..255 ->
        digest =
          request_id |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)

        {:ok, "pull-merge:#{binding.id}:#{pull.id}:#{actor.id}:#{digest}"}

      _ ->
        {:error, {:validation, [%{resource: "PullRequest", field: "request_id", code: :missing}]}}
    end
  end

  defp expected(projection, mapping, proof) do
    %{
      pull_id: projection.local_resource_id,
      issue_id: projection.issue_id,
      local_version: projection.local_version,
      fields: projection.fields,
      provider_identity: mapping.provider_identity,
      resource_state_lock_version: mapping.lock_version,
      pull_eligibility_proof: json(proof)
    }
  end

  defp exact_pull(pull, projection) do
    expected = %{
      "base_ref" => pull.base_ref,
      "base_sha" => pull.base_sha,
      "head_ref" => pull.head_ref,
      "head_sha" => pull.head_sha
    }

    if projection.local_resource_id == pull.id and
         Map.take(projection.fields, Map.keys(expected)) == expected,
       do: :ok,
       else: {:error, :ref_conflict}
  end

  defp repository_binding(%ForgeRepos.Repository{id: repository_id}) do
    Repo.one(
      from binding in ForgeMirrors.RepositoryMirror,
        where: binding.repository_id == ^repository_id,
        order_by: [desc: binding.id],
        limit: 1
    )
  end

  defp repository_binding(_), do: nil

  defp pull_mapping(binding_id, pull_id) do
    Repo.get_by(MirrorResourceState,
      repository_mirror_id: binding_id,
      resource_kind: :pull,
      local_resource_id: pull_id,
      local_resource_type: "ForgePulls.PullRequest",
      state: :confirmed
    )
  end

  defp persisted_signature_time(operation_id) do
    case Repo.get_by(MergeOperation, coordinator_operation_id: operation_id) do
      %MergeOperation{commit_intent: %{"author" => %{"seconds" => seconds}}}
      when is_integer(seconds) and seconds >= 0 ->
        case DateTime.from_unix(seconds) do
          {:ok, time} -> time
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp replay_identity?(
         intent,
         operation,
         actor,
         request_metadata,
         request_fingerprint
       ) do
    safe = ForgePulls.Mutations.safe_request_metadata(request_metadata)
    preparation = operation.checkpoint["merge_preparation"]

    intent.coordinator_operation_id == operation.id and intent.actor_user_id == actor.id and
      intent.request_id == safe[:request_id] and
      intent.pull_request_id == operation.cursor["pull_id"] and is_map(preparation) and
      preparation["merge_operation_id"] == intent.id and
      preparation["pull_id"] == intent.pull_request_id and
      preparation["issue_id"] == operation.cursor["issue_id"] and
      preparation["request_fingerprint"] == request_fingerprint
  end

  defp authorize_replay(actor_id, repository_id) do
    with %ForgeAccounts.User{state: :active, kind: :user} = actor <-
           Repo.get(ForgeAccounts.User, actor_id),
         %ForgeRepos.Repository{lifecycle: :ready, deleted_at: nil} = repository <-
           Repo.get(ForgeRepos.Repository, repository_id),
         true <- Fornacast.Access.allowed?(actor, :repository_write, repository) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp worker_available(options) do
    if callback(options, :worker_available?, fn ->
         is_pid(Process.whereis(ForgeGitHub.PullMergeWorker))
       end).(),
       do: :ok,
       else: {:error, {:unavailable, :mirror_merge_worker}}
  end

  defp wake_worker(options) do
    callback(options, :wake_worker, fn ->
      if worker = Process.whereis(ForgeGitHub.PullMergeWorker), do: send(worker, :tick)
      :ok
    end).()
  end

  defp await(admission, options) do
    callback(options, :await, &await_default/2).(admission, options)
  end

  defp await_default(admission, options) do
    timeout =
      options
      |> Keyword.get(:await_timeout_ms, @default_await_timeout_ms)
      |> min(@maximum_await_timeout_ms)
      |> max(0)

    await_until(admission, System.monotonic_time(:millisecond) + timeout)
  end

  defp await_until(%{operation: operation, intent: intent} = admission, deadline) do
    operation = Repo.get(MirrorOperation, operation.id)
    intent = Repo.get(MergeOperation, intent.id)
    pull = if intent, do: Repo.get(PullRequest, intent.pull_request_id)

    cond do
      exact_completion?(operation, intent, pull) ->
        {:ok,
         %{
           merged: true,
           message: "Pull Request successfully merged",
           sha: intent.merge_oid
         }}

      match?(%MirrorOperation{failure_disposition: :conflict}, operation) ->
        {:error, :conflict}

      match?(%MirrorOperation{state: :failed}, operation) ->
        {:error, {:unavailable, :mirror_merge_failed}}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:unavailable, :mirror_merge_pending}}

      true ->
        receive do
        after
          @poll_interval_ms -> await_until(admission, deadline)
        end
    end
  end

  defp exact_completion?(
         %MirrorOperation{state: :completed, id: operation_id},
         %MergeOperation{
           state: :completed,
           coordinator_operation_id: operation_id,
           merge_oid: merge_oid,
           pull_request_id: pull_id
         },
         %PullRequest{id: pull_id, merge_commit_sha: merge_oid}
       )
       when is_binary(merge_oid),
       do: true

  defp exact_completion?(_, _, _), do: false

  defp public_error(reason)
       when reason in [
              :merge_intent_conflict,
              :merge_reserved,
              :stale_baseline,
              :stale_merge_identity,
              :ref_effect_pending,
              :ineligible_pull
            ],
       do: :conflict

  defp public_error(:lost_lease), do: {:unavailable, :mirror_merge_pending}
  defp public_error(:permission_missing), do: :forbidden
  defp public_error(:credential_revoked), do: {:unavailable, :mirror_merge_worker}
  defp public_error(reason), do: reason

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()

  defp callback(options, key, default),
    do: if(@test_callbacks, do: Keyword.get(options, key, default), else: default)
end
