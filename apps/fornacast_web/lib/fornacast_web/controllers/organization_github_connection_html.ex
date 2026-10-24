defmodule FornacastWeb.OrganizationGitHubConnectionHTML do
  use FornacastWeb, :html
  alias FornacastWeb.OrganizationSettingsComponents
  embed_templates "organization_github_connection_html/*"

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()
  def base(organization), do: "/organizations/#{organization.username}/settings/github"
  def status(:disconnected), do: "Not connected"
  def status(:installation_required), do: "Authorization saved · installation required"
  def status(:permissions_missing), do: "Installation permissions missing"
  def status(:reconnect_required), do: "Reconnect required"
  def status(:ready), do: "Organization GitHub App connected"
  def status(_), do: "Connection unavailable"
  def repository_count(%{connection: nil}), do: 0

  def repository_count(%{connection: connection}),
    do: length(connection.inventory["repositories"] || [])

  def active_source?(config, view),
    do:
      view.state == :ready and config.credential_source == :organization_device and
        config.organization_connection_id == view.connection.id and
        config.organization_connection_version == view.connection_version

  def sync_status(%{last_sync_status: status})
      when status in ["queued", "running", "succeeded", "failed", "cancelled"],
      do: status

  def sync_status(_), do: "never synchronized"

  def message(reason) when reason in [:not_found, :forbidden],
    do: "Organization settings not found."

  def message(reason) when reason in [:busy, :leased, :conflict],
    do: "Synchronization is active or the connection is busy. Try again after it finishes."

  def message(:stale),
    do: "This organization connection or authorization changed. Refresh and start again."

  def message(:invalid_request), do: "The connection request is invalid. Refresh and try again."

  def message(reason) when reason in [:insufficient_installation_access, :missing_permissions],
    do:
      "Grant the Fornacast App read access to contents, issues and pull requests, then recheck the installation."

  def message(:installation_required),
    do:
      "Install the Fornacast App in the GitHub organization, then refresh and select its installation."

  def message(:identity_conflict),
    do: "This installation is already connected to a different organization."

  def message(reason)
      when reason in [:credential_unavailable, :reauthorization_required, :credential_changed],
      do: "Reconnect GitHub for this organization, then select its installation."

  def message(reason), do: FornacastWeb.GitHubSettingsHTML.device_message(reason)
end
