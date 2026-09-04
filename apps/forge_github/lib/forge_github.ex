defmodule ForgeGitHub do
  @moduledoc """
  GitHub provider boundary for authentication, bounded API transport, resource
  decoding, and webhook primitives.
  """

  @type provider :: :github
  @type external_id :: pos_integer()
  @type installation_id :: pos_integer()
end
