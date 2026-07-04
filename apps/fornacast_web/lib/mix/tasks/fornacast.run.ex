defmodule Mix.Tasks.Fornacast.Run do
  use Mix.Task

  @shortdoc "Creates the database if needed and starts Fornacast"

  @moduledoc """
  Starts Fornacast for local development.

      mix fornacast.run

  Ensures the database exists, runs the server (migrations and directory setup
  happen automatically at boot), and prints where to finish setup when the
  instance has not been initialized yet.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("app.config")
    Application.ensure_all_started(:fornacast)

    unless Fornacast.Setup.initialized?() do
      Mix.shell().info(
        "Fornacast is not initialized — open #{Fornacast.Config.base_url()}/setup to create the first admin."
      )
    end

    Mix.Task.run("phx.server", args)
  end
end
