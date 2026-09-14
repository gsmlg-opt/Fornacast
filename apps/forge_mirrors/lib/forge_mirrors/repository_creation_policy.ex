defmodule ForgeMirrors.RepositoryCreationPolicy do
  @moduledoc false

  @enabled_states [true, :enabled, :active, "enabled", "active"]
  @disabled_states [false, :disabled, "disabled"]

  @spec authorize(map(), map()) ::
          :ok
          | {:error,
             :policy_disabled | :capability_disabled | :invalid_policy | :invalid_capabilities}
  def authorize(policy, capabilities) when is_map(policy) and is_map(capabilities) do
    with {:ok, enabled?} <- boolean_value(policy, "auto_create_remote_repositories", false) do
      if enabled? do
        case value(capabilities, "git", "disabled") do
          {:ok, state} when state in @enabled_states -> :ok
          {:ok, state} when state in @disabled_states -> {:error, :capability_disabled}
          _invalid -> {:error, :invalid_capabilities}
        end
      else
        {:error, :policy_disabled}
      end
    else
      :error -> {:error, :invalid_policy}
    end
  end

  def authorize(policy, _capabilities) when not is_map(policy), do: {:error, :invalid_policy}
  def authorize(_policy, _capabilities), do: {:error, :invalid_capabilities}

  defp boolean_value(values, key, default) do
    case value(values, key, default) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _invalid -> :error
    end
  end

  defp value(values, key, default) do
    atom_key = atom_key(key)

    case {Map.fetch(values, key), Map.fetch(values, atom_key)} do
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> {:ok, default}
      {{:ok, value}, {:ok, value}} -> {:ok, value}
      _duplicate -> :error
    end
  end

  defp atom_key("auto_create_remote_repositories"), do: :auto_create_remote_repositories
  defp atom_key("git"), do: :git
end
