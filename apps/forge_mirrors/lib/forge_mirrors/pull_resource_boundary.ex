defmodule ForgeMirrors.PullResourceBoundary do
  @moduledoc false
  # This schemaless read avoids a ForgeMirrors -> ForgePulls dependency cycle.
  # Only the caller-supplied domain Multi mutates the canonical pull aggregate.
  import Ecto.Query
  alias Fornacast.Repo

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorRefState,
    OrganizationMirror,
    PullEligibility,
    RepositoryMirror
  }

  def local_id(operation) do
    case Map.fetch(operation.cursor, "issue_id") do
      {:ok, id} when is_integer(id) and id > 0 ->
        Repo.one(
          from p in "pull_requests",
            join: b in RepositoryMirror,
            on: b.repository_id == p.repository_id,
            where: b.id == ^operation.repository_mirror_id and p.issue_id == ^id,
            select: p.id
        ) || :invalid

      :error ->
        operation.cursor["local_resource_id"]

      _ ->
        :invalid
    end
  end

  def context(scope, mapping) do
    with %{local_resource_type: "ForgePulls.PullRequest", local_resource_id: id} <- mapping,
         true <- is_integer(id) and id > 0,
         true <-
           mapping.state in [:pending, :confirmed] and positive?(mapping.github_object_id) and
             positive?(mapping.github_number) and node?(mapping.github_node_id),
         %{issue_id: issue_id, local_version: version} <- load(scope.repository_id, id, false) do
      {:ok,
       %{
         issue_id: issue_id,
         local_resource_id: id,
         local_version: version,
         provider_identity: mapping.provider_identity,
         confirmed_merge_state: mapping.confirmed_merge_state
       }}
    else
      _ -> {:error, :invalid_pull_mapping}
    end
  end

  def mark(scope, mapping, marker) do
    with true <- marker["action"] in ~w(update_remote_pull_issue set_remote_pull_draft),
         true <- mapping != nil and marker["github_object_id"] == mapping.github_object_id,
         true <- marker["resource_state_lock_version"] == mapping.lock_version,
         true <-
           marker["github_node_id"] == mapping.github_node_id and
             marker["github_number"] == mapping.github_number,
         true <-
           valid_identity?(marker["provider_identity"]) and
             compatible_identity?(mapping.provider_identity, marker["provider_identity"]),
         true <- marker["provider_identity"]["github_number"] == mapping.github_number,
         {:ok, pull} <-
           eligible(scope, mapping, marker["pull_eligibility_proof"], marker["provider_identity"]),
         {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(pull.fields),
         true <-
           marker["expected_local_version"] == pull.local_version and
             marker["expected_local_fingerprint"] == fingerprint,
         true <- marker["expected_merge_state"] == merge_state(pull) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :stale_baseline}
    end
  end

  def confirm(scope, mapping, expected, confirmation) do
    with true <- mapping != nil and mapping.state in [:pending, :confirmed],
         true <- valid_identity?(confirmation[:provider_identity]),
         true <-
           mapping.provider_identity == expected[:provider_identity] and
             compatible_identity?(mapping.provider_identity, confirmation[:provider_identity]),
         true <- marker_identity_matches?(expected, confirmation),
         true <- confirmation.provider_identity["github_number"] == confirmation.github_number,
         true <- confirmation[:state] == :confirmed,
         {:ok, pull} <-
           eligible(
             scope,
             mapping,
             expected[:pull_eligibility_proof],
             confirmation.provider_identity
           ),
         true <-
           expected[:expected_merge_state] == merge_state(pull) and
             confirmation[:confirmed_merge_state] == merge_state(pull),
         true <-
           is_map(expected[:expected_fields]) and is_integer(expected[:expected_local_version]) and
             expected.expected_local_version > 0,
         true <-
           ref_fields(expected.expected_fields) ==
             json(Map.take(pull, [:head_ref, :head_sha, :base_ref, :base_sha])) and
             ref_fields(confirmation.confirmed_snapshot) == ref_fields(expected.expected_fields) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :stale_baseline}
    end
  end

  def projection(projection, expected, confirmation) do
    exact = projection.local_version == confirmation.confirmed_local_version

    issue_id =
      Repo.one(
        from p in "pull_requests",
          where:
            p.id == ^projection.local_resource_id and p.repository_id == ^projection.repository_id,
          select: p.issue_id
      )

    valid =
      issue_id != nil and projection[:issue_id] == issue_id and
        json(projection[:merge_state]) == confirmation[:confirmed_merge_state] and
        if exact,
          do: projection[:fields] == confirmation.confirmed_snapshot,
          else:
            confirmation.confirmed_local_version == expected[:expected_local_version] and
              is_map(expected[:effect_marker]) and
              Map.take(projection[:fields] || %{}, ~w(head_ref head_sha base_ref base_sha)) ==
                Map.take(confirmation.confirmed_snapshot, ~w(head_ref head_sha base_ref base_sha))

    if valid, do: :ok, else: {:error, :invalid_projection}
  end

  defp eligible(scope, mapping, proof, identity) do
    with true <-
           is_map(proof) and positive?(proof["organization_mirror_id"]) and
             valid_identity?(identity),
         %{local_resource_type: "ForgePulls.PullRequest", local_resource_id: id} <- mapping,
         %{head_repository_id: head_id} = pull when is_integer(head_id) <-
           load(scope.repository_id, id, true) do
      # Organization and base binding are already locked by lock_resource_operation.
      # Lock every row contributing to the proof before re-querying its predicate.
      base_binding = Repo.get!(RepositoryMirror, scope.repository_mirror_id)

      bindings =
        Repo.all(
          from b in RepositoryMirror,
            where:
              b.organization_mirror_id == ^base_binding.organization_mirror_id and
                b.repository_id in ^[scope.repository_id, head_id],
            order_by: b.id,
            lock: "FOR UPDATE"
        )

      repository_ids = [scope.repository_id, head_id] |> Enum.uniq() |> Enum.sort()

      Repo.all(
        from r in ForgeRepos.Repository,
          where: r.id in ^repository_ids,
          order_by: r.id,
          lock: "FOR UPDATE"
      )

      organization = Repo.get!(OrganizationMirror, base_binding.organization_mirror_id)

      Repo.all(
        from u in ForgeAccounts.User,
          where: u.id == ^organization.organization_id,
          lock: "FOR UPDATE"
      )

      Repo.all(
        from i in GitHubAppInstallation,
          where: i.github_installation_id == ^scope.github_installation_id,
          lock: "FOR UPDATE"
      )

      binding_ids = Enum.map(bindings, & &1.id)

      Repo.all(
        from r in MirrorRefState,
          where:
            r.repository_mirror_id in ^binding_ids and
              r.ref_name in ^[pull.head_ref, pull.base_ref],
          order_by: r.id,
          lock: "FOR UPDATE"
      )

      refs = Map.take(pull, [:head_ref, :head_sha, :base_ref, :base_sha])

      with {:ok, current} <- PullEligibility.check(scope.repository_mirror_id, head_id, refs),
           true <- json(current) == json(proof),
           true <-
             repository_identity?(
               bindings,
               current.base.repository_mirror_id,
               identity["base_repository"]
             ),
           true <-
             repository_identity?(
               bindings,
               current.head.repository_mirror_id,
               identity["head_repository"]
             ) do
        {:ok, pull}
      else
        _ -> {:error, :ineligible_pull}
      end
    else
      _ -> {:error, :ineligible_pull}
    end
  end

  defp repository_identity?(bindings, id, identity) do
    case Enum.find(bindings, &(&1.id == id)) do
      nil ->
        false

      binding ->
        identity == %{"id" => binding.github_repository_id, "node_id" => binding.github_node_id}
    end
  end

  defp load(repository_id, id, locked) do
    issue_query =
      from i in "issues",
        where:
          i.repository_id == ^repository_id and i.kind == "pull_request" and
            i.id in subquery(
              from p in "pull_requests",
                where: p.id == ^id and p.repository_id == ^repository_id,
                select: p.issue_id
            ),
        select: %{
          id: i.id,
          sync_version: i.sync_version,
          title: i.title,
          body: i.body,
          state: i.state,
          state_reason: i.state_reason
        }

    issue = Repo.one(if locked, do: lock(issue_query, "FOR UPDATE"), else: issue_query)

    if issue do
      query =
        from p in "pull_requests",
          where: p.id == ^id and p.repository_id == ^repository_id and p.issue_id == ^issue.id,
          select: %{
            issue_id: p.issue_id,
            head_repository_id: p.head_repository_id,
            head_ref: p.head_ref,
            base_ref: p.base_ref,
            head_sha: p.head_sha,
            base_sha: p.base_sha,
            draft: p.draft,
            merged_at: type(p.merged_at, :utc_datetime),
            merge_commit_sha: p.merge_commit_sha
          }

      case Repo.one(if locked, do: lock(query, "FOR UPDATE"), else: query) do
        nil ->
          nil

        pull ->
          fields =
            Map.merge(
              Map.take(issue, [:title, :body, :state, :state_reason]),
              Map.take(pull, [:draft, :head_ref, :head_sha, :base_ref, :base_sha])
            )
            |> json()

          pull |> Map.put(:local_version, issue.sync_version) |> Map.put(:fields, fields)
      end
    end
  end

  defp merge_state(pull), do: json(Map.take(pull, [:merged_at, :merge_commit_sha]))
  defp compatible_identity?(nil, _), do: true
  defp compatible_identity?(identity, observed), do: identity == observed
  defp marker_identity_matches?(%{effect_marker: nil}, _), do: true

  defp marker_identity_matches?(%{effect_marker: marker} = expected, confirmation)
       when is_map(marker) do
    with {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(expected[:expected_fields]) do
      marker["expected_local_fingerprint"] == fingerprint and
        marker["resource_state_lock_version"] == expected[:resource_state_lock_version] and
        marker["provider_identity"] == confirmation.provider_identity and
        marker["pull_eligibility_proof"] == json(expected[:pull_eligibility_proof]) and
        marker["expected_merge_state"] == expected[:expected_merge_state] and
        marker["expected_local_version"] == expected[:expected_local_version]
    else
      _ -> false
    end
  end

  defp marker_identity_matches?(_, _), do: false
  defp ref_fields(fields), do: Map.take(fields, ~w(head_ref head_sha base_ref base_sha))
  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()

  defp valid_identity?(
         %{
           "github_issue_object_id" => id,
           "github_issue_node_id" => node,
           "github_number" => number,
           "head_repository" => head,
           "base_repository" => base
         } = identity
       ) do
    map_size(identity) == 5 and positive?(id) and positive?(number) and node?(node) and
      valid_repository?(head) and valid_repository?(base)
  end

  defp valid_identity?(_), do: false

  defp valid_repository?(%{"id" => id, "node_id" => node} = value),
    do: map_size(value) == 2 and positive?(id) and node?(node)

  defp valid_repository?(_), do: false
  defp positive?(id), do: is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807

  defp node?(node),
    do: is_binary(node) and byte_size(node) in 1..255 and String.trim(node) == node
end
