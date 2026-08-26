defmodule FornacastWeb.GitHubSettingsHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "github_settings_html/*"

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  def credential_label(%{credential_present: false}), do: "No saved PAT"
  def credential_label(%{credential_status: :valid}), do: "Credential verified"
  def credential_label(%{credential_status: :invalid}), do: "Credential invalid"
  def credential_label(_account), do: "Saved PAT"

  def credential_variant(%{credential_present: false}), do: "neutral"
  def credential_variant(%{credential_status: :valid}), do: "success"
  def credential_variant(%{credential_status: :invalid}), do: "error"
  def credential_variant(_account), do: "info"

  def verification_time(nil), do: "Never"

  def verification_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %d, %Y at %H:%M UTC")
  end

  def datetime_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
