defmodule FornacastAPI.Validators.V2022_11_28.Pull do
  alias FornacastAPI.RequestValidator

  def validate(:pull_create, body) do
    RequestValidator.validate_fields(
      body,
      "PullRequest",
      %{
        "title" => &nonempty_string?/1,
        "head" => &nonempty_string?/1,
        "base" => &nonempty_string?/1,
        "body" => &nullable_string?/1
      },
      ~w(title head base)
    )
  end

  def validate(:pull_update, body) do
    RequestValidator.validate_fields(
      body,
      "PullRequest",
      %{
        "title" => &nonempty_string?/1,
        "body" => &nullable_string?/1,
        "state" => &(&1 in ~w(open closed)),
        "base" => &nonempty_string?/1
      },
      []
    )
  end

  def validate(:pull_merge, body) do
    RequestValidator.validate_fields(
      body,
      "PullRequest",
      %{
        "commit_title" => &nonempty_string?/1,
        "commit_message" => &is_binary/1,
        "sha" => &oid?/1,
        "merge_method" => &(&1 == "merge")
      },
      []
    )
  end

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp nullable_string?(value), do: is_nil(value) or is_binary(value)
  defp oid?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, value)
end
