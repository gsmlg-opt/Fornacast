defmodule ForgeImports.Recovery do
  @moduledoc false

  import Ecto.Query

  alias ForgeImports.{ImportRun, Persistence, RepositoryItem, RepositoryPublisher, Waits}
  alias Fornacast.{OperationLease, Repo}

  @recoverable_states [
    :queued,
    :staging_git,
    :git_staged,
    :staging_metadata,
    :ready_to_publish,
    :publishing
  ]

  @type durable_facts :: map()

  @spec classify(RepositoryItem.t(), durable_facts()) ::
          {:ok, atom()} | {:error, :inconsistent}
  def classify(%RepositoryItem{} = item, durable_facts) when is_map(durable_facts) do
    proof = Map.get(durable_facts, :proof, RepositoryPublisher.durable_proof_state(item))

    cond do
      item.state == :publishing and publication_in_progress?(item, durable_facts) ->
        {:ok, :publishing}

      item.state == :staging_metadata and get_in(item.checkpoint, ["git_staged"]) == true ->
        {:ok, :staging_metadata}

      item.state == :git_staged and get_in(item.checkpoint, ["git_staged"]) == true ->
        {:ok, :git_staged}

      match?({:ok, :ready_to_publish}, proof) ->
        {:ok, :ready_to_publish}

      match?({:ok, :git_staged}, proof) ->
        {:ok, :git_staged}

      match?({:ok, :queued}, proof) ->
        {:ok, :queued}

      staged_git_recovery?(item, proof) ->
        {:ok, :staging_git}

      true ->
        {:error, :inconsistent}
    end
  end

  @spec reconcile(RepositoryItem.t(), keyword()) ::
          {:ok, RepositoryItem.t()} | {:error, atom()}
  def reconcile(%RepositoryItem{} = item, opts \\ []) do
    facts = Keyword.get(opts, :durable_facts, gather_durable_facts(item))
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))

    with {:ok, item} <- maybe_pause_missing_credential(item, now) do
      if item.state == :awaiting_credential do
        {:ok, item}
      else
        reconcile_recoverable(item, facts, now)
      end
    end
  end

  defp reconcile_recoverable(%RepositoryItem{} = item, facts, now) do
    with true <- item.state in @recoverable_states,
         {:ok, _phase} <- classify(item, facts),
         {:ok, released} <- release_expired_lease(item, now) do
      align_state(released, facts, now)
    else
      false -> {:ok, item}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def gather_durable_facts(%RepositoryItem{} = item) do
    %{
      proof: RepositoryPublisher.durable_proof_state(item),
      publication_evidence?: publication_in_progress?(item, %{}),
      terminal_report?: terminal_report?(item),
      credential_cleared?: credential_cleared?(item)
    }
  end

  defp maybe_pause_missing_credential(%RepositoryItem{} = item, now) do
    case Repo.get(ImportRun, item.import_run_id) do
      %ImportRun{} = run ->
        if Waits.missing_saved_credential?(run) and item.state in @recoverable_states do
          case Waits.pause_for_missing_saved_credential(run, item, now: now) do
            {:ok, {_paused_run, paused_item}} when not is_nil(paused_item) ->
              {:ok, paused_item}

            {:ok, {_paused_run, nil}} ->
              {:ok, item}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:ok, item}
        end

      nil ->
        {:ok, item}
    end
  end

  defp align_state(%RepositoryItem{state: state} = item, facts, now)
       when state in [:git_staged, :staging_metadata, :ready_to_publish] do
    case classify(item, facts) do
      {:ok, ^state} ->
        {:ok, item}

      {:ok, target} when target in [:git_staged, :staging_metadata, :ready_to_publish] ->
        transition_to_recovered_state(item, target, now)

      {:ok, _other} ->
        {:ok, item}

      {:error, :inconsistent} ->
        {:error, :inconsistent}
    end
  end

  defp align_state(item, _facts, _now), do: {:ok, item}

  defp transition_to_recovered_state(item, target, now) do
    source_state =
      case item.state do
        :staging_metadata -> :staging_metadata
        :ready_to_publish -> :ready_to_publish
        _ -> :git_staged
      end

    allowed =
      case target do
        :git_staged -> source_state in [:git_staged, :staging_metadata, :ready_to_publish]
        :staging_metadata -> source_state in [:staging_metadata, :ready_to_publish]
        :ready_to_publish -> source_state == :ready_to_publish
        _ -> false
      end

    if allowed do
      Persistence.update_without_lease(
        item,
        [source_state],
        RepositoryItem.transition_changeset(item, target, %{}),
        now
      )
    else
      {:ok, item}
    end
  end

  defp release_expired_lease(%RepositoryItem{lease_owner: nil} = item, _now), do: {:ok, item}

  defp release_expired_lease(%RepositoryItem{} = item, now) do
    if live_lease?(item, now) do
      {:ok, item}
    else
      case OperationLease.release(RepositoryItem, item) do
        :ok -> {:ok, Repo.get!(RepositoryItem, item.id)}
        {:ok, released} -> {:ok, released}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp staged_git_recovery?(%RepositoryItem{} = item, proof) do
    match?({:error, :inconsistent}, proof) and
      item.state == :staging_git and
      is_integer(item.hidden_repository_id) and is_binary(item.staged_storage_path) and
      is_nil(item.cleanup_state)
  end

  defp publication_in_progress?(%RepositoryItem{state: :publishing} = item, _facts) do
    is_map(item.publication_evidence) and map_size(item.publication_evidence) > 0
  end

  defp publication_in_progress?(_item, _facts), do: false

  defp terminal_report?(item) do
    Repo.exists?(
      from entry in ForgeImports.ReportEntry,
        where: entry.repository_item_id == ^item.id and entry.scope == :repository
    )
  end

  defp credential_cleared?(%RepositoryItem{import_run_id: run_id}) do
    case Repo.get(ImportRun, run_id) do
      %ImportRun{credential_source: :one_time, credential_ciphertext: nil} -> true
      %ImportRun{credential_source: :saved} -> true
      %ImportRun{credential_source: :one_time} -> false
      nil -> false
    end
  end

  defp live_lease?(%{lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp live_lease?(_row, _now), do: false
end
