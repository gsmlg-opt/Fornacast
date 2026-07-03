defmodule ForgeAccounts do
  @moduledoc """
  Account, password, and SSH-key management for Fornacast.
  """

  import Ecto.Query

  alias ForgeAccounts.{SSHKey, User}
  alias Fornacast.Repo

  def get_user(id), do: Repo.get(User, id)

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: normalize_username(username))
  end

  def admin_exists? do
    Repo.exists?(from user in User, where: user.role == :admin)
  end

  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(Map.put(attrs, :role, :user))
    |> Repo.insert()
  end

  def create_admin(attrs) do
    %User{}
    |> User.registration_changeset(Map.put(attrs, :role, :admin))
    |> Repo.insert()
  end

  def create_first_admin(attrs) do
    Repo.transaction(fn ->
      if admin_exists?() do
        Repo.rollback(:admin_exists)
      else
        case create_admin(attrs) do
          {:ok, user} -> user
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
  end

  def authenticate_password(username, password)
      when is_binary(username) and is_binary(password) do
    case get_user_by_username(username) do
      %User{state: :active, password_hash: password_hash} = user ->
        if Bcrypt.verify_pass(password, password_hash), do: {:ok, user}, else: password_error()

      _ ->
        password_error()
    end
  end

  def authenticate_password(_, _) do
    password_error()
  end

  def create_ssh_key(%User{} = user, attrs) do
    %SSHKey{user_id: user.id}
    |> SSHKey.changeset(attrs)
    |> Repo.insert()
  end

  def list_user_ssh_keys(%User{id: user_id}), do: list_user_ssh_keys(user_id)

  def list_user_ssh_keys(user_id) do
    SSHKey
    |> where([key], key.user_id == ^user_id)
    |> order_by([key], desc: key.inserted_at)
    |> Repo.all()
  end

  def delete_ssh_key(%User{id: user_id}, key_id) do
    case Repo.get_by(SSHKey, id: key_id, user_id: user_id) do
      nil -> {:error, :not_found}
      key -> Repo.delete(key)
    end
  end

  def authorized_ssh_key?(username, public_key) do
    match?({:ok, _user}, authenticate_ssh_key(username, public_key))
  end

  def authenticate_ssh_key(username, public_key)
      when is_binary(username) and is_binary(public_key) do
    with %User{state: :active} = user <- get_user_by_username(username),
         {:ok, fingerprint} <- SSHKey.fingerprint(public_key),
         %SSHKey{} = key <- Repo.get_by(SSHKey, user_id: user.id, fingerprint_sha256: fingerprint) do
      touch_ssh_key(key)
      {:ok, user}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate_ssh_key(username, decoded_public_key) when is_binary(username) do
    with %User{state: :active} = user <- get_user_by_username(username),
         %SSHKey{} = key <- find_matching_ssh_key(user, decoded_public_key) do
      touch_ssh_key(key)
      {:ok, user}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate_ssh_key(_, _), do: {:error, :unauthorized}

  defp password_error do
    Bcrypt.no_user_verify()
    {:error, :invalid_credentials}
  end

  defp touch_ssh_key(%SSHKey{id: id}) do
    from(key in SSHKey, where: key.id == ^id)
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])

    :ok
  end

  defp find_matching_ssh_key(%User{} = user, decoded_public_key) do
    user
    |> list_user_ssh_keys()
    |> Enum.find(fn key ->
      case SSHKey.decode_public_key(key.public_key) do
        {:ok, stored_public_key} -> stored_public_key == decoded_public_key
        {:error, _reason} -> false
      end
    end)
  end

  defp normalize_username(username) do
    username
    |> String.trim()
    |> String.downcase()
  end
end
