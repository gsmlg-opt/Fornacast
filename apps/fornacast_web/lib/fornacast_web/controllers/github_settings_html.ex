defmodule FornacastWeb.GitHubSettingsHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "github_settings_html/*"

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  def device_message(:device_flow_disabled),
    do: "Enable Device Flow in the GitHub App settings, then try again."

  def device_message(:access_denied),
    do: "GitHub authorization was declined. You can start again."

  def device_message(:expired_token),
    do: "The GitHub authorization code expired. Start again for a new code."

  def device_message(:incorrect_client_credentials),
    do: "The configured GitHub App client ID was rejected."

  def device_message(:already_linked), do: "That GitHub account cannot be linked."
  def device_message(:stale), do: "This authorization attempt is no longer active. Start again."

  def device_message(:credential_service_unavailable),
    do:
      "GitHub credential storage is unavailable. Ask the operator to check the credential encryption keys."

  def device_message(_),
    do: "GitHub authorization is temporarily unavailable. Start again to retry."

  def credential_label(%{credential_kind: :github_app_user, reconnect_required: true}),
    do: "Reconnect GitHub"

  def credential_label(%{credential_kind: :github_app_user}), do: "GitHub App connected"
  def credential_label(%{credential_present: false}), do: "No saved PAT"
  def credential_label(%{credential_status: :valid}), do: "Credential verified"
  def credential_label(%{credential_status: :invalid}), do: "Credential invalid"
  def credential_label(_account), do: "Saved PAT"

  def credential_variant(%{credential_present: false}), do: "neutral"

  def credential_variant(%{credential_kind: :github_app_user, reconnect_required: true}),
    do: "warning"

  def credential_variant(%{credential_status: :valid}), do: "success"
  def credential_variant(%{credential_status: :invalid}), do: "error"
  def credential_variant(_account), do: "info"

  def verification_time(nil), do: "Never"

  def verification_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %d, %Y at %H:%M UTC")
  end

  def datetime_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  def credential_name(%{credential_kind: :github_app_user}), do: "GitHub App token"
  def credential_name(_), do: "PAT"

  def credential_delete_name(%{credential_kind: :github_app_user}), do: "GitHub App token"
  def credential_delete_name(_), do: "GitHub PAT"

  def replacement_label(%{credential_kind: :github_app_user}), do: "Replace with PAT"
  def replacement_label(_), do: "Replace saved PAT"
end
