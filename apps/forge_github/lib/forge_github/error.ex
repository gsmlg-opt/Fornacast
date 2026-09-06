defmodule ForgeGitHub.Error do
  @moduledoc "A classified, presentation-safe GitHub transport error."

  defexception [:kind, :retry_at, :detail]

  @type kind ::
          :invalid_request
          | :invalid_credential
          | :forbidden
          | :not_found
          | :primary_rate_limit
          | :secondary_rate_limit
          | :upstream_unavailable
          | :unexpected_status
          | :transport
          | :timeout
          | :host_unavailable
          | :unsafe_host
          | :request_too_large
          | :response_too_large
          | :invalid_json
          | :invalid_response
          | :invalid_lfs_response
          | :unsafe_action_url
          | :unsafe_redirect
          | :action_expired
          | :object_missing
          | :integrity_mismatch
          | :source
          | :sink
          | :local_storage
          | :invalid_pagination
          | :pagination_limit
          | :request_gate_busy

  @type t :: %__MODULE__{kind: kind(), retry_at: DateTime.t() | nil, detail: String.t()}

  @impl Exception
  def message(%__MODULE__{kind: kind}), do: message_for(kind)

  def new(kind, retry_at \\ nil) do
    %__MODULE__{kind: kind, retry_at: retry_at, detail: message_for(kind)}
  end

  defp message_for(:invalid_request), do: "The GitHub request is invalid"
  defp message_for(:invalid_credential), do: "GitHub rejected the credential"
  defp message_for(:forbidden), do: "The credential cannot access this GitHub resource"
  defp message_for(:not_found), do: "The GitHub resource was not found"
  defp message_for(:primary_rate_limit), do: "GitHub's primary rate limit was reached"
  defp message_for(:secondary_rate_limit), do: "GitHub's secondary rate limit was reached"
  defp message_for(:upstream_unavailable), do: "GitHub is temporarily unavailable"
  defp message_for(:unexpected_status), do: "GitHub returned an unexpected response"
  defp message_for(:transport), do: "The GitHub request could not be completed"
  defp message_for(:timeout), do: "The GitHub request timed out"
  defp message_for(:host_unavailable), do: "The GitHub API host could not be resolved"
  defp message_for(:unsafe_host), do: "The GitHub API host resolved to a non-public address"
  defp message_for(:request_too_large), do: "The GitHub request exceeded the size limit"
  defp message_for(:response_too_large), do: "The GitHub response exceeded the size limit"
  defp message_for(:invalid_json), do: "GitHub returned malformed JSON"
  defp message_for(:invalid_response), do: "GitHub returned an invalid resource"
  defp message_for(:invalid_lfs_response), do: "GitHub returned an invalid LFS response"
  defp message_for(:unsafe_action_url), do: "GitHub returned an unsafe LFS action URL"
  defp message_for(:unsafe_redirect), do: "GitHub attempted an unsafe redirect"
  defp message_for(:action_expired), do: "The GitHub LFS action expired"
  defp message_for(:object_missing), do: "The GitHub LFS object was not found"
  defp message_for(:integrity_mismatch), do: "The GitHub LFS object failed integrity checks"
  defp message_for(:source), do: "The local LFS source could not be read"
  defp message_for(:sink), do: "The local LFS destination could not be written"
  defp message_for(:local_storage), do: "The local LFS storage operation failed"
  defp message_for(:invalid_pagination), do: "GitHub returned an invalid pagination link"
  defp message_for(:pagination_limit), do: "GitHub pagination exceeded the page limit"
  defp message_for(:request_gate_busy), do: "The GitHub credential is already in use"
  defp message_for(_kind), do: "The GitHub request failed"
end

defimpl Inspect, for: ForgeGitHub.Error do
  import Inspect.Algebra

  def inspect(error, opts) do
    concat([
      "#ForgeGitHub.Error<",
      to_doc([kind: error.kind, retry_at: error.retry_at, detail: "[REDACTED]"], opts),
      ">"
    ])
  end
end
