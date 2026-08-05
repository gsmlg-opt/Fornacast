alias FornacastAPI.IssueFixtureLiterals

fixture_root = Path.expand("../apps/fornacast_api/test/fixtures", __DIR__)

for version <- IssueFixtureLiterals.versions(),
    {filename, literal} <- IssueFixtureLiterals.files(version) do
  fixture_path = Path.join([fixture_root, version, "issues", filename])
  File.write!(fixture_path, JSON.encode!(literal, &IssueFixtureLiterals.encode/2))
end
