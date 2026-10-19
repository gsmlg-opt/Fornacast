defmodule FornacastWeb.WorkbenchHTML do
  @moduledoc false

  use FornacastWeb, :html
  use FornacastComponent

  embed_templates "workbench_html/*"

  def title(:issue), do: "Issues"
  def title(:pull_request), do: "Pull requests"
  def base_path(:issue), do: "/issues"
  def base_path(:pull_request), do: "/pulls"
  def state_variant(:open), do: "success"
  def state_variant(:closed), do: "neutral"

  def pagination_url(kind, state, page) do
    base_path(kind) <>
      "?" <> URI.encode_query(%{state: state, per_page: page.per_page}) <> "&page={page}"
  end
end
