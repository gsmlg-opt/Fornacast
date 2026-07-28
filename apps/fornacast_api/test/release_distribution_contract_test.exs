defmodule FornacastAPI.ReleaseDistributionContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @workflow Path.join(@root, ".github/workflows/release.yml")
  @ci_workflow Path.join(@root, ".github/workflows/ci.yml")
  @e2e_workflow Path.join(@root, ".github/workflows/e2e.yml")
  @compose Path.join(@root, "docker-compose.yml")
  @dockerfile Path.join(@root, "Dockerfile")
  @readme Path.join(@root, "README.md")
  @version_resolver Path.join(@root, "scripts/resolve_release_version.sh")
  @web_mix Path.join(@root, "apps/fornacast_web/mix.exs")
  @config Path.join(@root, "config/config.exs")

  test "release version resolver accepts only normalized stable versions" do
    for {input, expected} <- [
          {"0.1.0", "0.1.0"},
          {"1.2.3", "1.2.3"},
          {"v10.20.30", "10.20.30"}
        ] do
      assert {output, 0} =
               System.cmd(@version_resolver, [input],
                 stderr_to_stdout: true,
                 cd: @root
               )

      assert String.trim(output) == expected
    end

    for input <- [
          "",
          "v",
          "1.2",
          "1.2.3.4",
          "01.2.3",
          "1.02.3",
          "1.2.03",
          "1.2.3-rc.1",
          "1.2.3+build.1"
        ] do
      assert {_output, status} =
               System.cmd(@version_resolver, [input],
                 stderr_to_stdout: true,
                 cd: @root
               )

      assert status != 0, "expected #{inspect(input)} to be rejected"
    end

    assert {_output, no_argument_status} =
             System.cmd(@version_resolver, [], stderr_to_stdout: true, cd: @root)

    assert no_argument_status != 0

    assert {_output, extra_argument_status} =
             System.cmd(@version_resolver, ["1.2.3", "extra"],
               stderr_to_stdout: true,
               cd: @root
             )

    assert extra_argument_status != 0
  end

  test "release validates its branch and cannot be cancelled mid-publication" do
    workflow = File.read!(@workflow)

    assert workflow =~ "description: Stable release version (e.g. 1.2.3)"
    assert workflow =~ "description: Git branch to release from"
    assert workflow =~ ~s(group: release-${{ github.repository }})
    assert workflow =~ "cancel-in-progress: false"
    assert workflow =~ ~s(scripts/resolve_release_version.sh "$VERSION_INPUT")
    assert workflow =~ ~s(git check-ref-format --branch "$GIT_REF_INPUT")

    assert workflow =~
             ~s(git ls-remote --exit-code --heads origin "refs/heads/${git_ref}")

    assert workflow =~ ~s(echo "git_ref=$git_ref" >> "$GITHUB_OUTPUT")
    assert workflow =~ ~s(GIT_REF: ${{ steps.version.outputs.git_ref }})
    assert workflow =~ ~s(git push origin "HEAD:refs/heads/${GIT_REF}")
  end

  test "release publishes normalized latest and versioned images through GHCR_TOKEN owner" do
    workflow = File.read!(@workflow)

    refute workflow =~ "packages: write"
    assert workflow =~ "uses: docker/setup-buildx-action@v3"

    assert workflow =~
             ~r/- name: Resolve GHCR username\s+id: ghcr\s+env:\s+GH_TOKEN: \$\{\{ secrets\.GHCR_TOKEN \}\}\s+.*?gh api user --jq \.login.*?echo "username=\$username" >> "\$GITHUB_OUTPUT"/s

    assert workflow =~
             ~r/- name: Log in to GHCR\s+uses: docker\/login-action@v3\s+with:\s+registry: ghcr.io\s+username: \$\{\{ steps\.ghcr\.outputs\.username \}\}\s+password: \$\{\{ secrets\.GHCR_TOKEN \}\}/

    assert workflow =~
             ~r/- name: Build and publish Docker image.*?uses: docker\/build-push-action@v6.*?context: \.\s+file: \.\/Dockerfile\s+push: true\s+tags: \|\s+ghcr\.io\/gsmlg-dev\/fornacast:latest\s+ghcr\.io\/gsmlg-dev\/fornacast:\$\{\{ steps\.version\.outputs\.version \}\}/s

    assert length(:binary.matches(workflow, ~s(${{ github.token }}))) == 1
    assert_order(workflow, "Resolve GHCR username", "Log in to GHCR")
    assert_order(workflow, "Log in to GHCR", "Push release commit and tag")
    assert_order(workflow, "Push release commit and tag", "Build and publish Docker image")
    assert_order(workflow, "Build and publish Docker image", "Create GitHub release")
  end

  test "release image and build workflows install the frozen Bun lock" do
    for path <- [@workflow, @ci_workflow, @e2e_workflow] do
      workflow = File.read!(path)

      assert workflow =~ "mix bun.install --if-missing"
      assert workflow =~ "./_build/bun install --frozen-lockfile"
      assert workflow =~ "bun.lock"
    end

    dockerfile = File.read!(@dockerfile)

    assert dockerfile =~ "COPY package.json bun.lock bunfig.toml ./"
    assert dockerfile =~ "mix bun.install --if-missing"
    assert dockerfile =~ "./_build/bun install --frozen-lockfile"
    assert File.read!(@web_mix) =~ ~s({:bun, "~> 1.4", runtime: false})
    assert File.read!(@config) =~ ~s(config :bun, version: "1.3.4")
  end

  test "release commit, tag, and page operations are safe to retry" do
    workflow = File.read!(@workflow)

    assert workflow =~ "git diff --cached --quiet"
    assert workflow =~ "Files already have requested version"
    assert workflow =~ ~s(git rev-parse --verify --quiet "refs/tags/v${VERSION}")
    assert workflow =~ ~s(git rev-list -n 1 "v${VERSION}")
    assert workflow =~ ~s(git rev-parse HEAD)
    assert workflow =~ ~s(Release tag v${VERSION} points to)
    assert workflow =~ ~s(gh release view "v${VERSION}")
    assert workflow =~ ~s(gh release view "v${VERSION}" --json isDraft --jq .isDraft)
    assert workflow =~ "<!-- FORNACAST_DEPLOY_NOTES_START -->"
    assert workflow =~ "<!-- FORNACAST_DEPLOY_NOTES_END -->"
    assert workflow =~ "existing_without_deploy="
    assert workflow =~ "in_deploy = 1"
    assert workflow =~ "in_deploy = 0"
    assert workflow =~ "## Deploy with Docker Compose"

    assert workflow =~
             ~s(gh release edit "v${VERSION}" --notes "$combined_notes")

    assert workflow =~ ~s(gh release upload "v${VERSION}")
    assert workflow =~ "--clobber"
    assert workflow =~ ~s(gh release edit "v${VERSION}" --draft=false)
    assert workflow =~ "--verify-tag"
    assert workflow =~ "--generate-notes"
    assert workflow =~ ~s(--notes "$notes")

    assert_order(
      workflow,
      ~s(gh release upload "v${VERSION}"),
      ~s(gh release edit "v${VERSION}" --draft=false)
    )
  end

  test "release page receives safe Compose deployment instructions" do
    workflow = File.read!(@workflow)

    assert workflow =~ "cat > release-notes.md <<'EOF'"

    assert_order(
      workflow,
      "<!-- FORNACAST_DEPLOY_NOTES_START -->",
      "## Deploy with Docker Compose"
    )

    assert_order(
      workflow,
      "## Deploy with Docker Compose",
      "<!-- FORNACAST_DEPLOY_NOTES_END -->"
    )

    assert workflow =~ "## Deploy with Docker Compose"
    assert workflow =~ "ghcr.io/gsmlg-dev/fornacast:{{VERSION}}"
    assert workflow =~ "ghcr.io/gsmlg-dev/fornacast:latest"
    assert workflow =~ "anonymous pulls work only when the package is public"
    assert workflow =~ "`read:packages`"
    assert workflow =~ "GHCR_USERNAME"
    assert workflow =~ "GHCR_READ_TOKEN"
    assert workflow =~ ~s(docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin)

    assert workflow =~
             ~s(FORNACAST_IMAGE=ghcr.io/gsmlg-dev/fornacast@${{ steps.docker.outputs.digest }})

    assert workflow =~ "supports Turso/libSQL only"
    assert workflow =~ "PostgreSQL requires a source build"
    assert workflow =~ "`FORNACAST_DATABASE_ADAPTER=postgres`"
    assert workflow =~ "docker compose pull app nginx"
    assert workflow =~ "docker compose up -d --no-build"
    assert workflow =~ "keep public port `4000` blocked"
    assert workflow =~ "locally or through an SSH tunnel"
    assert workflow =~ "Do not publish ports `4890` or `4001` directly."

    assert workflow =~
             "The `fornacast-data` volume is mounted at `/data` and persists the Ecto database, Concord config, repositories, and SSH keys."

    assert workflow =~ "`/setup`"
    assert_order(workflow, "keep public port `4000` blocked", "docker compose up -d --no-build")
  end

  test "Compose and README advertise the published release image" do
    compose = File.read!(@compose)
    readme = File.read!(@readme)

    assert compose =~
             ~s(image: ${FORNACAST_IMAGE:-ghcr.io/gsmlg-dev/fornacast:latest})

    assert readme =~
             "https://img.shields.io/github/v/release/gsmlg-opt/Fornacast"

    assert readme =~
             "https://github.com/gsmlg-opt/Fornacast/releases/latest"

    assert readme =~
             "https://img.shields.io/badge/GHCR-gsmlg--dev%2Ffornacast"

    assert readme =~ "logo=docker"

    assert readme =~
             "https://github.com/orgs/gsmlg-dev/packages/container/package/fornacast"

    assert readme =~
             "FORNACAST_IMAGE=ghcr.io/gsmlg-dev/fornacast:"

    assert readme =~ "digest printed on the GitHub release page"
    assert readme =~ "anonymous pulls work only when the package is public"
    assert readme =~ "`read:packages`"
    assert readme =~ "GHCR_USERNAME"
    assert readme =~ "GHCR_READ_TOKEN"
    assert readme =~ ~s(docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin)
    assert readme =~ "supports Turso/libSQL only"
    assert readme =~ "keep public port `4000` blocked"
    assert readme =~ "locally or through an SSH tunnel"
    refute readme =~ "immutable versioned image"
    refute readme =~ "repeatable production deployment"
  end

  defp assert_order(source, first, second) do
    assert position!(source, first) < position!(source, second),
           "expected #{inspect(first)} to appear before #{inspect(second)}"
  end

  defp position!(source, value) do
    case :binary.match(source, value) do
      {position, _length} -> position
      :nomatch -> flunk("expected to find #{inspect(value)}")
    end
  end
end
