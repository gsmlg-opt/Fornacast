defmodule Fornacast.OperationLease do
  @moduledoc false

  import Ecto.Query

  alias Fornacast.Repo

  @protected_fields [
    :id,
    :lease_owner,
    :lease_expires_at,
    :lock_version,
    :inserted_at,
    :updated_at
  ]

  @spec claim(module(), pos_integer(), String.t(), DateTime.t(), pos_integer()) ::
          {:ok, struct()} | :busy | {:error, :not_found | :invalid_argument}
  def claim(module, id, owner, %DateTime{} = now, lease_seconds)
      when is_atom(module) and is_integer(id) and id > 0 and is_binary(owner) and owner != "" and
             is_integer(lease_seconds) and lease_seconds > 0 do
    with :ok <- validate_utc(now),
         %{} = row <- Repo.get(module, id) do
      expires_at = now |> DateTime.add(lease_seconds, :second) |> DateTime.truncate(:second)

      query =
        from item in module,
          where:
            item.id == ^id and item.lock_version == ^row.lock_version and
              (is_nil(item.lease_expires_at) or item.lease_expires_at <= ^now)

      case Repo.update_all(query,
             set: [lease_owner: owner, lease_expires_at: expires_at],
             inc: [lock_version: 1]
           ) do
        {1, _} -> {:ok, Repo.get!(module, id)}
        {0, _} -> :busy
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

  @spec update_owned(module(), struct(), keyword()) ::
          {:ok, struct()} | {:error, :lost_lease | :invalid_fields}
  def update_owned(module, %{id: id, lease_owner: owner, lock_version: version}, updates)
      when is_atom(module) and is_integer(id) and is_binary(owner) and is_integer(version) and
             is_list(updates) do
    if allowed_updates?(module, updates) do
      case guarded_update(module, id, owner, version, updates) do
        {1, _} -> {:ok, Repo.get!(module, id)}
        {0, _} -> {:error, :lost_lease}
      end
    else
      {:error, :invalid_fields}
    end
  end

  def update_owned(_module, _operation, _updates), do: {:error, :lost_lease}

  defp guarded_update(module, id, owner, version, updates) do
    query =
      from item in module,
        where: item.id == ^id and item.lease_owner == ^owner and item.lock_version == ^version

    Repo.update_all(query,
      set: updates ++ [lease_owner: nil, lease_expires_at: nil],
      inc: [lock_version: 1]
    )
  end

  defp allowed_updates?(module, updates) do
    allowed = module.__schema__(:fields) -- @protected_fields
    Keyword.keyword?(updates) and Enum.all?(Keyword.keys(updates), &(&1 in allowed))
  end

  defp validate_utc(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: :ok
  defp validate_utc(_now), do: {:error, :invalid_argument}
end
