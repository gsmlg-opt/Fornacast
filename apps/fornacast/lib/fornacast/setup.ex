defmodule Fornacast.Setup do
  @moduledoc """
  Durable application initialization state.

  Initialization is recorded as an `initialized_at` timestamp in
  `Fornacast.ConfigStore`. A `:persistent_term` latch caches the positive
  result so per-request checks are free. Admin existence remains the
  correctness anchor: boot-time self-heal (see `Fornacast.Application`) writes
  the flag for pre-existing installs that already have an admin.
  """

  alias Fornacast.{Audit, ConfigStore}

  @flag_key "initialized_at"
  @latch {__MODULE__, :initialized}

  @spec initialized?() :: boolean()
  def initialized? do
    case :persistent_term.get(@latch, :unset) do
      true ->
        true

      _ ->
        case ConfigStore.get(@flag_key) do
          {:ok, value} when is_binary(value) ->
            :persistent_term.put(@latch, true)
            true

          _ ->
            false
        end
    end
  end

  @spec mark_initialized!(struct() | map()) :: :ok
  def mark_initialized!(actor) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    :ok = ConfigStore.put(@flag_key, timestamp)

    _ =
      Audit.record(actor, "app.initialized", "app", "fornacast", %{"initialized_at" => timestamp})

    :persistent_term.put(@latch, true)
    :ok
  end

  @doc "Test/boot helper: clears the latch and deletes the durable flag."
  @spec reset!() :: :ok
  def reset! do
    reset_latch_only!()
    _ = ConfigStore.delete(@flag_key)
    :ok
  end

  @doc "Test helper: clears only the persistent_term latch."
  @spec reset_latch_only!() :: :ok
  def reset_latch_only! do
    _ = :persistent_term.erase(@latch)
    :ok
  end

  @doc "Test helper: marks initialized in-memory only (no DB writes)."
  @spec force_initialized!() :: :ok
  def force_initialized! do
    :persistent_term.put(@latch, true)
    :ok
  end
end
