defmodule ForgeMirrors.PullOutboundCreation do
  @moduledoc """
  Admission and durable first-POST intent for a locally created pull.

  Only a newly committed marker grants the initial POST. A lost response or a
  repeated call returns recovery, never a second creator grant. The caller must
  verify live Git refs immediately before marking; this boundary rechecks the
  corresponding persisted proof and does no Git or provider I/O.
  """
  import Ecto.Query
  alias Fornacast.{DomainOutboxEvent, Repo}

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorResourceState,
    MirrorRefState,
    RepositoryMirror,
    OrganizationMirror,
    GitHubAppInstallation,
    PullCreationIntent,
    PullEligibility,
    IssueRelationships,
    PullMergeBoundary
  }

  @expected ~w(pull_id issue_id expected_local_version expected_fields expected_issue_snapshot expected_merge_state provider_repositories pull_eligibility_proof)a

  def context(%MirrorOperation{} = operation, lock_fun) do
    Repo.transaction(fn ->
      with {:ok, persisted, scope} <- lock_fun.(operation),
           {:ok, result} <- context_locked(persisted, scope),
           {:ok, _, _} <- lock_fun.(operation) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def context(_, _), do: {:error, :invalid_argument}

  def mark(%MirrorOperation{} = operation, %DateTime{} = now, expected, lock_fun, mark_fun)
      when is_map(expected) do
    if Repo.in_transaction?() do
      {:error, :transaction_not_allowed}
    else
      Repo.transaction(fn ->
        with {:ok, persisted, scope} <- lock_fun.(operation) do
          case context_locked(persisted, scope) do
            {:ok, %{phase: :recovery} = recovery} ->
              with {:ok, _, _} <- lock_fun.(operation) do
                %{
                  operation: persisted,
                  marker: persisted.external_effect_marker,
                  intent: recovery.intent,
                  newly_marked: false
                }
              else
                {:error, reason} -> Repo.rollback(reason)
              end

            {:ok, context} ->
              if Map.take(context, @expected) != expected, do: Repo.rollback(:stale_baseline)

              payload = %{
                "pull_snapshot" => context.expected_fields,
                "issue_snapshot" => context.expected_issue_snapshot,
                "merge_state" => context.expected_merge_state,
                "provider_repositories" => context.provider_repositories,
                "pull_eligibility_proof" => context.pull_eligibility_proof
              }

              with {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(payload),
                   {:ok, intent} <-
                     Repo.insert(
                       PullCreationIntent.create_changeset(%PullCreationIntent{}, %{
                         operation_id: persisted.id,
                         repository_mirror_id: scope.repository_mirror_id,
                         repository_id: scope.repository_id,
                         pull_id: context.pull_id,
                         issue_id: context.issue_id,
                         local_version: context.expected_local_version,
                         creation_uuid: Ecto.UUID.generate(),
                         payload: payload,
                         payload_fingerprint: fingerprint
                       })
                     ),
                   {:ok, persisted, _} <- lock_fun.(operation),
                   marker = marker(intent),
                   {:ok, marked} <- mark_fun.(persisted, now, marker) do
                %{operation: marked, marker: marker, intent: intent, newly_marked: true}
              else
                {:error, reason} -> Repo.rollback(reason)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def mark(_, _, _, _, _), do: {:error, :invalid_argument}

  @doc false
  def lock_recovery(operation, scope, marker) when is_map(marker) do
    if Repo.in_transaction?() and marker["action"] == "create_remote_pull" and
         marker["phase"] in ["unresolved", "identified"] and
         operation.external_effect_marker == marker and
         is_integer(marker["intent_id"]) do
      intent =
        Repo.one(
          from i in PullCreationIntent,
            where: i.id == ^marker["intent_id"] and i.operation_id == ^operation.id,
            lock: "FOR UPDATE"
        )

      with %PullCreationIntent{} <- intent,
           true <-
             intent.repository_id == scope.repository_id and
               intent.repository_mirror_id == scope.repository_mirror_id,
           true <-
             Map.take(
               marker,
               ~w(action creation_uuid intent_id intent_fingerprint pull_id issue_id expected_local_version)
             ) ==
               Map.take(
                 marker(intent),
                 ~w(action creation_uuid intent_id intent_fingerprint pull_id issue_id expected_local_version)
               ),
           {:ok, hash} <- ForgeMirrors.resource_fingerprint(intent.payload),
           true <- hash == intent.payload_fingerprint,
           true <- operation.cursor["issue_id"] == intent.issue_id do
        {:ok, intent}
      else
        _ -> {:error, :invalid_creation_intent}
      end
    else
      {:error, :invalid_creation_intent}
    end
  end

  def lock_recovery(_, _, _), do: {:error, :invalid_creation_intent}

  @doc false
  def active_recovery(operation, scope, intent) do
    stable =
      ~w(repository_mirror_id repository_id github_repository_id repository_generation ref oid)

    with :ok <- PullMergeBoundary.check_pull_unreserved(scope.repository_id, intent.pull_id),
         {:ok, pull} <- load_local(operation, scope),
         true <-
           pull.pull_id == intent.pull_id and pull.issue_id == intent.issue_id and
             pull.local_version >= intent.local_version,
         true <-
           Map.take(pull.fields, ~w(base_ref base_sha head_ref head_sha)) ==
             Map.take(intent.payload["pull_snapshot"], ~w(base_ref base_sha head_ref head_sha)),
         {:ok, proof, repositories} <- eligibility(scope, pull),
         true <- repositories == intent.payload["provider_repositories"],
         fresh = json(proof),
         true <-
           Map.take(fresh, ~w(organization_mirror_id github_installation_id)) ==
             Map.take(
               intent.payload["pull_eligibility_proof"],
               ~w(organization_mirror_id github_installation_id)
             ),
         true <-
           Enum.all?(
             ~w(base head),
             &(Map.take(fresh[&1], stable) ==
                 Map.take(intent.payload["pull_eligibility_proof"][&1], stable))
           ),
         {:ok, routing} <- routes(proof) do
      {:ok,
       %{
         git_proof: proof,
         pull_eligibility_proof: fresh,
         routing: routing,
         current_projection: %{
           repository_id: scope.repository_id,
           resource_kind: :pull,
           local_resource_type: "ForgePulls.PullRequest",
           local_resource_id: pull.pull_id,
           issue_id: pull.issue_id,
           local_version: pull.local_version,
           fields: pull.fields,
           head_repository_id: pull.head_repository_id,
           merge_state: %{merged_at: nil, merge_commit_sha: nil}
         }
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :ineligible_pull}
    end
  end

  defp context_locked(%{state: :effect_pending} = operation, scope) do
    with {:ok, intent} <- lock_recovery(operation, scope, operation.external_effect_marker) do
      {:ok,
       Map.merge(scope, %{
         phase: :recovery,
         intent: intent,
         marker: operation.external_effect_marker,
         pull_id: intent.pull_id,
         issue_id: intent.issue_id
       })}
    end
  end

  defp context_locked(
         %{state: :processing, external_effect_marker: nil, effect_marked_at: nil} = operation,
         scope
       ) do
    with :ok <- local_event(operation, scope),
         pull_id = ForgeMirrors.PullResourceBoundary.local_id(operation),
         :ok <- PullMergeBoundary.check_pull_unreserved(scope.repository_id, pull_id),
         {:ok, pull} <- load_local(operation, scope),
         :ok <- unmapped(scope, pull),
         {:ok, proof, repositories} <- eligibility(scope, pull),
         {:ok, issue_snapshot} <- issue_snapshot(scope, pull),
         {:ok, routing} <- routes(proof) do
      {:ok,
       Map.merge(scope, %{
         phase: :unmarked,
         pull_id: pull.pull_id,
         issue_id: pull.issue_id,
         expected_local_version: pull.local_version,
         expected_fields: pull.fields,
         expected_issue_snapshot: issue_snapshot,
         expected_merge_state: %{"merged_at" => nil, "merge_commit_sha" => nil},
         head_repository_id: pull.head_repository_id,
         provider_repositories: repositories,
         pull_eligibility_proof: json(proof),
         git_proof: proof,
         routing: routing
       })}
    end
  end

  defp context_locked(_, _), do: {:error, :invalid_transition}

  defp local_event(operation, scope) do
    c = operation.cursor

    event =
      if is_binary(c["outbox_event_id"]),
        do: Repo.get_by(DomainOutboxEvent, event_id: c["outbox_event_id"])

    with %DomainOutboxEvent{origin: :fornacast, aggregate_type: "issue"} <- event,
         true <- event.event_type in ~w(issue.created issue.updated),
         true <-
           c["trigger"] == "local" and c["origin"] == "fornacast" and
             c["issue_kind"] == "pull_request",
         true <- event.aggregate_id == to_string(c["issue_id"]),
         true <- event.payload["repository_id"] == scope.repository_id,
         true <-
           Enum.all?(
             ~w(repository_id issue_id issue_number issue_kind sync_version),
             &(c[&1] == event.payload[&1])
           ),
         true <-
           c["event_type"] == event.event_type and c["causation_id"] == event.causation_id and
             c["correlation_id"] == event.correlation_id,
         true <-
           Enum.all?(
             ~w(github_object_id github_node_id github_number local_resource_id github_issue_id),
             &is_nil(c[&1])
           ) do
      :ok
    else
      _ -> {:error, :invalid_local_event}
    end
  end

  defp load_local(operation, scope) do
    issue_id = operation.cursor["issue_id"]

    issue =
      Repo.one(
        from i in "issues",
          where: i.id == ^issue_id and i.repository_id == ^scope.repository_id,
          select: %{
            id: i.id,
            kind: i.kind,
            title: i.title,
            body: i.body,
            state: i.state,
            state_reason: i.state_reason,
            version: i.sync_version,
            number: i.number
          },
          lock: "FOR UPDATE"
      )

    pull =
      Repo.one(
        from p in "pull_requests",
          where: p.issue_id == ^issue_id and p.repository_id == ^scope.repository_id,
          select: %{
            pull_id: p.id,
            issue_id: p.issue_id,
            head_repository_id: p.head_repository_id,
            draft: p.draft,
            head_ref: p.head_ref,
            base_ref: p.base_ref,
            head_sha: p.head_sha,
            base_sha: p.base_sha,
            merged_at: type(p.merged_at, :utc_datetime),
            merge_commit_sha: p.merge_commit_sha
          },
          lock: "FOR UPDATE"
      )

    if issue && pull && issue.kind == "pull_request" && issue.state in ["open", "closed"] &&
         issue.version >= operation.cursor["sync_version"] &&
         issue.number == operation.cursor["issue_number"] &&
         is_integer(pull.head_repository_id) && is_nil(pull.merged_at) &&
         is_nil(pull.merge_commit_sha) do
      fields =
        Map.merge(
          Map.take(issue, [:title, :body, :state, :state_reason]),
          Map.take(pull, [:draft, :head_ref, :base_ref, :head_sha, :base_sha])
        )

      fields = Map.update!(fields, :body, fn value -> if value == "", do: nil, else: value end)
      {:ok, Map.merge(pull, %{local_version: issue.version, fields: json(fields)})}
    else
      {:error, :ineligible_pull}
    end
  end

  defp unmapped(scope, pull) do
    cond do
      Repo.exists?(
        from i in PullCreationIntent,
          where:
            i.repository_mirror_id == ^scope.repository_mirror_id and i.pull_id == ^pull.pull_id
      ) ->
        {:error, :creation_reserved}

      Repo.exists?(
        from m in MirrorResourceState,
          where:
            m.repository_mirror_id == ^scope.repository_mirror_id and
                ((m.resource_kind == :issue and m.local_resource_id == ^pull.issue_id) or
                   (m.resource_kind == :pull and m.local_resource_id == ^pull.pull_id))
      ) ->
        {:error, :identity_conflict}

      true ->
        :ok
    end
  end

  defp eligibility(scope, pull) do
    base = Repo.get!(RepositoryMirror, scope.repository_mirror_id)

    bindings =
      Repo.all(
        from b in RepositoryMirror,
          where:
            b.organization_mirror_id == ^base.organization_mirror_id and
              (b.id == ^base.id or b.repository_id == ^pull.head_repository_id),
          order_by: b.id,
          limit: 3,
          lock: "FOR UPDATE"
      )

    repositories = Enum.sort(Enum.uniq([scope.repository_id, pull.head_repository_id]))

    Repo.all(
      from r in ForgeRepos.Repository,
        where: r.id in ^repositories,
        order_by: r.id,
        lock: "FOR UPDATE"
    )

    org = Repo.get!(OrganizationMirror, base.organization_mirror_id)

    Repo.all(
      from u in ForgeAccounts.User, where: u.id == ^org.organization_id, lock: "FOR UPDATE"
    )

    Repo.all(
      from i in GitHubAppInstallation,
        where: i.github_installation_id == ^scope.github_installation_id,
        lock: "FOR UPDATE"
    )

    ids = Enum.map(bindings, & &1.id)

    Repo.all(
      from r in MirrorRefState,
        where: r.repository_mirror_id in ^ids and r.ref_name in ^[pull.base_ref, pull.head_ref],
        order_by: r.id,
        lock: "FOR UPDATE"
    )

    heads = Enum.filter(bindings, &(&1.repository_id == pull.head_repository_id))

    with [head] <- heads,
         true <-
           Enum.all?([base, head], &(is_binary(&1.github_node_id) and &1.github_node_id != "")),
         {:ok, proof} <-
           PullEligibility.check(
             base.id,
             pull.head_repository_id,
             Map.take(pull, [:head_ref, :base_ref, :head_sha, :base_sha])
           ) do
      {:ok, proof,
       %{
         "base_repository" => %{
           "id" => base.github_repository_id,
           "node_id" => base.github_node_id
         },
         "head_repository" => %{
           "id" => head.github_repository_id,
           "node_id" => head.github_node_id
         }
       }}
    else
      _ -> {:error, :ineligible_pull}
    end
  end

  defp issue_snapshot(scope, pull) do
    labels =
      Repo.all(
        from l in "issue_labels",
          where: l.issue_id == ^pull.issue_id,
          select: l.label_id,
          order_by: l.label_id,
          limit: 513
      )

    assignees =
      Repo.all(
        from a in "issue_assignees",
          where: a.issue_id == ^pull.issue_id,
          select: %{user_id: a.user_id, github_identity_id: a.github_identity_id},
          order_by: a.id,
          limit: 513
      )

    refs =
      Enum.map(assignees, fn a ->
        if a.user_id,
          do: %{kind: :local_user, id: a.user_id},
          else: %{kind: :github_identity, id: a.github_identity_id}
      end)

    with {:ok, relationships} <-
           IssueRelationships.resolve(scope.repository_mirror_id, :local, labels, refs) do
      {:ok,
       Map.merge(Map.take(pull.fields, ~w(title body state state_reason)), %{
         "label_github_ids" => Enum.map(relationships.labels, & &1.github_object_id),
         "assignee_github_ids" => Enum.map(relationships.assignees, & &1.github_user_id)
       })}
    end
  end

  defp marker(intent),
    do: %{
      "action" => "create_remote_pull",
      "phase" => "unresolved",
      "creation_uuid" => intent.creation_uuid,
      "intent_id" => intent.id,
      "intent_fingerprint" => intent.payload_fingerprint,
      "pull_id" => intent.pull_id,
      "issue_id" => intent.issue_id,
      "expected_local_version" => intent.local_version
    }

  defp routes(proof) do
    Enum.reduce_while([:base, :head], {:ok, %{}}, fn side, {:ok, acc} ->
      binding = Repo.get!(RepositoryMirror, proof[side].repository_mirror_id)

      case String.split(binding.github_full_name || "", "/") do
        [owner, name] when byte_size(owner) > 0 and byte_size(name) > 0 ->
          route = %{
            repository_mirror_id: binding.id,
            repository_id: binding.repository_id,
            github_repository_id: binding.github_repository_id,
            github_node_id: binding.github_node_id,
            remote_owner: owner,
            remote_repository: name
          }

          {:cont, {:ok, Map.put(acc, side, route)}}

        _ ->
          {:halt, {:error, :ineligible_pull}}
      end
    end)
  end

  defp json(value), do: JSON.decode!(JSON.encode!(value))
end
