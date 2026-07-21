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
end
