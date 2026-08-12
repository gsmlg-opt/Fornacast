defmodule FornacastAPI.Validators.V2026_03_10.Issue do
  alias FornacastAPI.RequestValidator

  @create_fields ~w(title body assignee assignees labels)
  @update_fields ~w(title body state state_reason assignee assignees labels)
  @comment_fields ~w(body)

  def validate(:issue_create, body), do: validate_issue(body, @create_fields, ["title"])
  def validate(:issue_update, body), do: validate_issue(body, @update_fields, [])
  def validate(:issue_comment_create, body), do: validate_comment(body)
  def validate(:issue_comment_update, body), do: validate_comment(body)

  defp validate_issue(body, accepted, required) do
    fields =
      %{
        "title" => &nonempty_string?/1,
        "body" => &nullable_string?/1,
        "assignee" => &nullable_string?/1,
        "assignees" => &username_list?/1,
        "labels" => &labels?/1,
        "state" => &(&1 in ["open", "closed"]),
        "state_reason" => &(&1 in ["completed", "not_planned", "reopened"])
      }
      |> Map.take(accepted)

    RequestValidator.validate_fields(body, "Issue", fields, required)
  end

  defp validate_comment(body) do
    fields = Map.take(%{"body" => &nonempty_string?/1}, @comment_fields)
    RequestValidator.validate_fields(body, "Issue", fields, ["body"])
  end

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp nullable_string?(value), do: is_nil(value) or is_binary(value)
  defp username_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp labels?(value), do: is_list(value) and Enum.all?(value, &label?/1)
  defp label?(value) when is_binary(value), do: true
  defp label?(%{"name" => name} = value), do: map_size(value) == 1 and is_binary(name)
  defp label?(_value), do: false
end
