defmodule ForgeAccounts.GitHubCredentialVaultTest do
  use ExUnit.Case, async: false

  alias Ecto.Changeset
  alias ForgeAccounts.{GitHubCredential, GitHubCredentialVault, GitHubIdentity, User}
  alias Fornacast.{Config, Repo}

  @pat "github_pat_never_print_this_value"
  @active_key :binary.copy(<<17>>, 32)
  @old_key :binary.copy(<<23>>, 32)
  @keyring %{active: "active", keys: %{"active" => @active_key, "old" => @old_key}}

  setup do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Ecto.Adapters.SQL.query!(Repo, "delete from github_credentials", [])
        Ecto.Adapters.SQL.query!(Repo, "delete from github_identities", [])
    end

    :ok
  end

  test "AES-256-GCM saved credentials round trip with fresh nonces" do
    credential = credential()
    identity = identity()

    assert {:ok, first} =
             GitHubCredentialVault.encrypt_saved(credential, identity, @pat, @keyring)

    assert {:ok, second} =
             GitHubCredentialVault.encrypt_saved(credential, identity, @pat, @keyring)

    assert first.key_id == "active"
    assert byte_size(first.nonce) == 12
    assert byte_size(first.tag) == 16
    assert first.nonce != second.nonce
    assert first.ciphertext != second.ciphertext
    refute first.ciphertext == @pat

    assert {:ok, :used} =
             first
             |> put_envelope(credential)
             |> GitHubCredentialVault.with_saved_credential(
               identity,
               fn pat ->
                 assert pat == @pat
                 :used
               end,
               @keyring
             )
  end

  test "plaintext decryption is callback-only and callback exceptions remain unexpected" do
    Code.ensure_loaded!(GitHubCredentialVault)

    refute function_exported?(GitHubCredentialVault, :decrypt_saved, 2)
    refute function_exported?(GitHubCredentialVault, :decrypt_saved, 3)
    refute function_exported?(GitHubCredentialVault, :decrypt_one_time, 4)
    refute function_exported?(GitHubCredentialVault, :decrypt_one_time, 5)

    assert {:ok, envelope} =
             GitHubCredentialVault.encrypt_one_time(41, 52, 63, @pat, @keyring)

    assert_raise RuntimeError, "callback failed", fn ->
      GitHubCredentialVault.with_one_time_credential(
        envelope,
        41,
        52,
        63,
        fn pat ->
          assert pat == @pat
          raise "callback failed"
        end,
        @keyring
      )
    end
  end

  test "saved AAD binds version, purpose, credential, owner, provider, and GitHub user" do
    credential = credential()
    identity = identity()

    assert {:ok, envelope} =
             GitHubCredentialVault.encrypt_saved(credential, identity, @pat, @keyring)

    encrypted = put_envelope(envelope, credential)

    for {changed_credential, changed_identity} <- [
          {%{encrypted | id: encrypted.id + 1}, identity},
          {%{encrypted | local_user_id: encrypted.local_user_id + 1}, identity},
          {encrypted, %{identity | github_user_id: identity.github_user_id + 1}}
        ] do
      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.with_saved_credential(
                 changed_credential,
                 changed_identity,
                 fn _pat -> flunk("callback invoked for changed saved AAD") end,
                 @keyring
               )
    end

    for aad <- [
          saved_aad(2, credential, identity, :github),
          saved_aad(1, credential, identity, :gitlab),
          one_time_aad(
            1,
            credential.id,
            credential.local_user_id,
            identity.github_user_id,
            :github
          )
        ] do
      wrong_envelope = encrypt_with_aad(@active_key, "active", @pat, aad)

      assert {:error, :credential_service_unavailable} =
               wrong_envelope
               |> put_envelope(credential)
               |> GitHubCredentialVault.with_saved_credential(
                 identity,
                 fn _pat -> flunk("callback invoked for wrong saved AAD") end,
                 @keyring
               )
    end
  end

  test "one-time AAD binds version, purpose, run, actor, provider, and GitHub user" do
    assert {:ok, envelope} =
             GitHubCredentialVault.encrypt_one_time(41, 52, 63, @pat, @keyring)

    assert {:ok, :used} =
             GitHubCredentialVault.with_one_time_credential(
               envelope,
               41,
               52,
               63,
               fn pat ->
                 assert pat == @pat
                 :used
               end,
               @keyring
             )

    for {run_id, actor_id, github_user_id} <- [{42, 52, 63}, {41, 53, 63}, {41, 52, 64}] do
      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.with_one_time_credential(
                 envelope,
                 run_id,
                 actor_id,
                 github_user_id,
                 fn _pat -> flunk("callback invoked for changed one-time AAD") end,
                 @keyring
               )
    end

    for aad <- [
          one_time_aad(2, 41, 52, 63, :github),
          one_time_aad(1, 41, 52, 63, :gitlab),
          saved_aad(1, %{id: 41, local_user_id: 52}, identity(63), :github)
        ] do
      wrong_envelope = encrypt_with_aad(@active_key, "active", @pat, aad)

      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.with_one_time_credential(
                 wrong_envelope,
                 41,
                 52,
                 63,
                 fn _pat -> flunk("callback invoked for wrong one-time AAD") end,
                 @keyring
               )
    end
  end

  test "one-time credential bindings reject nonpositive GitHub user IDs without callbacks" do
    for github_user_id <- [0, -1] do
      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.encrypt_one_time(
                 41,
                 52,
                 github_user_id,
                 @pat,
                 @keyring
               )

      envelope =
        encrypt_with_aad(
          @active_key,
          "active",
          @pat,
          one_time_aad(1, 41, 52, github_user_id, :github)
        )

      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.with_one_time_credential(
                 envelope,
                 41,
                 52,
                 github_user_id,
                 fn _pat -> send(self(), :invalid_one_time_callback_invoked) end,
                 @keyring
               )

      refute_received :invalid_one_time_callback_invoked
    end
  end

  test "the active key writes while configured old keys continue to read" do
    old_keyring = %{active: "old", keys: @keyring.keys}

    assert {:ok, old_envelope} =
             GitHubCredentialVault.encrypt_saved(credential(), identity(), @pat, old_keyring)

    assert old_envelope.key_id == "old"

    assert {:ok, :used} =
             old_envelope
             |> put_envelope(credential())
             |> GitHubCredentialVault.with_saved_credential(
               identity(),
               fn pat ->
                 assert pat == @pat
                 :used
               end,
               @keyring
             )

    assert {:ok, new_envelope} =
             GitHubCredentialVault.encrypt_saved(credential(), identity(), @pat, @keyring)

    assert new_envelope.key_id == "active"
  end

  test "unknown and wrong keys plus tampered envelope bytes fail closed" do
    assert {:ok, envelope} =
             GitHubCredentialVault.encrypt_saved(credential(), identity(), @pat, @keyring)

    cases = [
      {%{envelope | key_id: "missing"}, @keyring},
      {%{envelope | key_id: String.duplicate("k", 256)}, @keyring},
      {envelope, %{active: "active", keys: %{"active" => :binary.copy(<<99>>, 32)}}},
      {%{envelope | ciphertext: flip_first_byte(envelope.ciphertext)}, @keyring},
      {%{envelope | nonce: flip_first_byte(envelope.nonce)}, @keyring},
      {%{envelope | tag: flip_first_byte(envelope.tag)}, @keyring}
    ]

    for {changed_envelope, keyring} <- cases do
      result =
        changed_envelope
        |> put_envelope(credential())
        |> GitHubCredentialVault.with_saved_credential(
          identity(),
          fn _pat -> send(self(), :credential_callback_invoked) end,
          keyring
        )

      assert result == {:error, :credential_service_unavailable}
      refute_received :credential_callback_invoked
      refute inspect(result) =~ @pat
    end
  end

  test "saved credential custody requires the exact linked ordinary identity" do
    credential = credential()
    identity = identity()

    assert {:ok, envelope} =
             GitHubCredentialVault.encrypt_saved(credential, identity, @pat, @keyring)

    encrypted = put_envelope(envelope, credential)

    mismatches = [
      {%{credential | github_identity_id: identity.id + 1}, identity},
      {credential, %{identity | id: identity.id + 1}},
      {credential, %{identity | local_user_id: identity.local_user_id + 1}},
      {credential, %{identity | local_user_id: nil}},
      {credential, %{identity | kind: :deleted, local_user_id: nil, github_user_id: nil}},
      {credential, %{identity | github_user_id: 0}}
    ]

    for {changed_credential, changed_identity} <- mismatches do
      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.encrypt_saved(
                 changed_credential,
                 changed_identity,
                 @pat,
                 @keyring
               )

      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.with_saved_credential(
                 %{encrypted | github_identity_id: changed_credential.github_identity_id},
                 changed_identity,
                 fn _pat -> send(self(), :mismatched_identity_callback_invoked) end,
                 @keyring
               )

      refute_received :mismatched_identity_callback_invoked
    end
  end

  test "missing and malformed keyrings fail closed without SECRET_KEY_BASE fallback" do
    endpoint_secret =
      Application.fetch_env!(:fornacast_web, FornacastWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    assert is_binary(endpoint_secret)

    overlong_key_id = String.duplicate("k", 256)

    malformed = [
      :unavailable,
      nil,
      %{},
      %{active: "active", keys: %{}},
      %{active: "missing", keys: %{"active" => @active_key}},
      %{active: "active", keys: %{"active" => <<1, 2, 3>>}},
      %{active: "", keys: %{}},
      %{active: overlong_key_id, keys: %{overlong_key_id => @active_key}},
      %{
        active: "active",
        keys: %{"active" => @active_key, overlong_key_id => @old_key}
      }
    ]

    for keyring <- malformed do
      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.encrypt_saved(credential(), identity(), @pat, keyring)
    end

    original = Application.get_env(:fornacast, :github_credential_keyring)
    Application.put_env(:fornacast, :github_credential_keyring, :unavailable)

    try do
      assert {:error, :credential_service_unavailable} = Config.github_credential_keyring()

      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.encrypt_saved(credential(), identity(), @pat)

      assert {:ok, envelope} =
               GitHubCredentialVault.encrypt_saved(credential(), identity(), @pat, @keyring)

      assert {:error, :credential_service_unavailable} =
               envelope
               |> put_envelope(credential())
               |> GitHubCredentialVault.with_saved_credential(
                 identity(),
                 fn _pat -> send(self(), :unavailable_config_callback_invoked) end,
                 :unavailable
               )

      refute_received :unavailable_config_callback_invoked
    after
      Application.put_env(:fornacast, :github_credential_keyring, original)
    end
  end

  test "configured test keyring is valid and malformed configured values are rejected" do
    assert {:ok, %{active: active, keys: keys}} = Config.github_credential_keyring()
    assert active != ""
    assert byte_size(Map.fetch!(keys, active)) == 32

    original = Application.get_env(:fornacast, :github_credential_keyring)

    overlong_key_id = String.duplicate("k", 256)

    try do
      for keyring <- [
            %{active: "active", keys: %{"active" => <<1>>}},
            %{active: overlong_key_id, keys: %{overlong_key_id => @active_key}},
            %{
              active: "active",
              keys: %{"active" => @active_key, overlong_key_id => @old_key}
            }
          ] do
        Application.put_env(:fornacast, :github_credential_keyring, keyring)
        assert {:error, :credential_service_unavailable} = Config.github_credential_keyring()
      end
    after
      Application.put_env(:fornacast, :github_credential_keyring, original)
    end
  end

  test "production compile config never reads or embeds runtime credential keys" do
    key = :binary.copy(<<71>>, 32)
    encoded_key = Base.encode64(key)
    keys_json = JSON.encode!(%{"build-only" => encoded_key})

    assert {:unavailable, false} =
             read_keyring_config("config/config.exs", :prod, keys_json, "build-only", key)

    assert {%{active: "build-only", keys: %{"build-only" => ^key}}, true} =
             read_keyring_config("config/runtime.exs", :prod, keys_json, "build-only", key)
  end

  test "config parsing rejects overlong active and nonactive key IDs" do
    key = :binary.copy(<<73>>, 32)
    encoded_key = Base.encode64(key)
    overlong_key_id = String.duplicate("k", 256)

    for {active, keys} <- [
          {overlong_key_id, %{overlong_key_id => encoded_key}},
          {"active", %{"active" => encoded_key, overlong_key_id => encoded_key}}
        ],
        {config_path, env} <- [
          {"config/config.exs", :dev},
          {"config/runtime.exs", :prod}
        ] do
      assert {:unavailable, false} =
               read_keyring_config(config_path, env, JSON.encode!(keys), active, key)
    end
  end

  test "PAT input must be a nonempty bounded binary and errors do not contain it" do
    for invalid <- [nil, [], "", String.duplicate("x", 4_097)] do
      result =
        GitHubCredentialVault.encrypt_one_time(1, 2, 3, invalid, @keyring)

      assert result == {:error, :credential_service_unavailable}

      case String.slice(to_string_safe(invalid), 0, 32) do
        "" -> :ok
        fragment -> refute inspect(result) =~ fragment
      end
    end

    assert {:ok, envelope} =
             GitHubCredentialVault.encrypt_one_time(
               1,
               2,
               3,
               String.duplicate("x", 4_096),
               @keyring
             )

    assert byte_size(envelope.ciphertext) == 4_096
  end

  test "credential envelopes and schemas redact encrypted bytes from Inspect" do
    envelope = encrypt_with_aad(@active_key, "active", @pat, one_time_aad(1, 1, 2, 3, :github))

    credential =
      envelope
      |> put_envelope(credential())

    for inspected <- [inspect(envelope), inspect(credential)] do
      refute inspected =~ Base.encode16(envelope.ciphertext)
      refute inspected =~ envelope.ciphertext
      refute inspected =~ envelope.nonce
      refute inspected =~ envelope.tag
      refute inspected =~ @pat
    end

    assert MapSet.new(GitHubCredential.__schema__(:redact_fields)) ==
             MapSet.new([:ciphertext, :nonce, :tag])
  end

  test "credential schema persists one row per identity and validates status" do
    suffix = unique_suffix()
    github_user_id = unique_github_user_id()

    user =
      Repo.insert!(%User{
        username: "credential-user-#{suffix}",
        email: "credential-user-#{suffix}@example.test",
        password_hash: "redacted",
        kind: :user,
        role: :user,
        state: :active
      })

    github_identity =
      Repo.insert!(%GitHubIdentity{
        kind: :user,
        github_user_id: github_user_id,
        login: "credential-user-#{suffix}",
        local_user_id: user.id
      })

    attrs = %{
      local_user_id: user.id,
      github_identity_id: github_identity.id,
      ciphertext: <<255, 0, 254>>,
      nonce: :binary.copy(<<4>>, 12),
      tag: :binary.copy(<<5>>, 16),
      key_id: "active",
      status: :valid,
      last_verified_at: ~U[2026-08-25 00:02:00Z]
    }

    assert {:ok, saved} =
             %GitHubCredential{}
             |> GitHubCredential.changeset(attrs)
             |> Repo.insert()

    assert saved.status == :valid

    assert {:error, %Changeset{errors: [github_identity_id: {_, metadata}]}} =
             %GitHubCredential{}
             |> GitHubCredential.changeset(%{attrs | local_user_id: user.id})
             |> Repo.insert()

    assert metadata[:constraint] == :unique

    invalid = GitHubCredential.changeset(%GitHubCredential{}, %{attrs | status: :unknown})
    refute invalid.valid?
    assert Keyword.has_key?(invalid.errors, :status)

    injected_version =
      GitHubCredential.changeset(%GitHubCredential{}, Map.put(attrs, :verification_version, 0))

    assert injected_version.valid?
    assert Changeset.get_field(injected_version, :verification_version) == 1
    refute Map.has_key?(injected_version.changes, :verification_version)

    overlong_key_id =
      GitHubCredential.changeset(%GitHubCredential{}, %{
        attrs
        | key_id: String.duplicate("é", 128)
      })

    refute overlong_key_id.valid?
    assert Keyword.has_key?(overlong_key_id.errors, :key_id)

    assert MapSet.new(GitHubCredential.__schema__(:fields)) ==
             MapSet.new([
               :id,
               :local_user_id,
               :github_identity_id,
               :ciphertext,
               :nonce,
               :tag,
               :key_id,
               :status,
               :last_verified_at,
               :verification_version,
               :inserted_at,
               :updated_at
             ])
  end

  test "credential changesets count opaque AEAD field lengths in bytes" do
    %{user: user, identity: identity} = persisted_credential_fixture(insert_credential?: false)

    binding = %GitHubCredential{
      id: 77,
      local_user_id: user.id,
      github_identity_id: identity.id
    }

    assert {:ok, envelope} =
             GitHubCredentialVault.encrypt_saved(binding, identity, @pat, @keyring)

    attrs = %{
      local_user_id: user.id,
      github_identity_id: identity.id,
      ciphertext: envelope.ciphertext,
      nonce: envelope.nonce,
      tag: envelope.tag,
      key_id: envelope.key_id,
      status: :valid
    }

    assert {:ok, saved} =
             %GitHubCredential{}
             |> GitHubCredential.changeset(attrs)
             |> Repo.insert()

    assert saved.ciphertext == envelope.ciphertext
    assert saved.nonce == envelope.nonce
    assert saved.tag == envelope.tag

    non_utf8_attrs = %{
      attrs
      | ciphertext: <<255, 254, 0>>,
        nonce: <<255, 254, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>,
        tag: <<255, 254, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13>>
    }

    assert GitHubCredential.changeset(%GitHubCredential{}, non_utf8_attrs).valid?

    exact_multibyte_attrs = %{
      attrs
      | ciphertext: "é",
        nonce: String.duplicate("é", 6),
        tag: String.duplicate("é", 8)
    }

    assert byte_size(exact_multibyte_attrs.nonce) == 12
    assert byte_size(exact_multibyte_attrs.tag) == 16
    assert GitHubCredential.changeset(%GitHubCredential{}, exact_multibyte_attrs).valid?

    oversized = %{
      attrs
      | ciphertext: String.duplicate("é", 2_049)
    }

    assert byte_size(oversized.ciphertext) == 4_098
    refute GitHubCredential.changeset(%GitHubCredential{}, oversized).valid?
  end

  test "database status constraint rejects values outside valid and invalid" do
    %{user: user, identity: identity} = persisted_credential_fixture(insert_credential?: false)

    assert {:error, error} =
             capture_error(fn ->
               Ecto.Adapters.SQL.query!(Repo, invalid_status_insert_sql(), [
                 user.id,
                 identity.id,
                 <<1, 2, 3>>,
                 :binary.copy(<<4>>, 12),
                 :binary.copy(<<5>>, 16),
                 "active",
                 "unknown"
               ])
             end)

    assert Exception.message(error) =~ "github_credentials_status_check"
  end

  test "deleting a local user cascades its credential and retains the external identity" do
    %{user: user, identity: identity, credential: saved} = persisted_credential_fixture()

    assert {:ok, _deleted_user} = Repo.delete(user)
    refute Repo.get(GitHubCredential, saved.id)
    assert %GitHubIdentity{local_user_id: nil} = Repo.get!(GitHubIdentity, identity.id)
  end

  test "deleting an identity is restricted while its credential exists" do
    %{identity: identity} = persisted_credential_fixture()

    assert {:error, error} = capture_error(fn -> Repo.delete!(identity) end)
    assert Exception.message(error) =~ "constraint"
  end

  defp credential do
    struct(GitHubCredential, id: 7, local_user_id: 4, github_identity_id: 9)
  end

  defp identity(github_user_id \\ 9_000_000_001) do
    %GitHubIdentity{
      id: 9,
      github_user_id: github_user_id,
      login: "octocat",
      kind: :user,
      local_user_id: 4
    }
  end

  defp put_envelope(envelope, credential) do
    struct(credential,
      ciphertext: envelope.ciphertext,
      nonce: envelope.nonce,
      tag: envelope.tag,
      key_id: envelope.key_id
    )
  end

  defp encrypt_with_aad(key, key_id, plaintext, aad) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, 16, true)

    struct(GitHubCredentialVault.Envelope,
      ciphertext: ciphertext,
      nonce: nonce,
      tag: tag,
      key_id: key_id
    )
  end

  defp saved_aad(version, credential, identity, provider) do
    :erlang.term_to_binary(
      {:fornacast_github_credential, version, :saved, credential.id, credential.local_user_id,
       provider, identity.github_user_id},
      [:deterministic]
    )
  end

  defp one_time_aad(version, run_id, actor_id, github_user_id, provider) do
    :erlang.term_to_binary(
      {:fornacast_github_credential, version, :one_time, run_id, actor_id, provider,
       github_user_id},
      [:deterministic]
    )
  end

  defp flip_first_byte(<<byte, rest::binary>>), do: <<Bitwise.bxor(byte, 1), rest::binary>>

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)

  defp read_keyring_config(config_path, env, keys_json, active, expected_key) do
    project_root = Path.expand("../../..", __DIR__)
    config_path = Path.join(project_root, config_path)

    script = """
    config = Config.Reader.read!(#{inspect(config_path)}, env: #{inspect(env)}, target: :host)
    keyring = get_in(config, [:fornacast, :github_credential_keyring])
    expected_key = System.fetch_env!("FORNACAST_TEST_EXPECTED_CREDENTIAL_KEY") |> Base.decode64!()
    embedded? = :binary.match(:erlang.term_to_binary(config), expected_key) != :nomatch
    IO.write(Base.encode64(:erlang.term_to_binary({keyring, embedded?})))
    """

    {encoded_result, 0} =
      System.cmd("elixir", ["-e", script],
        cd: project_root,
        env: [
          {"FORNACAST_DATABASE_ADAPTER", "turso"},
          {"FORNACAST_GITHUB_CREDENTIAL_KEYS", keys_json},
          {"FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID", active},
          {"FORNACAST_TEST_EXPECTED_CREDENTIAL_KEY", Base.encode64(expected_key)},
          {"RELEASE_COMMAND", ""}
        ],
        stderr_to_stdout: true
      )

    encoded_result
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
  end

  defp persisted_credential_fixture(opts \\ []) do
    suffix = unique_suffix()

    user =
      Repo.insert!(%User{
        username: "persisted-credential-user-#{suffix}",
        email: "persisted-credential-user-#{suffix}@example.test",
        password_hash: "redacted",
        kind: :user,
        role: :user,
        state: :active
      })

    identity =
      Repo.insert!(%GitHubIdentity{
        kind: :user,
        github_user_id: unique_github_user_id(),
        login: "persisted-credential-user-#{suffix}",
        local_user_id: user.id
      })

    result = %{user: user, identity: identity}

    if Keyword.get(opts, :insert_credential?, true) do
      credential =
        Repo.insert!(%GitHubCredential{
          local_user_id: user.id,
          github_identity_id: identity.id,
          ciphertext: <<1, 2, 3>>,
          nonce: :binary.copy(<<4>>, 12),
          tag: :binary.copy(<<5>>, 16),
          key_id: "active",
          status: :valid
        })

      Map.put(result, :credential, credential)
    else
      result
    end
  end

  defp invalid_status_insert_sql do
    placeholders =
      if postgres?(),
        do: Enum.map_join(1..7, ", ", &"$#{&1}"),
        else: Enum.map_join(1..7, ", ", fn _ -> "?" end)

    """
    INSERT INTO github_credentials
      (local_user_id, github_identity_id, ciphertext, nonce, tag, key_id, status,
       inserted_at, updated_at)
    VALUES (#{placeholders}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp capture_error(callback) do
    try do
      {:ok, callback.()}
    rescue
      error -> {:error, error}
    end
  end

  defp unique_suffix do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp unique_github_user_id do
    7
    |> :crypto.strong_rand_bytes()
    |> :binary.decode_unsigned()
    |> Kernel.+(1)
  end
end
