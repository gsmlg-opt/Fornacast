defmodule FornacastWeb.OrganizationPublicSyncHTML do
  use FornacastWeb, :html
  alias FornacastWeb.OrganizationSettingsComponents
  embed_templates "organization_public_sync_html/*"
  def base(organization), do: "/organizations/#{organization.username}/settings/github/public"
  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()
  def configured?(config), do: config.id != nil and config.credential_source == :public
  def version(config), do: if(config.id, do: config.lock_version, else: 0)
end
