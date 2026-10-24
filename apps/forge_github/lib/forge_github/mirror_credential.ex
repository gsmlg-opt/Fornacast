defmodule ForgeGitHub.MirrorCredential do
  @moduledoc "Ephemeral credential checkout for a freshly authorized mirror scope."

  alias ForgeAccounts.GitHubCredentialVerification
  alias ForgeGitHub.{InstallationToken, InstallationTokenBroker}

  @allow_test_callbacks Mix.env() == :test

  def with_token(scope, permissions, options, callback)
      when is_map(scope) and is_map(permissions) and is_list(options) and is_function(callback, 1) do
    case Map.get(scope, :credential_source, :github_app) do
      :pat -> with_pat(scope, options, callback)
      :organization_device -> with_organization(scope, permissions, options, callback)
      :github_app -> with_app(scope, permissions, options, callback)
      _ -> {:error, :credential_unavailable}
    end
  end

  def gate_key(%{credential_source: :pat, github_credential_id: id}),
    do: {:saved_credential, id}

  def gate_key(%{credential_source: :organization_device, organization_credential_id: id}),
    do: {:organization_credential, id}

  def gate_key(%{github_installation_id: id}), do: {:github_installation, id}

  def valid_scope?(%{credential_source: :pat} = scope) do
    Enum.all?(
      [
        :github_credential_id,
        :github_identity_id,
        :github_credential_version,
        :credential_owner_user_id
      ],
      &(is_integer(scope[&1]) and scope[&1] > 0)
    )
  end

  def valid_scope?(%{credential_source: :organization_device} = scope) do
    Enum.all?(
      [
        :organization_id,
        :organization_connection_id,
        :organization_connection_version,
        :organization_credential_id,
        :organization_credential_version,
        :github_installation_id,
        :github_account_id
      ],
      &(is_integer(scope[&1]) and scope[&1] > 0)
    )
  end

  def valid_scope?(scope),
    do: is_integer(scope[:github_installation_id]) and scope.github_installation_id > 0

  defp with_pat(scope, options, callback) do
    authorize = test_callback(options, :pat_authorize, &ForgeMirrors.authorize_pat_credential/1)
    checkout = test_callback(options, :pat_checkout, &checkout(&1, &2, options))

    with true <- valid_scope?(scope),
         :ok <- authorize.(scope) do
      checkout.(scope, fn token, reference ->
        with true <- reference_matches?(scope, reference),
             :ok <- authorize.(scope) do
          # Domain persistence and provider error classification happen inside checkout.
          # Only a completion acknowledgement crosses the account vault boundary.
          case callback.(token) do
            {:ok, _durable_result} -> :ok
            result -> result
          end
        else
          false -> {:error, :credential_unavailable}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> normalize_checkout()
    else
      false -> {:error, :credential_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_organization(scope, permissions, options, callback) do
    authorize = test_callback(options, :pat_authorize, &ForgeMirrors.authorize_pat_credential/1)

    with true <- valid_scope?(scope),
         :ok <- authorize.(scope),
         {:ok, current} <-
           ForgeMirrors.OrganizationGitHubConnections.scope(scope.organization_connection_id),
         true <- organization_reference_matches?(scope, current) do
      ForgeGitHub.OrganizationCredential.with_credential(
        current,
        fn token, _reference ->
          with :ok <- authorize.(scope),
               {:ok, fresh} <-
                 ForgeMirrors.OrganizationGitHubConnections.scope(
                   scope.organization_connection_id
                 ),
               true <- organization_reference_matches?(scope, fresh),
               :ok <- verify_organization_installation(scope, fresh, token, permissions, options),
               :ok <- authorize.(scope),
               {:ok, final} <-
                 ForgeMirrors.OrganizationGitHubConnections.scope(
                   scope.organization_connection_id
                 ),
               true <- organization_reference_matches?(scope, final) do
            case callback.(token) do
              {:ok, _durable_result} -> :ok
              result -> result
            end
          else
            false -> {:error, :credential_unavailable}
            {:error, _} = error -> error
            _ -> {:error, :credential_unavailable}
          end
        end,
        options
      )
      |> normalize_checkout()
    else
      false -> {:error, :credential_unavailable}
      {:error, _} = error -> error
    end
  end

  defp organization_reference_matches?(scope, current) do
    scope.organization_id == current.organization_id and
      scope.organization_connection_version == current.connection_version and
      scope.organization_credential_id == current.credential_id and
      scope.organization_credential_version == current.verification_version and
      scope.github_installation_id == current.installation_id and
      scope.github_account_id == current.github_organization_id
  end

  defp verify_organization_installation(scope, current, token, permissions, options) do
    client =
      if @allow_test_callbacks,
        do: Keyword.get(options, :client, ForgeGitHub.Client),
        else: ForgeGitHub.Client

    opts = [gate_key: gate_key(scope)]

    with {:ok, installations} <- client.user_installations(token, opts),
         %ForgeGitHub.UserInstallation{} = item <-
           Enum.find(installations, &(&1.installation.id == scope.github_installation_id)),
         true <-
           item.app_id == current.github_app_id and item.app_slug == "fornacast" and
             (is_nil(item.client_id) or item.client_id == current.client_id),
         true <-
           item.installation.account_type == :organization and item.installation.state == :active and
             item.installation.account_id == scope.github_account_id,
         true <-
           Enum.all?(Map.get(permissions, :permissions, %{}), fn {key, value} ->
             actual = item.installation.permissions[key]
             key == "metadata" or actual == value or (value == "read" and actual == "write")
           end),
         {:ok, repositories} <-
           client.user_installation_repositories(token, scope.github_installation_id, opts),
         true <-
           is_list(repositories) and length(repositories) <= 10_000 and
             Enum.all?(repositories, &(&1.owner_id == scope.github_account_id)),
         true <- length(repositories) == length(Enum.uniq_by(repositories, & &1.id)),
         true <-
           is_nil(scope[:github_repository_id]) or
             Enum.any?(repositories, &(&1.id == scope.github_repository_id)),
         :ok <-
           ForgeAccounts.OrganizationGitHubCredentials.validate_external_profiles(
             current,
             repositories
           ),
         :ok <-
           ForgeAccounts.OrganizationGitHubCredentials.validate_external_profiles(current, [
             %{login: item.installation.account_login}
           ]) do
      :ok
    else
      {:error, %ForgeGitHub.Error{kind: kind}} -> {:error, kind}
      {:error, _} = error -> error
      _ -> {:error, :insufficient_installation_access}
    end
  end

  defp with_app(scope, permissions, options, callback) do
    fetch = Keyword.get(options, :token_fetch, &InstallationTokenBroker.fetch/2)

    case fetch.(scope.github_installation_id, permissions) do
      %InstallationToken{token: token} -> callback.(token)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :credential_unavailable}
    end
  end

  defp checkout(scope, callback, options) do
    case ForgeAccounts.get_user(scope.credential_owner_user_id) do
      %ForgeAccounts.User{} = actor ->
        ForgeGitHub.SavedCredential.with_import_credential(
          actor,
          scope.github_identity_id,
          scope.github_credential_id,
          callback,
          options
        )

      _ ->
        {:error, :credential_unavailable}
    end
  end

  defp reference_matches?(scope, %GitHubCredentialVerification{} = reference) do
    reference.credential_id == scope.github_credential_id and
      reference.identity_id == scope.github_identity_id and
      reference.local_user_id == scope.credential_owner_user_id and
      reference.verification_version == scope.github_credential_version
  end

  defp reference_matches?(_scope, _reference), do: false

  defp normalize_checkout({:ok, result}), do: result

  defp normalize_checkout({:error, :reauthorization_required}),
    do: {:error, :reauthorization_required}

  defp normalize_checkout({:error, :refresh_in_progress}), do: {:error, :busy}
  defp normalize_checkout({:error, :credential_service_unavailable}), do: {:error, :unavailable}
  defp normalize_checkout({:error, _reason}), do: {:error, :credential_unavailable}
  defp normalize_checkout(_), do: {:error, :credential_unavailable}

  defp test_callback(options, key, default) do
    if @allow_test_callbacks, do: Keyword.get(options, key, default), else: default
  end
end
