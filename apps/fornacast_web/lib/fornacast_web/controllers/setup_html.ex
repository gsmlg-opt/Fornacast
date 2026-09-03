defmodule FornacastWeb.SetupHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "setup_html/*"

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()
end
