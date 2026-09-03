defmodule FornacastWeb.SSHKeyHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "ssh_key_html/*"

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()
end
