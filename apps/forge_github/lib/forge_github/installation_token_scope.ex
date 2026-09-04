defmodule ForgeGitHub.InstallationTokenScope do
  @moduledoc false

  @max_signed_bigint 9_223_372_036_854_775_807

  @spec canonical(term()) :: {:ok, map(), term()} | {:error, :invalid_scope}
  def canonical(scope) when is_map(scope) do
    allowed = [:permissions, :repository_ids]

    if Enum.all?(Map.keys(scope), &(&1 in allowed)) do
      with {:ok, permissions, permission_key} <- permissions(scope),
           {:ok, repository_ids, repository_key} <- repository_ids(scope) do
        canonical =
          %{}
          |> maybe_put(:permissions, permissions)
          |> maybe_put(:repository_ids, repository_ids)

        {:ok, canonical, {permission_key, repository_key}}
      else
        _invalid -> {:error, :invalid_scope}
      end
    else
      {:error, :invalid_scope}
    end
  end

  def canonical(_scope), do: {:error, :invalid_scope}

  defp permissions(scope) do
    case Map.fetch(scope, :permissions) do
      :error ->
        {:ok, :absent, :installation_default}

      {:ok, permissions} when is_map(permissions) and map_size(permissions) <= 128 ->
        if Enum.all?(permissions, fn {key, value} ->
             is_binary(key) and byte_size(key) in 1..128 and String.valid?(key) and
               is_binary(value) and value in ["read", "write"]
           end) do
          canonical = Map.new(Enum.sort(permissions))
          {:ok, canonical, {:permissions, permissions |> Enum.sort() |> List.to_tuple()}}
        else
          :error
        end

      _invalid ->
        :error
    end
  end

  defp repository_ids(scope) do
    case Map.fetch(scope, :repository_ids) do
      :error ->
        {:ok, :absent, :installation_default}

      {:ok, repository_ids} when is_list(repository_ids) and length(repository_ids) <= 500 ->
        if Enum.all?(repository_ids, fn id -> is_integer(id) and id in 1..@max_signed_bigint end) do
          canonical = repository_ids |> Enum.uniq() |> Enum.sort()
          {:ok, canonical, {:repository_ids, List.to_tuple(canonical)}}
        else
          :error
        end

      _invalid ->
        :error
    end
  end

  defp maybe_put(map, _key, :absent), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
