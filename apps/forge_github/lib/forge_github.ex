defmodule ForgeGitHub do
  @moduledoc """
  GitHub provider boundary for authentication, transport, and webhook primitives.

  This scaffold intentionally exposes types only. Provider behavior remains in
  `forge_imports` until it is extracted in a later change.
  """

  @type provider :: :github
  @type external_id :: pos_integer()
  @type installation_id :: pos_integer()
end
