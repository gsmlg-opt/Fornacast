defmodule ForgeImports.OneTimeCredential do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.GitHubCredentialVault
  alias ForgeAccounts.GitHubCredentialVault.Envelope
  alias ForgeAccounts.GitHubCredentialCallback
  alias ForgeAccounts.GitHubAccounts.CredentialCallbackError
  alias ForgeAccounts.GitHubIdentity
  alias ForgeAccounts.GitHubProfileSafety
  alias ForgeAccounts.User
  alias ForgeImports.{ImportAttempt, ImportRun, RepositoryItem}
  alias Fornacast.Repo

  @service_error {:error, :credential_service_unavailable}

  @spec attach_changeset(ImportRun.t(), Envelope.t()) :: Ecto.Changeset.t()
  def attach_changeset(%ImportRun{credential_source: :one_time} = run, %Envelope{} = envelope) do
    ImportRun.one_time_credential_changeset(run, %{
      credential_ciphertext: envelope.ciphertext,
      credential_nonce: envelope.nonce,
      credential_tag: envelope.tag,
      credential_key_id: envelope.key_id
    })
  end

  def attach_changeset(%ImportRun{} = run, _envelope) do
    run
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:credential_source, "is not one-time")
  end

  @spec from_run(ImportRun.t()) :: {:ok, Envelope.t()} | {:error, :credential_service_unavailable}
  def from_run(%ImportRun{credential_source: :one_time} = run) do
    envelope = %Envelope{
      ciphertext: run.credential_ciphertext,
      nonce: run.credential_nonce,
      tag: run.credential_tag,
      key_id: run.credential_key_id
    }

    if valid_envelope?(envelope), do: {:ok, envelope}, else: @service_error
  end

  def from_run(_run), do: @service_error

  @spec with_credential(User.t(), ImportRun.t(), (binary() -> term()), term()) ::
          {:ok, :acknowledged}
          | {:error, :credential_service_unavailable | :unsafe_credential_result}
  def with_credential(
        actor,
        run,
        callback,
        keyring \\ Fornacast.Config.github_credential_keyring()
      )

  def with_credential(
        %User{id: actor_id},
        %ImportRun{lease_owner: owner, lock_version: version} = capability,
        callback,
        keyring
      )
      when is_integer(actor_id) and is_binary(owner) and owner != "" and is_integer(version) and
             is_function(callback, 1) do
    with %ImportRun{} = run <- current_owned_run(actor_id, capability),
         {:ok, envelope} <- from_run(run),
         %GitHubIdentity{github_user_id: github_user_id}
         when is_integer(github_user_id) and github_user_id > 0 <-
           Repo.get(GitHubIdentity, run.github_identity_id) do
      checked_out_result(envelope, run, github_user_id, callback, keyring)
    else
      _ -> @service_error
    end
  end

  def with_credential(_actor, _run, _callback, _keyring), do: @service_error

  @doc false
  @spec with_item_credential(User.t(), RepositoryItem.t(), (binary() -> term()), term()) ::
          {:ok, :acknowledged}
          | {:error, :credential_service_unavailable | :unsafe_credential_result}
  def with_item_credential(actor, item, callback, keyring)

  def with_item_credential(
        %User{id: actor_id},
        %RepositoryItem{lease_owner: owner, lock_version: version} = capability,
        callback,
        keyring
      )
      when is_integer(actor_id) and is_binary(owner) and owner != "" and is_integer(version) and
             is_function(callback, 1) do
    with {%ImportRun{} = run, %RepositoryItem{}} <- current_owned_item(actor_id, capability),
         {:ok, envelope} <- from_run(run),
         %GitHubIdentity{kind: :user, github_user_id: github_user_id}
         when is_integer(github_user_id) and github_user_id > 0 <-
           Repo.get(GitHubIdentity, run.github_identity_id) do
      checked_out_result(envelope, run, github_user_id, callback, keyring)
    else
      _ -> @service_error
    end
  end

  def with_item_credential(_actor, _item, _callback, _keyring), do: @service_error

  def verify_envelope(%ImportRun{} = run, %Envelope{} = envelope, keyring) do
    with %GitHubIdentity{github_user_id: github_user_id}
         when is_integer(github_user_id) and github_user_id > 0 <-
           Repo.get(GitHubIdentity, run.github_identity_id),
         {:ok, :verified} <-
           GitHubCredentialVault.with_one_time_credential(
             envelope,
             run.id,
             run.actor_user_id,
             github_user_id,
             fn _plaintext -> :verified end,
             keyring
           ) do
      :ok
    else
      _ -> @service_error
    end
  end

  def verify_envelope(_run, _envelope, _keyring), do: @service_error

  @doc false
  def validate_profiles(
        actor,
        run,
        profiles,
        keyring \\ Fornacast.Config.github_credential_keyring()
      )

  def validate_profiles(
        %User{id: actor_id},
        %ImportRun{} = expected,
        profiles,
        keyring
      )
      when is_integer(actor_id) and is_list(profiles) and length(profiles) <= 16 do
    with %ImportRun{} = run <- current_validation_run(actor_id, expected),
         {:ok, envelope} <- from_run(run),
         %GitHubIdentity{github_user_id: github_user_id}
         when is_integer(github_user_id) and github_user_id > 0 <-
           Repo.get(GitHubIdentity, run.github_identity_id),
         {:ok, result} <-
           GitHubCredentialVault.with_one_time_credential(
             envelope,
             run.id,
             run.actor_user_id,
             github_user_id,
             &validate_profile_values(profiles, &1),
             keyring
           ) do
      result
    else
      {:error, :invalid_response} = error -> error
      _ -> @service_error
    end
  end

  def validate_profiles(_actor, _run, _profiles, _keyring), do: @service_error

  def clear_changeset(%ImportRun{} = run), do: ImportRun.clear_one_time_credential_changeset(run)

  defp checked_out_result(envelope, run, github_user_id, callback, keyring) do
    case GitHubCredentialVault.with_one_time_credential(
           envelope,
           run.id,
           run.actor_user_id,
           github_user_id,
           fn plaintext ->
             GitHubCredentialCallback.invoke(callback, plaintext, CredentialCallbackError)
           end,
           keyring
         ) do
      {:ok, :ok} -> {:ok, :acknowledged}
      {:ok, {:error, _safe_reason}} -> {:ok, :acknowledged}
      {:ok, :unsafe} -> {:error, :unsafe_credential_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_owned_run(actor_id, capability) do
    now = DateTime.utc_now(:second)
    terminal_states = ImportRun.terminal_states()

    Repo.one(
      from run in ImportRun,
        join: actor in User,
        on: actor.id == run.actor_user_id,
        where:
          run.id == ^capability.id and run.actor_user_id == ^actor_id and
            actor.kind == :user and actor.state == :active and
            run.credential_source == :one_time and run.state not in ^terminal_states and
            run.lock_version == ^capability.lock_version and
            run.lease_owner == ^capability.lease_owner and not is_nil(run.lease_expires_at) and
            run.lease_expires_at > ^now
    )
  end

  defp current_owned_item(actor_id, capability) do
    now = DateTime.utc_now(:second)

    Repo.one(
      from item in RepositoryItem,
        join: run in ImportRun,
        on: run.id == item.import_run_id,
        join: actor in User,
        on: actor.id == run.actor_user_id,
        join: attempt in ImportAttempt,
        on:
          attempt.repository_item_id == item.id and
            attempt.attempt_number == item.attempt_count,
        where:
          item.id == ^capability.id and item.import_run_id == ^capability.import_run_id and
            item.lock_version == ^capability.lock_version and
            item.lease_owner == ^capability.lease_owner and not is_nil(item.lease_expires_at) and
            item.lease_expires_at > ^now and item.selected == true and item.state == :staging_git and
            is_nil(item.cleanup_state) and run.actor_user_id == ^actor_id and
            run.state == :running and
            actor.kind == :user and actor.state == :active and attempt.state == :running,
        select: {run, item}
    )
  end

  defp current_validation_run(actor_id, expected) do
    terminal_states = ImportRun.terminal_states()

    Repo.one(
      from run in ImportRun,
        join: actor in User,
        on: actor.id == run.actor_user_id,
        where:
          run.id == ^expected.id and run.actor_user_id == ^actor_id and
            actor.kind == :user and actor.state == :active and
            run.credential_source == :one_time and run.state not in ^terminal_states and
            run.lock_version == ^expected.lock_version
    )
  end

  defp validate_profile_values(profiles, credential) do
    Enum.reduce_while(profiles, :ok, fn
      profile, :ok when is_map(profile) ->
        case GitHubProfileSafety.validate(profile, credential) do
          :ok -> {:cont, :ok}
          {:error, :invalid_response} -> {:halt, {:error, :invalid_response}}
        end

      _invalid, :ok ->
        {:halt, {:error, :invalid_response}}
    end)
  end

  defp valid_envelope?(%Envelope{} = envelope) do
    is_binary(envelope.ciphertext) and byte_size(envelope.ciphertext) in 1..4_096 and
      is_binary(envelope.nonce) and byte_size(envelope.nonce) == 12 and
      is_binary(envelope.tag) and byte_size(envelope.tag) == 16 and
      is_binary(envelope.key_id) and byte_size(envelope.key_id) in 1..255
  end
end
