defmodule FornacastComponent do
  @moduledoc """
  Presentation components for Fornacast.

  Use this facade to import the repository renderers and shared layout. Callers
  prepare authorized presentation values and URLs before rendering.
  """

  @doc "Imports Fornacast repository components into a Phoenix component module."
  defmacro __using__(_opts) do
    quote do
      import FornacastComponent.GitRepository
      import FornacastComponent.RepositoryLayout
    end
  end
end
