defmodule FornacastWeb.OrganizationPATSettingsHTML do
  use FornacastWeb, :html
  alias FornacastWeb.OrganizationSettingsComponents
  embed_templates "organization_pat_settings_html/*"
  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()
  def base(organization), do: "/organizations/#{organization.username}/settings/github"

  def accounts(view),
    do: for(owner <- view.owners, account <- owner.accounts, do: {owner, account})

  def credential_status(nil), do: "No owner PAT selected"
  def credential_status(%{credential_present: false}), do: "Saved PAT missing"
  def credential_status(%{credential_status: :valid}), do: "Saved PAT verified"
  def credential_status(_), do: "Saved PAT invalid"
  def repository_rows(view), do: Map.get(view.config.inventory, "repositories", [])

  def selected?(config, id),
    do: config.repository_selection == "all" or id in config.selected_repository_ids
end
