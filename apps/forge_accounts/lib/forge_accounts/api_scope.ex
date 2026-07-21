defmodule ForgeAccounts.APIScope do
  alias ForgeAccounts.APIKey

  @type action ::
          :identity_read
          | :organization_read
          | :organization_mutation
          | :repository_read
          | :repository_mutation
          | :git_read
          | :git_write
  @type visibility :: :public | :private | nil

  def authorize(%APIKey{} = key, action, visibility) do
    accepted = accepted_scopes(action, visibility)
    if Enum.any?(accepted, &enabled?(key, &1)), do: :ok, else: {:error, :insufficient_scope}
  end

  def accepted_scopes(:identity_read, nil),
    do: ["repo", "public_repo", "read:org", "write:org", "repo:read", "repo:write"]

  def accepted_scopes(:organization_read, nil), do: ["read:org", "write:org"]
  def accepted_scopes(:organization_mutation, nil), do: ["write:org"]

  def accepted_scopes(:repository_read, :public),
    do: ["public_repo", "repo", "repo:read", "repo:write"]

  def accepted_scopes(:repository_read, :private), do: ["repo", "repo:read", "repo:write"]
  def accepted_scopes(:repository_mutation, :public), do: ["public_repo", "repo"]
  def accepted_scopes(:repository_mutation, :private), do: ["repo"]

  def accepted_scopes(:git_read, :public),
    do: ["public_repo", "repo", "repo:read", "repo:write"]

  def accepted_scopes(:git_read, :private), do: ["repo", "repo:read", "repo:write"]
  def accepted_scopes(:git_write, :public), do: ["public_repo", "repo", "repo:write"]
  def accepted_scopes(:git_write, :private), do: ["repo", "repo:write"]

  defp enabled?(%APIKey{scopes: scopes}, "public_repo"),
    do: scopes["public_repo"] == true or scopes["repo"] == true

  defp enabled?(%APIKey{scopes: scopes}, "read:org"),
    do: scopes["read:org"] == true or scopes["write:org"] == true

  defp enabled?(%APIKey{scopes: scopes}, scope), do: scopes[scope] == true
end
