defmodule Fornacast.Audit do
  @moduledoc """
  Minimal audit-event writer for first-release repository operations.
  """

  @sensitive_metadata_keys ~w(token content message storage_path)

  alias Fornacast.{AuditEvent, Repo}

  def record(actor, action, target_type, target_id, metadata \\ %{}, opts \\ []) do
    # WORKAROUND(upstream): gsmlg-dev/concord#70
    if turso?() or Repo.in_transaction?() do
      request_metadata = Keyword.get(opts, :request_metadata, %{}) || %{}

      actor
      |> audit_attrs(action, target_type, target_id, metadata, request_metadata, opts)
      |> then(&AuditEvent.changeset(%AuditEvent{}, &1))
      |> Repo.insert(insert_options(opts))
    else
      case Ecto.Multi.new()
           |> record_multi(:audit, actor, action, target_type, target_id, metadata, opts)
           |> Repo.transaction() do
        {:ok, %{audit: audit}} -> {:ok, audit}
        {:error, :audit, reason, _changes} -> {:error, reason}
      end
    end
  end

  @spec record_multi(
          Ecto.Multi.t(),
          Ecto.Multi.name(),
          term(),
          String.t(),
          String.t(),
          term() | (map() -> term()),
          map() | (map() -> map()),
          keyword()
        ) :: Ecto.Multi.t()
  def record_multi(multi, key, actor, action, target_type, target_id, metadata, opts \\ []) do
    Ecto.Multi.insert(
      multi,
      key,
      fn changes ->
        target_id = resolve_multi_value(target_id, changes)
        metadata = resolve_multi_value(metadata, changes)
        request_metadata = Keyword.get(opts, :request_metadata, %{}) || %{}

        attrs =
          audit_attrs(actor, action, target_type, target_id, metadata, request_metadata, opts)

        AuditEvent.changeset(%AuditEvent{}, attrs)
      end,
      insert_options(opts)
    )
  end

  defp audit_attrs(actor, action, target_type, target_id, metadata, request_metadata, opts) do
    %{
      actor_user_id: actor_id(actor),
      action: action,
      target_type: target_type,
      target_id: to_string(target_id),
      metadata: metadata |> merge_metadata(request_metadata) |> reject_sensitive_metadata(),
      request_id: option_value(opts, :request_id, request_metadata),
      operation_id: option_value(opts, :operation_id, request_metadata),
      ip_address: option_value(opts, :ip_address, request_metadata),
      user_agent: option_value(opts, :user_agent, request_metadata)
    }
  end

  defp resolve_multi_value(fun, changes) when is_function(fun, 1), do: fun.(changes)
  defp resolve_multi_value(value, _changes), do: value

  defp merge_metadata(metadata, request_metadata) do
    (metadata || %{})
    |> stringify_keys()
    |> Map.merge(stringify_keys(request_metadata || %{}))
  end

  defp stringify_keys(map) do
    non_string_keys =
      Enum.reduce(map, %{}, fn
        {key, _value}, acc when is_binary(key) -> acc
        {key, value}, acc -> Map.put(acc, to_string(key), value)
      end)

    Enum.reduce(map, non_string_keys, fn
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      {_key, _value}, acc -> acc
    end)
  end

  defp request_metadata_value(metadata, key) do
    case Map.fetch(metadata, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(metadata, key)
    end
  end

  defp option_value(opts, key, request_metadata) do
    if Keyword.has_key?(opts, key) do
      Keyword.get(opts, key)
    else
      request_metadata_value(request_metadata || %{}, key)
    end
  end

  defp insert_options(opts) do
    operation_id = option_value(opts, :operation_id, Keyword.get(opts, :request_metadata, %{}))

    if operation_id == nil do
      []
    else
      [
        on_conflict: [set: [operation_id: operation_id]],
        conflict_target: [:operation_id, :action],
        returning: true
      ]
    end
  end

  defp reject_sensitive_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, safe ->
      if to_string(key) in @sensitive_metadata_keys do
        safe
      else
        Map.put(safe, key, reject_sensitive_metadata(value))
      end
    end)
  end

  defp reject_sensitive_metadata(metadata) when is_list(metadata),
    do: Enum.map(metadata, &reject_sensitive_metadata/1)

  defp reject_sensitive_metadata(metadata), do: metadata

  defp turso? do
    Application.get_env(:fornacast, :database_adapter) in ["libsql", "turso"]
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil
end
