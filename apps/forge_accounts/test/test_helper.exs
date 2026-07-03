ExUnit.start()

if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
  Ecto.Adapters.SQL.Sandbox.mode(Fornacast.Repo, :manual)
end
