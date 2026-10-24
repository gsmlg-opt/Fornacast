defmodule ForgeGitHub.UserInstallation do
  @moduledoc "A GitHub App installation visible to an authenticated App user."

  alias ForgeGitHub.AppInstallation

  @enforce_keys [:app_id, :app_slug, :installation]
  defstruct [:client_id | @enforce_keys]

  def from_json(%{"app_id" => app_id, "app_slug" => slug} = json)
      when is_integer(app_id) and app_id > 0 and app_id <= 9_223_372_036_854_775_807 and
             is_binary(slug) and byte_size(slug) in 1..100 do
    client_id = json["client_id"]

    with true <- String.match?(slug, ~r/\A[a-zA-Z0-9][a-zA-Z0-9-]*\z/),
         true <- is_nil(client_id) or (is_binary(client_id) and byte_size(client_id) in 1..255),
         {:ok, installation} <- AppInstallation.from_json(json) do
      {:ok,
       %__MODULE__{
         app_id: app_id,
         app_slug: slug,
         client_id: client_id,
         installation: installation
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def from_json(_), do: {:error, :invalid_response}
end
