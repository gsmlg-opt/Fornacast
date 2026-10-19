defmodule FornacastAPI.Validators.GitData do
  alias FornacastAPI.RequestValidator

  def validate(:git_create_ref, body),
    do:
      RequestValidator.validate_fields(
        body,
        "Reference",
        %{"ref" => &nonempty?/1, "sha" => &oid?/1},
        ["ref", "sha"]
      )

  def validate(:git_update_ref, body),
    do:
      RequestValidator.validate_fields(
        body,
        "Reference",
        %{"sha" => &oid?/1, "force" => &(&1 == false)},
        ["sha"]
      )

  def validate(:content_put, body),
    do:
      RequestValidator.validate_fields(
        body,
        "Content",
        Map.merge(fields(), %{"content" => &is_binary/1, "sha" => &oid?/1}),
        ["message", "content"]
      )

  def validate(:content_delete, body),
    do:
      RequestValidator.validate_fields(body, "Content", Map.put(fields(), "sha", &oid?/1), [
        "message",
        "sha"
      ])

  defp fields,
    do: %{
      "message" => &message?/1,
      "branch" => &nonempty?/1,
      "author" => &signature?/1,
      "committer" => &signature?/1
    }

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp message?(value),
    do: nonempty?(value) and byte_size(value) <= 65_536 and not String.contains?(value, <<0>>)

  defp oid?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\z/, value)

  defp signature?(value) when is_map(value) do
    Map.keys(value) -- ["name", "email", "date"] == [] and
      signature_field?(value["name"], 255) and signature_field?(value["email"], 320) and
      (not Map.has_key?(value, "date") or valid_date?(value["date"]))
  end

  defp signature?(_), do: false

  defp signature_field?(value, limit),
    do:
      nonempty?(value) and byte_size(value) <= limit and
        not String.contains?(value, [<<0>>, "\r", "\n", "<", ">"])

  defp valid_date?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_date?(_), do: false
end
