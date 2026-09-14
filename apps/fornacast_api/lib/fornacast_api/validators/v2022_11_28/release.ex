defmodule FornacastAPI.Validators.V2022_11_28.Release do
  alias FornacastAPI.RequestValidator

  def validate(:release_create, body), do: validate_fields(body, ["tag_name"])
  def validate(:release_update, body), do: validate_fields(body, [])

  defp validate_fields(body, required),
    do: RequestValidator.validate_fields(body, "Release", fields(), required)

  defp fields do
    %{
      "tag_name" => &nonempty_string?/1,
      "target_commitish" => &nonempty_string?/1,
      "name" => &nullable_string?/1,
      "body" => &nullable_string?/1,
      "draft" => &is_boolean/1,
      "prerelease" => &is_boolean/1
    }
  end

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp nullable_string?(value), do: is_nil(value) or is_binary(value)
end
