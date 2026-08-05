defmodule FornacastAPI.Serializers.V2026_03_10.IssueComment do
  def render(comment, opts),
    do: FornacastAPI.Serializers.V2022_11_28.IssueComment.render(comment, with_version(opts))

  defp with_version(opts) when is_list(opts), do: Keyword.put(opts, :version, "2026-03-10")
  defp with_version(opts), do: Map.put(opts, :version, "2026-03-10")
end
