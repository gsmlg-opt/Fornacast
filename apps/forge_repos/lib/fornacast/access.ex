defmodule Fornacast.Access do
  @moduledoc """
  Central repository authorization boundary.
  """

  alias ForgeAccounts.User
  alias ForgeRepos.Repository

  @permissions [:repository_read, :repository_write, :repository_admin]

  def authorize(actor, permission, %Repository{} = repository) when permission in @permissions do
    if allowed?(actor, permission, repository), do: :ok, else: {:error, :unauthorized}
  end

  def authorize(_actor, _permission, _resource), do: {:error, :unauthorized}

  def allowed?(%User{role: :admin, state: :active}, _permission, %Repository{}), do: true

  def allowed?(%User{id: user_id, state: :active}, _permission, %Repository{
        owner_user_id: user_id
      }),
      do: true

  def allowed?(_actor, :repository_read, %Repository{visibility: :public}), do: true

  def allowed?(%User{state: :active} = user, permission, %Repository{} = repository) do
    user
    |> ForgeRepos.collaborator_role(repository)
    |> collaborator_allows?(permission)
  end

  def allowed?(_actor, _permission, _repository), do: false

  defp collaborator_allows?(:admin, _permission), do: true

  defp collaborator_allows?(:write, permission),
    do: permission in [:repository_read, :repository_write]

  defp collaborator_allows?(:read, :repository_read), do: true
  defp collaborator_allows?(_, _), do: false
end
