defmodule ForgeGitHub.RepositoryMetadataSyncWorker do
  @moduledoc "Bounded executor for leased canonical repository-metadata reconciliation."

  use GenServer

  alias ForgeGitHub.{
    Client,
    Error,
    InstallationToken,
    InstallationTokenBroker,
    RepositoryClient,
    RepositoryMetadataProjection
  }

  @kind "reconcile.repository.metadata"
  @default_interval_ms 1_000
  @default_lease_seconds 60
  @operations_per_run 1

  def start_link(options) when is_list(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc false
  def run_once(owner, options \\ [])

  def run_once(owner, options) when is_binary(owner) and is_list(options) do
    now = callback(options, :now, &DateTime.utc_now/0).()
    claim = callback(options, :claim, &ForgeMirrors.claim_operations/5)

    with {:ok, operations} <-
           claim.(
             owner,
             now,
             Keyword.get(options, :lease_seconds, @default_lease_seconds),
             @operations_per_run,
             [@kind]
           ) do
      {:ok, Enum.map(operations, &{&1.id, process_operation(&1, now, options)})}
    end
  end

  def run_once(_, _), do: {:error, :invalid_argument}

  @doc false
  def process_operation(%{kind: @kind} = operation, %DateTime{} = now, options) do
    context = callback(options, :context, &ForgeMirrors.repository_metadata_operation_context/1)
    token_fetch = callback(options, :token_fetch, &InstallationTokenBroker.fetch/2)
    record = callback(options, :record, &ForgeMirrors.record_repository_metadata_observation/3)

    with {:ok, sync} <- context.(operation),
         %InstallationToken{token: token} <-
           token_fetch.(sync.github_installation_id, %{permissions: %{"metadata" => "read"}}),
         {:ok, remote} <- fetch_repository(token, sync, options),
         {:ok, remote} <- RepositoryMetadataProjection.from_remote(remote),
         {:ok, result} <- record.(operation, remote, now) do
      execute_result(result, sync, now, options)
    else
      {:error, %Error{} = error} -> persist_error(operation, now, error, options)
      {:error, reason} -> persist_reason(operation, now, reason, options)
      _ -> persist_reason(operation, now, :credential_unavailable, options)
    end
  rescue
    _ -> persist_reason(operation, now, :worker_crash, options)
  end

  def process_operation(_, _, _), do: {:error, :invalid_argument}

  defp fetch_repository(token, sync, options) do
    repository_fetch = callback(options, :repository_fetch, &Client.repository/4)

    sync
    |> repository_candidates()
    |> Enum.reduce_while(nil, fn repository, _last_error ->
      case repository_fetch.(token, sync.remote_owner, repository,
             gate_key: {:github_installation, sync.github_installation_id}
           ) do
        {:ok, remote} ->
          if expected_repository_identity?(remote, sync),
            do: {:halt, {:ok, remote}},
            else: {:cont, {:error, Error.new(:not_found)}}

        {:error, %Error{kind: :not_found}} = error ->
          {:cont, error}

        {:error, _reason} = error ->
          {:halt, error}

        _invalid ->
          {:halt, {:error, Error.new(:invalid_response)}}
      end
    end)
    |> case do
      nil -> {:error, Error.new(:invalid_request)}
      result -> result
    end
  end

  defp repository_candidates(sync) do
    target = get_in(sync, [:effect_marker, "target", "name"])

    [target, sync.remote_repository]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp expected_repository_identity?(remote, sync) do
    remote_id = Map.get(remote, :id, Map.get(remote, "id"))
    remote_node = Map.get(remote, :node_id, Map.get(remote, "node_id"))

    remote_id == sync.github_repository_id and remote_node == sync.github_node_id
  end

  defp execute_result(
         %{action: :update_remote, operation: operation, target: target},
         sync,
         now,
         options
       ) do
    token_fetch = callback(options, :token_fetch, &InstallationTokenBroker.fetch/2)

    repository_update =
      callback(options, :repository_update, &RepositoryClient.update_repository/5)

    confirm_effect =
      callback(options, :confirm_effect, &ForgeMirrors.record_repository_metadata_observation/3)

    with %InstallationToken{token: token} <-
           token_fetch.(sync.github_installation_id, %{
             permissions: %{"administration" => "write"}
           }),
         {:ok, remote} <-
           repository_update.(token, sync.remote_owner, sync.remote_repository, target,
             gate_key: {:github_installation, sync.github_installation_id}
           ),
         {:ok, remote} <- RepositoryMetadataProjection.from_remote(remote),
         {:ok, result} <- confirm_effect.(operation, remote, now) do
      {:ok, result}
    else
      {:error, %Error{} = error} -> persist_effect_error(operation, now, error, options)
      {:error, reason} -> persist_effect_reason(operation, now, reason, options)
      _ -> persist_effect_reason(operation, now, :credential_unavailable, options)
    end
  rescue
    _ -> persist_effect_reason(operation, now, :worker_crash, options)
  end

  defp execute_result(result, _sync, _now, _options), do: {:ok, result}

  @impl true
  def init(options) do
    state = %{
      enabled: Keyword.get(options, :enabled, true),
      interval_ms: Keyword.get(options, :interval_ms, @default_interval_ms),
      owner:
        Keyword.get(options, :owner, "repository-metadata-#{System.unique_integer([:positive])}"),
      options: Keyword.drop(options, [:enabled, :interval_ms, :owner, :name, :task_starter]),
      task_starter:
        Keyword.get(options, :task_starter, fn task ->
          Task.Supervisor.start_child(ForgeGitHub.RepositoryMetadataTaskSupervisor, task)
        end),
      task_ref: nil
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{task_ref: nil} = state) do
    case start_task(state.task_starter, fn -> run_once(state.owner, state.options) end) do
      {:ok, pid} ->
        {:noreply, %{state | task_ref: Process.monitor(pid)}}

      _ ->
        schedule(state.interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task_ref: ref} = state) do
    schedule(state.interval_ms)
    {:noreply, %{state | task_ref: nil}}
  end

  defp persist_error(operation, now, %Error{kind: kind, retry_at: retry_at}, options)
       when kind in [:primary_rate_limit, :secondary_rate_limit],
       do: retry(operation, now, retry_at || DateTime.add(now, 60), Atom.to_string(kind), options)

  defp persist_error(operation, now, %Error{kind: kind}, options)
       when kind in [
              :transport,
              :timeout,
              :host_unavailable,
              :upstream_unavailable,
              :request_gate_busy
            ],
       do: retry(operation, now, DateTime.add(now, 60), "network", options)

  defp persist_error(operation, now, %Error{kind: :invalid_credential}, options),
    do: fail(operation, now, "credential_revoked", options)

  defp persist_error(operation, now, _error, options),
    do: fail(operation, now, "provider_validation", options)

  defp persist_reason(operation, now, reason, options)
       when reason in [:busy, :timeout, :unavailable, :invalidated, :worker_crash],
       do: retry(operation, now, DateTime.add(now, 60), "network", options)

  defp persist_reason(operation, now, :revoked, options),
    do: fail(operation, now, "credential_revoked", options)

  defp persist_reason(operation, now, :credential_unavailable, options),
    do: fail(operation, now, "credential_revoked", options)

  defp persist_reason(operation, now, :invalid_remote_resource, options),
    do: fail(operation, now, "provider_validation", options)

  defp persist_reason(operation, now, :invalid_remote_repository, options),
    do: fail(operation, now, "provider_validation", options)

  defp persist_reason(operation, now, _reason, options),
    do: fail(operation, now, "local_validation", options)

  defp persist_effect_error(operation, now, %Error{kind: kind, retry_at: retry_at}, options)
       when kind in [:primary_rate_limit, :secondary_rate_limit] do
    defer_effect(
      operation,
      now,
      retry_at || DateTime.add(now, 60),
      Atom.to_string(kind),
      options
    )
  end

  defp persist_effect_error(operation, now, %Error{kind: kind}, options)
       when kind in [
              :transport,
              :timeout,
              :host_unavailable,
              :upstream_unavailable,
              :request_gate_busy
            ],
       do: defer_effect(operation, now, DateTime.add(now, 60), "network", options)

  defp persist_effect_error(operation, now, %Error{kind: :invalid_credential}, options),
    do: fail(operation, now, "credential_revoked", options)

  defp persist_effect_error(operation, now, _error, options),
    do: fail(operation, now, "provider_validation", options)

  defp persist_effect_reason(operation, now, reason, options)
       when reason in [:busy, :timeout, :unavailable, :invalidated, :worker_crash],
       do: defer_effect(operation, now, DateTime.add(now, 60), "network", options)

  defp persist_effect_reason(operation, now, reason, options)
       when reason in [:revoked, :credential_unavailable],
       do: fail(operation, now, "credential_revoked", options)

  defp persist_effect_reason(operation, now, reason, options)
       when reason in [:invalid_remote_resource, :invalid_remote_repository],
       do: fail(operation, now, "provider_validation", options)

  defp persist_effect_reason(operation, now, _reason, options),
    do: fail(operation, now, "provider_validation", options)

  defp defer_effect(operation, now, retry_at, failure_class, options) do
    callback(options, :defer_effect, &ForgeMirrors.defer_repository_metadata_effect/4).(
      operation,
      now,
      retry_at,
      failure_class
    )
  end

  defp retry(operation, now, retry_at, failure_class, options) do
    callback(options, :retry, &ForgeMirrors.retry_operation/5).(
      operation,
      now,
      retry_at,
      failure_class,
      []
    )
  end

  defp fail(operation, now, failure_class, options) do
    callback(options, :fail, &ForgeMirrors.fail_operation/4).(operation, now, failure_class, nil)
  end

  defp callback(options, key, default), do: Keyword.get(options, key, default)

  defp start_task(task_starter, task) do
    task_starter.(task)
  catch
    :exit, _reason -> {:error, :task_supervisor_unavailable}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
