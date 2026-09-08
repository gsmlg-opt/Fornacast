defmodule ForgeMirrors.PullEligibility do
  @moduledoc """
  Read-only persisted eligibility proof for represented pull-request refs.

  One database statement observes both same-organization mappings and their
  confirmed branch baselines. This is not authorization for a provider effect:
  callers must hold their operation lease, freshly verify local and remote refs,
  and recheck binding/ref versions before applying an effect. In particular,
  historical confirmed OIDs do not prove current Git object availability.
  """
  import Ecto.Query
  alias ForgeMirrors.{GitHubAppInstallation, MirrorRefState, OrganizationMirror, RepositoryMirror}
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @max_id 9_223_372_036_854_775_807
  defguardp positive_id(id) when is_integer(id) and id > 0 and id <= @max_id

  def check(base_mirror_id, head_repository_id, refs)
      when positive_id(base_mirror_id) and positive_id(head_repository_id) and is_map(refs) do
    if valid_refs?(refs) do
      query =
        from base in RepositoryMirror,
          join: organization in OrganizationMirror,
          on: organization.id == base.organization_mirror_id,
          join: head in RepositoryMirror,
          on:
            head.organization_mirror_id == organization.id and
              head.repository_id == ^head_repository_id,
          join: base_repository in Repository,
          on: base_repository.id == base.repository_id,
          join: head_repository in Repository,
          on: head_repository.id == head.repository_id,
          join: owner in ForgeAccounts.User,
          on: owner.id == organization.organization_id,
          join: installation in GitHubAppInstallation,
          on:
            installation.github_installation_id == organization.github_installation_id and
              installation.github_account_id == organization.github_account_id,
          join: base_ref in MirrorRefState,
          on: base_ref.repository_mirror_id == base.id and base_ref.ref_name == ^refs.base_ref,
          join: head_ref in MirrorRefState,
          on: head_ref.repository_mirror_id == head.id and head_ref.ref_name == ^refs.head_ref,
          where:
            base.id == ^base_mirror_id and organization.provider == "github" and
              organization.state == :active,
          where:
            owner.kind == :organization and owner.state == :active and
              installation.state == :active,
          where:
            base.state == :active and head.state == :active and base.inventory_included and
              head.inventory_included,
          where: base.github_repository_id > 0 and head.github_repository_id > 0,
          where:
            base_repository.lifecycle == :ready and head_repository.lifecycle == :ready and
              is_nil(base_repository.deleted_at) and is_nil(head_repository.deleted_at) and
              base_repository.owner_user_id == owner.id and
              head_repository.owner_user_id == owner.id and
              base_repository.generation > 0 and head_repository.generation > 0,
          where:
            base_ref.state == :confirmed and head_ref.state == :confirmed and
              base_ref.ref_kind == :branch and head_ref.ref_kind == :branch and
              not is_nil(base_ref.last_confirmed_at) and not is_nil(head_ref.last_confirmed_at),
          where:
            base_ref.confirmed_oid == ^refs.base_sha and base_ref.last_local_oid == ^refs.base_sha and
              base_ref.last_remote_oid == ^refs.base_sha and
              head_ref.confirmed_oid == ^refs.head_sha and
              head_ref.last_local_oid == ^refs.head_sha and
              head_ref.last_remote_oid == ^refs.head_sha,
          select:
            {organization, base, head, base_repository.generation, head_repository.generation,
             base_ref, head_ref},
          limit: 2

      case Repo.all(query) do
        [{organization, base, head, base_generation, head_generation, base_ref, head_ref}] ->
          if enabled?(organization.capabilities, "git") and
               enabled?(organization.capabilities, "pulls") do
            {:ok,
             %{
               organization_mirror_id: organization.id,
               organization_lock_version: organization.lock_version,
               github_installation_id: organization.github_installation_id,
               base: proof(base, base_generation, base_ref),
               head: proof(head, head_generation, head_ref)
             }}
          else
            {:error, :ineligible_pull}
          end

        _ ->
          {:error, :ineligible_pull}
      end
    else
      {:error, :ineligible_pull}
    end
  end

  def check(_, _, _), do: {:error, :ineligible_pull}

  defp proof(binding, generation, ref) do
    %{
      repository_mirror_id: binding.id,
      repository_id: binding.repository_id,
      github_repository_id: binding.github_repository_id,
      repository_generation: generation,
      mirror_lock_version: binding.lock_version,
      ref_lock_version: ref.lock_version,
      ref: ref.ref_name,
      oid: ref.confirmed_oid
    }
  end

  defp enabled?(capabilities, key),
    do: Map.get(capabilities || %{}, key) in [true, "enabled", "active"]

  defp valid_refs?(
         %{base_ref: base, head_ref: head, base_sha: base_sha, head_sha: head_sha} = refs
       ),
       do:
         map_size(refs) == 4 and branch?(base) and branch?(head) and oid?(base_sha) and
           oid?(head_sha)

  defp valid_refs?(_), do: false

  defp oid?(oid) when is_binary(oid), do: Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, oid)
  defp oid?(_), do: false

  defp branch?("refs/heads/" <> name) do
    byte_size(name) in 1..1_013 and String.valid?(name) and
      not String.contains?(name, ["..", "@{", "//", "\\", " ", "~", "^", ":", "?", "*", "["]) and
      not Regex.match?(~r/[\x00-\x1f\x7f]/, name) and
      Enum.all?(String.split(name, "/"), fn part ->
        part != "" and not String.starts_with?(part, ".") and
          not String.ends_with?(part, [".", ".lock"])
      end)
  end

  defp branch?(_), do: false
end
