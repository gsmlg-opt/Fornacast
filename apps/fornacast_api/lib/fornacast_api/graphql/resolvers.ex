defmodule FornacastAPI.GraphQL.Resolvers do
  @moduledoc false

  alias ForgeAccounts.{AccountView, Organization, User}
  alias ForgeRepos.Repository
  alias FornacastAPI.URL

  def viewer(_parent, _args, %{context: %{actor: %User{} = actor, api_key: api_key}}) do
    case ForgeAccounts.APIScope.authorize(api_key, :identity_read, nil) do
      :ok ->
        view = ForgeRepos.account_view(actor, actor)
        {:ok, render_user(view, private?: true)}

      {:error, :insufficient_scope} ->
        {:error, "Resource not accessible by personal access token"}
    end
  end

  def viewer(_parent, _args, _resolution), do: {:error, "Bad credentials"}

  def user(_parent, %{login: login}, %{context: context}) do
    case ForgeAccounts.get_public_user(login) do
      {:ok, user} ->
        view = ForgeRepos.account_view(context.actor, user)
        {:ok, render_user(view, private?: false)}

      {:error, :not_found} ->
        {:ok, nil}
    end
  end

  def organization(_parent, %{login: login}, %{context: context}) do
    case ForgeAccounts.get_public_organization(login) do
      {:ok, organization} ->
        view = ForgeRepos.account_view(context.actor, organization)
        {:ok, render_organization(view)}

      {:error, :not_found} ->
        {:ok, nil}
    end
  end

  def repository(_parent, %{owner: owner, name: name}, %{context: context}) do
    actor = context.actor

    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, name, :repository_read),
         :ok <- authorize_repository_scope(context.api_key, repository),
         {:ok, view} <- ForgeRepos.repository_view(actor, repository) do
      {:ok, render_repository(view)}
    else
      {:error, :not_found} ->
        {:ok, nil}

      {:error, :forbidden} ->
        {:ok, nil}

      {:error, :insufficient_scope} ->
        {:error, "Resource not accessible by personal access token"}

      {:error, _reason} ->
        {:ok, nil}
    end
  end

  defp authorize_repository_scope(_api_key, %Repository{visibility: :public}), do: :ok

  defp authorize_repository_scope(api_key, %Repository{visibility: :private})
       when not is_nil(api_key) do
    ForgeAccounts.APIScope.authorize(api_key, :repository_read, :private)
  end

  defp authorize_repository_scope(_api_key, %Repository{visibility: :private}),
    do: {:error, :not_found}

  defp render_user(%AccountView{account: %User{} = account}, opts) do
    private? = Keyword.fetch!(opts, :private?)

    %{
      id: node_id("User", account.id),
      database_id: account.id,
      login: account.username,
      name: account.display_name,
      url: URL.user(account.username),
      email: if(private?, do: account.email, else: nil),
      bio: account.description,
      is_site_admin: account.role == :admin
    }
  end

  defp render_organization(%AccountView{account: %Organization{} = account}) do
    %{
      id: node_id("Organization", account.id),
      database_id: account.id,
      login: account.username,
      name: account.display_name,
      description: account.description,
      url: URL.organization(account.username)
    }
  end

  defp render_repository(%{repository: repository, owner: owner}) do
    owner_login = owner.username
    slug = repository.slug

    %{
      id: node_id("Repository", repository.id),
      database_id: repository.id,
      name: repository.name,
      name_with_owner: owner_login <> "/" <> slug,
      description: repository.description,
      url: URL.repository(owner_login, slug),
      is_private: repository.visibility == :private
    }
  end

  defp node_id(type, id), do: Base.url_encode64("#{type}:#{id}", padding: false)
end
