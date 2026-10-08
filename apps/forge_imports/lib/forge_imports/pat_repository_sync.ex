defmodule ForgeImports.PatRepositorySync do
  @moduledoc "PAT-backed, inbound Git synchronization for an already bound repository."

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, User}
  alias ForgeGitHub.LFS.TransferCoordinator
  alias ForgeMirrors.{PatConfiguration, PatSettings}
  alias ForgeRepos.Repository
  alias Fornacast.Repo
  alias GitCore.Remote
  alias GitCore.Remote.{ObservedRef, SyncRequest}
  alias GitLFS.PointerScanner
  alias GitLFS.PointerScanner.Scan

  @allow_test_options Mix.env() == :test
  @scan_batch_limit 100
  @work_lease_seconds 300
  @ref_batch_limit 32
  @zero_oid String.duplicate("0", 40)

  @doc "Downloads all remote branch/tag history and LFS bytes before publishing safe ref updates."
  def sync(owner, config, repository, source_full_name, opts \\ [])

  def sync(
        %User{} = owner,
        %PatConfiguration{} = config,
        %Repository{} = repository,
        source_full_name,
        opts
      )
      when is_binary(source_full_name) and is_list(opts) do
    with {:ok, options} <- options(opts),
         [remote_owner, remote_repository] <- String.split(source_full_name, "/"),
         true <- String.downcase(remote_owner) == config.github_organization,
         {:ok, identity, credential} <- credential(owner, config),
         authorize <- authorization(owner, config, repository, credential, options),
         :ok <- authorize.(),
         request <- %SyncRequest{
           provider: :github,
           owner: remote_owner,
           repository: remote_repository,
           credential_login: identity.login,
           repository_path: ForgeRepos.absolute_storage_path(repository)
         } do
      owner
      |> ForgeAccounts.with_github_credential(config.github_identity_id, fn token ->
        request
        |> synchronize(token, owner, repository, config, credential, authorize, options)
        |> safe_result()
      end)
      |> credential_result()
    else
      {:error, reason} -> safe_result({:error, reason})
      _invalid -> {:error, :invalid_request}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def sync(_, _, _, _, _), do: {:error, :invalid_request}

  defp synchronize(request, token, owner, repository, config, credential, authorize, options) do
    namespace = "pat-sync-#{config.id}"

    with :ok <- authorize.(),
         :ok <- verify_source(request, token, credential, options),
         {:ok, observations} <- options.fetch_refs.(request, token, namespace, authorize),
         :ok <- authorize.(),
         :ok <- verify_source(request, token, credential, options),
         {:ok, baselines} <- baselines(observations),
         {:ok, updates} <- plan(repository, observations, authorize),
         :ok <-
           ensure_lfs(
             request,
             token,
             repository,
             credential,
             baselines,
             authorize,
             options
           ),
         :ok <- authorize.() do
      apply_updates(owner, repository, updates, authorize)
    end
  end

  defp verify_source(request, token, credential, options) do
    case options.lookup_repository.(token, request.owner, request.repository,
           gate_key: {:saved_credential, credential.id}
         ) do
      {:ok, %{id: id, owner_login: login}} when is_binary(login) ->
        if id == options.github_repository_id and
             String.downcase(login) == String.downcase(request.owner),
           do: :ok,
           else: {:error, :source_changed}

      {:ok, _changed} ->
        {:error, :source_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plan(repository, observations, authorize) do
    observations
    |> Enum.chunk_every(@ref_batch_limit)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, updates} ->
      case plan_batch(repository, batch, authorize) do
        {:ok, planned} -> {:cont, {:ok, planned ++ updates}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp plan_batch(repository, observations, authorize) do
    ForgeRepos.with_write_fence(repository, :ref, fn path, remaining ->
      with :ok <- authorize.() do
        Enum.reduce_while(observations, {:ok, []}, fn observation, {:ok, updates} ->
          with :ok <- authorize.(),
               {:ok, local} <- GitCore.exact_ref(path, observation.ref, deadline_ms: remaining),
               :ok <- safe_ref_update(path, observation, local, remaining) do
            {:cont,
             {:ok,
              [%{ref: observation.ref, expected: local, proposed: observation.oid} | updates]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end)
  end

  defp safe_ref_update(_path, %ObservedRef{oid: oid}, oid, _remaining), do: :ok
  defp safe_ref_update(_path, %ObservedRef{}, nil, _remaining), do: :ok

  defp safe_ref_update(_path, %ObservedRef{ref: "refs/tags/" <> _}, _local, _remaining),
    do: {:error, :tag_retarget}

  defp safe_ref_update(path, %ObservedRef{oid: proposed}, local, remaining) do
    case GitCore.is_ancestor(path, local, proposed, deadline_ms: remaining) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :git_divergence}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_lfs(request, token, repository, credential, baselines, authorize, options) do
    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(baselines, [:deterministic]))
    scan_key = "pat-sync:#{repository.generation}:#{Base.encode16(fingerprint, case: :lower)}"

    with :ok <- authorize.(),
         {:ok, scan} <-
           PointerScanner.begin_scan(repository, scan_key, baselines,
             batch_limit: @scan_batch_limit
           ),
         {:ok, scan} <- complete_scan(repository, scan, request.repository_path, authorize),
         :ok <-
           transfer_pages(repository, scan, request, token, credential, nil, authorize, options),
         :ok <- authorize.(),
         {:ok, _prepared} <- PointerScanner.prepare_scan(scan) do
      :ok
    end
  end

  defp complete_scan(_repository, %Scan{state: state} = scan, _path, _authorize)
       when state in [:complete, :prepared, :published],
       do: {:ok, scan}

  defp complete_scan(repository, %Scan{} = scan, path, authorize) do
    lease_owner = "pat-sync-lfs:#{scan.id}:#{System.unique_integer([:positive])}"

    with :ok <- authorize.(),
         {:ok, work_items} <-
           PointerScanner.claim_work(scan, lease_owner,
             limit: @scan_batch_limit,
             lease_seconds: @work_lease_seconds
           ),
         :ok <- expand_work(work_items, lease_owner, scan, path, authorize),
         {:ok, resumed} <- PointerScanner.resume_scan(repository, scan.scan_key) do
      case {work_items, resumed.state} do
        {[], :scanning} -> {:error, :busy}
        _ -> complete_scan(repository, resumed, path, authorize)
      end
    end
  end

  defp expand_work(work_items, lease_owner, scan, path, authorize) do
    Enum.reduce_while(work_items, :ok, fn work, :ok ->
      with :ok <- authorize.(),
           {:ok, expansion} <-
             GitCore.expand_lfs_scan_object(
               path,
               work.object_oid,
               work.object_kind,
               work.tree_offset,
               scan.batch_limit
             ),
           :ok <- authorize.(),
           {:ok, _result} <- PointerScanner.record_expansion(work, lease_owner, expansion) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp transfer_pages(repository, scan, request, token, credential, cursor, authorize, options) do
    transfer_opts =
      Keyword.merge(options.lfs_transfer_options,
        gate_key: {:saved_credential, credential.id},
        authorize: authorize
      )

    with :ok <- authorize.(),
         {:ok, next} <-
           TransferCoordinator.process_page(
             repository,
             scan,
             :inbound,
             token,
             request.owner,
             request.repository,
             cursor,
             transfer_opts
           ),
         :ok <- authorize.() do
      case next do
        nil ->
          :ok

        next when is_binary(next) and next != cursor ->
          transfer_pages(repository, scan, request, token, credential, next, authorize, options)

        _invalid ->
          {:error, :invalid_lfs_state}
      end
    end
  end

  defp apply_updates(owner, repository, updates, authorize) do
    updates
    |> Enum.chunk_every(min(@ref_batch_limit, GitCore.Limits.get(:receive_pack_commands)))
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case apply_batch(owner, repository, batch, authorize) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_batch(owner, repository, updates, authorize) do
    ForgeRepos.with_write_fence(repository, :ref, fn path, remaining ->
      with :ok <- authorize.(),
           {:ok, pending} <- current_refs(path, updates, remaining) do
        journal_and_apply(owner, repository, path, pending, remaining, authorize)
      end
    end)
  end

  defp journal_and_apply(_owner, _repository, _path, [], _remaining, _authorize), do: :ok

  defp journal_and_apply(owner, repository, path, updates, remaining, authorize) do
    deadline = System.monotonic_time(:millisecond) + remaining
    commands = Enum.map(updates, &{&1.expected || @zero_oid, &1.proposed, &1.ref})

    with :ok <- authorize.(),
         {:ok, _operations} <-
           ForgeRepos.prepare_inbound_git_operations(
             owner,
             repository,
             "pat-sync-#{Ecto.UUID.generate()}",
             commands,
             deadline
           ) do
      result = write_refs(path, updates, deadline, authorize)

      # Recovery only classifies observed refs and commits bookkeeping; it cannot apply
      # an unstarted ref write. The same fence recovers incomplete bookkeeping on retry.
      with :ok <-
             ForgeRepos.GitWriteRecovery.reconcile_repository_locked(repository, path, deadline) do
        result
      end
    end
  end

  defp write_refs(path, updates, deadline, authorize) do
    Enum.reduce_while(updates, :ok, fn update, :ok ->
      with :ok <- authorize.(),
           {:ok, _oid} <-
             GitCore.compare_and_swap_ref(
               path,
               update.ref,
               update.expected,
               update.proposed,
               :fast_forward,
               deadline_ms: max(deadline - System.monotonic_time(:millisecond), 0)
             ) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp current_refs(path, updates, remaining) do
    Enum.reduce_while(updates, {:ok, []}, fn update, {:ok, pending} ->
      case GitCore.exact_ref(path, update.ref, deadline_ms: remaining) do
        {:ok, current} when current == update.proposed ->
          {:cont, {:ok, pending}}

        {:ok, current} when current == update.expected ->
          {:cont, {:ok, [update | pending]}}

        {:ok, _changed} ->
          {:halt, {:error, :stale_ref}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp authorization(owner, config, repository, credential, options) do
    fn ->
      with :ok <- options.authorize.(),
           {:ok, %{config: current}} <- PatSettings.view(owner, config.organization_id),
           true <-
             current.id == config.id and current.owner_user_id == owner.id and
               current.github_identity_id == config.github_identity_id and
               current.github_organization == config.github_organization and
               current.lock_version == config.lock_version,
           true <- current.enabled and not current.paused,
           {:ok, _owner} <-
             ForgeAccounts.organization_github_owner(owner, config.organization_id, owner.id),
           {:ok, _, current_credential} <- credential(owner, config),
           true <- current_credential == credential,
           {:ok, current_repository} <- ForgeRepos.fetch_live_repository(repository.id),
           true <-
             current_repository.owner_user_id == config.organization_id and
               current_repository.generation == repository.generation do
        :ok
      else
        false -> authorization_mismatch(owner, config, repository)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp authorization_mismatch(owner, config, repository) do
    case ForgeRepos.fetch_live_repository(repository.id) do
      {:ok, current} when current.generation != repository.generation ->
        {:error, :stale_repository}

      {:ok, current} when current.owner_user_id != config.organization_id ->
        {:error, :stale_repository}

      _ ->
        case PatSettings.view(owner, config.organization_id) do
          {:ok, %{config: %{paused: true}}} -> {:error, :paused}
          {:ok, %{config: %{enabled: false}}} -> {:error, :not_enabled}
          _ -> {:error, :stale}
        end
    end
  end

  defp credential(owner, config) do
    with %GitHubIdentity{kind: :user, local_user_id: actor_id} = identity <-
           Repo.get(GitHubIdentity, config.github_identity_id),
         true <- actor_id == owner.id and config.owner_user_id == owner.id,
         %GitHubCredential{status: :valid} = credential <-
           Repo.get_by(GitHubCredential,
             github_identity_id: identity.id,
             local_user_id: owner.id
           ) do
      {:ok, identity, credential}
    else
      _invalid -> {:error, :credential_unavailable}
    end
  end

  defp baselines(observations) when is_list(observations) do
    Enum.reduce_while(observations, {:ok, []}, fn
      %ObservedRef{ref: "refs/heads/" <> suffix, oid: oid} = observation, {:ok, acc}
      when suffix != "" ->
        {:cont, {:ok, [%{ref_name: observation.ref, ref_kind: :branch, oid: oid} | acc]}}

      %ObservedRef{ref: "refs/tags/" <> suffix, oid: oid} = observation, {:ok, acc}
      when suffix != "" ->
        {:cont, {:ok, [%{ref_name: observation.ref, ref_kind: :tag, oid: oid} | acc]}}

      _invalid, _acc ->
        {:halt, {:error, :invalid_ref}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.sort_by(values, & &1.ref_name)}
      error -> error
    end
  end

  defp baselines(_invalid), do: {:error, :invalid_ref}

  defp options(opts) do
    keys = [
      :authorize,
      :github_repository_id,
      :lookup_repository,
      :fetch_refs,
      :lfs_transfer_options
    ]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in keys)) and
         (@allow_test_options or Keyword.keys(opts) -- [:authorize, :github_repository_id] == []) do
      fetch = Keyword.get(opts, :fetch_refs)
      authorize = Keyword.get(opts, :authorize, fn -> :ok end)
      github_repository_id = Keyword.get(opts, :github_repository_id)
      lookup = Keyword.get(opts, :lookup_repository, &ForgeGitHub.Client.repository/4)

      if is_function(authorize, 0) and (is_nil(fetch) or is_function(fetch, 3)) and
           is_function(lookup, 4) and is_integer(github_repository_id) and
           github_repository_id > 0 do
        {:ok,
         %{
           authorize: authorize,
           github_repository_id: github_repository_id,
           lookup_repository: lookup,
           lfs_transfer_options: Keyword.get(opts, :lfs_transfer_options, []),
           fetch_refs: fn request, token, namespace, authorize ->
             if fetch do
               fetch.(request, token, namespace)
             else
               Remote.fetch_observed_refs(request, token, namespace,
                 heartbeat: authorize,
                 cancel?: fn -> authorize.() != :ok end
               )
             end
           end
         }}
      else
        {:error, :invalid_argument}
      end
    else
      {:error, :invalid_argument}
    end
  end

  defp credential_result({:ok, :ok}), do: :ok
  defp credential_result({:ok, {:error, reason}}), do: safe_result({:error, reason})
  defp credential_result({:error, reason}), do: safe_result({:error, reason})

  defp safe_result(:ok), do: :ok
  defp safe_result({:error, %{kind: kind}}) when is_atom(kind), do: {:error, kind}
  defp safe_result({:error, {:unavailable, :stale_repository}}), do: {:error, :stale_repository}
  defp safe_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp safe_result(_unexpected), do: {:error, :unavailable}
end
