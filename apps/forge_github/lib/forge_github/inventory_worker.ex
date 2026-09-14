defmodule ForgeGitHub.InventoryWorker do
  @moduledoc """
  Bounded executor for installation-scoped organization inventory operations.

  Each task fetches at most one provider page. The durable operation checkpoint
  determines the next page, so a crash never requires keeping repository lists
  or installation tokens in process state.
  """

  use GenServer

  alias ForgeGitHub.{Client, Error, InstallationToken, InstallationTokenBroker, Repository}

  @inventory_operation_kind "reconcile.organization_inventory"
  @finalizer_operation_kind "finalize.organization.reconciliation"
  @operation_kinds [@inventory_operation_kind, @finalizer_operation_kind]
  @default_interval_ms 1_000
  @default_lease_seconds 30
  @default_batch_size 8
  @default_max_concurrency 4
  @default_processor_timeout_ms 20_000
  @lease_margin_ms 5_000
  @run_option_keys [
    :lease_seconds,
    :batch_size,
    :max_concurrency,
    :processor_timeout_ms,
    :task_supervisor,
    :claim,
    :context,
    :token_fetch,
    :page_fetch,
    :page_record,
    :finalize_reconciliation,
    :operation_retry,
    :operation_fail,
    :now
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc false
  @spec run_once(String.t(), keyword()) :: {:ok, list()} | {:error, atom()}
  def run_once(owner, options \\ [])

  def run_once(owner, options) when is_binary(owner) and is_list(options) do
    now = callback(options, :now, fn -> DateTime.utc_now(:second) end).()
    lease_seconds = bounded_option(options, :lease_seconds, @default_lease_seconds, 1, 3_600)
    batch_size = bounded_option(options, :batch_size, @default_batch_size, 1, 100)

    max_concurrency =
      bounded_option(
        options,
        :max_concurrency,
        config(:inventory_worker_max_concurrency, @default_max_concurrency),
        1,
        8
      )

    processor_timeout_ms =
      bounded_option(
        options,
        :processor_timeout_ms,
        config(:inventory_worker_processor_timeout_ms, @default_processor_timeout_ms),
        1,
        3_599_000
      )

    unless processor_timeout_ms <= lease_seconds * 1_000 - @lease_margin_ms do
      raise ArgumentError, "inventory processor timeout must finish inside its lease"
    end

    claim = callback(options, :claim, &ForgeMirrors.claim_operations/5)

    with {:ok, operations} <-
           claim.(owner, now, lease_seconds, min(batch_size, max_concurrency), @operation_kinds) do
      task_supervisor =
        Keyword.get(options, :task_supervisor, ForgeGitHub.InventoryTaskSupervisor)

      results =
        task_supervisor
        |> Task.Supervisor.async_stream_nolink(
          operations,
          &process_operation(&1, now, options),
          max_concurrency: max_concurrency,
          ordered: true,
          on_timeout: :kill_task,
          timeout: processor_timeout_ms
        )
        |> Stream.zip(operations)
        |> Enum.map(fn
          {{:ok, result}, operation} -> {operation.id, result}
          {{:exit, _reason}, operation} -> {operation.id, {:error, :worker_crash}}
        end)

      {:ok, results}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def run_once(_owner, _options), do: {:error, :invalid_argument}

  @impl true
  def init(options) do
    owner = "inventory-#{node()}-#{System.unique_integer([:positive])}"
    run_options = Keyword.take(options, @run_option_keys)

    state = %{
      enabled: Keyword.get(options, :enabled, config(:inventory_worker_enabled, true)),
      interval_ms:
        bounded_option(
          options,
          :interval_ms,
          config(:inventory_worker_interval_ms, @default_interval_ms),
          1,
          3_600_000
        ),
      task_supervisor:
        Keyword.get(options, :task_supervisor, ForgeGitHub.InventoryTaskSupervisor),
      runner: Keyword.get(options, :runner, fn -> run_once(owner, run_options) end),
      task_ref: nil
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{task_ref: nil} = state) do
    case Task.Supervisor.start_child(state.task_supervisor, state.runner) do
      {:ok, pid} ->
        {:noreply, %{state | task_ref: Process.monitor(pid)}}

      {:error, _reason} ->
        schedule(state.interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    schedule(state.interval_ms)
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp process_operation(%{kind: @finalizer_operation_kind} = operation, now, options) do
    callback(
      options,
      :finalize_reconciliation,
      &ForgeMirrors.finalize_organization_reconciliation/2
    ).(operation, now)
  end

  defp process_operation(%{kind: @inventory_operation_kind} = operation, now, options) do
    context = callback(options, :context, &ForgeMirrors.inventory_operation_context/1)
    token_fetch = callback(options, :token_fetch, &InstallationTokenBroker.fetch/2)
    page_fetch = callback(options, :page_fetch, &Client.installation_repositories_page/3)

    with {:ok, inventory} <- context.(operation),
         %InstallationToken{token: token} <-
           token_fetch.(inventory.github_installation_id, %{
             permissions: %{"metadata" => "read"}
           }),
         {:ok, page} <-
           page_fetch.(token, inventory.cursor,
             gate_key: {:github_installation, inventory.github_installation_id}
           ),
         {:ok, repositories} <- normalize_page(page, inventory.github_account_id) do
      callback(options, :page_record, &ForgeMirrors.record_inventory_page/4).(
        operation,
        repositories,
        page.next_cursor,
        now
      )
    else
      {:error, %Error{} = error} ->
        persist_provider_error(operation, now, error, options)

      {:error, :owner_mismatch} ->
        fail_operation(
          operation,
          now,
          "provider_validation",
          "installation repository owner identity mismatch",
          options
        )

      {:error, :invalid_response} ->
        fail_operation(
          operation,
          now,
          "provider_validation",
          "invalid GitHub inventory response",
          options
        )

      {:error, reason} when reason in [:busy, :timeout, :unavailable, :invalidated] ->
        retry_operation(operation, now, "network", nil, options)

      {:error, :revoked} ->
        fail_operation(
          operation,
          now,
          "credential_revoked",
          "installation token revoked",
          options
        )

      {:error, reason} when reason in [:not_configured, :invalid_scope] ->
        fail_operation(
          operation,
          now,
          "local_validation",
          "installation token configuration is unavailable",
          options
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_page(%{repositories: repositories, next_cursor: next_cursor}, account_id)
       when is_list(repositories) and length(repositories) <= 100 and
              (is_nil(next_cursor) or
                 (is_integer(next_cursor) and next_cursor in 2..100)) do
    if Enum.all?(repositories, &match?(%Repository{owner_id: ^account_id}, &1)) do
      {:ok,
       Enum.map(repositories, fn repository ->
         %{
           github_repository_id: repository.id,
           github_node_id: repository.node_id,
           github_full_name: repository.full_name,
           github_archived: repository.archived
         }
       end)}
    else
      {:error, :owner_mismatch}
    end
  end

  defp normalize_page(_page, _account_id), do: {:error, :invalid_response}

  defp persist_provider_error(operation, now, %Error{kind: kind, retry_at: retry_at}, options)
       when kind in [:primary_rate_limit, :secondary_rate_limit] do
    retry_operation(operation, now, Atom.to_string(kind), retry_at, options)
  end

  defp persist_provider_error(operation, now, %Error{kind: kind}, options)
       when kind in [
              :transport,
              :timeout,
              :host_unavailable,
              :upstream_unavailable,
              :request_gate_busy
            ],
       do: retry_operation(operation, now, "network", nil, options)

  defp persist_provider_error(operation, now, %Error{kind: :invalid_credential}, options),
    do:
      fail_operation(
        operation,
        now,
        "credential_revoked",
        "GitHub rejected installation token",
        options
      )

  defp persist_provider_error(operation, now, %Error{kind: :forbidden}, options),
    do:
      fail_operation(
        operation,
        now,
        "permission_missing",
        "installation cannot list repositories",
        options
      )

  defp persist_provider_error(operation, now, %Error{}, options),
    do:
      fail_operation(
        operation,
        now,
        "provider_validation",
        "invalid GitHub inventory response",
        options
      )

  defp retry_operation(operation, now, failure_class, retry_at, options) do
    retry_at = valid_future_retry_at(retry_at, now)

    callback(options, :operation_retry, &ForgeMirrors.retry_operation/4).(
      operation,
      now,
      retry_at,
      failure_class
    )
  end

  defp fail_operation(operation, now, failure_class, detail, options) do
    callback(options, :operation_fail, &ForgeMirrors.fail_operation/4).(
      operation,
      now,
      failure_class,
      detail
    )
  end

  defp valid_future_retry_at(%DateTime{} = retry_at, now) do
    if DateTime.after?(retry_at, now), do: retry_at, else: DateTime.add(now, 60)
  end

  defp valid_future_retry_at(_retry_at, now), do: DateTime.add(now, 60)

  defp callback(options, key, default) do
    case Keyword.get(options, key, default) do
      callback when is_function(callback) -> callback
      _invalid -> raise ArgumentError, "invalid inventory worker callback"
    end
  end

  defp bounded_option(options, key, default, minimum, maximum) do
    value = Keyword.get(options, key, default)

    if is_integer(value) and value in minimum..maximum,
      do: value,
      else: raise(ArgumentError, "invalid inventory worker option")
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
  defp config(key, default), do: Application.get_env(:forge_github, key, default)
end
