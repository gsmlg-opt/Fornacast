defmodule ForgeImports.Reconciler do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias ForgeAccounts.User

  alias ForgeImports.{
    DiscoveryWorker,
    ImportAttempt,
    ImportRun,
    RepositoryItem,
    RepositoryPublisher,
    RepositoryWorker
  }

  alias Fornacast.Repo

  @default_interval_ms 30_000
  @default_batch_size 25
  @default_lease_seconds 2_400

  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def kick(server \\ __MODULE__), do: GenServer.cast(server, :kick)

  @doc false
  def discovering_run_ids(limit, %DateTime{} = now)
      when is_integer(limit) and limit in 1..100 do
    now = DateTime.truncate(now, :second)

    ImportRun
    |> where(
      [run],
      run.state == :discovering and
        (is_nil(run.next_attempt_at) or run.next_attempt_at <= ^now) and
        (is_nil(run.lease_expires_at) or run.lease_expires_at <= ^now)
    )
    |> order_by([run], asc: run.id)
    |> limit(^limit)
    |> select([run], run.id)
    |> Repo.all()
  end

  @doc false
  def runnable_repository_item_ids(limit, %DateTime{} = now)
      when is_integer(limit) and limit in 1..100 do
    now = DateTime.truncate(now, :second)

    staging_branch =
      dynamic(
        [item, run, _attempt, actor],
        ((item.state == :queued and is_nil(item.hidden_repository_id) and
            is_nil(item.staged_storage_path)) or
           (item.state == :staging_git and not is_nil(item.hidden_repository_id) and
              not is_nil(item.staged_storage_path)) or
           (item.state in [:git_staged, :staging_metadata] and
              not is_nil(item.hidden_repository_id) and not is_nil(item.staged_storage_path))) and
          is_nil(item.cleanup_state) and
          ((run.state == :running and actor.state == :active and
              (is_nil(run.lease_expires_at) or run.lease_expires_at <= ^now)) or
             (item.state == :staging_git and
                run.state in [
                  :running,
                  :cancel_requested,
                  :canceled,
                  :failed,
                  :completed,
                  :completed_with_warnings
                ] and (run.state != :running or actor.state != :active)))
      )

    fresh_publication_branch =
      dynamic(
        [item, run, _attempt, actor],
        item.state == :ready_to_publish and is_nil(item.cleanup_state) and
          run.state == :running and actor.state == :active and
          (is_nil(run.lease_expires_at) or run.lease_expires_at <= ^now)
      )

    recovery_publication_branch =
      dynamic(
        [item, run, _attempt, _actor],
        item.state == :publishing and
          run.state in [:running, :cancel_requested, :awaiting_credential]
      )

    eligible_branch =
      dynamic(
        [item, run, attempt, actor],
        ^staging_branch or ^fresh_publication_branch or ^recovery_publication_branch
      )

    RepositoryItem
    |> join(:inner, [item], run in ImportRun, on: run.id == item.import_run_id)
    |> join(:inner, [item, _run], attempt in ImportAttempt,
      on:
        attempt.repository_item_id == item.id and
          attempt.attempt_number == item.attempt_count
    )
    |> join(:inner, [_item, run, _attempt], actor in User, on: actor.id == run.actor_user_id)
    |> where(
      [item, run, attempt, actor],
      item.selected == true and
        item.state in [:queued, :staging_git, :git_staged, :staging_metadata, :ready_to_publish, :publishing] and
        item.attempt_count > 0 and
        (is_nil(item.next_attempt_at) or item.next_attempt_at <= ^now) and
        (is_nil(item.lease_expires_at) or item.lease_expires_at <= ^now) and
        attempt.state == :running and actor.kind == :user
    )
    |> where(^eligible_branch)
    |> order_by([item, _run, _attempt, _actor],
      desc: item.state == :publishing,
      desc: is_nil(item.next_attempt_at),
      asc: item.next_attempt_at,
      asc: item.id
    )
    |> limit(^limit)
    |> select([item, _run, _attempt, _actor], item.id)
    |> Repo.all()
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: Keyword.get(opts, :enabled, true),
      interval_ms: clamp(Keyword.get(opts, :interval_ms, @default_interval_ms), 50, 60_000),
      batch_size: clamp(Keyword.get(opts, :batch_size, @default_batch_size), 1, 100),
      lease_seconds: clamp(Keyword.get(opts, :lease_seconds, @default_lease_seconds), 2, 2_400),
      client: Keyword.get(opts, :client, ForgeImports.GitHub.Client),
      client_options: Keyword.get(opts, :client_options, []),
      keyring: Keyword.get(opts, :keyring, Fornacast.Config.github_credential_keyring()),
      repository_worker: Keyword.get(opts, :repository_worker, RepositoryWorker),
      repository_worker_options: Keyword.get(opts, :repository_worker_options, []),
      task_supervisor: Keyword.get(opts, :task_supervisor, ForgeImports.TaskSupervisor),
      task: nil,
      timer: nil,
      scan_queued: false,
      rescan_requested: false
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, %{enabled: true} = state) do
    {:noreply, queue_scan(state)}
  end

  def handle_continue(:startup, state), do: {:noreply, state}

  @impl true
  def handle_cast(:kick, %{enabled: true, task: nil} = state) do
    state = state |> cancel_scheduled_scan() |> queue_scan()
    {:noreply, state}
  end

  def handle_cast(:kick, %{enabled: true} = state),
    do: {:noreply, %{state | rescan_requested: true}}

  def handle_cast(:kick, state), do: {:noreply, state}

  @impl true
  def handle_info(:scan, %{enabled: true, task: nil} = state) do
    start_scan(%{state | scan_queued: false, timer: nil})
  end

  def handle_info(:scan, %{enabled: true} = state) do
    {:noreply, %{state | scan_queued: false, rescan_requested: true}}
  end

  def handle_info(
        {:scan, token},
        %{enabled: true, task: nil, timer: {_timer, token}} = state
      ) do
    start_scan(%{state | timer: nil})
  end

  def handle_info(
        {:scan, token},
        %{enabled: true, timer: {_timer, token}} = state
      ) do
    {:noreply, %{state | timer: nil, rescan_requested: true}}
  end

  def handle_info({:scan, _token}, state), do: {:noreply, state}
  def handle_info(:scan, state), do: {:noreply, %{state | scan_queued: false}}

  def handle_info({reference, _result}, %{task: %Task{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, after_scan(%{state | task: nil})}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{task: %Task{ref: reference}} = state
      ) do
    {:noreply, after_scan(%{state | task: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reconcile_batch(state) do
    now = DateTime.utc_now(:second)

    discovery_results =
      state.batch_size
      |> discovering_run_ids(now)
      |> Enum.map(fn run_id ->
        DiscoveryWorker.perform(run_id,
          lease_seconds: state.lease_seconds,
          client: state.client,
          client_options: state.client_options,
          keyring: state.keyring
        )
      end)

    repository_results =
      state.batch_size
      |> runnable_repository_item_ids(now)
      |> Enum.map(fn item_id ->
        reconcile_repository_item(state, item_id)
      end)

    discovery_results ++ repository_results
  end

  defp reconcile_repository_item(state, item_id) do
    case Repo.get(RepositoryItem, item_id) do
      %RepositoryItem{state: :publishing} ->
        RepositoryPublisher.recover(item_id)

      %RepositoryItem{state: :ready_to_publish, import_run_id: run_id} ->
        with %ImportRun{} = run <- Repo.get(ImportRun, run_id),
             %User{} = actor <- Repo.get(User, run.actor_user_id) do
          RepositoryPublisher.publish(actor, item_id, run.request_metadata)
        else
          _missing -> {:error, :not_found}
        end

      %RepositoryItem{} ->
        state.repository_worker.stage(item_id, repository_worker_options(state))

      nil ->
        {:error, :not_found}
    end
  end

  defp repository_worker_options(state) do
    minimum = max(state.lease_seconds, 2)

    Keyword.update(
      state.repository_worker_options,
      :lease_seconds,
      minimum,
      fn
        value when is_integer(value) -> max(value, 2)
        value -> value
      end
    )
  end

  defp start_scan(state) do
    case start_scan_task(state) do
      {:ok, task} -> {:noreply, %{state | task: task}}
      {:error, :max_children} -> {:noreply, schedule(state)}
    end
  end

  defp start_scan_task(state) do
    {:ok, Task.Supervisor.async_nolink(state.task_supervisor, fn -> reconcile_batch(state) end)}
  rescue
    RuntimeError -> {:error, :max_children}
  end

  defp queue_scan(%{scan_queued: true} = state), do: state

  defp queue_scan(state) do
    send(self(), :scan)
    %{state | scan_queued: true}
  end

  defp after_scan(%{enabled: true, rescan_requested: true} = state) do
    state
    |> Map.put(:rescan_requested, false)
    |> queue_scan()
  end

  defp after_scan(state), do: schedule(state)

  defp schedule(%{enabled: true} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:scan, token}, state.interval_ms)
    %{state | timer: {timer, token}}
  end

  defp schedule(state), do: state

  defp cancel_scheduled_scan(%{timer: {reference, _token}} = state) do
    Process.cancel_timer(reference)
    %{state | timer: nil}
  end

  defp cancel_scheduled_scan(state), do: state

  defp clamp(value, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp clamp(_value, _min, max), do: max
end
