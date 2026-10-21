defmodule ForgeGitHub.SavedCredential do
  @moduledoc "Renews saved GitHub App user tokens before trusted callback checkouts."

  alias ForgeAccounts.GitHubCredentialVerification
  alias ForgeGitHub.DeviceFlow

  def with_credential(actor, identity_id, callback, opts \\ []) when is_function(callback, 1) do
    with {:ok, %{credential: %GitHubCredentialVerification{} = reference}} <-
           ForgeAccounts.github_account_reference(actor, identity_id) do
      with_import_credential(
        actor,
        identity_id,
        reference.credential_id,
        fn access, current ->
          if same_authority?(reference, current),
            do: callback.(access),
            else: {:error, :credential_changed}
        end,
        opts
      )
    else
      {:ok, %{credential: nil}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def with_import_credential(actor, identity_id, credential_id, callback, opts \\ [])
      when is_function(callback, 2) do
    with {:ok, reference} <- reference(actor, identity_id, credential_id),
         :ok <- ensure_fresh(actor, identity_id, credential_id, opts) do
      ForgeAccounts.with_github_import_credential(actor, identity_id, credential_id, fn token,
                                                                                        current ->
        if same_authority?(reference, current),
          do: callback.(token, current),
          else: {:error, :credential_changed}
      end)
    end
  end

  def with_credential_for_verification(actor, identity_id, callback, opts \\ [])
      when is_function(callback, 2) do
    with {:ok, %{credential: %GitHubCredentialVerification{} = reference}} <-
           ForgeAccounts.github_account_reference(actor, identity_id),
         :ok <- ensure_fresh(actor, identity_id, reference.credential_id, opts) do
      ForgeAccounts.with_github_credential_for_verification(actor, identity_id, fn token,
                                                                                   current ->
        if same_authority?(reference, current),
          do: callback.(token, current),
          else: {:error, :credential_changed}
      end)
    else
      {:ok, %{credential: nil}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def ensure_fresh(actor, identity_id, credential_id, opts \\ []) do
    device_opts = Keyword.get(opts, :device_flow_options, [])

    callback = fn refresh, client_id ->
      DeviceFlow.refresh(refresh, Keyword.put(device_opts, :client_id, client_id))
    end

    # Waiting only observes another owner's durable claim. Provider errors are
    # never retried here because a one-use refresh may already have been consumed.
    await_refresh(actor, identity_id, credential_id, callback, 20)
  end

  defp await_refresh(actor, identity_id, credential_id, callback, attempts) do
    case ForgeAccounts.refresh_github_credential(actor, identity_id, credential_id, callback) do
      {:error, :refresh_in_progress} when attempts > 0 ->
        Process.sleep(100)
        await_refresh(actor, identity_id, credential_id, callback, attempts - 1)

      result ->
        result
    end
  end

  defp reference(actor, identity_id, credential_id) do
    case ForgeAccounts.github_account_reference(actor, identity_id) do
      {:ok,
       %{credential: %GitHubCredentialVerification{credential_id: ^credential_id} = reference}} ->
        {:ok, reference}

      {:ok, _} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  defp same_authority?(expected, current) do
    expected.credential_id == current.credential_id and
      expected.identity_id == current.identity_id and
      expected.local_user_id == current.local_user_id and
      expected.verification_version == current.verification_version
  end
end
