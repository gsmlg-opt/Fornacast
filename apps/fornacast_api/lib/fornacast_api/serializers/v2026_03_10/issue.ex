defmodule FornacastAPI.Serializers.V2026_03_10.Issue do
  defdelegate render(issue, opts), to: FornacastAPI.Serializers.V2022_11_28.Issue
  defdelegate render_label(label, owner, repo), to: FornacastAPI.Serializers.V2022_11_28.Issue
end
