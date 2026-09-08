defmodule ForgeGitHub.PullCreateWorker do
  @moduledoc """
  Bounded outbound pull creation and observation-only ambiguous-create recovery.

  Only a newly committed admission may POST. Recovery consumes one listing page
  per claim; no number of empty scans authorizes another POST. Paired immutable
  IDs are durably identified before a later claim removes the transport marker.
  """
  import Ecto.Query

  alias ForgeGitHub.{
    Client,
    Error,
    InstallationToken,
    InstallationTokenBroker,
    IssueClient,
    IssueSyncProjection,
    LabelClient,
    PullClient,
    PullCreateRecovery,
    PullSyncProjection,
    PullSyncWorker,
    RefObservation
  }

  alias ForgeMirrors.{CorrelationMarker, MirrorOperation, MirrorResourceState}
  alias Fornacast.Repo

  @test_callbacks Mix.env() == :test
  @expected ~w(pull_id issue_id expected_local_version expected_fields expected_issue_snapshot expected_merge_state provider_repositories pull_eligibility_proof)a

  def process_operation(%MirrorOperation{} = operation, %DateTime{} = now, sync, options)
      when is_map(sync) and is_list(options) do
    guarded(operation, now, options, fn ->
      result =
        with {:ok, token} <- token(sync, options) do
          if operation.state == :processing and sync.phase == :unmarked,
            do: first(operation, now, sync, token, options),
            else: recover(operation, now, sync, token, options)
        else
          {:error, reason} ->
            if operation.state == :processing,
              do: {:unmarked_error, reason},
              else: failure(operation, now, reason, options)
        end

      case result do
        {:error, reason} when operation.state == :effect_pending ->
          failure(operation, now, reason, options)

        other ->
          other
      end
    end)
  end

  def process_operation(_, _, _, _), do: {:error, :invalid_argument}

  defp first(operation, now, sync, token, options) do
    result =
      fenced(sync.git_proof, options, fn ->
        result =
          with :ok <- provider_refs(sync, token, options),
               {:ok, marked} <-
                 callback(options, :mark, &ForgeMirrors.mark_outbound_pull_creation/3).(
                   operation,
                   now,
                   Map.take(sync, @expected)
                 ) do
            # Never let a post-mark error escape to the parent's original processing
            # capability. It does not own the committed external-effect state.
            guarded(marked.operation, now, options, fn ->
              recovery =
                Map.merge(sync, %{intent: marked.intent, marker: marked.marker, phase: :recovery})

              if marked.newly_marked do
                with {:ok, attrs} <- create_attrs(recovery),
                     {:ok, created} <-
                       callback(options, :create_pull, &PullClient.create_pull/5).(
                         token,
                         sync.remote_owner,
                         sync.remote_repository,
                         attrs,
                         request_options(sync, options)
                       ),
                     {:ok, pair} <- observe_pair(sync, token, created["number"], options),
                     true <- candidate_matches?(candidate(created), pair),
                     {:ok, identified} <-
                       identify(marked.operation, now, marked.marker, pair, options) do
                  yield_identified(identified.operation, now, options)
                else
                  false -> failure(marked.operation, now, :identity_conflict, options)
                  {:error, reason} -> failure(marked.operation, now, reason, options)
                end
              else
                recover(marked.operation, now, recovery, token, options)
              end
            end)
          else
            {:error, reason} -> {:unmarked_error, reason}
          end

        {:entered, result}
      end)

    case result do
      {:entered, result} -> result
      {:error, reason} -> {:unmarked_error, reason}
    end
  end

  defp recover(%{state: :effect_pending} = operation, now, sync, token, options) do
    case operation.external_effect_marker["phase"] do
      "unresolved" -> recover_unresolved(operation, now, sync, token, options)
      "identified" -> cleanup(operation, now, sync, token, options)
      _ -> failure(operation, now, :invalid_creation_intent, options)
    end
  end

  defp recover(operation, now, _sync, _token, options),
    do: failure(operation, now, :invalid_transition, options)

  defp recover_unresolved(operation, now, sync, token, options) do
    scan = Map.get(sync, :recovery_checkpoint) || scan(operation)

    case PullCreateRecovery.decision(scan) do
      {:scan, page} ->
        with {:ok, rows} <-
               callback(options, :list_pulls_page, &PullClient.list_pulls_page/5).(
                 token,
                 sync.remote_owner,
                 sync.remote_repository,
                 page,
                 request_options(sync, options)
               ) do
          case PullCreateRecovery.advance(scan, rows, sync.intent.creation_uuid) do
            {:ok, next} ->
              checkpoint(operation, scan, next, now, options)

            {:error, :ambiguous_external_effect} ->
              conflict(
                operation,
                now,
                "ambiguous_external_effect",
                %{
                  "reason" => "multiple_uuid_matches",
                  "candidates" => conflicting_candidates(scan, rows, sync.intent.creation_uuid)
                },
                options
              )

            {:error, reason} ->
              failure(operation, now, reason, options)
          end
        else
          {:error, reason} -> failure(operation, now, reason, options)
        end

      {:found, candidate} ->
        with {:ok, pair} <- observe_pair(sync, token, candidate["github_number"], options),
             true <- candidate_matches?(candidate, pair),
             {:ok, identified} <-
               identify(operation, now, operation.external_effect_marker, pair, options) do
          yield_identified(identified.operation, now, options)
        else
          false -> failure(operation, now, :identity_conflict, options)
          {:error, reason} -> failure(operation, now, reason, options)
        end

      {:error, :ambiguous_external_effect} ->
        conflict(
          operation,
          now,
          "ambiguous_external_effect",
          %{"reason" => "zero_complete_scan"},
          options
        )

      {:error, reason} ->
        failure(operation, now, reason, options)
    end
  end

  defp cleanup(operation, now, _sync, token, options) do
    with {:ok, fresh} <-
           callback(
             options,
             :recovery_context,
             &ForgeMirrors.outbound_pull_creation_recovery_context/1
           ).(operation) do
      fenced(fresh.git_proof, options, fn ->
        with {:ok, fresh} <-
               callback(
                 options,
                 :recovery_context,
                 &ForgeMirrors.outbound_pull_creation_recovery_context/1
               ).(operation),
             :ok <- provider_refs(fresh, token, options),
             {:ok, pair} <-
               observe_pair(
                 fresh,
                 token,
                 fresh.marker["remote_identity"]["github_number"],
                 options
               ),
             true <- identified_pair?(fresh, pair) do
          case phase(fresh.intent, pair) do
            :desired ->
              confirm(operation, now, fresh, pair, token, options)

            :transport ->
              patch(operation, now, fresh, pair, token, options)

            :conflict ->
              conflict(
                operation,
                now,
                "third_party_metadata",
                %{
                  "reason" => "third_party_metadata",
                  "observation" => conflict_observation(pair)
                },
                options
              )
          end
        else
          false -> failure(operation, now, :identity_conflict, options)
          {:error, reason} -> failure(operation, now, reason, options)
        end
      end)
    else
      {:error, reason} -> failure(operation, now, reason, options)
    end
  end

  defp patch(operation, now, sync, before, token, options) do
    with {:ok, relationships} <-
           callback(options, :relationship_attrs, &relationship_attrs/4).(
             sync,
             sync.intent,
             token,
             options
           ),
         # Re-read after relationship HTTP calls; do not overwrite intervening
         # metadata from a third party while removing the correlation marker.
         {:ok, current} <- observe_pair(sync, token, before.pull.github_number, options),
         true <- identified_pair?(sync, current) and phase(sync.intent, current) == :transport,
         :ok <- provider_refs(sync, token, options),
         {:ok, authorized} <-
           callback(
             options,
             :recovery_context,
             &ForgeMirrors.outbound_pull_creation_recovery_context/1
           ).(operation),
         true <- same_active_context?(sync, authorized),
         attrs =
           Map.merge(
             Map.take(sync.intent.payload["issue_snapshot"], ~w(title body state state_reason)),
             relationships
           ),
         {:ok, _} <-
           callback(options, :update_pull_issue, &IssueClient.update_pull_issue/6).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             before.pull.github_number,
             attrs,
             request_options(sync, options)
           ),
         {:ok, after_effect} <- observe_pair(sync, token, before.pull.github_number, options),
         true <-
           identified_pair?(sync, after_effect) and phase(sync.intent, after_effect) == :desired do
      confirm(operation, now, sync, after_effect, token, options)
    else
      false -> failure(operation, now, :identity_conflict, options)
      {:error, reason} -> failure(operation, now, reason, options)
    end
  end

  defp confirm(operation, now, sync, pair, token, options) do
    with :ok <- provider_refs(sync, token, options) do
      intent = sync.intent

      observe = fn multi ->
        ForgePulls.append_sync_observe(multi, :resource, %{
          repository_id: intent.repository_id,
          resource_kind: :pull,
          local_resource_id: intent.pull_id,
          minimum_local_version: intent.local_version,
          expected_fields: intent.payload["pull_snapshot"],
          expected_merge_state: %{merged_at: nil, merge_commit_sha: nil}
        })
      end

      callback(options, :confirm, &ForgeMirrors.confirm_outbound_pull_creation/5).(
        operation,
        now,
        operation.external_effect_marker,
        pair,
        observe
      )
    else
      {:error, reason} -> failure(operation, now, reason, options)
    end
  end

  defp observe_pair(sync, token, number, options) do
    opts = request_options(sync, options)

    with {:ok, pull} <-
           callback(options, :get_pull, &PullClient.get_pull/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             number,
             opts
           ),
         {:ok, issue} <-
           callback(options, :get_pull_issue, &IssueClient.get_pull_issue/5).(
             token,
             sync.remote_owner,
             sync.remote_repository,
             number,
             opts
           ),
         # Scalar projections do not write attribution or invent local identity.
         {:ok, canonical_issue} <-
           IssueSyncProjection.from_remote_issue(
             Map.merge(issue, %{"labels" => [], "assignees" => []}),
             %{labels: [], assignees: []}
           ),
         {:ok, canonical_pull} <- PullSyncProjection.from_remote(pull, canonical_issue),
         {:ok, labels} <- provider_ids(issue["labels"]),
         {:ok, assignees} <- provider_ids(issue["assignees"]) do
      identity = %{
        "github_issue_object_id" => canonical_issue.github_object_id,
        "github_issue_node_id" => canonical_issue.github_node_id,
        "github_number" => number,
        "base_repository" => repository_identity(canonical_pull.base_repository),
        "head_repository" => repository_identity(canonical_pull.head_repository)
      }

      {:ok,
       %{
         pull: %{
           github_object_id: canonical_pull.github_object_id,
           github_node_id: canonical_pull.github_node_id,
           github_number: number,
           remote_updated_at: canonical_pull.remote_updated_at,
           confirmed_snapshot: canonical_pull.snapshot,
           confirmed_merge_state:
             Map.take(canonical_pull.merge_state, [:merged_at, :merge_commit_sha]) |> json(),
           provider_identity: identity
         },
         issue: %{
           github_object_id: canonical_issue.github_object_id,
           github_node_id: canonical_issue.github_node_id,
           github_number: number,
           remote_updated_at: canonical_issue.remote_updated_at,
           confirmed_snapshot:
             Map.merge(canonical_issue.snapshot, %{
               "label_github_ids" => labels,
               "assignee_github_ids" => assignees
             })
         }
       }}
    end
  end

  defp provider_ids(values) when is_list(values) and length(values) <= 512 do
    ids = Enum.map(values, & &1["id"])

    if Enum.all?(ids, &(is_integer(&1) and &1 > 0 and &1 <= 9_223_372_036_854_775_807)) and
         length(Enum.uniq(ids)) == length(ids),
       do: {:ok, Enum.sort(ids)},
       else: {:error, :invalid_projection}
  end

  defp provider_ids(_), do: {:error, :invalid_projection}

  defp same_active_context?(before, current) do
    stable =
      ~w(repository_mirror_id repository_id github_repository_id repository_generation ref oid)a

    before.intent == current.intent and before.marker == current.marker and
      before.routing == current.routing and
      Enum.all?(
        [:base, :head],
        &(Map.take(before.git_proof[&1], stable) == Map.take(current.git_proof[&1], stable))
      )
  end

  defp phase(intent, pair) do
    {:ok, body} = CorrelationMarker.append(nil, intent.creation_uuid)
    desired = intent.payload
    common = %{"body" => body, "state" => "open", "state_reason" => nil}
    transport_pull = Map.merge(desired["pull_snapshot"], common)

    transport_issue =
      desired["issue_snapshot"]
      |> Map.merge(common)
      |> Map.merge(%{"label_github_ids" => [], "assignee_github_ids" => []})

    cond do
      pair.pull.confirmed_snapshot == desired["pull_snapshot"] and
          pair.issue.confirmed_snapshot == desired["issue_snapshot"] ->
        :desired

      pair.pull.confirmed_snapshot == transport_pull and
          pair.issue.confirmed_snapshot == transport_issue ->
        :transport

      true ->
        :conflict
    end
  end

  defp identified_pair?(sync, pair) do
    remote = sync.marker["remote_identity"]

    candidate_matches?(remote, pair) and
      remote["github_issue_object_id"] == pair.issue.github_object_id and
      remote["github_issue_node_id"] == pair.issue.github_node_id and
      Map.take(pair.pull.provider_identity, ~w(base_repository head_repository)) ==
        sync.intent.payload["provider_repositories"] and
      pair.pull.confirmed_merge_state == %{"merged_at" => nil, "merge_commit_sha" => nil}
  end

  defp candidate_matches?(candidate, pair),
    do:
      candidate["github_object_id"] == pair.pull.github_object_id and
        candidate["github_node_id"] == pair.pull.github_node_id and
        candidate["github_number"] == pair.pull.github_number

  defp candidate(raw),
    do: %{
      "github_object_id" => raw["id"],
      "github_node_id" => raw["node_id"],
      "github_number" => raw["number"]
    }

  defp create_attrs(sync) do
    fields = sync.intent.payload["pull_snapshot"]
    base = sync.routing.base
    head = sync.routing.head

    with {:ok, body} <- CorrelationMarker.append(nil, sync.intent.creation_uuid) do
      attrs = %{
        "title" => fields["title"],
        "body" => body,
        "base" => short_ref(fields["base_ref"]),
        "draft" => fields["draft"],
        "maintainer_can_modify" => false
      }

      if base == head,
        do: {:ok, Map.put(attrs, "head", short_ref(fields["head_ref"]))},
        else:
          {:ok,
           Map.merge(attrs, %{
             "head" => head.remote_owner <> ":" <> short_ref(fields["head_ref"]),
             "head_repo" => head.remote_repository
           })}
    end
  end

  defp provider_refs(sync, token, options),
    do: callback(options, :provider_refs, &default_provider_refs/3).(sync, token, options)

  defp default_provider_refs(sync, token, options) do
    repositories =
      if Map.has_key?(sync, :intent),
        do: sync.intent.payload["provider_repositories"],
        else: sync.provider_repositories

    Enum.reduce_while([:base, :head], :ok, fn side, :ok ->
      route = sync.routing[side]
      proof = sync.git_proof[side]
      remote = repositories[Atom.to_string(side) <> "_repository"]
      expected = %{github_object_id: remote["id"], github_node_id: remote["node_id"]}

      case RefObservation.observe(
             token,
             route.remote_owner,
             route.remote_repository,
             expected,
             proof.ref,
             request_options(sync, options)
           ) do
        {:ok, %{oid: oid}} when oid == proof.oid -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :required_ref_unavailable}}
      end
    end)
  end

  defp relationship_attrs(sync, intent, token, options) do
    snapshot = intent.payload["issue_snapshot"]

    with {:ok, labels} <- label_names(sync, snapshot["label_github_ids"], token, options),
         {:ok, assignees} <-
           assignee_logins(sync, snapshot["assignee_github_ids"], token, options) do
      {:ok, %{"labels" => labels, "assignees" => assignees}}
    end
  end

  defp label_names(sync, ids, token, options) do
    rows =
      Repo.all(
        from m in MirrorResourceState,
          where:
            m.repository_mirror_id == ^sync.repository_mirror_id and m.resource_kind == :label and
              m.state == :confirmed and m.github_object_id in ^ids,
          select: {m.github_object_id, m.confirmed_snapshot}
      )
      |> Map.new()

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, names} ->
      name = get_in(rows, [id, "name"])

      with true <- is_binary(name),
           {:ok, %{"id" => ^id, "name" => ^name}} <-
             LabelClient.get_label(
               token,
               sync.remote_owner,
               sync.remote_repository,
               name,
               request_options(sync, options)
             ) do
        {:cont, {:ok, names ++ [name]}}
      else
        _ -> {:halt, {:error, :relationship_prerequisite}}
      end
    end)
  end

  defp assignee_logins(sync, ids, token, options) do
    rows =
      Repo.all(
        from u in ForgeAccounts.GitHubIdentity,
          where: u.kind == :user and u.github_user_id in ^ids,
          select: {u.github_user_id, u.login}
      )
      |> Map.new()

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, logins} ->
      login = rows[id]

      with true <- ForgeGitHub.RepositoryReference.valid_owner?(login),
           {:ok, %{"id" => ^id, "login" => ^login}} <-
             Client.request(token, :get, "/users/#{login}", request_options(sync, options)) do
        {:cont, {:ok, logins ++ [login]}}
      else
        _ -> {:halt, {:error, :relationship_prerequisite}}
      end
    end)
  end

  defp token(sync, options) do
    case callback(options, :token_fetch, &InstallationTokenBroker.fetch/2).(
           sync.github_installation_id,
           %{
             permissions: %{
               "metadata" => "read",
               "contents" => "read",
               "pull_requests" => "write",
               "issues" => "write"
             }
           }
         ) do
      %InstallationToken{token: token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :credential_unavailable}
    end
  end

  defp identify(operation, now, marker, pair, options),
    do:
      callback(options, :identify, &ForgeMirrors.identify_outbound_pull_creation/4).(
        operation,
        now,
        marker,
        pair
      )

  defp scan(operation),
    do: Map.get(operation.checkpoint, "pull_creation_recovery", PullCreateRecovery.initial())

  defp yield_identified(operation, now, options),
    do: checkpoint(operation, scan(operation), scan(operation), now, options)

  defp checkpoint(operation, old, next, now, options),
    do:
      callback(options, :checkpoint, &ForgeMirrors.checkpoint_outbound_pull_creation/5).(
        operation,
        old,
        next,
        now,
        now
      )

  defp fenced(proof, options, fun),
    do: callback(options, :with_ref_fences, &PullSyncWorker.with_ref_fences/2).(proof, fun)

  # A candidate is only diagnostic evidence. Never select one of two UUID
  # matches as an authenticated provider identity or create a mapping for it.
  defp conflicting_candidates(scan, %{pulls: pulls}, uuid) do
    current =
      pulls
      |> Enum.filter(&CorrelationMarker.matches?(&1["body"], uuid))
      |> Enum.map(&candidate/1)

    [scan["candidate"] | current] |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.take(2)
  end

  defp conflict_observation(pair),
    do: %{
      "pull_snapshot" => pair.pull.confirmed_snapshot,
      "issue_snapshot" => pair.issue.confirmed_snapshot,
      "provider_identity" => pair.pull.provider_identity,
      "github_object_id" => pair.pull.github_object_id,
      "github_node_id" => pair.pull.github_node_id,
      "github_number" => pair.pull.github_number
    }

  defp conflict(operation, now, kind, evidence, options),
    do:
      callback(options, :conflict, &ForgeMirrors.conflict_outbound_pull_creation/5).(
        operation,
        now,
        operation.external_effect_marker,
        kind,
        evidence
      )

  defp failure(%{state: :effect_pending} = operation, now, :identity_conflict, options),
    do: conflict(operation, now, "identity_conflict", %{"reason" => "pair_mismatch"}, options)

  defp failure(%{state: :effect_pending} = operation, now, reason, options) do
    {failure_class, retry_at} =
      case reason do
        %Error{kind: kind, retry_at: %DateTime{} = retry_at}
        when kind in [:primary_rate_limit, :secondary_rate_limit] ->
          {Atom.to_string(kind), retry_at}

        _ ->
          {"network", DateTime.add(now, 30)}
      end

    retry_at = if DateTime.after?(retry_at, now), do: retry_at, else: DateTime.add(now, 30)

    callback(options, :defer, &ForgeMirrors.defer_resource_effect/5).(
      operation,
      now,
      retry_at,
      failure_class,
      "resource_context_unavailable"
    )
  end

  defp failure(_operation, _now, reason, _options), do: {:error, reason}

  defp guarded(operation, now, options, fun) do
    fun.()
  rescue
    _ -> failure(operation, now, :worker_crash, options)
  catch
    _, _ -> failure(operation, now, :worker_crash, options)
  end

  defp request_options(sync, options) do
    extra = if @test_callbacks, do: Keyword.get(options, :client_options, []), else: []
    Keyword.put(extra, :gate_key, {:github_installation, sync.github_installation_id})
  end

  defp callback(options, key, default),
    do: if(@test_callbacks, do: Keyword.get(options, key, default), else: default)

  defp short_ref("refs/heads/" <> ref), do: ref

  defp repository_identity(repository),
    do: %{"id" => repository.github_object_id, "node_id" => repository.github_node_id}

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
