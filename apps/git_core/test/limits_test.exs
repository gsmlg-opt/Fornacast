defmodule GitCore.LimitsTest do
  use ExUnit.Case, async: false

  @hard %{
    scan_concurrency: 4,
    scan_deadline_ms: 30_000,
    commit_visits: 50_000,
    tree_entry_visits: 100_000,
    changed_path_visits: 10_000,
    patch_bytes: 20_971_520,
    blob_concurrency: 8,
    blob_reserved_bytes: 134_217_728,
    blob_bytes: 104_857_600,
    repository_writer_concurrency: 2,
    body_memory_bytes: 536_870_912,
    contents_reservation_bytes: 251_658_240,
    contents_json_bytes: 146_800_640,
    ref_deadline_ms: 10_000,
    content_deadline_ms: 60_000,
    receive_pack_commands: 1_024,
    receive_pack_bytes: 104_857_600,
    body_total_timeout_ms: 120_000,
    body_idle_timeout_ms: 15_000,
    reconcile_interval_ms: 30_000,
    remote_concurrency: 2,
    remote_wall_time_ms: 1_800_000,
    remote_output_bytes: 1_048_576,
    remote_repository_bytes: 21_474_836_480,
    remote_refs: 200_000,
    remote_poll_interval_ms: 100,
    remote_credential_startup_ms: 10_000,
    remote_kill_escalation_ms: 5_000,
    remote_cleanup_wait_ms: 10_000
  }

  setup do
    original = Application.get_env(:git_core, :limits)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:git_core, :limits)
      else
        Application.put_env(:git_core, :limits, original)
      end
    end)
  end

  test "all limits default to their hard ceilings when absent" do
    Application.delete_env(:git_core, :limits)

    for {key, value} <- @hard do
      assert GitCore.Limits.hard(key) == value
      assert GitCore.Limits.get(key) == value
    end
  end

  test "all limits accept lower values and clamp higher values" do
    for {key, hard} <- @hard do
      Application.put_env(:git_core, :limits, [{key, hard - 1}])
      assert GitCore.Limits.get(key) == hard - 1

      Application.put_env(:git_core, :limits, [{key, hard + 1}])
      assert GitCore.Limits.get(key) == hard
    end
  end

  test "configured limits must be positive integers" do
    for {key, _hard} <- @hard, invalid <- ["1", 0, -1] do
      Application.put_env(:git_core, :limits, [{key, invalid}])

      assert_raise ArgumentError, ~r/#{key}.*positive integer/, fn ->
        GitCore.Limits.get(key)
      end
    end
  end

  test "unknown limit keys fail explicitly" do
    assert_raise KeyError, fn -> GitCore.Limits.hard(:unknown) end
    assert_raise KeyError, fn -> GitCore.Limits.get(:unknown) end
  end

  test "receive_pack_bytes is the bounded future API ingestion ceiling" do
    assert GitCore.Limits.hard(:receive_pack_bytes) == 100 * 1024 * 1024
    assert GitCore.Limits.get(:receive_pack_bytes) == 100 * 1024 * 1024
  end
end
