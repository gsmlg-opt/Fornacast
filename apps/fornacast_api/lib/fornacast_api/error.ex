defmodule FornacastAPI.Error do
  @enforce_keys [:status, :message, :documentation_url]
  defstruct [:status, :message, :documentation_url, errors: nil, accepted_scopes: []]

  @type validation_error :: %{
          required(:resource) => String.t(),
          required(:field) => String.t(),
          required(:code) => atom(),
          optional(:message) => String.t()
        }

  @type t :: %__MODULE__{
          status: pos_integer(),
          message: String.t(),
          documentation_url: String.t(),
          errors: nil | [validation_error()],
          accepted_scopes: [String.t()]
        }

  def new(status, message, documentation_url, opts \\ []) do
    %__MODULE__{
      status: status,
      message: message,
      documentation_url: documentation_url,
      errors: Keyword.get(opts, :errors),
      accepted_scopes: Keyword.get(opts, :accepted_scopes, [])
    }
  end

  def from_domain(:invalid_credentials, url), do: new(401, "Bad credentials", url)

  def from_domain(:insufficient_scope, url),
    do: new(403, "Resource not accessible by personal access token", url)

  def from_domain(:forbidden, url), do: new(403, "Forbidden", url)
  def from_domain(:not_found, url), do: new(404, "Not Found", url)
  def from_domain(:git_initializer_unavailable, url), do: new(503, "Service unavailable", url)
  def from_domain({:conflict, _safe_reason}, url), do: new(409, "Conflict", url)

  def from_domain({:validation, errors}, url),
    do: new(422, "Validation Failed", url, errors: errors)

  def from_domain({:unavailable, _dependency}, url),
    do: new(503, "Service unavailable", url)

  def from_domain(_unclassified, url), do: new(500, "Internal Server Error", url)
end
