defmodule FornacastAPI.Fixtures do
  alias Ecto.Changeset
  alias ForgeAccounts.{APIKey, Organization, User}
  alias Fornacast.Repo

  def user(login, opts \\ []) when is_binary(login) and is_list(opts) do
    attrs = %{
      username: login,
      email: Keyword.get(opts, :email, "#{login}@example.test"),
      password: Keyword.get(opts, :password, "correct horse battery staple"),
      state: Keyword.get(opts, :state, :active)
    }

    result =
      case Keyword.get(opts, :role, :user) do
        :admin -> ForgeAccounts.create_admin(attrs)
        :user -> ForgeAccounts.create_user(attrs)
      end

    {:ok, user} = result

    profile =
      opts
      |> Keyword.take([:display_name, :description])
      |> Map.new()

    if map_size(profile) == 0 do
      user
    else
      user |> Changeset.change(profile) |> Repo.update!()
    end
  end

  def organization(owner, login, opts \\ [])
      when is_struct(owner, User) and is_binary(login) and is_list(opts) do
    attrs = %{
      username: login,
      display_name: Keyword.get(opts, :display_name, login),
      description: Keyword.get(opts, :description),
      state: Keyword.get(opts, :state, :active)
    }

    {:ok, %Organization{} = organization} = ForgeAccounts.create_organization(owner, attrs)
    organization
  end

  def pat(user, scopes, opts \\ [])
      when is_struct(user, User) and is_list(scopes) and is_list(opts) do
    if Enum.all?(scopes, &(&1 in APIKey.classic_scopes())) do
      {:ok, api_key, secret} =
        ForgeAccounts.create_api_key(user, %{
          name: Keyword.get(opts, :name, "API test token"),
          scopes: scopes,
          expires_at: Keyword.get(opts, :expires_at)
        })

      {api_key, secret}
    else
      {secret, token_prefix, token_hash} = APIKey.generate_secret()

      api_key =
        Repo.insert!(%APIKey{
          user_id: user.id,
          name: Keyword.get(opts, :name, "Legacy API test token"),
          token_prefix: token_prefix,
          token_hash: token_hash,
          scopes: Map.new(scopes, &{&1, true}),
          expires_at: Keyword.get(opts, :expires_at)
        })

      {api_key, secret}
    end
  end

  def authorization(secret, scheme \\ "Bearer")
      when is_binary(secret) and is_binary(scheme) do
    {"authorization", "#{scheme} #{secret}"}
  end
end
