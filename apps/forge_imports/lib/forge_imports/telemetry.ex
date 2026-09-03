defmodule ForgeImports.Telemetry do
  @moduledoc false

  @namespace [:fornacast, :github_import]

  @id_keys ~w(run_id item_id repository_id predecessor_run_id)a

  @allowed_keys ~w(
    run_id item_id repository_id predecessor_run_id
    phase outcome error classification cleanup_kind
    completion_state success replaced canceled retry
    bytes
  )a

  @allowed_phases ~w(
    discovering awaiting_resolution ready running awaiting_credential
    cancel_requested canceled completed completed_with_warnings failed
    queued awaiting_resolution staging_git git_staged staging_metadata
    ready_to_publish publishing published completed skipped failed canceled
    discovery cleanup
  )a

  @allowed_outcomes ~w(ok error busy ignored attempted none)a

  @allowed_errors ~w(
    invalid_request invalid_credential forbidden not_found
    primary_rate_limit secondary_rate_limit upstream_unavailable
    unexpected_status transport timeout host_unavailable unsafe_host
    response_too_large invalid_json invalid_response invalid_pagination
    pagination_limit request_gate_busy cancelled canceled not_found
    metadata_not_ready busy destination_changed publication_unavailable
    persistence_unavailable publication_inconsistent invalid_transition
    invalid_request_metadata lost_lease stale
  )a

  @allowed_completion_states ~w(completed completed_with_warnings canceled failed)a

  @allowed_cleanup_kinds ~w(remote_quarantine unpublished_shadow replacement_tombstone)a

  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata)
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(
      @namespace ++ event,
      bounded_measurements(measurements),
      bounded(metadata)
    )
  end

  @spec bounded(map()) :: map()
  def bounded(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      case bounded_entry(key, value) do
        {:ok, key, value} -> Map.put(acc, key, value)
        :drop -> acc
      end
    end)
  end

  defp bounded_measurements(measurements) do
    Enum.reduce(measurements, %{}, fn
      {key, value}, acc
      when key in [:duration, :system_time] and is_integer(value) and value >= 0 ->
        Map.put(acc, key, value)

      {key, value}, acc when key in [:count, :bytes] and is_integer(value) and value >= 0 ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  defp bounded_entry(key, value) when is_atom(key) do
    cond do
      key in @id_keys and is_integer(value) and value > 0 ->
        {:ok, key, value}

      key in @allowed_keys ->
        bounded_allowed(key, value)

      true ->
        :drop
    end
  end

  defp bounded_entry(_key, _value), do: :drop

  defp bounded_allowed(:phase, phase) when phase in @allowed_phases, do: {:ok, :phase, phase}

  defp bounded_allowed(:outcome, outcome) when outcome in @allowed_outcomes,
    do: {:ok, :outcome, outcome}

  defp bounded_allowed(:error, error) when error in @allowed_errors, do: {:ok, :error, error}

  defp bounded_allowed(:classification, classification)
       when classification in [:primary, :secondary],
       do: {:ok, :classification, classification}

  defp bounded_allowed(:cleanup_kind, kind) when kind in @allowed_cleanup_kinds,
    do: {:ok, :cleanup_kind, kind}

  defp bounded_allowed(:completion_state, state) when state in @allowed_completion_states,
    do: {:ok, :completion_state, state}

  defp bounded_allowed(key, value)
       when key in [:success, :replaced, :retry, :canceled] and is_boolean(value),
       do: {:ok, key, value}

  defp bounded_allowed(:bytes, bytes) when is_integer(bytes) and bytes >= 0,
    do: {:ok, :bytes, bytes}

  defp bounded_allowed(_key, _value), do: :drop
end
