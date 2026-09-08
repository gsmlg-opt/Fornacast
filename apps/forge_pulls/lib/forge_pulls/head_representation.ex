defmodule ForgePulls.HeadRepresentation do
  @moduledoc """
  Trusted, one-way representation of a previously external pull head.

  The caller must prove immutable provider identity and active mirror/ref
  eligibility in the same outer transaction. A repository ID is not that proof.
  This API never resolves a repository by name, grants authority, or writes Git.
  Existing represented heads remain immutable, including replay to the same ID;
  the caller's durable operation/mapping owns idempotency.
  """
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.Issue
  alias ForgePulls.{PullRequest, Sync}
  alias ForgeRepos.Repository
  alias Fornacast.{Audit, DomainOutbox}

  @max_id 9_223_372_036_854_775_807
  @keys Enum.sort([
          :repository_id,
          :resource_kind,
          :local_resource_id,
          :issue_id,
          :expected_local_version,
          :expected_fields,
          :expected_merge_state,
          :expected_head_repository_id,
          :head_repository_id,
          :expected_repository_generation,
          :expected_head_repository_generation,
          :provenance
        ])

  def append_sync_represent_head(%Multi{} = multi, key, request) do
    multi
    |> Multi.run({key, :request}, fn repo, _ ->
      with :ok <- validate(request) do
        # Same sorted advisory keys as coordinated merge reservations. Existing
        # row order remains Issue -> Pull -> Repository, not its inverse.
        [request.repository_id, request.head_repository_id]
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.each(fn id ->
          Ecto.Adapters.SQL.query!(
            repo,
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            ["fornacast:merge-reservation:#{id}"]
          )
        end)

        {:ok, :validated}
      end
    end)
    |> Sync.append_sync_observe({key, :observed}, request)
    |> Multi.run(key, fn repo, changes ->
      observed = Map.fetch!(changes, {key, :observed})

      with true <- observed.issue_id == request.issue_id,
           :ok <- unrepresented(observed),
           :ok <- repositories(repo, request),
           :ok <- distinct_refs(request),
           {1, _} <-
             repo.update_all(
               from(p in PullRequest,
                 where:
                   p.id == ^request.local_resource_id and
                     p.repository_id == ^request.repository_id and
                     p.issue_id == ^request.issue_id and is_nil(p.head_repository_id)
               ),
               set: [
                 head_repository_id: request.head_repository_id,
                 updated_at: DateTime.utc_now(:second)
               ]
             ),
           %Issue{} = issue <- repo.get(Issue, observed.issue_id),
           {:ok, issue} <-
             issue
             |> Changeset.change()
             |> Changeset.optimistic_lock(:sync_version, &(&1 + 1))
             |> repo.update(force: true, stale_error_field: :id) do
        {:ok,
         %{
           observed
           | head_repository_id: request.head_repository_id,
             local_version: issue.sync_version
         }}
      else
        false -> {:error, :stale_local_snapshot}
        {0, _} -> {:error, :immutable_identity}
        {:error, _} = error -> error
      end
    end)
    |> DomainOutbox.record_multi({key, :outbox}, fn changes ->
      result = Map.fetch!(changes, key)

      %{
        event_id: Ecto.UUID.generate(),
        aggregate_type: "issue",
        aggregate_id: to_string(result.issue_id),
        event_type: "issue.updated",
        origin: :github,
        causation_id: request.provenance[:causation_id],
        correlation_id: request.provenance[:correlation_id],
        payload: %{
          "repository_id" => result.repository_id,
          "issue_id" => result.issue_id,
          "issue_number" => result.issue_number,
          "issue_kind" => "pull_request",
          "sync_version" => result.local_version
        }
      }
    end)
    |> Audit.record_multi(
      {key, :audit},
      nil,
      "github_sync.applied",
      "repository",
      fn changes -> Map.fetch!(changes, key).repository_id end,
      fn changes ->
        result = Map.fetch!(changes, key)

        %{
          "repository_id" => result.repository_id,
          "resource_id" => result.local_resource_id,
          "resource_kind" => "pull",
          "action" => "represent_head",
          "head_repository_id" => result.head_repository_id
        }
      end
    )
  end

  defp validate(
         %{
           resource_kind: :pull,
           expected_head_repository_id: nil,
           provenance: %{origin: :github} = provenance
         } = request
       ) do
    if Enum.sort(Map.keys(request)) == @keys and
         Enum.all?(
           [
             :repository_id,
             :local_resource_id,
             :issue_id,
             :head_repository_id,
             :expected_repository_generation,
             :expected_head_repository_generation
           ],
           &positive?(request[&1])
         ) and
         Enum.all?(Map.keys(provenance), &(&1 in [:origin, :causation_id, :correlation_id])) and
         Enum.all?([:causation_id, :correlation_id], &bounded?(provenance[&1])),
       do: :ok,
       else: {:error, :invalid_sync_request}
  end

  defp validate(_), do: {:error, :invalid_sync_request}

  defp unrepresented(%{head_repository_id: nil}), do: :ok
  defp unrepresented(_), do: {:error, :immutable_identity}

  defp repositories(repo, request) do
    ids = [request.repository_id, request.head_repository_id] |> Enum.uniq() |> Enum.sort()

    rows =
      repo.all(
        from r in Repository,
          where:
            r.id in ^ids and is_nil(r.deleted_at) and r.lifecycle in [:ready, :synchronizing],
          order_by: r.id,
          lock: "FOR UPDATE"
      )
      |> Map.new(&{&1.id, &1})

    with %{generation: base_generation} <- rows[request.repository_id],
         %{generation: head_generation} <- rows[request.head_repository_id],
         true <-
           base_generation == request.expected_repository_generation and
             head_generation == request.expected_head_repository_generation do
      :ok
    else
      _ -> {:error, :stale_repository_identity}
    end
  end

  defp distinct_refs(request) do
    if request.repository_id == request.head_repository_id and
         request.expected_fields["head_ref"] == request.expected_fields["base_ref"],
       do: {:error, :invalid_head_identity},
       else: :ok
  end

  defp positive?(id), do: is_integer(id) and id > 0 and id <= @max_id
  defp bounded?(nil), do: true

  defp bounded?(value),
    do:
      is_binary(value) and byte_size(value) <= 255 and
        String.valid?(value) and not String.contains?(value, <<0>>)
end
