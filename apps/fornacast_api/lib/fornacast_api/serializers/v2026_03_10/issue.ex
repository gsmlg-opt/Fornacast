defmodule FornacastAPI.Serializers.V2026_03_10.Issue do
  def render(issue, opts),
    do: FornacastAPI.Serializers.V2022_11_28.Issue.render(issue, with_version(opts))

  def render_label(label, owner, repo),
    do: FornacastAPI.Serializers.V2022_11_28.Issue.render_label(label, owner, repo)

  defp with_version(opts) when is_list(opts), do: Keyword.put(opts, :version, "2026-03-10")
  defp with_version(opts), do: Map.put(opts, :version, "2026-03-10")
end
