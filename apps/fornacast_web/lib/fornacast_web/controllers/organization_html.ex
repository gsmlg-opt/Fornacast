defmodule FornacastWeb.OrganizationHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "organization_html/*"

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()
end
