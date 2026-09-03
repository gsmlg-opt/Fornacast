defmodule FornacastWeb.DashboardHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "dashboard_html/*"

  def owner_username(repo) do
    owner = ForgeRepos.repository_owner(repo)
    owner.username
  end
end
