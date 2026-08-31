defmodule GitCore.Limits do
  @moduledoc """
  Hard ceilings for bounded Git work shared by GitCore and future API ingestion.

  `:receive_pack_bytes` is the future API request ceiling. Git-over-SSH and
  Git-over-HTTP keep their independent `GitTransport.ReceivePack` policy.
  """

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

  @spec hard(atom()) :: pos_integer()
  def hard(key), do: Map.fetch!(@hard, key)

  @spec get(atom()) :: pos_integer()
  def get(key) do
    hard = hard(key)
    configured = Keyword.get(Application.get_env(:git_core, :limits, []), key, hard)

    if is_integer(configured) and configured > 0 do
      min(configured, hard)
    else
      raise ArgumentError,
            "git_core limit #{inspect(key)} must be a positive integer, got: #{inspect(configured)}"
    end
  end

  @spec minimum_repository_cleanup_grace_seconds() :: pos_integer()
  def minimum_repository_cleanup_grace_seconds do
    div(
      get(:remote_wall_time_ms) +
        get(:remote_kill_escalation_ms) +
        get(:remote_cleanup_wait_ms) + 999,
      1_000
    ) + 1
  end
end
