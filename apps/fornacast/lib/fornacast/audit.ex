defmodule Fornacast.Audit do
  @moduledoc """
  Minimal audit-event writer for first-release repository operations.
  """

  alias Fornacast.{AuditEvent, Repo}

  def record(actor, action, target_type, target_id, metadata \\ %{}, opts \\ []) do
    attrs = %{
      actor_user_id: actor_id(actor),
      action: action,
      target_type: target_type,
      target_id: to_string(target_id),
      metadata: metadata || %{},
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    }

    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
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
    Ecto.Multi.insert(multi, key, fn changes ->
      target_id = resolve_multi_value(target_id, changes)
      metadata = resolve_multi_value(metadata, changes)
      request_metadata = Keyword.get(opts, :request_metadata, %{}) || %{}

      attrs = %{
        actor_user_id: actor_id(actor),
        action: action,
        target_type: target_type,
        target_id: to_string(target_id),
        metadata: merge_metadata(metadata || %{}, request_metadata),
        ip_address: request_metadata_value(request_metadata, :ip_address),
        user_agent: request_metadata_value(request_metadata, :user_agent)
      }

      AuditEvent.changeset(%AuditEvent{}, attrs)
    end)
  end

  defp resolve_multi_value(fun, changes) when is_function(fun, 1), do: fun.(changes)
  defp resolve_multi_value(value, _changes), do: value

  defp merge_metadata(metadata, request_metadata) do
    metadata
    |> stringify_keys()
    |> Map.merge(stringify_keys(request_metadata))
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

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil
end
