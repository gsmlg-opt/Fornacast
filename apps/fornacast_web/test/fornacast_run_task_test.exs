defmodule Mix.Tasks.Fornacast.RunTest do
  use ExUnit.Case, async: true

  test "service_applications mirrors the web app umbrella service dependencies" do
    assert Mix.Tasks.Fornacast.Run.service_applications() == service_applications()
  end

  test "service_dependency_applications leaves the web endpoint to phx.server" do
    assert Mix.Tasks.Fornacast.Run.service_dependency_applications() ==
             List.delete(service_applications(), :fornacast_web)
  end

  defp service_applications do
    project = Mix.Project.config()

    umbrella_dependencies =
      project
      |> Keyword.fetch!(:deps)
      |> Enum.flat_map(fn
        {app, opts} when is_list(opts) ->
          if Keyword.get(opts, :in_umbrella), do: [app], else: []

        {app, _requirement, opts} when is_list(opts) ->
          if Keyword.get(opts, :in_umbrella), do: [app], else: []

        _dep ->
          []
      end)

    umbrella_dependencies ++ [Keyword.fetch!(project, :app)]
  end
end
