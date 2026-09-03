defmodule FornacastWeb.SessionHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "session_html/*"

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()
end
