defmodule ForgeImports.GitHub.RepositoryReferenceTest do
  use ExUnit.Case, async: true

  alias ForgeImports.GitHub.RepositoryReference

  test "parses an owner/repository reference" do
    assert {:ok, %{owner: "octocat", repository: "hello-world"}} =
             RepositoryReference.parse("octocat/hello-world")
  end

  test "parses only canonical GitHub HTTPS URLs and removes presentation data" do
    assert {:ok, %{owner: "Octo-Cat", repository: "hello.world"}} =
             RepositoryReference.parse(
               " https://ignored@GitHub.com/Octo-Cat/hello.world.git/?tab=readme#top "
             )
  end

  test "rejects non-GitHub hosts, non-HTTPS URLs, ports, and extra path components" do
    invalid = [
      "http://github.com/octocat/hello-world",
      "https://github.example/octocat/hello-world",
      "https://github.com:443/octocat/hello-world",
      "https://github.com/octocat/hello-world/issues",
      "https://github.com/octocat/hello-world.git/extra",
      "https://github.com/octocat/hello-world//"
    ]

    for source <- invalid do
      assert {:error, :invalid_source} = RepositoryReference.parse(source)
    end
  end

  test "rejects missing, encoded, or invalid owner and repository components" do
    invalid = [
      "",
      "octocat",
      "octocat/",
      "/hello-world",
      "octocat/hello%2Fworld",
      "-octocat/hello-world",
      "octocat-/hello-world",
      "octocat/..",
      "octocat/hello world",
      "octocat/hello-world//",
      "octocat/hello-world/issues",
      "octocat/hello-world/?tab=readme",
      "octocat/hello-world#readme"
    ]

    for source <- invalid do
      assert {:error, :invalid_source} = RepositoryReference.parse(source)
    end
  end

  test "accepts a single optional trailing slash on shorthand and canonical URL forms" do
    assert {:ok, %{owner: "octocat", repository: "hello-world"}} =
             RepositoryReference.parse("octocat/hello-world/")

    assert {:ok, %{owner: "octocat", repository: "hello-world"}} =
             RepositoryReference.parse("https://github.com/octocat/hello-world/")
  end

  test "rejects non-binary and NUL-bearing input" do
    assert {:error, :invalid_source} = RepositoryReference.parse(nil)
    assert {:error, :invalid_source} = RepositoryReference.parse("octocat/hello\0world")
  end
end
