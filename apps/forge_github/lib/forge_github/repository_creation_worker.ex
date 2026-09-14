defmodule ForgeGitHub.RepositoryCreationWorker do
  @moduledoc "Crash-recoverable creator for policy-enabled local organization repositories."

  use GenServer

  alias ForgeGitHub.{
    Client,
    Error,
    InstallationToken,
    InstallationTokenBroker,
    RepositoryClient,
    RepositoryMetadataProjection
  }

  alias ForgeMirrors.MirrorOperation

  @kind "sync.repository.create"
  @default_interval_ms 1_000
  @default_lease_seconds 60

  def start_link(options) when is_list(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc false
  def run_once(owner, options \\ [])

  def run_once(owner, options) when is_binary(owner) and is_list(options) do
    now = callback(options, :now, fn -> DateTime.utc_now(:second) end).()
    claim = callback(options, :claim, &ForgeMirrors.claim_operations/5)

    with {:ok, operations} <-
           claim.(owner, now, Keyword.get(options, :lease_seconds, @default_lease_seconds), 1, [
             @kind
           ]) do
      {:ok, Enum.map(operations, &{&1.id, process_operation(&1, now, options)})}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def run_once(_, _), do: {:error, :invalid_argument}

  @doc false
  def process_operation(%MirrorOperation{kind: @kind} = operation, %DateTime{} = now, options) do
    context = callback(options, :context, &ForgeMirrors.repository_creation_context/1)
    token_fetch = callback(options, :token_fetch, &InstallationTokenBroker.fetch/2)

    with {:ok, sync} <- context.(operation),
         %InstallationToken{token: token} <-
           token_fetch.(sync.github_installation_id, %{
             permissions: %{"administration" => "write", "metadata" => "read"}
           }) do
      recover_or_preflight(operation, sync, token, now, options)
    else
      {:error, reason} -> persist_context_reason(operation, now, reason, options)
      _invalid -> persist_context_reason(operation, now, :credential_unavailable, options)
    end
  rescue
    _exception -> persist_context_reason(operation, now, :worker_crash, options)
  end

  def process_operation(_, _, _), do: {:error, :invalid_argument}

  defp persist_context_reason(
         %MirrorOperation{state: :effect_pending} = operation,
         now,
         reason,
         options
       ),
       do: persist_effect_reason(operation, now, reason, options)

  defp persist_context_reason(operation, now, :paused, options),
    do: pause(operation, now, options)

  defp persist_context_reason(operation, now, reason, options),
    do: persist_reason(operation, now, reason, options)

  defp recover_or_preflight(
         %MirrorOperation{state: :effect_pending} = operation,
         sync,
         token,
         now,
         options
       ) do
    case fetch_repository(token, sync, options) do
      {:ok, remote} -> confirm(operation, remote, now, options)
      {:error, %Error{kind: :not_found}} -> create_marked(operation, sync, token, now, options)
      {:error, %Error{} = error} -> persist_effect_error(operation, now, error, options)
      {:error, reason} -> persist_effect_reason(operation, now, reason, options)
    end
  end

  defp recover_or_preflight(operation, sync, token, now, options) do
    case fetch_repository(token, sync, options) do
      {:error, %Error{kind: :not_found}} ->
        mark_effect =
          callback(options, :mark_effect, &ForgeMirrors.mark_repository_creation_effect/3)

        with {:ok, marked} <- mark_effect.(operation, sync, now) do
          create_marked(marked, sync, token, now, options)
        else
          {:error, reason} -> persist_reason(operation, now, reason, options)
        end

      {:ok, existing} ->
        conflict(operation, existing, now, options)

      {:error, %Error{} = error} ->
        persist_error(operation, now, error, options)

      {:error, reason} ->
        persist_reason(operation, now, reason, options)
    end
  end

  defp create_marked(operation, _sync, token, now, options) do
    authorize_effect =
      callback(
        options,
        :authorize_effect,
        &ForgeMirrors.authorize_repository_creation_effect/1
      )

    repository_create =
      callback(options, :repository_create, &RepositoryClient.create_organization_repository/4)

    with {:ok, authorized} <- authorize_effect.(operation) do
      attrs = Map.take(authorized.target, ~w(name description visibility))

      case repository_create.(
             token,
             authorized.github_account_login,
             attrs,
             request_options(authorized)
           ) do
        {:ok, remote} ->
          confirm(operation, remote, now, options)

        {:error, %Error{kind: :unprocessable_entity}} ->
          recover_create_collision(operation, authorized, token, now, options)

        {:error, %Error{} = error} ->
          persist_effect_error(operation, now, error, options)

        {:error, reason} ->
          persist_effect_reason(operation, now, reason, options)

        _invalid ->
          persist_effect_reason(operation, now, :invalid_remote_resource, options)
      end
    else
      {:error, reason} -> persist_effect_reason(operation, now, reason, options)
    end
  end

  defp recover_create_collision(operation, sync, token, now, options) do
    case fetch_repository(token, sync, options) do
      {:ok, remote} ->
        confirm(operation, remote, now, options)

      {:error, %Error{kind: :not_found}} ->
        persist_effect_reason(operation, now, :provider_validation, options)

      {:error, %Error{} = error} ->
        persist_effect_error(operation, now, error, options)

      {:error, reason} ->
        persist_effect_reason(operation, now, reason, options)
    end
  end

  defp fetch_repository(token, sync, options) do
    repository_fetch = callback(options, :repository_fetch, &Client.repository/4)

    repository_fetch.(
      token,
      sync.github_account_login,
      sync.target["name"],
      request_options(sync)
    )
  end

  defp confirm(operation, remote, now, options) do
    confirm = callback(options, :confirm, &ForgeMirrors.confirm_repository_creation/3)

    with {:ok, observation} <- canonical_observation(remote) do
      case confirm.(operation, observation, now) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} when reason in [:namespace_collision, :identity_conflict] ->
          conflict(operation, observation, now, options)

        {:error, reason} ->
          persist_effect_reason(operation, now, reason, options)
      end
    else
      {:error, reason} -> persist_effect_reason(operation, now, reason, options)
    end
  end

  defp conflict(operation, remote, now, options) do
    with {:ok, observation} <- canonical_observation(remote) do
      callback(
        options,
        :conflict,
        &ForgeMirrors.conflict_repository_creation/4
      ).(operation, observation, "repository_namespace_collision", now)
    else
      {:error, reason} -> persist_reason(operation, now, reason, options)
    end
  end

  defp canonical_observation(remote) when is_map(remote) do
    with {:ok, projection} <- RepositoryMetadataProjection.from_remote(remote),
         owner_id when is_integer(owner_id) <- field(remote, :owner_id),
         owner_login when is_binary(owner_login) <- field(remote, :owner_login),
         full_name when is_binary(full_name) <- field(remote, :full_name) do
      {:ok,
       projection
       |> Map.put(:owner_id, owner_id)
       |> Map.put(:owner_login, owner_login)
       |> Map.put(:full_name, full_name)}
    else
      _invalid -> {:error, :invalid_remote_resource}
    end
  end

  defp canonical_observation(_), do: {:error, :invalid_remote_resource}

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
    do: persist_effect_reason(operation, now, :revoked, options)

  defp persist_effect_error(operation, now, %Error{kind: :forbidden}, options),
    do: persist_effect_reason(operation, now, :permission_missing, options)

  defp persist_effect_error(operation, now, _error, options),
    do: persist_effect_reason(operation, now, :provider_validation, options)

  defp persist_effect_reason(operation, now, reason, options)
       when reason in [:timeout, :unavailable, :invalidated, :worker_crash],
       do: defer_effect(operation, now, DateTime.add(now, 60), "network", options)

  defp persist_effect_reason(operation, now, :paused, options),
    do: pause(operation, now, options)

  defp persist_effect_reason(operation, now, reason, options)
       when reason in [:revoked, :credential_unavailable],
       do: halt_effect(operation, now, "credential_revoked", options)

  defp persist_effect_reason(operation, now, :permission_missing, options),
    do: halt_effect(operation, now, "permission_missing", options)

  defp persist_effect_reason(operation, now, reason, options)
       when reason in [
              :policy_disabled,
              :capability_disabled,
              :invalid_policy,
              :invalid_capabilities
            ],
       do: halt_effect(operation, now, "local_validation", options)

  defp persist_effect_reason(operation, now, reason, options),
    do: persist_reason(operation, now, reason, options)

  defp defer_effect(operation, now, retry_at, failure_class, options) do
    callback(
      options,
      :defer_effect,
      &ForgeMirrors.defer_repository_creation_effect/4
    ).(operation, now, retry_at, failure_class)
  end

  defp halt_effect(operation, now, failure_class, options) do
    callback(
      options,
      :halt_effect,
      &ForgeMirrors.halt_repository_creation_effect/3
    ).(operation, now, failure_class)
  end

  defp pause(operation, now, options) do
    callback(options, :pause, &ForgeMirrors.pause_repository_creation/2).(operation, now)
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

  defp persist_error(operation, now, %Error{kind: :forbidden}, options),
    do: persist_reason(operation, now, :permission_missing, options)

  defp persist_error(operation, now, _error, options),
    do: persist_reason(operation, now, :provider_validation, options)

  defp persist_reason(operation, now, reason, options)
       when reason in [:timeout, :unavailable, :invalidated, :worker_crash],
       do: retry(operation, now, DateTime.add(now, 60), "network", options)

  defp persist_reason(operation, now, :revoked, options),
    do: fail(operation, now, "credential_revoked", options)

  defp persist_reason(operation, now, :credential_unavailable, options),
    do: fail(operation, now, "credential_revoked", options)

  defp persist_reason(operation, now, :permission_missing, options),
    do: fail(operation, now, "permission_missing", options)

  defp persist_reason(operation, now, :namespace_collision, options),
    do: fail(operation, now, "namespace_collision", options)

  defp persist_reason(operation, now, :provider_validation, options),
    do: fail(operation, now, "provider_validation", options)

  defp persist_reason(operation, now, _reason, options),
    do: fail(operation, now, "local_validation", options)

  defp retry(operation, now, retry_at, failure_class, options) do
    callback(options, :retry, &ForgeMirrors.retry_operation/4).(
      operation,
      now,
      retry_at,
      failure_class
    )
  end

  defp fail(operation, now, failure_class, options) do
    callback(options, :fail, &ForgeMirrors.fail_operation/4).(
      operation,
      now,
      failure_class,
      nil
    )
  end

  defp request_options(sync),
    do: [gate_key: {:github_installation, sync.github_installation_id}]

  defp field(value, key), do: Map.get(value, key, Map.get(value, Atom.to_string(key)))
  defp callback(options, key, default), do: Keyword.get(options, key, default)

  @impl true
  def init(options) do
    state = %{
      enabled: Keyword.get(options, :enabled, true),
      interval_ms: Keyword.get(options, :interval_ms, @default_interval_ms),
      owner:
        Keyword.get(options, :owner, "repository-create-#{System.unique_integer([:positive])}"),
      options: Keyword.drop(options, [:enabled, :interval_ms, :owner, :name, :task_starter]),
      task_starter:
        Keyword.get(options, :task_starter, fn task ->
          Task.Supervisor.start_child(ForgeGitHub.RepositoryCreationTaskSupervisor, task)
        end),
      task_ref: nil
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{task_ref: nil} = state) do
    case state.task_starter.(fn -> run_once(state.owner, state.options) end) do
      {:ok, pid} -> {:noreply, %{state | task_ref: Process.monitor(pid)}}
      _ -> schedule(state.interval_ms) && {:noreply, state}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    schedule(state.interval_ms)
    {:noreply, %{state | task_ref: nil}}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
