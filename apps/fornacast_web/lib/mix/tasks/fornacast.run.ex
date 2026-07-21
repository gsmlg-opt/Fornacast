defmodule Mix.Tasks.Fornacast.Run do
  use Mix.Task

  @shortdoc "Creates the database if needed and starts Fornacast"
  @service_applications [
    :fornacast,
    :forge_accounts,
    :forge_repos,
    :git_core,
    :git_transport,
    :fornacast_api,
    :fornacast_web
  ]
  @web_application :fornacast_web

  @moduledoc """
  Starts Fornacast for local development.

      mix fornacast.run

  Ensures the database exists, starts the service applications, runs the server
  (migrations and directory setup happen automatically at boot), and prints
  where to finish setup when the instance has not been initialized yet.
  """

  @doc false
  def service_applications, do: @service_applications

  @doc false
  def service_dependency_applications do
    List.delete(@service_applications, @web_application)
  end

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("app.config")
    start_service_dependencies!()

    unless Fornacast.Setup.initialized?() do
      Mix.shell().info(
        "Fornacast is not initialized — open #{Fornacast.Config.base_url()}/setup to create the first admin."
      )
    end

    Mix.Task.run("phx.server", args)
  end

  defp start_service_dependencies! do
    Enum.each(service_dependency_applications(), &start_application!/1)
  end

  defp start_application!(application) do
    case Application.ensure_all_started(application) do
      {:ok, _started} ->
        :ok

      {:error, reason} ->
        Mix.raise("could not start #{application}: #{inspect(reason)}")
    end
  end
end
