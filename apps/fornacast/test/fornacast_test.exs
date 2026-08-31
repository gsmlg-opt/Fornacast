defmodule FornacastTest do
  use ExUnit.Case, async: false

  alias Ecto.Multi
  alias Fornacast.{Audit, AuditEvent, Repo}

  setup do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Repo.delete_all(AuditEvent)
    end

    :ok
  end

  @tag :tmp_dir
  test "storage paths resolve under the configured repository root", %{tmp_dir: tmp_dir} do
    original = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    try do
      assert :ok =
               Fornacast.Storage.validate_relative_storage_path("@hashed/aa/bb/repo.git")

      for invalid <- [
            "/srv/fornacast/repositories/repo.git",
            "@hashed/aa/../repo.git",
            "C:/private/repo.git",
            "C:private/repo.git"
          ] do
        assert {:error, _reason} =
                 Fornacast.Storage.validate_relative_storage_path(invalid)
      end

      assert Fornacast.Storage.repository_path!("@hashed/aa/bb/repo.git") ==
               Path.join([tmp_dir, "@hashed", "aa", "bb", "repo.git"])

      assert_raise ArgumentError, fn ->
        Fornacast.Storage.repository_path!("../repo.git")
      end
    after
      Application.put_env(:fornacast, :repo_storage_root, original)
    end
  end

  test "record_multi resolves prior results and lets request metadata win after key normalization" do
    first_changeset =
      AuditEvent.changeset(%AuditEvent{}, %{
        action: "seed.created",
        target_type: "seed",
        metadata: %{"kind" => "seed"}
      })

    multi =
      Multi.new()
      |> Multi.insert(:seed, first_changeset)
      |> Audit.record_multi(
        :audit,
        nil,
        "seed.followed",
        "seed",
        fn %{seed: seed} -> seed.id end,
        fn %{seed: seed} ->
          %{request_id: "event-#{seed.id}", source: "callback", nested: %{kept: true}}
        end,
        request_metadata: %{
          "request_id" => "request-1",
          "source" => "request",
          ip_address: "127.0.0.1",
          user_agent: "ExUnit"
        }
      )

    assert {:ok, %{seed: seed, audit: audit}} = Repo.transaction(multi)
    assert audit.target_id == Integer.to_string(seed.id)
    assert audit.actor_user_id == nil
    assert audit.ip_address == "127.0.0.1"
    assert audit.user_agent == "ExUnit"
    assert audit.metadata["request_id"] == "request-1"
    assert audit.metadata["source"] == "request"
    assert audit.metadata["ip_address"] == "127.0.0.1"
    assert audit.metadata["user_agent"] == "ExUnit"
    assert audit.metadata["nested"] in [%{kept: true}, %{"kept" => true}]
    assert Enum.all?(Map.keys(audit.metadata), &is_binary/1)
  end

  test "record_multi/7 uses empty request metadata and stays inside the caller transaction" do
    first_changeset =
      AuditEvent.changeset(%AuditEvent{}, %{
        action: "seed.created",
        target_type: "seed",
        metadata: %{}
      })

    successful_multi =
      Multi.new()
      |> Multi.insert(:seed, first_changeset)
      |> Audit.record_multi(
        :audit,
        nil,
        "seed.followed",
        "seed",
        fn %{seed: seed} -> seed.id end,
        %{"source" => "default-arity"}
      )

    assert {:ok, %{audit: audit}} = Repo.transaction(successful_multi)
    assert audit.metadata == %{"source" => "default-arity"}
    assert audit.ip_address == nil
    assert audit.user_agent == nil

    count_before = Repo.aggregate(AuditEvent, :count, :id)

    invalid_multi =
      Multi.new()
      |> Multi.insert(
        :first_audit,
        AuditEvent.changeset(%AuditEvent{}, %{
          action: "rollback.first",
          target_type: "seed",
          metadata: %{}
        })
      )
      |> Audit.record_multi(
        :second_audit,
        nil,
        "rollback.second",
        "seed",
        fn %{first_audit: event} -> event.id end,
        %{},
        request_metadata: %{ip_address: {:invalid, :ip}}
      )

    assert {:error, :second_audit, %Ecto.Changeset{valid?: false}, %{}} =
             Repo.transaction(invalid_multi)

    assert Repo.aggregate(AuditEvent, :count, :id) == count_before
  end

  test "record and record_multi normalize literal and callback nil metadata" do
    assert {:ok, direct} =
             Audit.record(nil, "nil.direct", "test", "1", nil,
               request_metadata: %{"request_id" => "request-direct"},
               request_id: "explicit-direct"
             )

    assert direct.metadata == %{"request_id" => "request-direct"}
    assert direct.request_id == "explicit-direct"

    multi =
      Multi.new()
      |> Audit.record_multi(
        :audit,
        nil,
        "nil.callback",
        "test",
        fn _changes -> "2" end,
        fn _changes -> nil end,
        request_metadata: %{"request_id" => "request-callback"},
        request_id: "explicit-callback"
      )

    assert {:ok, %{audit: callback}} = Repo.transaction(multi)
    assert callback.metadata == %{"request_id" => "request-callback"}
    assert callback.request_id == "explicit-callback"
  end

  test "audit metadata recursively removes credential secrets case-insensitively" do
    secret_keys = [
      :token,
      "CONTENT",
      :Message,
      "Storage_Path",
      :pat,
      "GitHub_PAT",
      :access_token,
      "AUTHORIZATION",
      :credential_envelope,
      "Credential_Envelopes",
      :ciphertext,
      "NONCE",
      :tag
    ]

    nested_secrets = Map.new(secret_keys, &{&1, "github_pat_never_print_this_value"})

    assert {:ok, audit} =
             Audit.record(nil, "credential.redacted", "github_credential", "7", %{
               safe: "kept",
               nested: nested_secrets,
               list: [%{"safe" => "also-kept", "Authorization" => "Bearer secret"}]
             })

    assert audit.metadata["safe"] == "kept"
    assert audit.metadata["nested"] == %{}
    assert audit.metadata["list"] == [%{"safe" => "also-kept"}]
    refute inspect(audit.metadata) =~ "github_pat_never_print_this_value"
    refute inspect(audit.metadata) =~ "Bearer secret"
  end

  test "audit metadata removes sensitive header tuples and nested keyword entries" do
    assert {:ok, audit} =
             Audit.record(nil, "credential.tuple_redacted", "github_credential", "8", %{
               headers: [
                 {"Authorization", "Bearer tuple-secret"},
                 {"X-Request-ID", "request-1"}
               ],
               nested: [[github_pat: "keyword-secret", safe: "kept"]]
             })

    refute inspect(audit.metadata) =~ "tuple-secret"
    refute inspect(audit.metadata) =~ "keyword-secret"
    assert audit.metadata["headers"] == [%{"X-Request-ID" => "request-1"}]
    assert audit.metadata["nested"] == [[%{"safe" => "kept"}]]
  end

  test "Phoenix parameter logging filters every value including mixed-case secrets and paths" do
    params = %{
      "GitHub_PAT" => "github-pat-secret",
      "Authorization" => "authorization-secret",
      "path" => "/repositories/example",
      "ordinary" => "not-safe-for-request-logs"
    }

    filtered = Phoenix.Logger.filter_values(params)

    for key <- Map.keys(params) do
      assert filtered[key] == "[FILTERED]"
    end
  end
end
