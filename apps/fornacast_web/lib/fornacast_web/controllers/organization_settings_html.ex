defmodule FornacastWeb.OrganizationSettingsHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "organization_settings_html/*"

  def sync_status(%{mirror: nil}), do: "Not configured"
  def sync_status(%{mirror: %{state: state}}), do: humanize(state)
  def sync_status(_view), do: "Unavailable"

  def humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  def humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def humanize(_value), do: "Unknown"
end
