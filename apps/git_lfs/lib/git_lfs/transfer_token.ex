defmodule GitLFS.TransferToken do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{APIKey, APIScope, User}
  alias ForgeRepos.Repository
  alias Fornacast.Repo
  alias GitLFS.Principal

  @version 1
  @default_ttl_seconds 300
  @maximum_ttl_seconds 900
  @endpoint_config_key :"Elixir.FornacastWeb.Endpoint"
  @payload_keys ~w(v aid ck cid cv rid rg sc ac oid sz exp)
  @oid_regex ~r/\A[0-9a-f]{64}\z/

  @spec issue(
          Principal.t(),
          Repository.t(),
          :batch | :object,
          atom(),
          String.t() | nil,
          keyword()
        ) ::
          {:ok, String.t(), pos_integer()} | {:error, atom()}
  def issue(principal, repository, scope, action, oid, options \\ [])

  def issue(
        %Principal{} = principal,
        %Repository{} = repository,
        scope,
        action,
        oid,
        options
      )
      when is_list(options) do
    with {:ok, now, ttl, object_size} <- issue_options(options),
         :ok <- validate_issue_target(scope, action, oid, object_size),
         {:ok, secret} <- signing_secret(),
         {:ok, canonical_repository} <- authorize_repository(principal, repository, action),
         {:ok, canonical_principal, credential_version} <-
           canonical_principal(principal, canonical_repository, action, now, secret) do
      payload = %{
        "v" => @version,
        "aid" => actor_id(canonical_principal),
        "ck" => Atom.to_string(canonical_principal.credential_kind),
        "cid" => canonical_principal.credential_id,
        "cv" => credential_version,
        "rid" => canonical_repository.id,
        "rg" => canonical_repository.generation,
        "sc" => Atom.to_string(scope),
        "ac" => Atom.to_string(action),
        "oid" => oid,
        "sz" => object_size,
        "exp" => DateTime.to_unix(now) + ttl
      }

      encoded = payload |> JSON.encode!() |> Base.url_encode64(padding: false)
      signature = signature(secret, encoded)
      {:ok, "v1.#{encoded}.#{signature}", ttl}
    end
  end

  def issue(_principal, _repository, _scope, _action, _oid, _options),
    do: {:error, :invalid_credentials}

  @doc false
  @spec authorize(Principal.t(), Repository.t(), :download | :upload, keyword()) ::
          {:ok, Principal.t(), Repository.t()} | {:error, :invalid_credentials | :not_found}
  def authorize(principal, repository, action, options \\ [])

  def authorize(%Principal{} = principal, %Repository{} = repository, action, options)
      when action in [:download, :upload] and is_list(options) do
    with {:ok, now, _ttl, nil} <- issue_options(options),
         {:ok, secret} <- signing_secret(),
         {:ok, canonical_repository} <- authorize_repository(principal, repository, action),
         {:ok, canonical_principal, _credential_version} <-
           canonical_principal(principal, canonical_repository, action, now, secret) do
      {:ok, canonical_principal, canonical_repository}
    else
      {:error, :not_found} -> {:error, :not_found}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  def authorize(_principal, _repository, _action, _options),
    do: {:error, :invalid_credentials}

  @spec verify(String.t(), :batch | :object, atom(), String.t() | nil, keyword()) ::
          {:ok, Principal.t(), Repository.t()}
          | {:error, :invalid_credentials | :not_found | :size_mismatch}
  def verify(token, scope, action, oid, options \\ [])

  def verify(token, scope, action, oid, options)
      when is_binary(token) and byte_size(token) <= 4_096 and is_list(options) do
    with {:ok, now, object_size} <- verify_options(options),
         :ok <- validate_verify_target(scope, action, oid, object_size),
         {:ok, secret} <- signing_secret(),
         {:ok, payload} <- decode_and_authenticate(token, secret),
         :ok <- verify_claims(payload, scope, action, oid, object_size, now),
         {:ok, repository} <- load_repository(payload),
         {:ok, principal} <- load_principal(payload, repository, action, now, secret),
         {:ok, authorized_repository} <- authorize_repository(principal, repository, action) do
      {:ok, principal, authorized_repository}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :size_mismatch} -> {:error, :size_mismatch}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  def verify(_token, _scope, _action, _oid, _options),
    do: {:error, :invalid_credentials}

  defp issue_options(options) do
    with true <- Keyword.keyword?(options),
         true <- Enum.all?(Keyword.keys(options), &(&1 in [:now, :ttl_seconds, :object_size])),
         %DateTime{} = now <- Keyword.get(options, :now, DateTime.utc_now(:second)),
         ttl when is_integer(ttl) and ttl > 0 and ttl <= @maximum_ttl_seconds <-
           Keyword.get(options, :ttl_seconds, @default_ttl_seconds),
         object_size <- Keyword.get(options, :object_size) do
      {:ok, DateTime.truncate(now, :second), ttl, object_size}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :size_mismatch} -> {:error, :size_mismatch}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_options(options) do
    with true <- Keyword.keyword?(options),
         true <- Enum.all?(Keyword.keys(options), &(&1 in [:now, :object_size])),
         %DateTime{} = now <- Keyword.get(options, :now, DateTime.utc_now(:second)),
         object_size <- Keyword.get(options, :object_size) do
      {:ok, DateTime.truncate(now, :second), object_size}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp validate_issue_target(:batch, action, nil, nil) when action in [:download, :upload],
    do: :ok

  defp validate_issue_target(:object, action, oid, object_size)
       when action in [:download, :upload, :verify] and is_binary(oid) and
              is_integer(object_size) and object_size >= 0 do
    if Regex.match?(@oid_regex, oid), do: :ok, else: {:error, :invalid_credentials}
  end

  defp validate_issue_target(_scope, _action, _oid, _object_size),
    do: {:error, :invalid_credentials}

  defp validate_verify_target(:batch, action, nil, nil) when action in [:download, :upload],
    do: :ok

  defp validate_verify_target(:object, :download, oid, object_size)
       when is_binary(oid) and
              (is_nil(object_size) or (is_integer(object_size) and object_size >= 0)) do
    if Regex.match?(@oid_regex, oid), do: :ok, else: {:error, :invalid_credentials}
  end

  defp validate_verify_target(:object, action, oid, object_size)
       when action in [:upload, :verify] and is_binary(oid) and is_integer(object_size) and
              object_size >= 0 do
    if Regex.match?(@oid_regex, oid), do: :ok, else: {:error, :invalid_credentials}
  end

  defp validate_verify_target(_scope, _action, _oid, _object_size),
    do: {:error, :invalid_credentials}

  defp authorize_repository(%Principal{actor: actor}, %Repository{} = supplied, action) do
    permission = if action in [:upload, :verify], do: :repository_write, else: :repository_read

    case ForgeRepos.fetch_authorized_repository_by_id(actor, supplied.id, permission) do
      {:ok, %Repository{generation: generation} = repository}
      when generation == supplied.generation ->
        {:ok, repository}

      {:ok, %Repository{}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonical_principal(
         %Principal{actor: nil, credential_kind: :anonymous, credential_id: nil},
         %Repository{visibility: :public},
         :download,
         _now,
         _secret
       ),
       do: {:ok, Principal.anonymous(), nil}

  defp canonical_principal(
         %Principal{
           actor: %User{id: actor_id},
           credential_kind: credential_kind,
           credential_id: credential_id
         },
         repository,
         action,
         now,
         secret
       )
       when credential_kind in [:password, :ssh, :api_key] do
    with %User{state: :active} = actor <-
           Repo.get_by(User, id: actor_id, kind: :user, state: :active),
         {:ok, principal, credential_version} <-
           canonical_credential(
             actor,
             credential_kind,
             credential_id,
             repository,
             action,
             now,
             secret
           ) do
      {:ok, principal, credential_version}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp canonical_principal(_principal, _repository, _action, _now, _secret),
    do: {:error, :invalid_credentials}

  defp canonical_credential(actor, :password, nil, _repository, _action, _now, secret) do
    {:ok, Principal.password(actor), credential_version(secret, actor.password_hash)}
  end

  defp canonical_credential(actor, :ssh, nil, _repository, _action, _now, secret),
    do: {:ok, Principal.ssh(actor), ssh_credential_version(actor, secret)}

  defp canonical_credential(actor, :api_key, credential_id, repository, action, now, _secret) do
    with %APIKey{user_id: user_id} = api_key <- Repo.get(APIKey, credential_id),
         true <- user_id == actor.id,
         true <- is_nil(api_key.revoked_at),
         true <- is_nil(api_key.expires_at) or DateTime.compare(api_key.expires_at, now) == :gt,
         :ok <- APIScope.authorize(api_key, api_action(action), repository.visibility) do
      {:ok, Principal.api_key(actor, api_key), nil}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp canonical_credential(_actor, _kind, _credential_id, _repository, _action, _now, _secret),
    do: {:error, :invalid_credentials}

  defp api_action(action) when action in [:upload, :verify], do: :git_write
  defp api_action(:download), do: :git_read

  defp actor_id(%Principal{actor: nil}), do: nil
  defp actor_id(%Principal{actor: %User{id: id}}), do: id

  defp decode_and_authenticate(token, secret) do
    with ["v1", encoded, received_signature] <- String.split(token, ".", parts: 3),
         true <- secure_equal?(signature(secret, encoded), received_signature),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(json) <= 2_048,
         {:ok, payload} when is_map(payload) <- JSON.decode(json),
         true <- Map.keys(payload) |> Enum.sort() == Enum.sort(@payload_keys) do
      {:ok, payload}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_claims(payload, scope, action, oid, object_size, now) do
    with @version <- payload["v"],
         true <- payload["sc"] == Atom.to_string(scope),
         true <- payload["ac"] == Atom.to_string(action),
         expires_at when is_integer(expires_at) <- payload["exp"],
         true <- expires_at > DateTime.to_unix(now),
         repository_id when is_integer(repository_id) and repository_id > 0 <- payload["rid"],
         generation when is_integer(generation) and generation > 0 <- payload["rg"],
         :ok <- verify_oid_claim(payload, scope, oid),
         :ok <- verify_size_claim(payload, scope, object_size) do
      :ok
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :size_mismatch} -> {:error, :size_mismatch}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_oid_claim(%{"oid" => nil}, :batch, nil), do: :ok
  defp verify_oid_claim(%{"oid" => oid}, :object, oid), do: :ok
  defp verify_oid_claim(%{"oid" => _oid}, :object, _expected), do: {:error, :not_found}
  defp verify_oid_claim(_payload, _scope, _expected), do: {:error, :invalid_credentials}

  defp verify_size_claim(%{"sz" => nil}, :batch, nil), do: :ok

  defp verify_size_claim(%{"sz" => size}, :object, nil)
       when is_integer(size) and size >= 0,
       do: :ok

  defp verify_size_claim(%{"sz" => size}, :object, size)
       when is_integer(size) and size >= 0,
       do: :ok

  defp verify_size_claim(%{"sz" => size}, :object, expected)
       when is_integer(size) and size >= 0 and is_integer(expected) and expected >= 0,
       do: {:error, :size_mismatch}

  defp verify_size_claim(_payload, _scope, _expected), do: {:error, :invalid_credentials}

  defp load_repository(%{"rid" => repository_id, "rg" => generation}) do
    case live_repository(repository_id, generation) do
      %Repository{} = repository -> {:ok, repository}
      nil -> {:error, :not_found}
    end
  end

  defp live_repository(repository_id, generation) do
    Repository
    |> where(
      [repository],
      repository.id == ^repository_id and repository.generation == ^generation and
        repository.lifecycle == :ready and is_nil(repository.deleted_at)
    )
    |> Repo.one()
  end

  defp load_principal(
         %{"aid" => nil, "ck" => "anonymous", "cid" => nil, "cv" => nil},
         %Repository{visibility: :public},
         :download,
         _now,
         _secret
       ),
       do: {:ok, Principal.anonymous()}

  defp load_principal(
         %{"aid" => nil, "ck" => "anonymous", "cid" => nil, "cv" => nil},
         %Repository{},
         :download,
         _now,
         _secret
       ),
       do: {:error, :not_found}

  defp load_principal(
         %{"aid" => actor_id, "ck" => credential_kind, "cid" => credential_id, "cv" => version},
         repository,
         action,
         now,
         secret
       )
       when is_integer(actor_id) and actor_id > 0 do
    with {:ok, kind} <- credential_kind(credential_kind),
         %User{state: :active} = actor <-
           Repo.get_by(User, id: actor_id, kind: :user, state: :active),
         {:ok, principal, expected_version} <-
           canonical_credential(actor, kind, credential_id, repository, action, now, secret),
         true <- secure_optional_equal?(expected_version, version) do
      {:ok, principal}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp load_principal(_payload, _repository, _action, _now, _secret),
    do: {:error, :invalid_credentials}

  defp credential_kind("password"), do: {:ok, :password}
  defp credential_kind("ssh"), do: {:ok, :ssh}
  defp credential_kind("api_key"), do: {:ok, :api_key}
  defp credential_kind(_kind), do: {:error, :invalid_credentials}

  defp signing_secret do
    configured = Application.get_env(:git_lfs, :transfer_token_secret)

    endpoint_secret =
      :fornacast_web
      |> Application.get_env(@endpoint_config_key, [])
      |> Keyword.get(:secret_key_base)

    case configured || endpoint_secret do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        {:ok, :crypto.mac(:hmac, :sha256, secret, "fornacast-git-lfs-transfer-v1")}

      _missing ->
        {:error, :invalid_credentials}
    end
  end

  defp signature(secret, encoded) do
    secret
    |> then(&:crypto.mac(:hmac, :sha256, &1, encoded))
    |> Base.url_encode64(padding: false)
  end

  defp credential_version(secret, value) when is_binary(value), do: signature(secret, value)

  defp ssh_credential_version(actor, secret) do
    actor
    |> ForgeAccounts.list_user_ssh_keys()
    |> Enum.map(&[&1.id, &1.fingerprint_sha256])
    |> Enum.sort()
    |> JSON.encode!()
    |> then(&credential_version(secret, &1))
  end

  defp secure_optional_equal?(nil, nil), do: true
  defp secure_optional_equal?(left, right), do: secure_equal?(left, right)

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
