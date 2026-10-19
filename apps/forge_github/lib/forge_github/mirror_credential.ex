defmodule ForgeGitHub.MirrorCredential do
  @moduledoc "Ephemeral credential checkout for a freshly authorized mirror scope."

  alias ForgeAccounts.GitHubCredentialVerification
  alias ForgeGitHub.{InstallationToken, InstallationTokenBroker}

  @allow_test_callbacks Mix.env() == :test

  def with_token(scope, permissions, options, callback)
      when is_map(scope) and is_map(permissions) and is_list(options) and is_function(callback, 1) do
    case Map.get(scope, :credential_source, :github_app) do
      :pat -> with_pat(scope, options, callback)
      :github_app -> with_app(scope, permissions, options, callback)
      _ -> {:error, :credential_unavailable}
    end
  end

  def gate_key(%{credential_source: :pat, github_credential_id: id}),
    do: {:saved_credential, id}

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

  def valid_scope?(scope),
    do: is_integer(scope[:github_installation_id]) and scope.github_installation_id > 0

  defp with_pat(scope, options, callback) do
    authorize = test_callback(options, :pat_authorize, &ForgeMirrors.authorize_pat_credential/1)
    checkout = test_callback(options, :pat_checkout, &checkout/2)

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

  defp with_app(scope, permissions, options, callback) do
    fetch = Keyword.get(options, :token_fetch, &InstallationTokenBroker.fetch/2)

    case fetch.(scope.github_installation_id, permissions) do
      %InstallationToken{token: token} -> callback.(token)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :credential_unavailable}
    end
  end

  defp checkout(scope, callback) do
    case ForgeAccounts.get_user(scope.credential_owner_user_id) do
      %ForgeAccounts.User{} = actor ->
        ForgeAccounts.with_github_import_credential(
          actor,
          scope.github_identity_id,
          scope.github_credential_id,
          callback
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
  defp normalize_checkout({:error, :credential_service_unavailable}), do: {:error, :unavailable}
  defp normalize_checkout({:error, _reason}), do: {:error, :credential_unavailable}
  defp normalize_checkout(_), do: {:error, :credential_unavailable}

  defp test_callback(options, key, default) do
    if @allow_test_callbacks, do: Keyword.get(options, key, default), else: default
  end
end
