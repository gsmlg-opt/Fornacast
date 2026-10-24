defmodule ForgeAccounts.OrganizationGitHubCredentials do
  @moduledoc "Encrypted organization grants with independent lifecycle and durable one-use renewal."
  import Ecto.Query

  alias ForgeAccounts.{
    GitHubCredentialCallback,
    GitHubCredentialVault,
    GitHubDeviceToken,
    GitHubProfileSafety,
    GitHubRequestMetadata,
    OrganizationMember,
    OrganizationGitHubCredential,
    User
  }

  alias Fornacast.{Audit, Repo}

  @client_id "Iv23lizCVE3E24s7fCA0"
  @app_id 5_412_311

  defmodule CallbackError do
    defexception message: "organization GitHub credential callback failed"
  end

  def view(actor, organization_id), do: reference(actor, organization_id)

  def reference(actor, organization_id) do
    with {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, organization_id),
         do: current_reference(organization_id)
  end

  def current_reference(organization_id) do
    with :ok <- active_organization(organization_id) do
      {:ok,
       public(
         Repo.get_by(OrganizationGitHubCredential, organization_id: organization_id),
         organization_id
       )}
    end
  end

  def save_device_grant_if_current(
        actor,
        organization_id,
        profile,
        token_value,
        expected,
        metadata
      ) do
    with {:ok, token} <- GitHubDeviceToken.normalize(token_value),
         true <- token.client_id == @client_id,
         :ok <- valid_profile(profile, token),
         {:ok, metadata} <- GitHubRequestMetadata.validate(metadata, token.access_token),
         {:ok, metadata} <- GitHubRequestMetadata.validate(metadata, token.refresh_token) do
      transaction(fn ->
        with :ok <- lock_management(actor, organization_id),
             credential <- locked_credential(organization_id),
             :ok <- expected_reference(credential, organization_id, expected),
             {:ok, saved} <- persist_grant(actor, organization_id, credential, profile, token),
             {:ok, _} <- audit(actor, "github.organization_credential.connected", saved, metadata) do
          {:ok, public(saved, organization_id)}
        end
      end)
    else
      false -> {:error, :invalid_response}
      {:error, _} = error -> error
    end
  end

  def disconnect_if_current(actor, organization_id, expected, metadata) do
    with {:ok, metadata} <- GitHubRequestMetadata.validate(metadata) do
      transaction(fn ->
        with :ok <- lock_management(actor, organization_id),
             credential <- locked_credential(organization_id),
             :ok <- expected_reference(credential, organization_id, expected) do
          if credential do
            with {:ok, invalid} <-
                   update_credential(credential, %{
                     status: :invalid,
                     verification_version: credential.verification_version + 1,
                     refresh_claim_id: nil,
                     refresh_claimed_at: nil
                   }),
                 {:ok, _} <-
                   audit(actor, "github.organization_credential.disconnected", invalid, metadata),
                 do: {:ok, public(invalid, organization_id)}
          else
            {:ok, public(nil, organization_id)}
          end
        end
      end)
    end
  end

  def with_credential(scope, callback) when is_map(scope) and is_function(callback, 2) do
    with {:ok, credential} <- current_credential(scope),
         :ok <- usable_access(credential) do
      with_secrets(credential, fn access, refresh ->
        GitHubCredentialCallback.invoke(
          fn _ ->
            GitHubCredentialCallback.invoke(
              fn _ ->
                callback.(access, public(credential, credential.organization_id))
              end,
              access,
              CallbackError
            )
          end,
          refresh,
          CallbackError
        )
      end)
      |> callback_result()
    end
  end

  def with_credential(_, _), do: {:error, :forbidden}

  def mark_invalid_if_current(scope) when is_map(scope) do
    transaction(fn ->
      with :ok <- lock_organization(scope[:organization_id]),
           {:ok, current} <- current_credential(scope, true),
           {:ok, {:invalid, reference}} <- invalidate(current),
           do: {:ok, reference}
    end)
  end

  def validate_external_profiles(scope, profiles) when is_list(profiles) do
    with {:ok, credential} <- current_credential(scope) do
      with_secrets(credential, fn access, refresh ->
        Enum.reduce_while(profiles, :ok, fn
          profile, :ok when is_map(profile) ->
            with :ok <- GitHubProfileSafety.validate(profile, access),
                 :ok <- GitHubProfileSafety.validate(profile, refresh) do
              {:cont, :ok}
            else
              error -> {:halt, error}
            end

          _, :ok ->
            {:halt, {:error, :invalid_response}}
        end)
      end)
      |> callback_result()
      |> case do
        {:ok, result} -> result
        error -> error
      end
    end
  end

  def validate_external_profiles(_, _), do: {:error, :invalid_response}

  def refresh_credential(scope, callback, opts \\ [])

  def refresh_credential(scope, callback, opts)
      when is_map(scope) and is_function(callback, 2) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :credential_service_unavailable}
    else
      now = Keyword.get(opts, :now, DateTime.utc_now(:second))

      case transaction(fn -> claim_refresh(scope, now, opts) end) do
        {:ok, :ready} -> :ok
        {:ok, {:invalid, _}} -> {:error, :reauthorization_required}
        {:ok, {:claimed, credential}} -> exchange_refresh(scope, credential, callback)
        error -> error
      end
    end
  end

  def refresh_credential(_, _, _), do: {:error, :forbidden}

  defp claim_refresh(scope, now, opts) do
    with :ok <- lock_organization(scope[:organization_id]),
         {:ok, credential} <- current_credential(scope, true),
         :ok <- GitHubCredentialVault.ready?() do
      cond do
        credential.refresh_claim_id != nil ->
          if DateTime.diff(now, credential.refresh_claimed_at) >=
               Keyword.get(opts, :claim_timeout_seconds, 60),
             do: invalidate(credential),
             else: {:error, :refresh_in_progress}

        DateTime.compare(credential.refresh_expires_at, now) != :gt ->
          invalidate(credential)

        DateTime.diff(credential.expires_at, now) > Keyword.get(opts, :refresh_before_seconds, 60) ->
          {:ok, :ready}

        true ->
          with {:ok, claimed} <-
                 update_credential(credential, %{
                   refresh_claim_id: Ecto.UUID.generate(),
                   refresh_claimed_at: now
                 }),
               do: {:ok, {:claimed, claimed}}
      end
    end
  end

  defp exchange_refresh(scope, credential, callback) do
    outcome =
      GitHubCredentialVault.with_organization_refresh(credential, fn refresh ->
        try do
          with {:ok, value} <- callback.(refresh, credential.client_id),
               {:ok, token} <- GitHubDeviceToken.normalize(value),
               true <- token.client_id == credential.client_id,
               false <- token.refresh_token == refresh do
            {:ok, token}
          else
            _ -> :ambiguous
          end
        rescue
          _ -> :ambiguous
        catch
          _, _ -> :ambiguous
        end
      end)

    case outcome do
      {:ok, {:ok, token}} ->
        case settle_refresh(scope, credential, {:token, token}) do
          {:error, :credential_service_unavailable} -> settle_refresh(scope, credential, :invalid)
          result -> result
        end

      {:ok, :ambiguous} ->
        settle_refresh(scope, credential, :invalid)

      {:error, _} ->
        _ = settle_refresh(scope, credential, :undispatched)
        {:error, :credential_service_unavailable}
    end
  end

  defp settle_refresh(scope, claimed, outcome) do
    transaction(fn ->
      with :ok <- lock_organization(scope[:organization_id]),
           {:ok, current} <- current_credential(scope, true),
           true <-
             current.token_generation == claimed.token_generation and
               current.refresh_claim_id == claimed.refresh_claim_id do
        settle(current, outcome)
      else
        false -> {:error, :stale}
        error -> error
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, {:invalid, _}} -> {:error, :reauthorization_required}
      error -> error
    end
  end

  defp settle(current, {:token, token}) do
    with {:ok, envelopes} <- envelopes(current, token),
         {:ok, saved} <-
           update_credential(
             current,
             Map.merge(envelopes, %{
               token_generation: current.token_generation + 1,
               refresh_claim_id: nil,
               refresh_claimed_at: nil
             })
           ),
         {:ok, _} <- audit(nil, "github.organization_credential.refreshed", saved, %{}),
         do: {:ok, :ok}
  end

  defp settle(current, :invalid), do: invalidate(current)

  defp settle(current, :undispatched) do
    with {:ok, _} <- update_credential(current, %{refresh_claim_id: nil, refresh_claimed_at: nil}),
         do: {:ok, :ok}
  end

  defp invalidate(credential) do
    with {:ok, invalid} <-
           update_credential(credential, %{
             status: :invalid,
             verification_version: credential.verification_version + 1,
             refresh_claim_id: nil,
             refresh_claimed_at: nil
           }),
         {:ok, _} <- audit(nil, "github.organization_credential.invalidated", invalid, %{}),
         do: {:ok, {:invalid, public(invalid, invalid.organization_id)}}
  end

  defp persist_grant(actor, organization_id, previous, profile, token) do
    credential =
      previous || %OrganizationGitHubCredential{id: next_id(), organization_id: organization_id}

    credential = %{
      credential
      | authorized_by_user_id: actor.id,
        github_user_id: profile.github_user_id,
        github_user_login: profile.login,
        github_app_id: @app_id,
        client_id: @client_id
    }

    with {:ok, material} <- envelopes(credential, token) do
      attrs =
        Map.merge(material, %{
          status: :valid,
          refresh_claim_id: nil,
          refresh_claimed_at: nil,
          authorized_by_user_id: credential.authorized_by_user_id,
          github_user_id: credential.github_user_id,
          github_user_login: credential.github_user_login,
          github_app_id: @app_id,
          client_id: @client_id,
          verification_version: if(previous, do: previous.verification_version + 1, else: 1),
          token_generation: if(previous, do: previous.token_generation + 1, else: 1)
        })

      if previous, do: update_credential(previous, attrs), else: insert(credential, attrs)
    end
  end

  defp envelopes(credential, token) do
    with {:ok, access} <-
           GitHubCredentialVault.encrypt_organization_access(credential, token.access_token),
         {:ok, refresh} <-
           GitHubCredentialVault.encrypt_organization_refresh(credential, token.refresh_token) do
      {:ok,
       %{
         ciphertext: access.ciphertext,
         nonce: access.nonce,
         tag: access.tag,
         key_id: access.key_id,
         refresh_ciphertext: refresh.ciphertext,
         refresh_nonce: refresh.nonce,
         refresh_tag: refresh.tag,
         refresh_key_id: refresh.key_id,
         expires_at: token.expires_at,
         refresh_expires_at: token.refresh_expires_at
       }}
    end
  end

  defp current_credential(scope, lock? \\ false) do
    with :ok <- active_organization(scope[:organization_id]),
         %OrganizationGitHubCredential{} = credential <-
           credential_query(scope[:organization_id], lock?) |> Repo.one(),
         :ok <- expected_reference(credential, credential.organization_id, scope),
         true <- credential.status == :valid do
      {:ok, credential}
    else
      nil -> {:error, :not_found}
      false -> {:error, :reauthorization_required}
      error -> error
    end
  end

  defp usable_access(credential) do
    if DateTime.compare(credential.expires_at, DateTime.utc_now(:second)) == :gt,
      do: :ok,
      else: {:error, :reauthorization_required}
  end

  defp with_secrets(credential, callback) do
    case GitHubCredentialVault.with_organization_refresh(credential, fn refresh ->
           GitHubCredentialVault.with_organization_access(credential, fn access ->
             callback.(access, refresh)
           end)
         end) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp callback_result({:ok, :unsafe}), do: {:error, :unsafe_credential_result}
  defp callback_result(result), do: result

  defp expected_reference(credential, organization_id, expected) when is_map(expected) do
    actual = public(credential, organization_id)

    if Enum.all?(
         [:organization_id, :credential_id, :verification_version],
         &(Map.fetch(expected, &1) == Map.fetch(actual, &1))
       ), do: :ok, else: {:error, :stale}
  end

  defp expected_reference(_, _, _), do: {:error, :stale}

  defp public(nil, organization_id),
    do: %{
      organization_id: organization_id,
      credential_id: nil,
      verification_version: nil,
      status: :absent,
      github_user_id: nil,
      github_user_login: nil,
      client_id: nil,
      github_app_id: nil,
      expires_at: nil,
      refresh_expires_at: nil
    }

  defp public(credential, organization_id),
    do: %{
      organization_id: organization_id,
      credential_id: credential.id,
      verification_version: credential.verification_version,
      status: credential.status,
      github_user_id: credential.github_user_id,
      github_user_login: credential.github_user_login,
      client_id: credential.client_id,
      github_app_id: credential.github_app_id,
      expires_at: credential.expires_at,
      refresh_expires_at: credential.refresh_expires_at
    }

  defp lock_management(%User{id: actor_id} = actor, organization_id)
       when is_integer(actor_id) and is_integer(organization_id) and actor_id > 0 and
              organization_id > 0 do
    Repo.all(
      from u in User,
        where: u.id in ^Enum.sort([actor_id, organization_id]),
        order_by: u.id,
        lock: "FOR UPDATE"
    )

    Repo.all(
      from m in OrganizationMember,
        where: m.organization_id == ^organization_id and m.user_id == ^actor_id,
        lock: "FOR UPDATE"
    )

    case ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp lock_management(_, _), do: {:error, :forbidden}

  defp lock_organization(id) when is_integer(id) do
    Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE")
    active_organization(id)
  end

  defp lock_organization(_), do: {:error, :forbidden}

  defp active_organization(id) when is_integer(id) and id > 0 do
    if Repo.exists?(
         from u in User, where: u.id == ^id and u.kind == :organization and u.state == :active
       ), do: :ok, else: {:error, :forbidden}
  end

  defp active_organization(_), do: {:error, :forbidden}

  defp credential_query(id, lock?) do
    query = from c in OrganizationGitHubCredential, where: c.organization_id == ^id
    if lock?, do: lock(query, "FOR UPDATE"), else: query
  end

  defp locked_credential(id), do: Repo.one(credential_query(id, true))

  defp next_id do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT nextval(pg_get_serial_sequence('organization_github_credentials', 'id'))",
        []
      )

    id
  end

  defp valid_profile(%{github_user_id: id, login: login} = profile, token)
       when is_integer(id) and id in 1..9_223_372_036_854_775_807 and is_binary(login) do
    if byte_size(login) in 1..255 and login == String.trim(login) do
      with :ok <- GitHubProfileSafety.validate(profile, token.access_token),
           do: GitHubProfileSafety.validate(profile, token.refresh_token)
    else
      {:error, :invalid_response}
    end
  end

  defp valid_profile(_, _), do: {:error, :invalid_response}

  defp insert(credential, attrs),
    do: credential |> Ecto.Changeset.change(attrs) |> Repo.insert() |> safe_persistence()

  defp update_credential(credential, attrs),
    do: credential |> Ecto.Changeset.change(attrs) |> Repo.update() |> safe_persistence()

  defp safe_persistence({:ok, _} = result), do: result
  defp safe_persistence({:error, _}), do: {:error, :credential_service_unavailable}

  defp audit(actor, action, credential, metadata),
    do:
      Audit.record(
        actor,
        action,
        "organization_github_credential",
        credential.id,
        %{
          organization_id: credential.organization_id,
          github_user_id: credential.github_user_id,
          verification_version: credential.verification_version
        },
        request_metadata: metadata
      )

  defp transaction(callback) do
    Repo.transaction(fn ->
      case callback.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
