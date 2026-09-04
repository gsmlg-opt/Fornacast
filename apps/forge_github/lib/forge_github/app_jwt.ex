defmodule ForgeGitHub.AppJWT do
  @moduledoc "A short-lived GitHub App JWT whose textual value is always redacted from inspection."

  @enforce_keys [:token, :issued_at, :expires_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{token: String.t(), issued_at: DateTime.t(), expires_at: DateTime.t()}
end

defimpl Inspect, for: ForgeGitHub.AppJWT do
  import Inspect.Algebra

  def inspect(jwt, opts) do
    concat([
      "#ForgeGitHub.AppJWT<",
      to_doc([token: "[REDACTED]", issued_at: jwt.issued_at, expires_at: jwt.expires_at], opts),
      ">"
    ])
  end
end
