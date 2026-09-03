defmodule ForgeImports.Worker do
  @moduledoc false

  alias ForgeAccounts.User

  alias ForgeImports.{
    Cancellation,
    ImportRun,
    Recovery,
    RepositoryItem,
    RepositoryPublisher,
    RepositoryWorker,
    RunAggregator,
    Telemetry
  }

  alias Fornacast.Repo

  @spec run(pos_integer(), String.t(), keyword()) ::
          term()
  def run(item_id, lease_owner, opts \\ [])
      when is_integer(item_id) and item_id > 0 and is_binary(lease_owner) do
    repository_worker = Keyword.get(opts, :repository_worker, RepositoryWorker)
    worker_opts = worker_options(lease_owner, opts)

    with %RepositoryItem{} = item <- Repo.get(RepositoryItem, item_id),
         {:ok, item} <- Recovery.reconcile(item, opts),
         false <- skip_dispatch?(item) do
      dispatch(item, repository_worker, worker_opts)
    else
      nil -> {:error, :not_found}
      true -> {:error, :cancelled}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run_discovery(pos_integer(), String.t(), keyword()) :: term()
  def run_discovery(run_id, lease_owner, opts \\ [])
      when is_integer(run_id) and run_id > 0 and is_binary(lease_owner) do
    case Repo.get(ImportRun, run_id) do
      %ImportRun{state: state} when state in [:cancel_requested, :canceled] ->
        {:ok, :ignored}

      _other ->
        discovery_opts =
          opts
          |> Keyword.drop([:repository_worker, :repository_worker_options])
          |> Keyword.put(:owner, lease_owner)

        ForgeImports.DiscoveryWorker.perform(run_id, discovery_opts)
    end
  end

  defp skip_dispatch?(%RepositoryItem{state: :publishing}), do: false

  defp skip_dispatch?(%RepositoryItem{} = item) do
    Cancellation.check(item) and item.state not in [:cancel_requested, :staging_git]
  end

  defp dispatch(%RepositoryItem{state: :publishing, id: item_id} = item, _worker, _opts) do
    started = System.monotonic_time()

    result =
      item_id
      |> RepositoryPublisher.recover()
      |> tap(fn _result -> finish_if_terminal(item.import_run_id) end)

    emit_phase(item, :publishing, result, System.monotonic_time() - started)
    result
  end

  defp dispatch(
         %RepositoryItem{state: :ready_to_publish, import_run_id: run_id} = item,
         _worker,
         _opts
       ) do
    started = System.monotonic_time()

    result =
      with %ImportRun{} = run <- Repo.get(ImportRun, run_id),
           %User{} = actor <- Repo.get(User, run.actor_user_id) do
        RepositoryPublisher.publish(actor, item.id, run.request_metadata)
      else
        _missing -> {:error, :not_found}
      end

    finish_if_terminal(run_id)
    emit_phase(item, :ready_to_publish, result, System.monotonic_time() - started)
    result
  end

  defp dispatch(%RepositoryItem{} = item, repository_worker, opts) do
    started = System.monotonic_time()
    phase = item.state

    result =
      item.id
      |> then(&apply(repository_worker, :stage, [&1, opts]))
      |> tap(fn _result -> finish_if_terminal(item.import_run_id) end)

    emit_phase(item, phase, result, System.monotonic_time() - started)
    result
  end

  defp finish_if_terminal(run_id) do
    case RunAggregator.finish_if_terminal(run_id) do
      {:ok, %ImportRun{id: id, state: state}} ->
        Telemetry.execute([:run, :completed], %{count: 1}, %{
          run_id: id,
          completion_state: state
        })

      _other ->
        :ok
    end
  end

  defp emit_phase(%RepositoryItem{id: item_id, import_run_id: run_id}, phase, result, duration) do
    metadata =
      %{
        run_id: run_id,
        item_id: item_id,
        phase: phase,
        outcome: phase_outcome(result)
      }
      |> maybe_put_error(result)

    Telemetry.execute([:phase, :stop], %{duration: duration}, metadata)
  end

  defp phase_outcome({:ok, :busy}), do: :busy
  defp phase_outcome({:ok, :ignored}), do: :ignored
  defp phase_outcome({:ok, _}), do: :ok
  defp phase_outcome({:error, _}), do: :error
  defp phase_outcome(_), do: :ok

  defp maybe_put_error(metadata, {:error, reason}) when is_atom(reason) do
    Map.put(metadata, :error, reason)
  end

  defp maybe_put_error(metadata, _result), do: metadata

  defp worker_options(lease_owner, opts) do
    opts
    |> Keyword.get(:repository_worker_options, [])
    |> Keyword.put(:owner, lease_owner)
  end
end
