defmodule ForgeRepos.RepositoryWriteReconcilers do
  @moduledoc false

  @callback reconcile_repository_locked(
              ForgeRepos.Repository.t(),
              Path.t(),
              integer()
            ) :: :ok | {:error, :unavailable}

  @callback cleanup_safety_locked(ForgeRepos.Repository.t(), DateTime.t()) ::
              :safe
              | {:blocked, :live_lease}
              | {:blocked, :claimable_operation}
              | {:blocked, :inconsistent_lease}
              | {:error, :unavailable}

  @spec entries() :: [{integer(), atom(), module()}]
  def entries do
    configured = Application.get_env(:forge_repos, :repository_write_reconcilers, [])

    with true <- is_list(configured),
         true <- Enum.all?(configured, &valid_entry?/1),
         true <- unique?(configured, 1),
         true <- unique?(configured, 2) do
      Enum.sort_by(configured, fn {priority, name, _module} -> {priority, name} end)
    else
      _ -> raise ArgumentError, "invalid :forge_repos repository_write_reconcilers configuration"
    end
  end

  @spec reconcile_locked(ForgeRepos.Repository.t(), Path.t(), integer()) ::
          :ok | {:error, :unavailable}
  def reconcile_locked(repository, repository_path, absolute_deadline)
      when is_binary(repository_path) and is_integer(absolute_deadline) do
    Enum.reduce_while(entries(), :ok, fn {_priority, _name, module}, :ok ->
      result =
        try do
          module.reconcile_repository_locked(repository, repository_path, absolute_deadline)
        rescue
          _error -> {:error, :unavailable}
        catch
          _kind, _reason -> {:error, :unavailable}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, :unavailable} = error -> {:halt, error}
        _other -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  @spec cleanup_safety_locked(ForgeRepos.Repository.t(), DateTime.t()) ::
          :safe
          | {:blocked, :live_lease}
          | {:blocked, :claimable_operation}
          | {:blocked, :inconsistent_lease}
          | {:error, :unavailable}
  def cleanup_safety_locked(repository, %DateTime{} = now) do
    try do
      entries()
      |> Enum.map(fn {_priority, _name, module} ->
        module.cleanup_safety_locked(repository, now)
      end)
      |> safety_result()
    rescue
      _error -> {:error, :unavailable}
    catch
      _kind, _reason -> {:error, :unavailable}
    end
  end

  def cleanup_safety_locked(_repository, _now), do: {:error, :unavailable}

  defp valid_entry?({priority, name, module}) do
    is_integer(priority) and is_atom(name) and is_atom(module) and
      Code.ensure_loaded?(module) and
      function_exported?(module, :reconcile_repository_locked, 3) and
      function_exported?(module, :cleanup_safety_locked, 2)
  end

  defp valid_entry?(_entry), do: false

  defp unique?(entries, tuple_index) do
    values = Enum.map(entries, &elem(&1, tuple_index))
    length(values) == length(Enum.uniq(values))
  end

  defp safety_result(results) do
    cond do
      results == [] ->
        {:error, :unavailable}

      Enum.any?(results, &(&1 == {:error, :unavailable})) ->
        {:error, :unavailable}

      Enum.any?(results, &(&1 == {:blocked, :inconsistent_lease})) ->
        {:blocked, :inconsistent_lease}

      Enum.any?(results, &(&1 == {:blocked, :live_lease})) ->
        {:blocked, :live_lease}

      Enum.any?(results, &(&1 == {:blocked, :claimable_operation})) ->
        {:blocked, :claimable_operation}

      Enum.all?(results, &(&1 == :safe)) ->
        :safe

      true ->
        {:error, :unavailable}
    end
  end
end
