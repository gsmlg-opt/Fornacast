defmodule FornacastWeb.OrganizationSettingsHTML do
  @moduledoc false

  use FornacastWeb, :html

  import FornacastWeb.OrganizationSettingsComponents

  embed_templates "organization_settings_html/*"

  def form_value(form, key, default \\ "") when is_map(form) do
    case Map.get(form, key, default) do
      value when is_binary(value) -> value
      nil -> default
      _invalid -> default
    end
  end

  def profile_field_errors(errors, field) do
    errors
    |> Enum.filter(&(&1.resource == "Organization" and &1.field == field))
    |> Enum.map(&validation_message/1)
  end

  def focus_field(errors) do
    Enum.find_value(["name", "description"], fn field ->
      if profile_field_errors(errors, field) == [], do: nil, else: field
    end)
  end

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  defp validation_message(%{field: field, code: code}) do
    label = field |> String.replace("_", " ") |> String.capitalize()

    case code do
      :invalid -> "#{label} is invalid"
      :too_long -> "#{label} is too long"
      :missing_field -> "#{label} is required"
      _other -> "#{label} could not be saved"
    end
  end
end
