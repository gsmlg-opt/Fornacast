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
    RunAggregator
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
    item_id
    |> RepositoryPublisher.recover()
    |> tap(fn _result -> RunAggregator.finish_if_terminal(item.import_run_id) end)
  end

  defp dispatch(
         %RepositoryItem{state: :ready_to_publish, import_run_id: run_id} = item,
         _worker,
         _opts
       ) do
    result =
      with %ImportRun{} = run <- Repo.get(ImportRun, run_id),
           %User{} = actor <- Repo.get(User, run.actor_user_id) do
        RepositoryPublisher.publish(actor, item.id, run.request_metadata)
      else
        _missing -> {:error, :not_found}
      end

    RunAggregator.finish_if_terminal(run_id)
    result
  end

  defp dispatch(%RepositoryItem{} = item, repository_worker, opts) do
    item.id
    |> then(&apply(repository_worker, :stage, [&1, opts]))
    |> tap(fn _result -> RunAggregator.finish_if_terminal(item.import_run_id) end)
  end

  defp worker_options(lease_owner, opts) do
    opts
    |> Keyword.get(:repository_worker_options, [])
    |> Keyword.put(:owner, lease_owner)
  end
end
