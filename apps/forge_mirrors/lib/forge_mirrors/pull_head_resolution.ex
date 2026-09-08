defmodule ForgeMirrors.PullHeadResolution do
  @moduledoc """
  Leased, immutable repository identity resolution for a new remote pull.

  Absence is scoped to the locked organization mirror, never inferred from a
  repository name. A known but unready head is retryable, not an external head.
  Returned proofs describe persisted baselines only: the caller must still
  authenticate the paired provider observations and freshly verify Git refs.
  """
  import Ecto.Query
  alias Fornacast.Repo

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorResourceState,
    MirrorRefState,
    RepositoryMirror,
    OrganizationMirror,
    GitHubAppInstallation,
    PullEligibility
  }

  @fields ~w(base_ref base_sha body draft head_ref head_sha state state_reason title)
  @max_id 9_223_372_036_854_775_807

  def resolve(%MirrorOperation{} = operation, identity, snapshot, lock_fun)
      when is_function(lock_fun, 1) do
    with :ok <- validate(identity, snapshot) do
      Repo.transaction(fn ->
        with {:ok, persisted, scope} <- lock_fun.(operation),
             :ok <- new_remote?(persisted, identity),
             :ok <- missing?(scope, identity),
             {:ok, result} <- resolve_locked(scope, identity.provider_identity, snapshot),
             {:ok, persisted, _} <- lock_fun.(operation),
             :ok <- new_remote?(persisted, identity) do
          result
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def resolve(_, _, _, _), do: {:error, :identity_conflict}

  @doc false
  def resolve_existing(scope, identity, snapshot) do
    with :ok <- validate(identity, snapshot),
         do: resolve_locked(scope, identity.provider_identity, snapshot)
  end

  defp resolve_locked(scope, identity, snapshot) do
    base = Repo.get!(RepositoryMirror, scope.repository_mirror_id)
    head_identity = identity["head_repository"]

    candidates =
      if is_nil(head_identity),
        do: dynamic([b], b.id == ^base.id),
        else:
          dynamic(
            [b],
            b.id == ^base.id or b.github_repository_id == ^head_identity["id"] or
              b.github_node_id == ^head_identity["node_id"]
          )

    bindings =
      Repo.all(
        from b in RepositoryMirror,
          where: b.organization_mirror_id == ^base.organization_mirror_id,
          where: ^candidates,
          order_by: b.id,
          limit: 4,
          lock: "FOR UPDATE"
      )

    heads =
      if is_nil(head_identity),
        do: [],
        else:
          Enum.filter(
            bindings,
            &(&1.github_repository_id == head_identity["id"] or
                &1.github_node_id == head_identity["node_id"])
          )

    repository_ids =
      bindings
      |> Enum.map(& &1.repository_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    Repo.all(
      from r in ForgeRepos.Repository,
        where: r.id in ^repository_ids,
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

    refs = %{
      base_ref: snapshot["base_ref"],
      base_sha: snapshot["base_sha"],
      head_ref: snapshot["head_ref"],
      head_sha: snapshot["head_sha"]
    }

    Repo.all(
      from r in MirrorRefState,
        where: r.repository_mirror_id in ^ids and r.ref_name in ^[refs.base_ref, refs.head_ref],
        order_by: r.id,
        lock: "FOR UPDATE"
    )

    cond do
      identity["base_repository"] != %{
        "id" => base.github_repository_id,
        "node_id" => base.github_node_id
      } ->
        {:error, :identity_conflict}

      length(heads) > 1 ->
        {:error, :identity_conflict}

      heads == [] ->
        base_refs = %{refs | head_ref: refs.base_ref, head_sha: refs.base_sha}

        with {:ok, proof} <- PullEligibility.check(base.id, base.repository_id, base_refs) do
          {:ok,
           %{
             status: :unrepresented,
             head_repository_id: nil,
             pull_eligibility_proof: nil,
             git_proof: %{base: proof.base, head: nil}
           }}
        end

      true ->
        [head] = heads

        if head.github_repository_id == head_identity["id"] and
             head.github_node_id == head_identity["node_id"] do
          case PullEligibility.check(base.id, head.repository_id, refs) do
            {:ok, proof} ->
              {:ok,
               %{
                 status: :represented,
                 head_repository_id: head.repository_id,
                 pull_eligibility_proof: JSON.decode!(JSON.encode!(proof)),
                 git_proof: proof
               }}

            {:error, _} ->
              {:error, :head_not_ready}
          end
        else
          {:error, :identity_conflict}
        end
    end
  end

  defp new_remote?(operation, identity) do
    c = operation.cursor

    if operation.state == :processing and is_nil(operation.external_effect_marker) and
         is_nil(operation.effect_marked_at) and c["trigger"] in ["remote", "reconcile"] and
         c["resource_kind"] == "pull" and c["github_object_id"] == identity.github_object_id and
         c["github_number"] == identity.github_number and
         c["github_issue_id"] in [nil, identity.provider_identity["github_issue_object_id"]] and
         Enum.all?(~w(issue_id local_resource_id sync_version outbox_event_id), &is_nil(c[&1])),
       do: :ok,
       else: {:error, :identity_conflict}
  end

  defp missing?(scope, identity) do
    nodes = [identity.github_node_id, identity.provider_identity["github_issue_node_id"]]
    issue_id = identity.provider_identity["github_issue_object_id"]

    exists =
      Repo.exists?(
        from m in MirrorResourceState,
          where:
            m.repository_mirror_id == ^scope.repository_mirror_id and
              (m.github_node_id in ^nodes or
                 (m.resource_kind in [:issue, :pull] and
                    m.github_number == ^identity.github_number) or
                 (m.resource_kind == :issue and m.github_object_id == ^issue_id) or
                 (m.resource_kind == :pull and m.github_object_id == ^identity.github_object_id))
      )

    if exists, do: {:error, :identity_conflict}, else: :ok
  end

  defp validate(
         %{
           github_object_id: id,
           github_node_id: node,
           github_number: number,
           provider_identity: provider
         } = identity,
         snapshot
       )
       when is_map(provider) and is_map(snapshot) do
    if map_size(identity) == 4 and Enum.sort(Map.keys(snapshot)) == @fields and
         Enum.all?(~w(base_ref head_ref base_sha head_sha), fn key ->
           is_binary(snapshot[key]) and byte_size(snapshot[key]) <= 1024
         end) and
         positive?(id) and node?(node) and positive?(number) and
         Enum.sort(Map.keys(provider)) ==
           ~w(base_repository github_issue_node_id github_issue_object_id github_number head_repository) and
         positive?(provider["github_issue_object_id"]) and node?(provider["github_issue_node_id"]) and
         provider["github_issue_node_id"] != node and
         provider["github_number"] == number and repository_identity?(provider["base_repository"]) and
         (is_nil(provider["head_repository"]) or repository_identity?(provider["head_repository"])),
       do: :ok,
       else: {:error, :identity_conflict}
  end

  defp validate(_, _), do: {:error, :identity_conflict}
  defp positive?(value), do: is_integer(value) and value > 0 and value <= @max_id

  defp node?(value),
    do:
      is_binary(value) and byte_size(value) in 1..255 and String.valid?(value) and
        String.trim(value) == value and not String.contains?(value, <<0>>)

  defp repository_identity?(%{"id" => id, "node_id" => node} = value),
    do: map_size(value) == 2 and positive?(id) and node?(node)

  defp repository_identity?(_), do: false
end
