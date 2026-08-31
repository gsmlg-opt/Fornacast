defmodule ForgeAccounts.GitHubCredentialVault do
  @moduledoc false

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, GitHubProfileSafety}

  @aad_version 1
  @max_pat_bytes 4_096
  @service_error {:error, :credential_service_unavailable}

  @spec ready?(term()) :: :ok | {:error, :credential_service_unavailable}
  def ready?(keyring \\ configured()) do
    case normalize_keyring(keyring) do
      {:ok, _normalized} -> :ok
      @service_error -> @service_error
    end
  end

  defmodule Envelope do
    @moduledoc false

    @derive {Inspect, only: [:key_id]}
    @enforce_keys [:ciphertext, :nonce, :tag, :key_id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            ciphertext: binary(),
            nonce: binary(),
            tag: binary(),
            key_id: String.t()
          }
  end

  @spec encrypt_saved(GitHubCredential.t(), GitHubIdentity.t(), binary(), term()) ::
          {:ok, Envelope.t()} | {:error, :credential_service_unavailable}
  def encrypt_saved(credential, identity, pat, keyring \\ configured())

  def encrypt_saved(
        %GitHubCredential{} = credential,
        %GitHubIdentity{} = identity,
        pat,
        keyring
      ) do
    with true <- valid_pat?(pat),
         true <- valid_saved_binding?(credential, identity),
         {:ok, normalized_keyring} <- normalize_keyring(keyring) do
      encrypt(pat, saved_aad(credential, identity), normalized_keyring)
    else
      _ -> @service_error
    end
  rescue
    _ -> @service_error
  catch
    _, _ -> @service_error
  end

  def encrypt_saved(_credential, _identity, _pat, _keyring), do: @service_error

  @spec with_saved_credential(
          GitHubCredential.t(),
          GitHubIdentity.t(),
          (binary() -> callback_result),
          term()
        ) :: {:ok, callback_result} | {:error, :credential_service_unavailable}
        when callback_result: term()
  def with_saved_credential(credential, identity, callback, keyring \\ configured())

  def with_saved_credential(
        %GitHubCredential{} = credential,
        %GitHubIdentity{} = identity,
        callback,
        keyring
      )
      when is_function(callback, 1) do
    case decrypt_saved(credential, identity, keyring) do
      {:ok, plaintext} -> {:ok, callback.(plaintext)}
      @service_error -> @service_error
    end
  end

  def with_saved_credential(_credential, _identity, _callback, _keyring), do: @service_error

  @doc false
  @spec validate_actor_owned_profile(
          GitHubCredential.t(),
          GitHubIdentity.t(),
          pos_integer(),
          map(),
          term()
        ) :: :ok | {:error, :invalid_response | :credential_service_unavailable}
  def validate_actor_owned_profile(
        credential,
        identity,
        actor_id,
        profile,
        keyring \\ configured()
      )

  def validate_actor_owned_profile(
        %GitHubCredential{} = credential,
        %GitHubIdentity{} = identity,
        actor_id,
        profile,
        keyring
      )
      when is_map(profile) do
    case decrypt_actor_owned_saved(credential, identity, actor_id, keyring) do
      {:ok, plaintext} -> GitHubProfileSafety.validate(profile, plaintext)
      @service_error -> @service_error
    end
  end

  def validate_actor_owned_profile(
        _credential,
        _identity,
        _actor_id,
        _profile,
        _keyring
      ),
      do: @service_error

  defp decrypt_saved(%GitHubCredential{} = credential, %GitHubIdentity{} = identity, keyring) do
    with true <- valid_saved_binding?(credential, identity),
         {:ok, normalized_keyring} <- normalize_keyring(keyring),
         {:ok, envelope} <- envelope_from_credential(credential) do
      decrypt(envelope, saved_aad(credential, identity), normalized_keyring)
    else
      _ -> @service_error
    end
  rescue
    _ -> @service_error
  catch
    _, _ -> @service_error
  end

  defp decrypt_actor_owned_saved(credential, identity, actor_id, keyring) do
    with true <- valid_actor_owned_binding?(credential, identity, actor_id),
         {:ok, normalized_keyring} <- normalize_keyring(keyring),
         {:ok, envelope} <- envelope_from_credential(credential) do
      decrypt(envelope, saved_aad(credential, identity), normalized_keyring)
    else
      _ -> @service_error
    end
  rescue
    _ -> @service_error
  catch
    _, _ -> @service_error
  end

  @spec encrypt_one_time(pos_integer(), pos_integer(), pos_integer(), binary(), term()) ::
          {:ok, Envelope.t()} | {:error, :credential_service_unavailable}
  def encrypt_one_time(run_id, actor_id, github_user_id, pat, keyring \\ configured())

  def encrypt_one_time(run_id, actor_id, github_user_id, pat, keyring) do
    with true <- valid_pat?(pat),
         true <- valid_one_time_binding?(run_id, actor_id, github_user_id),
         {:ok, normalized_keyring} <- normalize_keyring(keyring) do
      encrypt(pat, one_time_aad(run_id, actor_id, github_user_id), normalized_keyring)
    else
      _ -> @service_error
    end
  rescue
    _ -> @service_error
  catch
    _, _ -> @service_error
  end

  @spec with_one_time_credential(
          Envelope.t(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          (binary() -> callback_result),
          term()
        ) :: {:ok, callback_result} | {:error, :credential_service_unavailable}
        when callback_result: term()
  def with_one_time_credential(
        envelope,
        run_id,
        actor_id,
        github_user_id,
        callback,
        keyring \\ configured()
      )

  def with_one_time_credential(
        %Envelope{} = envelope,
        run_id,
        actor_id,
        github_user_id,
        callback,
        keyring
      )
      when is_function(callback, 1) do
    case decrypt_one_time(envelope, run_id, actor_id, github_user_id, keyring) do
      {:ok, plaintext} -> {:ok, callback.(plaintext)}
      @service_error -> @service_error
    end
  end

  def with_one_time_credential(
        _envelope,
        _run_id,
        _actor_id,
        _github_user_id,
        _callback,
        _keyring
      ),
      do: @service_error

  defp decrypt_one_time(
         %Envelope{} = envelope,
         run_id,
         actor_id,
         github_user_id,
         keyring
       ) do
    with true <- valid_one_time_binding?(run_id, actor_id, github_user_id),
         true <- valid_envelope?(envelope),
         {:ok, normalized_keyring} <- normalize_keyring(keyring) do
      decrypt(envelope, one_time_aad(run_id, actor_id, github_user_id), normalized_keyring)
    else
      _ -> @service_error
    end
  rescue
    _ -> @service_error
  catch
    _, _ -> @service_error
  end

  defp configured, do: Fornacast.Config.github_credential_keyring()

  defp encrypt(plaintext, aad, %{active: key_id, keys: keys}) do
    with {:ok, key} <- Map.fetch(keys, key_id) do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          plaintext,
          aad,
          16,
          true
        )

      {:ok, %Envelope{ciphertext: ciphertext, nonce: nonce, tag: tag, key_id: key_id}}
    else
      _ -> @service_error
    end
  end

  defp decrypt(%Envelope{} = envelope, aad, %{keys: keys}) do
    with {:ok, key} <- Map.fetch(keys, envelope.key_id),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             envelope.nonce,
             envelope.ciphertext,
             aad,
             envelope.tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> @service_error
    end
  end

  defp envelope_from_credential(%GitHubCredential{} = credential) do
    envelope = %Envelope{
      ciphertext: credential.ciphertext,
      nonce: credential.nonce,
      tag: credential.tag,
      key_id: credential.key_id
    }

    if valid_envelope?(envelope), do: {:ok, envelope}, else: @service_error
  end

  defp normalize_keyring({:ok, keyring}), do: normalize_keyring(keyring)

  defp normalize_keyring(%{active: active, keys: keys} = keyring)
       when is_binary(active) and byte_size(active) in 1..255 and is_map(keys) do
    valid? =
      map_size(keys) > 0 and
        match?({:ok, key} when is_binary(key) and byte_size(key) == 32, Map.fetch(keys, active)) and
        Enum.all?(keys, fn
          {key_id, key}
          when is_binary(key_id) and byte_size(key_id) in 1..255 and is_binary(key) ->
            byte_size(key) == 32

          _ ->
            false
        end)

    if valid?, do: {:ok, keyring}, else: @service_error
  end

  defp normalize_keyring(_keyring), do: @service_error

  defp valid_pat?(pat),
    do: is_binary(pat) and byte_size(pat) > 0 and byte_size(pat) <= @max_pat_bytes

  defp valid_saved_binding?(credential, identity) do
    positive_integer?(credential.id) and positive_integer?(credential.local_user_id) and
      positive_integer?(credential.github_identity_id) and
      credential.github_identity_id == identity.id and
      credential.local_user_id == identity.local_user_id and identity.kind == :user and
      positive_integer?(identity.github_user_id)
  end

  defp valid_actor_owned_binding?(credential, identity, actor_id) do
    positive_integer?(actor_id) and positive_integer?(credential.id) and
      credential.local_user_id == actor_id and positive_integer?(credential.github_identity_id) and
      credential.github_identity_id == identity.id and identity.kind == :user and
      identity.local_user_id in [nil, actor_id] and positive_integer?(identity.github_user_id)
  end

  defp valid_one_time_binding?(run_id, actor_id, github_user_id) do
    positive_integer?(run_id) and positive_integer?(actor_id) and
      positive_integer?(github_user_id)
  end

  defp valid_envelope?(%Envelope{} = envelope) do
    is_binary(envelope.ciphertext) and byte_size(envelope.ciphertext) in 1..@max_pat_bytes and
      is_binary(envelope.nonce) and byte_size(envelope.nonce) == 12 and
      is_binary(envelope.tag) and byte_size(envelope.tag) == 16 and
      is_binary(envelope.key_id) and byte_size(envelope.key_id) in 1..255
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp saved_aad(credential, identity) do
    :erlang.term_to_binary(
      {:fornacast_github_credential, @aad_version, :saved, credential.id,
       credential.local_user_id, :github, identity.github_user_id},
      [:deterministic]
    )
  end

  defp one_time_aad(run_id, actor_id, github_user_id) do
    :erlang.term_to_binary(
      {:fornacast_github_credential, @aad_version, :one_time, run_id, actor_id, :github,
       github_user_id},
      [:deterministic]
    )
  end
end
