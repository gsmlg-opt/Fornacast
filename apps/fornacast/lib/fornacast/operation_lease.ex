defmodule Fornacast.OperationLease do
  @moduledoc false

  import Ecto.Query

  alias Fornacast.Repo

  @after_write_hook_key {__MODULE__, :after_write_hook}

  @doc false
  def with_test_after_write_hook(hook, fun) when is_function(hook, 4) and is_function(fun, 0) do
    previous = Process.get(@after_write_hook_key)
    Process.put(@after_write_hook_key, hook)

    try do
      fun.()
    after
      if previous == nil,
        do: Process.delete(@after_write_hook_key),
        else: Process.put(@after_write_hook_key, previous)
    end
  end

  @spec claim(module(), pos_integer(), String.t(), DateTime.t(), pos_integer()) ::
          {:ok, struct()} | :busy | {:error, :not_found | :invalid_argument}
  def claim(module, id, owner, %DateTime{} = now, lease_seconds)
      when is_atom(module) and is_integer(id) and id > 0 and is_binary(owner) and owner != "" and
             is_integer(lease_seconds) and lease_seconds > 0 do
    with :ok <- validate_utc(now),
         %{} = row <- Repo.get(module, id) do
      now = DateTime.truncate(now, :second)
      expires_at = DateTime.add(now, lease_seconds, :second)
      expected_version = row.lock_version + 1

      query =
        from item in module,
          where:
            item.id == ^id and item.lock_version == ^row.lock_version and
              (is_nil(item.lease_expires_at) or item.lease_expires_at <= ^now)

      case Repo.update_all(query,
             set: [lease_owner: owner, lease_expires_at: expires_at],
             inc: [lock_version: 1]
           ) do
        {1, _} ->
          run_after_write_hook(:claim, module, id, expected_version)

          case owned_row(module, id, owner, expected_version) do
            nil -> :busy
            claimed -> {:ok, claimed}
          end

        {0, _} ->
          :busy
      end
    else
      nil -> {:error, :not_found}
      {:error, :invalid_argument} = error -> error
    end
  end

  def claim(_module, _id, _owner, _now, _lease_seconds), do: {:error, :invalid_argument}

  @spec release(module(), struct()) :: :ok | {:error, :lost_lease}
  def release(module, %{id: id, lease_owner: owner, lock_version: version})
      when is_atom(module) and is_integer(id) and is_binary(owner) and is_integer(version) do
    case guarded_update(module, id, owner, version, []) do
      {1, _} -> :ok
      {0, _} -> {:error, :lost_lease}
    end
  end

  def release(_module, _operation), do: {:error, :lost_lease}

  @spec renew_owned(module(), struct(), keyword()) ::
          {:ok, struct()} | {:error, :lost_lease | :invalid_argument}
  def renew_owned(module, operation, options)
      when is_atom(module) and is_list(options) do
    with {:ok, now, expires_at} <- lease_window(options),
         {:ok, renewed} <-
           renew_owned_row(module, operation, [], now, expires_at, :renew_owned) do
      {:ok, renewed}
    end
  end

  def renew_owned(_module, _operation, _options), do: {:error, :invalid_argument}

  @spec update_owned(module(), struct(), keyword(), keyword()) ::
          {:ok, struct()} | {:error, :lost_lease | :invalid_update | :invalid_argument}
  def update_owned(module, operation, updates, options)
      when is_atom(module) and is_list(updates) and is_list(options) do
    with {:ok, now, expires_at} <- lease_window(options),
         {:ok, validated} <- owned_updates(module, operation, updates),
         {:ok, updated} <-
           renew_owned_row(
             module,
             operation,
             validated,
             now,
             expires_at,
             :update_owned_retained
           ) do
      {:ok, updated}
    end
  end

  def update_owned(_module, _operation, _updates, _options),
    do: {:error, :invalid_argument}

  @spec update_owned(module(), struct(), keyword()) ::
          {:ok, struct()} | {:error, :lost_lease | :invalid_update}
  def update_owned(
        module,
        %{id: id, lease_owner: owner, lock_version: version} = operation,
        updates
      )
      when is_atom(module) and is_integer(id) and is_binary(owner) and is_integer(version) and
             is_list(updates) do
    case validated_updates(module, operation, updates) do
      {:ok, validated} ->
        case guarded_update(module, id, owner, version, validated) do
          {1, _} ->
            expected_version = version + 1
            run_after_write_hook(:update_owned, module, id, expected_version)

            case released_row(module, id, expected_version) do
              nil -> {:error, :lost_lease}
              updated -> {:ok, updated}
            end

          {0, _} ->
            {:error, :lost_lease}
        end

      :error ->
        {:error, :invalid_update}
    end
  end

  def update_owned(_module, _operation, _updates), do: {:error, :invalid_update}

  defp owned_updates(module, operation, updates) do
    case validated_updates(module, operation, updates) do
      {:ok, validated} -> {:ok, validated}
      :error -> {:error, :invalid_update}
    end
  end

  defp validated_updates(module, operation, updates) do
    with true <- Keyword.keyword?(updates),
         true <- function_exported?(module, :lease_update_changeset, 2),
         %Ecto.Changeset{valid?: true, changes: changes} when map_size(changes) > 0 <-
           module.lease_update_changeset(operation, updates) do
      {:ok, Map.to_list(changes)}
    else
      _ -> :error
    end
  end

  defp lease_window(options) do
    with true <- Keyword.keyword?(options),
         {:ok, now} <- Keyword.fetch(options, :now),
         {:ok, lease_seconds} <- Keyword.fetch(options, :lease_seconds),
         true <- Keyword.keys(options) |> Enum.sort() == [:lease_seconds, :now],
         %DateTime{} <- now,
         :ok <- validate_utc(now),
         true <- is_integer(lease_seconds) and lease_seconds > 0 do
      now = DateTime.truncate(now, :second)
      {:ok, now, DateTime.add(now, lease_seconds, :second)}
    else
      _ -> {:error, :invalid_argument}
    end
  end

  defp renew_owned_row(
         module,
         %{id: id, lease_owner: owner, lock_version: version},
         updates,
         now,
         expires_at,
         hook_kind
       )
       when is_integer(id) and is_binary(owner) and owner != "" and is_integer(version) do
    query =
      from item in module,
        where:
          item.id == ^id and item.lease_owner == ^owner and item.lock_version == ^version and
            item.lease_expires_at > ^now

    case Repo.update_all(query,
           set: updates ++ [lease_expires_at: expires_at],
           inc: [lock_version: 1]
         ) do
      {1, _} ->
        expected_version = version + 1
        run_after_write_hook(hook_kind, module, id, expected_version)

        case owned_row(module, id, owner, expected_version) do
          nil -> {:error, :lost_lease}
          row -> {:ok, row}
        end

      {0, _} ->
        {:error, :lost_lease}
    end
  end

  defp renew_owned_row(_module, _operation, _updates, _now, _expires_at, _hook_kind),
    do: {:error, :lost_lease}

  defp guarded_update(module, id, owner, version, updates) do
    query =
      from item in module,
        where: item.id == ^id and item.lease_owner == ^owner and item.lock_version == ^version

    Repo.update_all(query,
      set: updates ++ [lease_owner: nil, lease_expires_at: nil],
      inc: [lock_version: 1]
    )
  end

  defp owned_row(module, id, owner, version) do
    Repo.one(
      from item in module,
        where: item.id == ^id and item.lease_owner == ^owner and item.lock_version == ^version
    )
  end

  defp released_row(module, id, version) do
    Repo.one(
      from item in module,
        where:
          item.id == ^id and item.lock_version == ^version and is_nil(item.lease_owner) and
            is_nil(item.lease_expires_at)
    )
  end

  defp run_after_write_hook(kind, module, id, version) do
    case Process.delete(@after_write_hook_key) do
      hook when is_function(hook, 4) -> hook.(kind, module, id, version)
      nil -> :ok
    end
  end

  defp validate_utc(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: :ok
  defp validate_utc(_now), do: {:error, :invalid_argument}
end
