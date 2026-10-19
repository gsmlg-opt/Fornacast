defmodule ForgeImports.PatSyncWorker do
  @moduledoc false
  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeImports.{ImportRun, PatSyncRun, PatSyncRepositoryResult, RepositoryItem, SyncJobs}
  alias ForgeMirrors.{PatConfiguration, PatSettings}
  alias Fornacast.Repo

  @lease_seconds 300
  @allow_test_options Mix.env() == :test

  @doc false
  def perform(job_id, opts \\ []) do
    with {:ok, %PatSyncRun{} = job} <- claim(job_id) do
      if is_nil(job.started_at), do: persist(job, started_at: DateTime.utc_now(:second))
      result = with {:ok, owner, config} <- context(job), do: advance(job, owner, config, opts)

      if Keyword.get(opts, :queued_updates, false) and
           match?(
             {:error, reason}
             when reason in [:persistence_unavailable, :unavailable, :worker_crash, :lost_lease],
             result
           ) do
        with {:ok, _} <- persist(job, lease_owner: nil, lease_expires_at: nil), do: result
      else
        settle(job, result)
      end
    end
  end

  defp claim(job_id) do
    now = DateTime.utc_now(:second)
    token = Ecto.UUID.generate()

    {count, jobs} =
      Repo.update_all(
        from(j in PatSyncRun,
          where:
            j.id == ^job_id and j.state in ["queued", "running"] and
              (is_nil(j.lease_expires_at) or j.lease_expires_at <= ^now),
          select: j
        ),
        set: [
          state: "running",
          lease_owner: token,
          lease_expires_at: DateTime.add(now, @lease_seconds, :second),
          updated_at: now,
          heartbeat_at: now
        ]
      )

    case {count, jobs} do
      {1, [job]} -> {:ok, job}
      _ -> {:ok, :busy}
    end
  end

  @doc false
  def import_authorized?(run_id, opts \\ []) do
    run = Repo.get(ImportRun, run_id)
    job_query = from j in PatSyncRun, where: j.import_run_id == ^run_id

    job_query =
      if Repo.in_transaction?() and Keyword.get(opts, :lock, false),
        do: lock(job_query, "FOR SHARE"),
        else: job_query

    job = Repo.one(job_query) || provisional_job(run)

    case job do
      nil ->
        :ok

      %PatSyncRun{} = job ->
        if Repo.in_transaction?() and Keyword.get(opts, :lock, false) do
          Repo.one(
            from c in PatConfiguration, where: c.id == ^job.configuration_id, lock: "FOR SHARE"
          )
        end

        with true <-
               job.state != "failed" and run.actor_user_id == job.owner_user_id and
                 run.github_identity_id == job.github_identity_id and
                 run.source_owner_login == job.github_organization and
                 run.destination_organization_id == job.organization_id,
             {:ok, _owner, _config} <- context(job) do
          :ok
        else
          false -> {:error, :configuration_changed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp provisional_job(%ImportRun{
         request_metadata: %{"operation_id" => "organization-pat-sync-" <> id}
       }) do
    case Integer.parse(id) do
      {job_id, ""} -> Repo.get(PatSyncRun, job_id)
      _ -> nil
    end
  end

  defp provisional_job(_), do: nil

  defp context(job) do
    config = Repo.get(PatConfiguration, job.configuration_id)
    owner = Repo.get(User, job.owner_user_id)

    with %PatConfiguration{} <- config,
         true <-
           config.organization_id == job.organization_id and
             config.owner_user_id == job.owner_user_id and
             config.github_identity_id == job.github_identity_id and
             config.github_organization == job.github_organization,
         true <- config.enabled,
         false <- config.paused,
         %User{state: :active} <- owner,
         {:ok, _} <- ForgeAccounts.organization_github_owner(owner, job.organization_id, owner.id) do
      {:ok, owner, config}
    else
      false -> {:error, :configuration_changed}
      true -> {:error, :paused}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :configuration_changed}
    end
  end

  defp advance(%PatSyncRun{import_run_id: nil} = job, owner, _config, opts) do
    operation_id = "organization-pat-sync-#{job.id}"
    metadata = Map.put(job.request_metadata, "operation_id", operation_id)

    existing =
      Repo.one(
        from r in ImportRun,
          where:
            r.actor_user_id == ^owner.id and
              fragment("?->>'operation_id'", r.request_metadata) == ^operation_id,
          order_by: [asc: r.id],
          limit: 1
      )

    create =
      callback(opts, :create_discovery, fn actor, attrs, request_metadata ->
        ForgeImports.create_organization_discovery(
          actor,
          attrs,
          request_metadata,
          test_options(opts, :discovery_options)
        )
      end)

    result =
      if existing,
        do: {:ok, existing},
        else:
          create.(
            owner,
            %{
              organization: job.github_organization,
              credential_source: :saved,
              github_identity_id: job.github_identity_id,
              destination_organization: %{action: :existing, id: job.organization_id}
            },
            metadata
          )

    with {:ok, run} <- result,
         {:ok, _} <- persist(job, import_run_id: run.id) do
      :pending
    end
  end

  defp advance(job, owner, config, opts) do
    case Repo.get(ImportRun, job.import_run_id) do
      %ImportRun{state: :discovering} ->
        :pending

      %ImportRun{state: :awaiting_resolution} = run ->
        prepare(job, owner, run)

      %ImportRun{state: :ready} = run ->
        with {:ok, _} <- ForgeImports.start_import(owner, run.id, job.request_metadata),
             do: :pending

      %ImportRun{state: :failed} when job.progress == %{} ->
        {:error, :discovery_failed}

      %ImportRun{state: state} = run
      when state in [:running, :completed, :completed_with_warnings, :failed] ->
        synchronize(job, owner, config, run, opts)

      %ImportRun{state: :awaiting_credential} ->
        {:error, :credential_unavailable}

      %ImportRun{state: state} when state in [:canceled, :cancel_requested] ->
        {:error, :import_failed}

      %ImportRun{} ->
        :pending

      nil ->
        {:error, :import_unavailable}
    end
  end

  defp prepare(job, owner, run) do
    items = items(run.id)

    progress =
      Map.new(items, fn item ->
        id = to_string(item.id)
        {id, Map.get(job.progress, id) || plan(job, item)}
      end)

    decisions =
      Map.new(
        Enum.filter(progress, fn {_id, row} -> row["mode"] != "import" end),
        fn {id, _row} -> {id, %{action: :skip}} end
      )

    with {:ok, _} <- persist(job, progress: progress),
         {:ok, _} <-
           ForgeImports.resolve_repository_conflicts(
             owner,
             run.id,
             decisions,
             job.request_metadata
           ),
         {:ok, _} <- ForgeImports.start_import(owner, run.id, job.request_metadata) do
      case ForgeImports.RunAggregator.finish_if_terminal(run.id) do
        {:error, reason} -> {:error, reason}
        _ -> :pending
      end
    else
      {:error, :invalid_selection} when items == [] ->
        case ForgeImports.request_cancel(owner, run.id, job.request_metadata) do
          {:ok, _} -> :succeeded
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plan(job, item) do
    row = %{
      "github_repository_id" => item.github_repository_id,
      "source_full_name" => item.source_full_name,
      "status" => "pending"
    }

    case binding(job, item.github_repository_id) do
      {:ok, repository} ->
        Map.merge(row, %{
          "mode" => "update",
          "repository_id" => repository.id,
          "generation" => repository.generation
        })

      nil when item.state == :queued and is_nil(item.wait_reason) ->
        Map.put(row, "mode", "import")

      _ ->
        Map.merge(row, %{
          "mode" => "conflict",
          "status" => "failed",
          "error" => "repository_conflict"
        })
    end
  end

  defp binding(job, github_repository_id) do
    previous =
      Repo.all(
        from i in RepositoryItem,
          where:
            i.github_repository_id == ^github_repository_id and
              i.destination_owner_id == ^job.organization_id and
              i.state in [:published, :completed],
          order_by: [desc: i.id]
      )

    Enum.find_value(previous, fn item ->
      evidence = item.publication_evidence

      with "committed" <- evidence["state"],
           true <- evidence["repository_id"] == item.hidden_repository_id,
           {:ok, repository} <- ForgeRepos.fetch_live_repository(item.hidden_repository_id),
           true <-
             repository.owner_user_id == job.organization_id and
               repository.generation == evidence["generation"] and repository.lifecycle == :ready do
        {:ok, repository}
      else
        _ -> nil
      end
    end)
  end

  defp synchronize(job, owner, config, run, opts) do
    if Keyword.get(opts, :queued_updates, false) do
      {:ok, progress} = repository_progress(job)

      Enum.each(
        Repo.all(
          from r in PatSyncRepositoryResult,
            where: r.pat_sync_run_id == ^job.id and r.state in ["pending", "running"]
        ),
        fn row ->
          if row.data["mode"] == "update" do
            case SyncJobs.enqueue_update(row.id) do
              {:ok, _} -> :ok
              {:error, _} -> raise "GitHub repository update admission failed"
            end
          end
        end
      )

      finish(%{job | progress: progress}, run)
    else
      synchronize_inline(job, owner, config, run, opts)
    end
  end

  defp synchronize_inline(job, owner, config, run, opts) do
    case job.progress
         |> Enum.sort_by(fn {id, row} -> {Map.get(row, "retry_after", 0), id} end)
         |> Enum.find(fn {_id, row} -> update_ready?(row) end) do
      {id, row} ->
        sync = callback(opts, :sync_repository, &ForgeImports.PatRepositorySync.sync/5)

        result =
          with :ok <- authorize(job),
               {:ok, repository} <-
                 ForgeRepos.fetch_organization_repository(
                   job.organization_id,
                   row["repository_id"]
                 ),
               true <- repository.generation == row["generation"] do
            sync_target(
              sync,
              job,
              owner,
              config,
              repository,
              row["source_full_name"],
              [
                github_repository_id: row["github_repository_id"],
                authorize: fn -> authorize(job) end
              ] ++ test_options(opts, :repository_options)
            )
          else
            false -> {:error, :stale_repository}
            {:error, reason} -> {:error, reason}
          end

        row =
          case result do
            :ok ->
              row
              |> Map.put("status", "succeeded")
              |> Map.delete("error")
              |> Map.delete("retry_after")

            {:error, reason} when reason in [:remote_busy, :busy, :request_gate_busy] ->
              attempts = if run.state == :running, do: 0, else: Map.get(row, "retry_count", 0) + 1

              Map.merge(row, %{
                "status" =>
                  if(run.state == :running or attempts <= 20, do: "pending", else: "failed"),
                "error" => classification(reason),
                "retry_count" => attempts,
                "retry_exhausted" => run.state != :running and attempts > 20,
                "retry_after" => System.system_time(:second) + 5
              })

            {:error, reason} ->
              Map.merge(row, %{"status" => "failed", "error" => classification(reason)})
          end

        with {:ok, _} <- persist(job, progress: Map.put(job.progress, id, row)), do: :pending

      nil ->
        finish(job, run)
    end
  end

  defp update_ready?(row) do
    pending? =
      row["status"] == "pending" or
        (row["status"] == "failed" and
           row["error"] in ["remote_busy", "busy", "request_gate_busy"] and
           not Map.get(row, "retry_exhausted", false))

    row["mode"] == "update" and pending? and
      Map.get(row, "retry_after", 0) <= System.system_time(:second)
  end

  defp finish(job, run) do
    items = items(run.id)
    snapshots = ForgeImports.PatSyncProgress.snapshots(items)

    with {:ok, restored} <-
           ForgeImports.PatSyncProgress.restore_ancestor_imports(job, run, job.progress, items) do
      progress =
        Enum.reduce(items, restored, fn item, rows ->
          id = to_string(item.id)

          case rows[id] do
            %{"mode" => "import"} = row ->
              status =
                cond do
                  item.state in [:published, :completed] -> "succeeded"
                  item.state in [:failed, :canceled, :skipped] -> "failed"
                  true -> "pending"
                end

              error =
                if status == "failed",
                  do: item.failure_kind || "import_failed",
                  else: item.failure_kind

              result =
                row
                |> Map.put("status", status)
                |> Map.put("error", error)
                |> Map.put("progress", snapshots[item.id])

              Map.put(rows, id, result)

            _ ->
              rows
          end
        end)

      with {:ok, _} <- persist(job, progress: progress) do
        cond do
          run.state == :running -> :pending
          Enum.any?(progress, fn {_id, row} -> row["status"] == "pending" end) -> :pending
          Enum.all?(progress, fn {_id, row} -> row["status"] == "succeeded" end) -> :succeeded
          true -> {:error, :repository_sync_failed}
        end
      end
    end
  end

  defp items(run_id),
    do:
      Repo.all(from i in RepositoryItem, where: i.import_run_id == ^run_id, order_by: [asc: i.id])

  defp authorize(job) do
    with {:ok, _owner, _config} <- context(job),
         {:ok, _} <-
           persist(job,
             lease_expires_at: DateTime.add(DateTime.utc_now(:second), @lease_seconds, :second)
           ) do
      :ok
    end
  end

  defp settle(job, result) when result in [:pending, {:error, :paused}] do
    with {:ok, _} <- persist(job, lease_owner: nil, lease_expires_at: nil), do: :pending
  end

  defp settle(job, result) do
    status = if result == :succeeded, do: "succeeded", else: "failed"

    settlement =
      Repo.transact(fn ->
        with {:ok, _} <-
               persist(job,
                 state: status,
                 finished_at: DateTime.utc_now(:second),
                 lease_owner: nil,
                 lease_expires_at: nil,
                 error: if(status == "failed", do: classification(elem(result, 1)), else: nil)
               ) do
          {:ok, status}
        end
      end)

    case settlement do
      {:ok, _} -> if result == :succeeded, do: :ok, else: result
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist(job, changes) do
    Repo.transact(fn ->
      if progress = Keyword.get(changes, :progress), do: seed_results(job, progress)
      persist_owned(job, changes)
    end)
  end

  defp seed_results(job, progress) do
    now = DateTime.utc_now(:second)

    Enum.each(progress, fn {key, data} ->
      item_id =
        case Integer.parse(key) do
          {id, ""} -> if Repo.get(RepositoryItem, id), do: id
          _ -> nil
        end

      Repo.insert_all(
        PatSyncRepositoryResult,
        [
          %{
            pat_sync_run_id: job.id,
            repository_item_id: item_id,
            item_key: key,
            data: data,
            state: data["status"] || "pending",
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:pat_sync_run_id, :item_key]
      )

      if data["mode"] == "update" and data["status"] == "pending" do
        row = Repo.get_by!(PatSyncRepositoryResult, pat_sync_run_id: job.id, item_key: key)

        case SyncJobs.enqueue_update(row.id) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      if data["mode"] != "update" do
        Repo.update_all(
          from(r in PatSyncRepositoryResult,
            where: r.pat_sync_run_id == ^job.id and r.item_key == ^key
          ),
          set: [data: data, state: data["status"] || "pending", updated_at: now]
        )
      end
    end)

    :ok
  end

  defp repository_progress(job) do
    Repo.transact(fn ->
      seed_results(job, job.progress)
      rows = Repo.all(from r in PatSyncRepositoryResult, where: r.pat_sync_run_id == ^job.id)
      {:ok, Map.new(rows, &{&1.item_key, &1.data})}
    end)
  end

  @doc false
  def perform_repository(id, opts \\ []) do
    now = DateTime.utc_now(:second)
    token = Ecto.UUID.generate()

    {count, rows} =
      Repo.update_all(
        from(r in PatSyncRepositoryResult,
          where:
            r.id == ^id and r.state in ["pending", "running"] and
              (is_nil(r.lease_expires_at) or r.lease_expires_at <= ^now),
          select: r
        ),
        set: [
          state: "running",
          lease_owner: token,
          lease_expires_at: DateTime.add(now, 2_400),
          updated_at: now
        ]
      )

    case {count, rows} do
      {1, [row]} -> synchronize_repository(row, opts)
      _ -> {:ok, :busy}
    end
  end

  defp synchronize_repository(row, opts) do
    job = Repo.get!(PatSyncRun, row.pat_sync_run_id)
    sync = callback(opts, :sync_repository, &ForgeImports.PatRepositorySync.sync/5)

    authorize = fn ->
      with true <- Repo.get!(PatSyncRun, job.id).state in ["queued", "running"],
           {:ok, _, _} <- context(job),
           {1, _} <-
             Repo.update_all(
               from(r in PatSyncRepositoryResult,
                 where:
                   r.id == ^row.id and r.lease_owner == ^row.lease_owner and
                     r.lease_expires_at > ^DateTime.utc_now(:second)
               ),
               set: [lease_expires_at: DateTime.add(DateTime.utc_now(:second), 2_400)]
             ) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        false -> {:error, :configuration_changed}
        _ -> {:error, :lost_lease}
      end
    end

    result =
      with :ok <- authorize.(),
           {:ok, owner, config} <- context(job),
           {:ok, repository} <-
             ForgeRepos.fetch_organization_repository(
               job.organization_id,
               row.data["repository_id"]
             ),
           true <- repository.generation == row.data["generation"] do
        sync_target(
          sync,
          job,
          owner,
          config,
          repository,
          row.data["source_full_name"],
          [github_repository_id: row.data["github_repository_id"], authorize: authorize] ++
            test_options(opts, :repository_options)
        )
      else
        false -> {:error, :stale_repository}
        {:error, reason} -> {:error, reason}
      end

    now = DateTime.utc_now(:second)
    state = if result == :ok, do: "succeeded", else: "pending"

    data =
      Map.merge(row.data, %{
        "status" => state,
        "error" => if(result == :ok, do: nil, else: classification(elem(result, 1)))
      })

    settlement =
      Repo.transact(fn ->
        case Repo.update_all(
               from(r in PatSyncRepositoryResult,
                 where:
                   r.id == ^row.id and r.lease_owner == ^row.lease_owner and
                     r.lease_expires_at > ^now
               ),
               set: [
                 state: state,
                 data: data,
                 lease_owner: nil,
                 lease_expires_at: nil,
                 updated_at: now,
                 finished_at: if(state == "succeeded", do: now)
               ]
             ) do
          {1, _} ->
            with {:ok, _} <- SyncJobs.enqueue_pat_sync(job.id), do: {:ok, :ok}

          _ ->
            {:error, :lost_lease}
        end
      end)

    case settlement do
      {:ok, _} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_target(sync, job, owner, config, repository, source_full_name, options) do
    with {:ok, handoff} <- ForgeMirrors.pat_repository_handoff(config.id, repository.id) do
      case handoff do
        :legacy ->
          sync.(owner, config, repository, source_full_name, options)

        {:mirror, _binding} ->
          authorize = Keyword.fetch!(options, :authorize)

          with :ok <- authorize.(),
               {:ok, operation} <-
                 ForgeMirrors.schedule_pat_git_repository(
                   owner,
                   config.id,
                   repository.id,
                   "pat-sync:#{job.id}:repository:#{repository.id}"
                 ),
               {:ok, status} <-
                 ForgeMirrors.pat_git_repository_status(
                   owner,
                   config.id,
                   repository.id,
                   operation.id
                 ) do
            if status == :complete, do: :ok, else: {:error, :busy}
          end
      end
    end
  end

  defp persist_owned(job, changes) do
    now = DateTime.utc_now(:second)
    current = Repo.get!(PatSyncRun, job.id)
    progress = Keyword.get(changes, :progress)

    changes =
      if progress && progress != current.progress,
        do: Keyword.put(changes, :last_progress_at, now),
        else: changes

    {count, _} =
      Repo.update_all(
        from(j in PatSyncRun,
          where:
            j.id == ^job.id and j.lease_owner == ^job.lease_owner and j.lease_expires_at > ^now
        ),
        set: Keyword.put(changes, :updated_at, now)
      )

    if count == 1 do
      if Keyword.has_key?(changes, :progress) or Keyword.has_key?(changes, :state) do
        record_summary(job.id)
      end

      {:ok, job.id}
    else
      {:error, :lost_lease}
    end
  end

  @doc false
  def record_summary(id) do
    current = Repo.get!(PatSyncRun, id)
    rows = current.progress |> Map.values() |> Enum.sort_by(& &1["source_full_name"])

    summary = %{
      "total" => length(rows),
      "succeeded" => Enum.count(rows, &(&1["status"] == "succeeded")),
      "failed" => Enum.count(rows, &(&1["status"] == "failed")),
      "pending" => Enum.count(rows, &(&1["status"] == "pending")),
      "repositories" => Enum.map(rows, &Map.take(&1, ~w(source_full_name status error progress))),
      "error" => current.error,
      "status" => current.state
    }

    _ = PatSettings.record_sync_summary(current.id, summary)
    :ok
  end

  defp classification(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classification(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp classification(_), do: "repository_sync_failed"

  defp callback(opts, key, default) do
    if @allow_test_options, do: Keyword.get(opts, key, default), else: default
  end

  defp test_options(opts, key),
    do: if(@allow_test_options, do: Keyword.get(opts, key, []), else: [])
end
