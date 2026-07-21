defmodule FornacastAPI.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint FornacastAPI.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import FornacastAPI.Fixtures

      alias Fornacast.Repo
    end
  end

  setup _tags do
    reset_database!()
    Fornacast.Setup.force_initialized!()
    reset_rate_limit!()

    on_exit(fn ->
      reset_turso_database!()
      Fornacast.Setup.reset_latch_only!()
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(reset_tables(), fn table ->
          Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{table}", [])
        end)
    end
  end

  defp reset_rate_limit! do
    case Process.whereis(FornacastAPI.RateLimit) do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, fn state ->
          true = :ets.delete_all_objects(state.table)
          %{state | current_window: nil}
        end)

        :ok

      nil ->
        :ok
    end
  end

  defp reset_turso_database! do
    if Application.get_env(:fornacast, :database_adapter) in ["libsql", "turso"] do
      Enum.each(reset_tables(), fn table ->
        Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{table}", [])
      end)
    end

    :ok
  end

  defp reset_tables do
    [
      "audit_events",
      "repository_collaborators",
      "repositories",
      "organization_members",
      "api_keys",
      "ssh_keys",
      "users"
    ]
  end
end
