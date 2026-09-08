defmodule ForgeGitHub.PullMergeWorker do
  @moduledoc """
  Bounded remote CAS execution for an already written coordinated merge.

  A successful push only yields the durable pre-push marker. A subsequent
  authenticated observation of the exact merged result and shared metadata can
  finalize locally through the coordinator boundary. Ref-only readiness never
  closes a pull. This module is not yet admitted by the worker pool.
  """
  alias ForgeGitHub.{
    InstallationToken,
    InstallationTokenBroker,
    IssueClient,
    LFSSync,
    PullClient,
    PullMergeObservation,
    PullSyncWorker,
    RefObservation
  }

  alias ForgeMirrors.{
    MirrorOperation,
    OrganizationMirror,
    PullMergeBoundary,
    PullMergeConfirmation,
    RepositoryMirror
  }

  alias Fornacast.Repo
  alias GitCore.Remote.{RefUpdate, SyncRequest}

  @test_callbacks Mix.env() == :test

  def process_operation(
        %MirrorOperation{kind: "merge.pull"} = operation,
        %DateTime{} = now,
        options
      )
      when is_list(options) do
    if operation.external_effect_marker do
      recover(operation, now, options)
    else
      with {:ok, context} <- PullMergeBoundary.context(operation, now),
           {:ok, sync} <- execution_context(context),
           {:ok, token} <- token(sync, options) do
        push(operation, now, sync, token, options)
      end
    end
  end

  def process_operation(_, _, _), do: {:error, :invalid_argument}

  defp recover(operation, now, options) do
    result =
      with {:ok, context} <- PullMergeBoundary.recovery_context(operation, now),
           {:ok, sync} <- execution_context(context),
           {:ok, token} <- token(sync, options),
           {:ok, remote} <- observe(sync, :base, token, options),
           {:ok, pair} <- pair(sync, token, options) do
        cond do
          remote.oid == context.intent.expected_base_oid ->
            # An unchanged remote ref is the only recovery observation that may
            # authorize another attempt, and it still requires fresh authority.
            with {:ok, fresh} <- PullMergeBoundary.context(operation, now),
                 {:ok, fresh_sync} <- execution_context(fresh) do
              push(operation, now, fresh_sync, token, options)
            end

          remote.oid == context.intent.merge_oid and pair.pull["merged"] == true ->
            finalize(operation, sync, pair, remote.oid)

          true ->
            PullMergeBoundary.record_observation(operation, now, next(now), %{
              remote_base_oid: remote.oid,
              provider_pull_id: pair.pull["id"]
            })
        end
      end

    case result do
      {:error, reason} -> PullMergeBoundary.defer(operation, now, next(now), reason)
      other -> other
    end
  end

  defp finalize(operation, sync, pair, remote_base_oid) do
    with {:ok, observation} <- PullMergeObservation.build(sync, pair, remote_base_oid),
         {:ok, merged_at, 0} <-
           DateTime.from_iso8601(observation.pull.confirmed_merge_state["merged_at"]),
         {:ok, result} <-
           ForgePulls.finalize_coordinated_merge(sync.intent.id, operation.id, merged_at,
             authorize: fn intent ->
               PullMergeConfirmation.authorize(
                 operation,
                 DateTime.utc_now(:second),
                 intent,
                 observation
               )
             end,
             confirm: fn projection, intent ->
               PullMergeConfirmation.confirm(
                 operation,
                 DateTime.utc_now(:second),
                 intent,
                 observation,
                 projection
               )
             end
           ) do
      {:ok, result.confirmation.operation}
    end
  end

  defp push(operation, now, sync, token, options) do
    with :ok <- local_refs(sync),
         :ok <- provider_ready(sync, token, options),
         :ok <- lfs(operation, sync, token, options) do
      # Remote.push_refs owns its own repository fence; nesting it under
      # with_ref_fences would deadlock its supervised transport task.
      with :ok <- local_refs(sync),
           :ok <- provider_ready(sync, token, options),
           {:ok, marked} <-
             PullMergeBoundary.mark(
               operation,
               now,
               operation.external_effect_marker,
               marker(sync.intent)
             ) do
        execute(marked, now, sync, token, options)
      end
    else
      {:incomplete, checkpoint} ->
        PullMergeBoundary.checkpoint_lfs(operation, now, checkpoint)

      {:error, _} = error ->
        error
    end
  end

  defp execute(marked, now, sync, _token, options) do
    # Recheck after marking: a slow LFS scan or provider request can outlive
    # the lease or installation permission that initially admitted the claim.
    with {:ok, push_token} <- push_token(sync, options),
         {:ok, _} <- PullMergeBoundary.context(marked, now) do
      update = %RefUpdate{
        ref: sync.intent.base_ref,
        expected_oid: sync.intent.expected_base_oid,
        proposed_oid: sync.intent.merge_oid
      }

      transport_options = [
        heartbeat: fn ->
          case PullMergeBoundary.context(marked, DateTime.utc_now(:second)) do
            {:ok, _} -> :ok
            {:error, _} -> :error
          end
        end
      ]

      result =
        callback(options, :push_remote, &GitCore.Remote.push_refs/4).(
          request(sync),
          push_token,
          [update],
          transport_options
        )

      reason =
        case result do
          :ok -> :remote_confirmation_required
          {:ok, _} -> :remote_confirmation_required
          {:error, reason} -> reason
          _ -> :invalid_remote_result
        end

      PullMergeBoundary.defer(marked, now, next(now), reason)
    else
      {:error, reason} -> PullMergeBoundary.defer(marked, now, next(now), reason)
    end
  end

  defp execution_context(context) do
    with true <- context.intent.state == "merge_written",
         base when not is_nil(base) <- Repo.get(RepositoryMirror, context.repository_mirror_id),
         head when not is_nil(head) <-
           Repo.get(
             RepositoryMirror,
             context.expected.pull_eligibility_proof["head"]["repository_mirror_id"]
           ),
         {:ok, repository} <- ForgeRepos.fetch_live_repository(context.repository_id),
         organization when not is_nil(organization) <-
           Repo.get(OrganizationMirror, context.organization_mirror_id),
         {:ok, base_route} <- route(base),
         {:ok, head_route} <- route(head) do
      {:ok,
       Map.merge(context, %{
         routing: %{base: base_route, head: head_route},
         repository_path: ForgeRepos.absolute_storage_path(repository),
         repository_generation: repository.generation,
         remote_owner: base_route.owner,
         remote_repository: base_route.repository,
         ref_name: context.intent.base_ref,
         ref_kind: :branch,
         lfs_enabled: organization.capabilities["lfs"] in [true, "enabled", "active"],
         git_proof:
           Map.new([:base, :head], fn side ->
             proof = context.expected.pull_eligibility_proof[Atom.to_string(side)]

             {side,
              %{
                repository_id: proof["repository_id"],
                repository_generation: proof["repository_generation"],
                ref: proof["ref"],
                oid: proof["oid"]
              }}
           end)
       })}
    else
      _ -> {:error, :stale_merge_identity}
    end
  end

  defp route(binding) do
    case String.split(binding.github_full_name || "", "/") do
      [owner, repository] when owner != "" and repository != "" ->
        {:ok, %{owner: owner, repository: repository}}

      _ ->
        {:error, :invalid_remote_repository}
    end
  end

  defp observe(sync, side, token, options) do
    route = sync.routing[side]
    repository = sync.expected.provider_identity[Atom.to_string(side) <> "_repository"]
    identity = %{github_object_id: repository["id"], github_node_id: repository["node_id"]}
    ref = if side == :base, do: sync.intent.base_ref, else: sync.intent.head_ref

    callback(options, :observe_ref, &RefObservation.observe/6).(
      token,
      route.owner,
      route.repository,
      identity,
      ref,
      request_options(sync, options)
    )
  end

  defp pair(sync, token, options) do
    route = sync.routing.base
    number = sync.expected.provider_identity["github_number"]
    opts = request_options(sync, options)

    with {:ok, pull} <-
           callback(options, :get_pull, &PullClient.get_pull/5).(
             token,
             route.owner,
             route.repository,
             number,
             opts
           ),
         {:ok, issue} <-
           callback(options, :get_pull_issue, &IssueClient.get_pull_issue/5).(
             token,
             route.owner,
             route.repository,
             number,
             opts
           ),
         true <-
           pull["id"] == sync.provider_pull_identity["id"] and
             pull["node_id"] == sync.provider_pull_identity["node_id"] and
             pull["number"] == number,
         true <-
           issue["id"] == sync.expected.provider_identity["github_issue_object_id"] and
             issue["node_id"] == sync.expected.provider_identity["github_issue_node_id"] and
             issue["number"] == number,
         true <-
           Enum.all?([:base, :head], fn side ->
             name = Atom.to_string(side)
             observed = pull[name] || %{}
             expected = sync.expected.provider_identity[name <> "_repository"]
             ref = if side == :base, do: sync.intent.base_ref, else: sync.intent.head_ref

             observed["ref"] == String.replace_prefix(ref, "refs/heads/", "") and
               Map.take(observed["repo"] || %{}, ["id", "node_id"]) == expected
           end) do
      {:ok, %{pull: pull, issue: issue}}
    else
      {:error, _} = error -> error
      _ -> {:error, :provider_identity_conflict}
    end
  end

  defp open_pair(%{pull: pull, issue: issue}, sync) do
    if pull["state"] == "open" and issue["state"] == "open" and pull["draft"] == false and
         pull["merged"] == false and is_nil(pull["merged_at"]) and
         pull["head"]["sha"] == sync.intent.expected_head_oid and
         pull["base"]["sha"] == sync.intent.expected_base_oid,
       do: :ok,
       else: {:error, :changed_provider_pull}
  end

  defp provider_ready(sync, token, options) do
    with {:ok, base} <- observe(sync, :base, token, options),
         {:ok, head} <- observe(sync, :head, token, options),
         true <-
           base.oid == sync.intent.expected_base_oid and head.oid == sync.intent.expected_head_oid,
         {:ok, pair} <- pair(sync, token, options),
         :ok <- open_pair(pair, sync) do
      :ok
    else
      false -> {:error, :changed_remote_refs}
      {:error, _} = error -> error
    end
  end

  defp local_refs(sync), do: PullSyncWorker.with_ref_fences(sync.git_proof, fn -> :ok end)

  defp lfs(_operation, %{lfs_enabled: false}, _token, _options), do: :ok

  defp lfs(operation, sync, _token, options) do
    authorize = fn ->
      case PullMergeBoundary.context(operation, DateTime.utc_now(:second)) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end

    with {:ok, token} <- push_token(sync, options),
         :ok <- authorize.() do
      callback(options, :lfs_gate, &LFSSync.ensure/7).(
        operation,
        sync,
        :outbound,
        sync.intent.merge_oid,
        token,
        request(sync),
        authorize: authorize
      )
    end
  end

  defp token(sync, options) do
    case callback(options, :token_fetch, &InstallationTokenBroker.fetch/2).(
           sync.github_installation_id,
           %{
             repository_ids:
               [
                 sync.expected.provider_identity["base_repository"]["id"],
                 sync.expected.provider_identity["head_repository"]["id"]
               ]
               |> Enum.uniq()
               |> Enum.sort(),
             permissions: %{
               "contents" => "read",
               "metadata" => "read",
               "pull_requests" => "read",
               "issues" => "read"
             }
           }
         ) do
      %InstallationToken{token: token} -> {:ok, token}
      {:error, _} = error -> error
      _ -> {:error, :credential_unavailable}
    end
  end

  defp push_token(sync, options) do
    scope = %{
      repository_ids: [sync.expected.provider_identity["base_repository"]["id"]],
      permissions: %{"contents" => "write"}
    }

    case callback(options, :token_fetch, &InstallationTokenBroker.fetch/2).(
           sync.github_installation_id,
           scope
         ) do
      %InstallationToken{token: token} -> {:ok, token}
      {:error, _} = error -> error
      _ -> {:error, :credential_unavailable}
    end
  end

  defp marker(intent),
    do: %{
      "phase" => "remote_cas_pending",
      "merge_operation_id" => intent.id,
      "merge_tree_oid" => intent.merge_tree_oid,
      "merge_oid" => intent.merge_oid
    }

  defp request(sync),
    do: %SyncRequest{
      provider: :github,
      owner: sync.remote_owner,
      repository: sync.remote_repository,
      credential_login: "x-access-token",
      repository_path: sync.repository_path
    }

  defp request_options(sync, options),
    do:
      options
      |> Keyword.get(:request_options, [])
      |> Keyword.put(:gate_key, {:github_installation, sync.github_installation_id})

  defp callback(options, key, default),
    do: if(@test_callbacks, do: Keyword.get(options, key, default), else: default)

  defp next(now), do: DateTime.add(now, 1, :second)
end
