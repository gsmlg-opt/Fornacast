defmodule FornacastAPI.Validators.V2022_11_28.Release do
  alias FornacastAPI.RequestValidator

  def validate(:release_create, body), do: validate_fields(body, ["tag_name"], true)
  def validate(:release_update, body), do: validate_fields(body, [], false)

  def validate(:release_notes, body),
    do:
      RequestValidator.validate_fields(
        body,
        "Release",
        %{
          "tag_name" => &nonempty_string?/1,
          "target_commitish" => &nonempty_string?/1,
          "previous_tag_name" => &nonempty_string?/1
        },
        ["tag_name"]
      )

  defp validate_fields(body, required, create?) do
    fields =
      if create?, do: Map.put(fields(), "generate_release_notes", &is_boolean/1), else: fields()

    RequestValidator.validate_fields(body, "Release", fields, required)
  end

  defp fields do
    %{
      "tag_name" => &nonempty_string?/1,
      "target_commitish" => &nonempty_string?/1,
      "name" => &nullable_string?/1,
      "body" => &nullable_string?/1,
      "draft" => &is_boolean/1,
      "prerelease" => &is_boolean/1,
      "make_latest" => &(&1 in ["true", "false", "legacy"])
    }
  end

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp nullable_string?(value), do: is_nil(value) or is_binary(value)
end
