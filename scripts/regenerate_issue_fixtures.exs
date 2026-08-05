alias FornacastAPI.IssueFixtureLiterals

fixture_root = Path.expand("../apps/fornacast_api/test/fixtures", __DIR__)
openapi_root = Path.expand("../apps/fornacast_api/priv/openapi", __DIR__)

documents =
  Map.new(IssueFixtureLiterals.versions(), fn version ->
    document =
      Path.join(openapi_root, "ghes-3.21-#{version}.json")
      |> File.read!()
      |> JSON.decode!()
      |> OpenApiSpex.OpenApi.Decode.decode()

    {version, document}
  end)

response = fn
  "issue.json" ->
    {"/repos/{owner}/{repo}/issues/{issue_number}", :get, "200"}

  "pull-issue.json" ->
    {"/repos/{owner}/{repo}/issues/{issue_number}", :get, "200"}

  "issue-list.json" ->
    {"/repos/{owner}/{repo}/issues", :get, "200"}

  "issue-comment.json" ->
    {"/repos/{owner}/{repo}/issues/{issue_number}/comments", :post, "201"}

  "issue-comment-list.json" ->
    {"/repos/{owner}/{repo}/issues/{issue_number}/comments", :get, "200"}
end

prepared =
  for version <- IssueFixtureLiterals.versions(),
      {filename, literal} <- IssueFixtureLiterals.files(version) do
    bytes = JSON.encode!(literal)
    ^literal = JSON.decode!(bytes)
    document = Map.fetch!(documents, version)
    {path, method, status} = response.(filename)

    schema =
      document.paths
      |> Map.fetch!(path)
      |> Map.fetch!(method)
      |> Map.fetch!(:responses)
      |> Map.fetch!(status)
      |> Map.fetch!(:content)
      |> Map.fetch!("application/json")
      |> Map.fetch!(:schema)

    {:ok, _value} = OpenApiSpex.cast_value(literal, schema, document)
    target = Path.join([fixture_root, version, "issues", filename])
    {target, bytes}
  end

10 = length(prepared)
staging_root = Path.join(fixture_root, ".issue-fixtures-#{System.unique_integer([:positive])}")

try do
  Enum.each(prepared, fn {target, bytes} ->
    staged = Path.join(staging_root, Path.relative_to(target, fixture_root))
    File.mkdir_p!(Path.dirname(staged))
    File.write!(staged, bytes)
    ^bytes = File.read!(staged)
  end)

  Enum.each(prepared, fn {target, _bytes} ->
    staged = Path.join(staging_root, Path.relative_to(target, fixture_root))
    File.rename!(staged, target)
  end)
after
  File.rm_rf!(staging_root)
end

IO.puts("Regenerated 10 issue fixtures with byte and schema validation")
