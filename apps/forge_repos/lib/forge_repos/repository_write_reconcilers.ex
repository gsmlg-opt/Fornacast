defmodule ForgeRepos.RepositoryWriteReconcilers do
  @moduledoc false

  @callback reconcile_repository_locked(
              ForgeRepos.Repository.t(),
              Path.t(),
              integer()
            ) :: :ok | {:error, :unavailable}

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

  defp valid_entry?({priority, name, module}) do
    is_integer(priority) and is_atom(name) and is_atom(module) and
      Code.ensure_loaded?(module) and
      function_exported?(module, :reconcile_repository_locked, 3)
  end

  defp valid_entry?(_entry), do: false

  defp unique?(entries, tuple_index) do
    values = Enum.map(entries, &elem(&1, tuple_index))
    length(values) == length(Enum.uniq(values))
  end
end
