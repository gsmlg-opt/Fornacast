defmodule FornacastAPI.ReleaseDistributionContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @workflow Path.join(@root, ".github/workflows/release.yml")
  @ci_workflow Path.join(@root, ".github/workflows/ci.yml")
  @e2e_workflow Path.join(@root, ".github/workflows/e2e.yml")
  @compose Path.join(@root, "docker-compose.yml")
  @dockerfile Path.join(@root, "Dockerfile")
  @env_example Path.join(@root, ".env.example")
  @readme Path.join(@root, "README.md")
  @agents Path.join(@root, "AGENTS.md")
  @version_resolver Path.join(@root, "scripts/resolve_release_version.sh")
  @web_mix Path.join(@root, "apps/fornacast_web/mix.exs")
  @config Path.join(@root, "config/config.exs")
  @runtime_config Path.join(@root, "config/runtime.exs")
  @releases_mix Path.join(@root, "apps/forge_releases/mix.exs")
  @deploy_notes_start "<!-- FORNACAST_DEPLOY_NOTES_START -->"
  @deploy_notes_end "<!-- FORNACAST_DEPLOY_NOTES_END -->"
  @obsolete_database_claims [
    ~r/\bdefault(?:\s+(?:domain\s+)?database)?\s+(?:is|uses?)\s+turso(?:\/libsql)?\b/i,
    ~r/\bturso(?:\/libsql)?\s+is\s+the\s+default(?:\s+(?:domain\s+)?database)?\b/i,
    ~r/\bdefault\s+turso(?:\/libsql)?(?:-backed)?\b/i,
    ~r/\b(?:supports?\s+)?turso\/libsql\s+only\b/i,
    ~r/\bonly\s+(?:supports?\s+)?turso\/libsql\b/i,
    ~r/\bturso[- ]only\b/i,
    ~r/\bpostgresql[\s:,-]+(?:is[\s:,-]+)?optional\b/i,
    ~r/\boptional[\s:,-]+postgresql\b/i,
    ~r/\bpostgresql\s+requires?\s+(?:a\s+)?source\s+build\b/i,
    ~r/\bsource\s+build(?:\s+\w+){0,2}\s+required\s+for\s+postgresql\b/i
  ]

  @runtime_database_env ~w(
    RELEASE_COMMAND FORNACAST_DATABASE_ADAPTER DATABASE_URL
    PGUSER PGPASSWORD PGHOST PGPORT PGDATABASE
    POSTGRES_USER POSTGRES_PASSWORD POSTGRES_HOST POSTGRES_PORT POSTGRES_DB
  )

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

  test "release publishes normalized images with GHCR_TOKEN used only for registry login" do
    workflow = File.read!(@workflow)

    refute workflow =~ "packages: write"
    assert workflow =~ "uses: docker/setup-buildx-action@v3"
    refute workflow =~ "Resolve GHCR username"
    refute workflow =~ "gh api user"

    assert workflow =~
             ~r/- name: Log in to GHCR\s+uses: docker\/login-action@v3\s+with:\s+registry: ghcr.io\s+username: \$\{\{ github\.actor \}\}\s+password: \$\{\{ secrets\.GHCR_TOKEN \}\}/

    assert workflow =~
             ~r/- name: Build and publish Docker image.*?uses: docker\/build-push-action@v6.*?context: \.\s+file: \.\/Dockerfile\s+push: true\s+tags: \|\s+ghcr\.io\/gsmlg-dev\/fornacast:latest\s+ghcr\.io\/gsmlg-dev\/fornacast:\$\{\{ steps\.version\.outputs\.version \}\}/s

    assert workflow =~
             ~r/- name: Build and publish Docker image.*?build-args: \|\s+FORNACAST_DATABASE_ADAPTER=postgres/s

    assert workflow =~ "scope=fornacast-release-postgres"

    assert length(:binary.matches(workflow, ~s(${{ secrets.GHCR_TOKEN }}))) == 1
    assert length(:binary.matches(workflow, ~s(${{ github.token }}))) == 1
    assert_order(workflow, "Log in to GHCR", "Push release commit and tag")
    assert_order(workflow, "Push release commit and tag", "Build and publish Docker image")
    assert_order(workflow, "Build and publish Docker image", "Create GitHub release")
  end

  test "release image and build workflows install the frozen npm lock" do
    for path <- [@workflow, @ci_workflow, @e2e_workflow] do
      workflow = File.read!(path)

      assert workflow =~ "mix npm.ci"
      assert workflow =~ "package-lock.json"
      refute workflow =~ "mix bun.install"
      refute workflow =~ "bun.lock"
    end

    dockerfile = File.read!(@dockerfile)

    assert dockerfile =~ "COPY package.json package-lock.json ./"
    assert dockerfile =~ "mix npm.ci"
    refute dockerfile =~ "mix bun.install"
    refute dockerfile =~ "bun.lock"
    refute File.read!(@web_mix) =~ "{:bun,"
    refute File.read!(@config) =~ "config :bun,"
  end

  test "release archive contains the current GitCore native library" do
    workflow = File.read!(@workflow)

    [_, cache_step] = String.split(workflow, "- name: Cache release dependencies", parts: 2)
    [cache_step, _] = String.split(cache_step, "- name: Install Hex and Rebar", parts: 2)

    refute cache_step =~ ~r/^\s+_build\s*$/m
    assert workflow =~ ~s(release_path="${RUNNER_TEMP}/fornacast")
    refute workflow =~ ~s(release_path="artifacts/fornacast")
    assert workflow =~ ~s(mix release fornacast --overwrite --path "$release_path")

    assert workflow =~
             ~s(test -s "$release_path/lib/git_core-${VERSION}/priv/native/fornacast_git_core.so")

    assert workflow =~ ~s(tar -C "$RUNNER_TEMP")
  end

  test "release image installs the Erlang SCTP runtime library" do
    dockerfile = File.read!(@dockerfile)
    [_, runtime_stage] = String.split(dockerfile, "FROM ${DEBIAN_IMAGE} AS app", parts: 2)
    [runtime_packages, _] = String.split(runtime_stage, "useradd --create-home", parts: 2)

    assert "libsctp1" in String.split(runtime_packages)
  end

  test "release image installs CMake only for native dependency builds" do
    dockerfile = File.read!(@dockerfile)

    [build_stage, runtime_stage] =
      String.split(dockerfile, "FROM ${DEBIAN_IMAGE} AS app", parts: 2)

    cmake_install = """
    RUN apt-get update && \\
        apt-get install -y --no-install-recommends cmake && \\
        rm -rf /var/lib/apt/lists/*
    """

    assert build_stage =~ cmake_install

    assert_order(build_stage, "cmake", "mix deps.compile")
    refute "cmake" in String.split(runtime_stage)
  end

  test "release image scopes Hex retry tuning to the build stage" do
    dockerfile = File.read!(@dockerfile)

    [build_stage, runtime_stage] =
      String.split(dockerfile, "FROM ${DEBIAN_IMAGE} AS app", parts: 2)

    assert build_stage =~ ~r/^ENV HEX_HTTP_CONCURRENCY=1 \\$/m
    assert build_stage =~ ~r/^[ \t]+HEX_HTTP_TIMEOUT=300$/m
    assert_order(build_stage, "HEX_HTTP_CONCURRENCY=1", "mix deps.get --only prod")
    assert_order(build_stage, "HEX_HTTP_TIMEOUT=300", "mix deps.get --only prod")

    refute runtime_stage =~ "HEX_HTTP_CONCURRENCY"
    refute runtime_stage =~ "HEX_HTTP_TIMEOUT"
  end

  test "production rejects cookie secrets shorter than 64 bytes" do
    {short_output, short_status} = read_runtime_config(String.duplicate("s", 63))

    assert short_status != 0
    assert short_output =~ "SECRET_KEY_BASE must be at least 64 bytes"

    {_valid_output, valid_status} = read_runtime_config(String.duplicate("s", 64))
    assert valid_status == 0
  end

  test "production defaults the API listener to port 4891" do
    {output, status} = read_runtime_config(String.duplicate("s", 64), nil)

    assert status == 0
    assert output =~ "api_port=4891"
  end

  test "production resolves bundled assets from the packaged OTP application" do
    {config, _imports} = Config.Reader.read_imports!(@config, env: :prod)

    outdir =
      config
      |> Keyword.fetch!(:duskmoon_bundler_runtime)
      |> Keyword.fetch!(:fornacast_web)
      |> Keyword.fetch!(:outdir)

    assert outdir == "priv/static/assets"
    assert Path.type(outdir) == :relative

    e2e_workflow = File.read!(@e2e_workflow)

    assert e2e_workflow =~ "rm -rf apps/fornacast_web/priv/static"
    assert e2e_workflow =~ ~s(grep -oE '<link[^>]*rel="stylesheet"[^>]*>')
    assert e2e_workflow =~ ~s(grep -oE '<script[^>]*type="module"[^>]*>')
    assert e2e_workflow =~ "> e2e-data/app.css"
    assert e2e_workflow =~ ~s(grep -F '.auth-shell' e2e-data/app.css)

    assert_order(
      e2e_workflow,
      "cp -a _build/prod/rel/fornacast release/fornacast",
      "rm -rf apps/fornacast_web/priv/static"
    )
  end

  test "release and E2E builds compile PostgreSQL with adapter-qualified caches" do
    for path <- [@workflow, @e2e_workflow] do
      workflow = File.read!(path)

      assert workflow =~ "FORNACAST_DATABASE_ADAPTER: postgres"
      assert workflow =~ ~r/key:.*-postgres-.*hashFiles/s
      assert workflow =~ ~r/restore-keys:\s*\|\s*\n\s*.*-postgres-/
      refute workflow =~ "FORNACAST_DATABASE_ADAPTER: turso"
    end

    e2e_workflow = File.read!(@e2e_workflow)

    assert e2e_workflow =~
             ~r/- name: Fetch dependencies\s+if: github\.event_name == 'pull_request'\s+run: mix deps\.get --only prod\s+- name: Clean cached project artifacts\s+if: github\.event_name == 'pull_request'\s+run: mix clean\s+- name: Compile dependencies/s
  end

  test "installed-release E2E uses PostgreSQL component mode and preserves protocol probes" do
    workflow = File.read!(@e2e_workflow)
    prepare_step = workflow_step!(workflow, "Prepare e2e environment", "Start release")

    assert workflow =~ ~r/^run-name:.*inputs\.version/m
    assert workflow =~ ~r/^permissions:\n  contents: read\n  packages: read\n/m
    assert workflow =~ "FORNACAST_DATABASE_ADAPTER: postgres"
    refute workflow =~ "FORNACAST_DATABASE_PATH"

    assert workflow =~
             ~r/release-smoke:\s*\n\s+name: Release Smoke\s*\n\s+runs-on: ubuntu-24\.04\s*\n\s+services:\s*\n\s+postgres:\s*\n\s+image: postgres:17\s*\n\s+env:\s*\n\s+POSTGRES_DB: fornacast_e2e\s*\n\s+POSTGRES_USER: fornacast\s*\n\s+POSTGRES_PASSWORD: fornacast_e2e_password\s*\n\s+ports:\s*\n\s+- 5432:5432\s*\n\s+options: >-\s*\n\s+--health-cmd "pg_isready -U fornacast -d fornacast_e2e"\s*\n\s+--health-interval 5s\s*\n\s+--health-timeout 5s\s*\n\s+--health-retries 20/s

    assert workflow =~ "POSTGRES_HOST: 127.0.0.1"
    assert workflow =~ ~r/POSTGRES_PORT: ["']5432["']/
    assert workflow =~ "POSTGRES_DB: fornacast_e2e"
    assert workflow =~ "POSTGRES_USER: fornacast"
    assert workflow =~ "POSTGRES_PASSWORD: fornacast_e2e_password"

    assert workflow =~
             "FORNACAST_CONFIG_DATABASE_PATH=${GITHUB_WORKSPACE}/e2e-data/fornacast_config.db"

    assert prepare_step =~
             ~S|legacy_turso_path="${GITHUB_WORKSPACE}/e2e-data/missing-legacy.db"|

    assert prepare_step =~ ~S|test ! -e "$legacy_turso_path"|

    assert prepare_step =~
             ~S|echo "FORNACAST_LEGACY_TURSO_DATABASE_PATH=$legacy_turso_path"|

    refute workflow =~ "FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA"

    assert_order(
      prepare_step,
      ~S|test ! -e "$legacy_turso_path"|,
      "FORNACAST_LEGACY_TURSO_DATABASE_PATH"
    )

    assert_order(workflow, ~S|test ! -e "$legacy_turso_path"|, "- name: Start release")

    assert workflow =~ "mix release fornacast --overwrite"
    assert workflow =~ "gh release download \"v${VERSION}\""
    assert workflow =~ "release/fornacast/bin/fornacast start"
    assert workflow =~ ~s(curl -fsS "http://127.0.0.1:${PORT}/health")
    assert workflow =~ ~s(curl -fsS "http://127.0.0.1:${FORNACAST_API_PORT}/health")
    assert workflow =~ "release/fornacast/bin/fornacast rpc '"
    assert workflow =~ "ssh://alice@127.0.0.1:${FORNACAST_SSH_PORT}/alice/demo.git"
    assert workflow =~ ~s(grep -oE '<link[^>]*rel="stylesheet"[^>]*>')
    assert workflow =~ ~s(grep -oE '<script[^>]*type="module"[^>]*>')
    assert workflow =~ "timeout 45 release/fornacast/bin/fornacast stop"
    assert workflow =~ "release/fornacast/bin/fornacast start > fornacast-restart.log"
    assert workflow =~ "release_asset_storage_smoke.sh release/fornacast write"
    assert workflow =~ "release_asset_storage_smoke.sh release/fornacast verify"
  end

  test "workflow dispatch normalizes one version for every published artifact selector" do
    workflow = File.read!(@e2e_workflow)

    resolve_step =
      workflow_step!(workflow, "Resolve published release version", "Download release artifact")

    download_step =
      workflow_step!(workflow, "Download release artifact", "Extract release artifact")

    extract_step = workflow_step!(workflow, "Extract release artifact", "Prepare e2e environment")

    compose_step =
      workflow_step!(workflow, "Verify default Compose distribution", "Stop release")

    assert resolve_step =~ "if: github.event_name == 'workflow_dispatch'"
    assert resolve_step =~ "id: dispatch_version"
    assert resolve_step =~ ~s(VERSION_INPUT: ${{ inputs.version }})
    assert resolve_step =~ ~S|version="$(scripts/resolve_release_version.sh "$VERSION_INPUT")"|
    assert resolve_step =~ ~S|echo "version=$version" >> "$GITHUB_OUTPUT"|

    assert length(:binary.matches(workflow, "scripts/resolve_release_version.sh")) == 1
    assert length(:binary.matches(workflow, "inputs.version")) == 2

    normalized_version = ~s(VERSION: ${{ steps.dispatch_version.outputs.version }})

    assert length(:binary.matches(workflow, normalized_version)) == 3

    for step <- [download_step, extract_step, compose_step] do
      assert step =~ normalized_version
      refute step =~ "inputs.version"
    end

    assert download_step =~ ~s(gh release download "v${VERSION}")
    assert download_step =~ ~s(--pattern "fornacast-${VERSION}-linux-x86_64.tar.gz")

    assert extract_step =~
             ~s(tar -xzf "artifacts/fornacast-${VERSION}-linux-x86_64.tar.gz" -C release)

    assert compose_step =~ ~s(export FORNACAST_IMAGE="ghcr.io/gsmlg-dev/fornacast:${VERSION}")
    refute compose_step =~ "scripts/resolve_release_version.sh"
  end

  test "E2E proves the default Compose distribution independently" do
    workflow = File.read!(@e2e_workflow)
    compose_step = workflow_step!(workflow, "Verify default Compose distribution", "Stop release")

    assert workflow =~
             ~r/- name: Log in to GHCR for published image\s+if: github\.event_name == 'workflow_dispatch'\s+uses: docker\/login-action@v3\s+with:\s+registry: ghcr\.io\s+username: \$\{\{ github\.actor \}\}\s+password: \$\{\{ github\.token \}\}/s

    assert compose_step =~
             ~s(compose_project="fornacast-e2e-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}")

    assert compose_step =~ "^fornacast-e2e-[0-9]+-[0-9]+$"
    assert compose_step =~ "export COMPOSE_PROJECT_NAME=$compose_project"
    assert compose_step =~ ~S|export SECRET_KEY_BASE="$(openssl rand -hex 32)"|
    assert compose_step =~ "export FORNACAST_BASE_URL=http://127.0.0.1:4000"

    assert compose_step =~
             "export FORNACAST_CONFIG_DATABASE_PATH=/data/fornacast_config.db"

    assert compose_step =~ "export FORNACAST_SSH_HOST=localhost"
    assert compose_step =~ "export FORNACAST_SSH_PORT=2222"
    assert compose_step =~ "export POSTGRES_DB=fornacast_compose_e2e"
    assert compose_step =~ "export POSTGRES_USER=fornacast"
    assert compose_step =~ ~S|export POSTGRES_PASSWORD="$(openssl rand -hex 24)"|
    assert compose_step =~ "trap cleanup EXIT"
    assert compose_step =~ "docker compose down -v --remove-orphans"

    assert compose_step =~ ~S|case "$GITHUB_EVENT_NAME" in|
    assert compose_step =~ "pull_request)"
    assert compose_step =~ "workflow_dispatch)"

    assert compose_step =~ "docker build \\\n"
    assert compose_step =~ "--build-arg FORNACAST_DATABASE_ADAPTER=postgres"
    assert compose_step =~ ~s(--tag "fornacast-e2e:${GITHUB_SHA}")
    assert compose_step =~ ~s(export FORNACAST_IMAGE="fornacast-e2e:${GITHUB_SHA}")
    assert compose_step =~ ~s(export FORNACAST_IMAGE="ghcr.io/gsmlg-dev/fornacast:${VERSION}")

    assert length(
             :binary.matches(
               compose_step,
               "docker compose up -d --no-build --wait --wait-timeout 180"
             )
           ) == 2

    assert length(
             :binary.matches(compose_step, "scripts/api_proxy_smoke.sh http://127.0.0.1:4000")
           ) ==
             2

    assert compose_step =~ "docker compose exec -T app /app/bin/fornacast rpc '"
    assert compose_step =~ "ForgeAccounts.create_first_admin"
    assert compose_step =~ "ForgeAccounts.create_api_key"
    assert compose_step =~ "ForgeAccounts.create_ssh_key"
    assert compose_step =~ "ForgeRepos.create_repository"
    assert compose_step =~ "ssh://compose@127.0.0.1:2222/compose/compose-demo.git"
    assert compose_step =~ "git -C compose-e2e/compose-demo push -u origin main"

    assert compose_step =~
             "docker compose exec -T app /app/bin/release_asset_storage_smoke /app write"

    assert compose_step =~ ~S|mapfile -t old_app_ids < <(docker compose ps -q app)|
    assert compose_step =~ ~S|test "${#old_app_ids[@]}" -eq 1|
    assert compose_step =~ ~S|old_app_id="${old_app_ids[0]}"|
    assert compose_step =~ "docker compose stop --timeout 45 app"

    assert compose_step =~
             ~S|test "$(docker container inspect -f '{{.State.Running}}' "$old_app_id")" = false|

    assert compose_step =~
             ~S|test "$(docker container inspect -f '{{.State.ExitCode}}' "$old_app_id")" = 0|

    assert compose_step =~
             ~S|test "$(docker container inspect -f '{{.State.OOMKilled}}' "$old_app_id")" = false|

    assert compose_step =~ "docker compose rm -f app"
    assert compose_step =~ ~S|! docker container inspect "$old_app_id" >/dev/null 2>&1|
    assert compose_step =~ "docker compose up -d --no-build --wait --wait-timeout 180 app"
    assert compose_step =~ "docker compose restart nginx"
    assert compose_step =~ ~S|mapfile -t new_app_ids < <(docker compose ps -q app)|
    assert compose_step =~ ~S|test "${#new_app_ids[@]}" -eq 1|
    assert compose_step =~ ~S|new_app_id="${new_app_ids[0]}"|
    assert compose_step =~ ~S|test "$new_app_id" != "$old_app_id"|
    refute compose_step =~ "docker compose restart app"

    assert compose_step =~
             "docker compose exec -T app /app/bin/release_asset_storage_smoke /app verify"

    refute compose_step =~ "docker run"

    assert_order(compose_step, "esac", "docker compose up -d --no-build")
    assert_order(compose_step, "create_api_key", "git -C compose-e2e/compose-demo push")
    assert_order(compose_step, "git -C compose-e2e/compose-demo push", "/app write")
    assert_order(compose_step, "/app write", "old_app_id=")
    assert_order(compose_step, "old_app_id=", "docker compose stop --timeout 45 app")
    assert_order(compose_step, ".State.OOMKilled", "docker compose rm -f app")

    assert_order(
      compose_step,
      "docker compose rm -f app",
      ~S|! docker container inspect "$old_app_id"|
    )

    assert_order(
      compose_step,
      ~S|! docker container inspect "$old_app_id"|,
      "docker compose up -d --no-build --wait --wait-timeout 180 app"
    )

    [_, recreated_app] =
      String.split(
        compose_step,
        "docker compose up -d --no-build --wait --wait-timeout 180 app",
        parts: 2
      )

    assert_order(recreated_app, "docker compose restart nginx", "scripts/api_proxy_smoke.sh")
    assert_order(compose_step, ~S|test "$new_app_id" != "$old_app_id"|, "/app verify")
    assert_order(compose_step, "/app verify", "StrictHostKeyChecking=yes")
  end

  test "Compose image selection is mutually exclusive and fails closed by event" do
    workflow = File.read!(@e2e_workflow)
    compose_step = workflow_step!(workflow, "Verify default Compose distribution", "Stop release")

    [selection, _running_proof] =
      String.split(
        compose_step,
        "docker compose up -d --no-build --wait --wait-timeout 180\n",
        parts: 2
      )

    [_, event_case] = String.split(selection, ~S|case "$GITHUB_EVENT_NAME" in|, parts: 2)

    [pull_request_arm, dispatch_and_fallback] =
      String.split(event_case, "workflow_dispatch)", parts: 2)

    [dispatch_arm, fallback_arm] = String.split(dispatch_and_fallback, "*)", parts: 2)

    assert pull_request_arm =~ "pull_request)"
    assert pull_request_arm =~ "docker build"
    assert pull_request_arm =~ ~s(export FORNACAST_IMAGE="fornacast-e2e:${GITHUB_SHA}")
    refute pull_request_arm =~ "ghcr.io/gsmlg-dev/fornacast"

    assert dispatch_arm =~ ~s(export FORNACAST_IMAGE="ghcr.io/gsmlg-dev/fornacast:${VERSION}")
    refute dispatch_arm =~ "docker build"
    refute dispatch_arm =~ "fornacast-e2e:${GITHUB_SHA}"

    assert fallback_arm =~ "exit 64"
    assert length(:binary.matches(compose_step, "docker build")) == 1

    assert length(
             :binary.matches(
               compose_step,
               ~s(export FORNACAST_IMAGE="fornacast-e2e:${GITHUB_SHA}")
             )
           ) == 1

    assert length(
             :binary.matches(
               compose_step,
               ~s(export FORNACAST_IMAGE="ghcr.io/gsmlg-dev/fornacast:${VERSION}")
             )
           ) == 1

    assert_order(selection, "pull_request)", "workflow_dispatch)")
    assert_order(selection, "workflow_dispatch)", "*)")
    assert_order(selection, "*)", "esac")
  end

  test "Compose env template requires a generated 64-byte cookie secret" do
    env_example = File.read!(@env_example)

    assert env_example =~ ~r/^SECRET_KEY_BASE=$/m
    assert env_example =~ "openssl rand -hex 32"
  end

  test "published image and default Compose deployment use PostgreSQL component mode" do
    dockerfile = File.read!(@dockerfile)
    compose = File.read!(@compose)
    env_example = File.read!(@env_example)

    assert dockerfile =~ "ARG FORNACAST_DATABASE_ADAPTER=postgres"

    [_, runtime_stage] = String.split(dockerfile, "FROM ${DEBIAN_IMAGE} AS app", parts: 2)
    [runtime_packages, _] = String.split(runtime_stage, "useradd --create-home", parts: 2)

    assert "curl" in String.split(runtime_packages)
    assert runtime_stage =~ ~r/^[ \t]+FORNACAST_DATABASE_ADAPTER=postgres \\$/m

    assert runtime_stage =~
             ~r/^[ \t]+FORNACAST_CONFIG_DATABASE_PATH=\/data\/fornacast_config\.db \\$/m

    assert runtime_stage =~
             ~r/^[ \t]+FORNACAST_LEGACY_TURSO_DATABASE_PATH=\/data\/fornacast\.db \\$/m

    refute runtime_stage =~ ~r/^[ \t]+FORNACAST_DATABASE_PATH=/m

    app = compose_service!(compose, "app")
    db = compose_service!(compose, "db")
    nginx = compose_service!(compose, "nginx")

    assert_order(compose, "  app:\n", "  db:\n")
    assert_order(compose, "  db:\n", "  nginx:\n")

    assert app =~
             ~r/build:\s*\n\s+context: \.\s*\n\s+args:\s*\n\s+FORNACAST_DATABASE_ADAPTER: postgres/s

    assert app =~ ~r/environment:\s*\n\s+FORNACAST_DATABASE_ADAPTER: postgres/s
    assert app =~ "POSTGRES_HOST: db"
    assert app =~ "POSTGRES_PORT: 5432"
    assert app =~ ~S|POSTGRES_DB: ${POSTGRES_DB:?set POSTGRES_DB}|
    assert app =~ ~S|POSTGRES_USER: ${POSTGRES_USER:?set POSTGRES_USER}|
    assert app =~ ~S|POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}|
    assert app =~ "FORNACAST_CONFIG_DATABASE_PATH:"
    assert app =~ "FORNACAST_CONFIG_TURSO_DATABASE_URL:"
    assert app =~ "FORNACAST_CONFIG_TURSO_AUTH_TOKEN:"
    refute app =~ ~r/^\s+DATABASE_URL:/m
    refute app =~ ~r/^\s+FORNACAST_DATABASE_PATH:/m
    refute app =~ ~r/^\s+TURSO_DATABASE_URL:/m
    refute app =~ ~r/^\s+TURSO_AUTH_TOKEN:/m
    assert app =~ ~r/depends_on:\s*\n\s+db:\s*\n\s+condition: service_healthy/s

    assert app =~
             "curl -fsS http://127.0.0.1:4890/health >/dev/null && curl -fsS http://127.0.0.1:4891/health >/dev/null"

    assert db =~ "image: postgres:17"
    refute db =~ "profiles:"
    assert db =~ ~S|POSTGRES_DB: ${POSTGRES_DB:?set POSTGRES_DB}|
    assert db =~ ~S|POSTGRES_USER: ${POSTGRES_USER:?set POSTGRES_USER}|
    assert db =~ ~S|POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}|
    assert db =~ ~S|pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}|
    assert nginx =~ ~r/depends_on:\s*\n\s+app:\s*\n\s+condition: service_healthy/s

    assert length(:binary.matches(compose, ~S|POSTGRES_DB: ${POSTGRES_DB:?set POSTGRES_DB}|)) ==
             2

    assert length(
             :binary.matches(compose, ~S|POSTGRES_USER: ${POSTGRES_USER:?set POSTGRES_USER}|)
           ) == 2

    assert length(
             :binary.matches(
               compose,
               ~S|POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}|
             )
           ) == 2

    assert compose =~ ~r/^  fornacast-data:\s*$/m
    assert compose =~ ~r/^  postgres-data:\s*$/m

    assert env_example =~ ~r/^SECRET_KEY_BASE=$/m
    assert env_example =~ ~r/^POSTGRES_DB=fornacast_prod$/m
    assert env_example =~ ~r/^POSTGRES_USER=fornacast$/m
    assert env_example =~ ~r/^POSTGRES_PASSWORD=$/m

    assert env_example =~
             "# Concord config store (separate from the PostgreSQL domain database)."

    assert env_example =~ ~r/^FORNACAST_CONFIG_DATABASE_PATH=\/data\/fornacast_config\.db$/m
    assert env_example =~ ~r/^FORNACAST_CONFIG_TURSO_DATABASE_URL=$/m
    assert env_example =~ ~r/^FORNACAST_CONFIG_TURSO_AUTH_TOKEN=$/m
    refute env_example =~ ~r/^FORNACAST_DATABASE_PATH=/m
    refute env_example =~ ~r/^TURSO_DATABASE_URL=/m
    refute env_example =~ ~r/^TURSO_AUTH_TOKEN=/m
    refute env_example =~ ~r/^DATABASE_URL=/m
  end

  test "Compose propagates the legacy Turso acknowledgement only when explicitly set" do
    blank_environment = compose_app_environment(nil)
    acknowledged_environment = compose_app_environment("true")

    assert blank_environment["FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA"] == ""
    assert acknowledged_environment["FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA"] == "true"

    env_example = File.read!(@env_example)
    assert env_example =~ ~r/^FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=$/m

    assert env_example =~
             "Leave acknowledgement blank. Set it to true only after intentionally backing up and completing the legacy Turso transition."
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
    deploy_notes = release_deploy_notes!(workflow)

    assert workflow =~ "cat > release-notes.md <<'EOF'"

    assert_order(
      workflow,
      @deploy_notes_start,
      "## Deploy with Docker Compose"
    )

    assert_order(
      workflow,
      "## Deploy with Docker Compose",
      @deploy_notes_end
    )

    assert deploy_notes =~ "## Deploy with Docker Compose"
    assert deploy_notes =~ "ghcr.io/gsmlg-dev/fornacast:{{VERSION}}"
    assert deploy_notes =~ "ghcr.io/gsmlg-dev/fornacast:latest"
    assert deploy_notes =~ "anonymous pulls work only when the package is public"
    assert deploy_notes =~ "`read:packages`"
    assert deploy_notes =~ "GHCR_USERNAME"
    assert deploy_notes =~ "GHCR_READ_TOKEN"
    assert deploy_notes =~ ~s(docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin)

    assert deploy_notes =~
             ~s(FORNACAST_IMAGE=ghcr.io/gsmlg-dev/fornacast@${{ steps.docker.outputs.digest }})

    assert_contains_all(deploy_notes, [
      "PostgreSQL 17",
      "supported domain database",
      "Default Compose uses complete PostgreSQL component mode",
      "POSTGRES_DB",
      "POSTGRES_USER",
      "POSTGRES_PASSWORD",
      "exactly one PostgreSQL connection mode",
      "Non-Compose",
      "external PostgreSQL providers",
      "URL mode",
      "nonempty `DATABASE_URL`",
      "component mode",
      "POSTGRES_HOST",
      "POSTGRES_PORT",
      "mutually exclusive",
      "Concord's separate embedded Turso/VSR configuration store",
      "not the Ecto domain database",
      "dormant compile-only",
      "not a supported runtime or release database",
      "FORNACAST_LEGACY_TURSO_DATABASE_PATH",
      "FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true",
      "does not automatically migrate",
      "scripts/compose_backup.sh BACKUP_DIR",
      "scripts/compose_restore.sh BACKUP_DIR --confirm-destroy",
      "paired backup",
      "PostgreSQL dump",
      "`fornacast-data`",
      "`postgres-data`",
      "PostgreSQL domain database",
      "repositories, SSH keys, LocalCAS release assets",
      "ports `4890` or `4891` directly"
    ])

    assert deploy_notes =~ "docker compose pull app nginx"
    assert deploy_notes =~ "docker compose up -d --no-build"
    assert deploy_notes =~ "keep public port `4000` blocked"
    assert deploy_notes =~ "locally or through an SSH tunnel"
    assert deploy_notes =~ "`/setup`"
    refute_obsolete_database_claims(deploy_notes)

    assert_order(
      deploy_notes,
      "keep public port `4000` blocked",
      "docker compose up -d --no-build"
    )
  end

  test "release note block documents complete external PostgreSQL component mode" do
    deploy_notes = @workflow |> File.read!() |> release_deploy_notes!()

    assert_contains_all(deploy_notes, [
      "Component mode requires nonempty `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD`",
      "`POSTGRES_PORT` is optional and defaults to `5432`"
    ])
  end

  test "release note block acknowledges legacy data only after a completed decision" do
    deploy_notes = @workflow |> File.read!() |> release_deploy_notes!()

    assert deploy_notes =~
             "only after the legacy database was intentionally migrated or abandoned"
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
             "FORNACAST_IMAGE='ghcr.io/gsmlg-dev/fornacast@sha256:REPLACE_WITH_POSTGRESQL_FIRST_RELEASE_DIGEST'"

    assert_contains_all(readme, [
      "digest printed on the GitHub release page",
      "PostgreSQL-first GitHub release",
      "`latest` is mutable and must not be treated as an immutable deployment pin"
    ])

    assert readme =~ "anonymous pulls work only when the package is public"
    assert readme =~ "`read:packages`"
    assert readme =~ "GHCR_USERNAME"
    assert readme =~ "GHCR_READ_TOKEN"
    assert readme =~ ~s(docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin)
    refute readme =~ "supports Turso/libSQL only"
    assert readme =~ "keep public port `4000` blocked"
    assert readme =~ "locally or through an SSH tunnel"
    refute readme =~ "immutable versioned image"
    refute readme =~ "repeatable production deployment"
    refute readme =~ ":0.1.3"

    refute readme =~
             ~r/FORNACAST_IMAGE=["']?ghcr\.io\/gsmlg-dev\/fornacast:\d+\.\d+\.\d+/
  end

  test "operator and contributor docs make PostgreSQL 17 the supported default" do
    readme = File.read!(@readme)
    agents = File.read!(@agents)
    release_notes = @workflow |> File.read!() |> release_deploy_notes!()

    assert_contains_all(readme, [
      "PostgreSQL 17 is the supported/default Fornacast domain database",
      "development, test, Docker Compose, CI, E2E, and releases",
      "Concord's separate embedded Turso/VSR configuration store",
      "not the Ecto domain database"
    ])

    assert_contains_all(agents, [
      "PostgreSQL 17",
      "supported/default domain database",
      "Concord's separate embedded Turso/VSR configuration store",
      "not the Ecto domain database"
    ])

    for source <- [readme, agents, release_notes] do
      refute_obsolete_database_claims(source)
      refute source =~ ~r/^\s*FORNACAST_DATABASE_ADAPTER=turso\b/m
    end

    for source <- [readme, release_notes] do
      assert_contains_all(source, [
        "PostgreSQL 17",
        "POSTGRES_DB",
        "POSTGRES_USER",
        "POSTGRES_PASSWORD",
        "FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true",
        "scripts/compose_backup.sh",
        "scripts/compose_restore.sh",
        "`postgres-data`",
        "`fornacast-data`"
      ])

      refute source =~ "supports Turso/libSQL only"
      refute source =~ "PostgreSQL requires a source build"
    end
  end

  test "README documents local and external PostgreSQL operation" do
    readme = File.read!(@readme)

    assert_contains_all(readme, [
      "devenv processes up -d --strict-ports postgres",
      "devenv processes wait --timeout 120",
      "devenv shell -- mix ecto.setup",
      "devenv shell -- mix fornacast.run",
      "Unix socket",
      "55432",
      "`fornacast_dev`",
      "`fornacast_test`",
      "`mix clean`",
      "exactly one PostgreSQL connection mode",
      "**URL mode:**",
      "**Component mode:**",
      "nonempty `DATABASE_URL`",
      "nonempty `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD`",
      "`POSTGRES_PORT` defaults to `5432`",
      "Mixed, partial, and explicitly blank configurations are invalid",
      "password is passed as the exact component value",
      "Do not reconstruct a URI from component values",
      "runtime adapter must match the compiled PostgreSQL adapter",
      "preflight runs before automatic migrations",
      "readiness succeeds only after migrations"
    ])
  end

  test "README separates development and test PostgreSQL database selection" do
    readme = File.read!(@readme)

    development =
      markdown_section!(
        readme,
        "### Development database connection",
        "### Test database connection"
      )

    test =
      markdown_section!(
        readme,
        "### Test database connection",
        "### PostgreSQL connection modes"
      )

    assert_contains_all(development, [
      "`PGHOST` / `POSTGRES_HOST`",
      "`PGPORT` / `POSTGRES_PORT`",
      "`PGDATABASE` / `POSTGRES_DB`",
      "`PGUSER` / `POSTGRES_USER`",
      "`PGPASSWORD` / `POSTGRES_PASSWORD`"
    ])

    assert_contains_all(test, [
      "`PGHOST` / `POSTGRES_HOST`",
      "`PGPORT` / `POSTGRES_PORT`",
      "`PGUSER` / `POSTGRES_USER`",
      "`PGPASSWORD` / `POSTGRES_PASSWORD`",
      "`POSTGRES_TEST_DB`, default `fornacast_test`",
      "Tests do not use `PGDATABASE` or `POSTGRES_DB` as the database name"
    ])

    refute test =~ "`PGDATABASE` / `POSTGRES_DB`"
  end

  test "README documents Compose topology and paired recovery" do
    readme = File.read!(@readme)

    assert_contains_all(readme, [
      "app waits for the PostgreSQL health check",
      "nginx waits for the app health check",
      "both internal health endpoints on `4890` and `4891`",
      "Compose requires `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` from `.env`",
      "public ports are `4000` for HTTP and `2222` for SSH",
      "ports `4890` and `4891` remain unpublished",
      "scripts/compose_backup.sh BACKUP_DIR",
      "scripts/compose_restore.sh BACKUP_DIR --confirm-destroy",
      "`fornacast.dump`",
      "`fornacast-data.tgz`",
      "`SHA256SUMS`",
      "same maintenance window",
      "recovery lock",
      "fail closed",
      "Restore is destructive",
      "`postgres-data` volume stores the PostgreSQL domain database",
      "`fornacast-data` volume stores Git repositories, SSH material, LocalCAS release assets",
      "back up PostgreSQL and `fornacast-data` together",
      "captures only the paired PostgreSQL domain dump and local `fornacast-data` volume",
      "does not capture `.env` or external secrets",
      "never store them as plaintext in `BACKUP_DIR`",
      "FORNACAST_GITHUB_CREDENTIAL_KEYS",
      "FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID",
      "required to decrypt saved GitHub PATs",
      "SECRET_KEY_BASE",
      "PostgreSQL connection credentials",
      "Concord/Turso connection credentials",
      "provider-native backup or snapshot",
      "remote Concord/Turso state"
    ])

    refute readme =~ "fornacast_fornacast-data:/data"
    refute readme =~ "docker run --rm -v"
  end

  test "README documents dormant Turso compatibility and the legacy transition" do
    readme = File.read!(@readme)

    assert_contains_all(readme, [
      "dormant compile-only source compatibility",
      "not a supported runtime, release, or acceptance database",
      "current full schema cannot be installed",
      "concord#90",
      "FORNACAST_LEGACY_TURSO_DATABASE_PATH",
      "default `/data/fornacast.db`",
      "PostgreSQL release preflight",
      "before automatic migrations",
      "back up the legacy file",
      "only set `FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=true`",
      "No automatic Turso-to-PostgreSQL migration or import is performed",
      "Remove or archive the legacy file"
    ])
  end

  test "environment example is secret-free and separates the two database roles" do
    env_example = File.read!(@env_example)

    assert env_example =~ ~r/^SECRET_KEY_BASE=$/m
    assert env_example =~ ~r/^FORNACAST_GITHUB_CREDENTIAL_KEYS=$/m
    assert env_example =~ ~r/^FORNACAST_GITHUB_CREDENTIAL_ACTIVE_KEY_ID=$/m
    assert env_example =~ ~r/^POSTGRES_DB=fornacast_prod$/m
    assert env_example =~ ~r/^POSTGRES_USER=fornacast$/m
    assert env_example =~ ~r/^POSTGRES_PASSWORD=$/m
    assert env_example =~ ~r/^FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA=$/m

    assert_contains_all(env_example, [
      "PostgreSQL domain database used by the default Compose deployment",
      "Concord config store (separate from the PostgreSQL domain database)",
      "embedded Turso/VSR configuration store",
      "legacy Ecto path defaults to /data/fornacast.db"
    ])

    refute env_example =~ ~r/^DATABASE_URL=/m
  end

  test "release assets ship core LocalCAS without an S3 listener" do
    dockerfile = File.read!(@dockerfile)
    compose = File.read!(@compose)
    env_example = File.read!(@env_example)
    readme = File.read!(@readme)
    e2e = File.read!(@e2e_workflow)

    [_, runtime_stage] = String.split(dockerfile, "FROM ${DEBIAN_IMAGE} AS app", parts: 2)
    [runtime_packages, _] = String.split(runtime_stage, "useradd --create-home", parts: 2)

    assert dockerfile =~ "FORNACAST_RELEASE_ASSET_STORAGE_ROOT=/data/release-assets"
    assert runtime_stage =~ "LANG=C.UTF-8"
    assert "coreutils" in String.split(runtime_packages)
    assert File.read!(@releases_mix) =~ ~s({:ex_storage_service, "== 0.6.4"})
    assert dockerfile =~ "scripts/release_asset_storage_smoke.sh"
    refute dockerfile =~ "COPY scripts scripts"
    assert dockerfile =~ "RELEASE_DISTRIBUTION=name"
    assert dockerfile =~ "RELEASE_NODE=fornacast@127.0.0.1"
    assert dockerfile =~ ~s(ELIXIR_ERL_OPTIONS="-kernel inet_dist_use_interface {127,0,0,1}")
    assert dockerfile =~ "ERL_EPMD_ADDRESS=127.0.0.1"
    assert compose =~ "FORNACAST_RELEASE_ASSET_STORAGE_ROOT: /data/release-assets"
    assert compose =~ "stop_grace_period: 45s"
    assert compose =~ "RELEASE_DISTRIBUTION: name"
    assert compose =~ "RELEASE_NODE: fornacast@127.0.0.1"
    assert compose =~ "ELIXIR_ERL_OPTIONS: -kernel inet_dist_use_interface {127,0,0,1}"
    assert compose =~ "ERL_EPMD_ADDRESS: 127.0.0.1"
    assert env_example =~ "FORNACAST_RELEASE_ASSET_MAX_BYTES=2147483648"
    assert readme =~ "one Fornacast BEAM with exclusive use of"
    assert readme =~ "one volume"
    assert readme =~ "back up PostgreSQL and"
    assert readme =~ "`fornacast-data` together"
    assert readme =~ "uses `fornacast@127.0.0.1` by default"
    assert readme =~ "release acceptance smoke"
    assert readme =~ "exercises"
    assert readme =~ "Erlang distribution and EPMD are bound to loopback"
    refute dockerfile =~ "EXPOSE 9000"
    refute compose =~ ~r/^\s+- ["']?9000/m
    assert e2e =~ "ex_storage_service-0.6.4"
    assert e2e =~ "release_asset_storage_smoke.sh release/fornacast write"
    assert e2e =~ "release_asset_storage_smoke.sh release/fornacast verify"
    assert e2e =~ ~s(echo "ELIXIR_ERL_OPTIONS=-kernel inet_dist_use_interface {127,0,0,1}")
    assert e2e =~ ~s(echo "ERL_EPMD_ADDRESS=127.0.0.1")
    assert e2e =~ "- name: Seed release data"
    assert e2e =~ "release/fornacast/bin/fornacast rpc '"
    refute e2e =~ "release/fornacast/bin/fornacast eval '"
    refute e2e =~ "Enum.each([:git_core, :fornacast, :forge_accounts, :forge_repos]"
    assert e2e =~ "docker compose exec -T app /app/bin/release_asset_storage_smoke /app write"
    assert e2e =~ "docker compose exec -T app /app/bin/release_asset_storage_smoke /app verify"
    assert e2e =~ "docker compose stop --timeout 45 app"
    assert e2e =~ "docker compose rm -f app"
    assert e2e =~ "docker compose up -d --no-build --wait --wait-timeout 180 app"
    refute e2e =~ "docker compose restart app"
    assert e2e =~ "docker compose down -v --remove-orphans"

    assert length(
             :binary.matches(
               e2e,
               "true = ExStorageService.Cluster.Readiness.ready?(timeout: 1_000)"
             )
           ) == 2

    assert length(
             :binary.matches(
               e2e,
               "true = ForgeReleases.AssetStorage.Manager.ready?()"
             )
           ) == 2

    assert length(:binary.matches(e2e, "true = Node.self() == :\"fornacast_e2e@127.0.0.1\"")) ==
             2

    assert e2e =~ "s3_package=\"$(find release/fornacast/lib"
    assert e2e =~ "listeners=\"$(ss -ltn)\""
    refute e2e =~ "test -z \"$(find release/fornacast/lib"
    refute e2e =~ "! ss -ltn |"
    refute e2e =~ "ss -ltnp"
    refute e2e =~ "| grep true"
    refute e2e =~ "docker run"
    refute e2e =~ "RELEASE_COOKIE"
    refute dockerfile =~ "RELEASE_COOKIE"
    refute compose =~ "RELEASE_COOKIE"
    refute env_example =~ "RELEASE_COOKIE"
    refute dockerfile =~ ~r/^EXPOSE\b[^\n]*\b4369\b/m
    refute compose =~ ~r/^\s+- ["']?4369["']?\s*$/m
    refute compose =~ ~r/^\s+- ["']?(4369|[0-9]+-[0-9]+):/m
    assert_order(e2e, "release/fornacast write", "release/fornacast verify")
    assert_order(e2e, "- name: Start release", "- name: Seed release data")
    assert_order(e2e, "- name: Wait for health", "- name: Seed release data")
    assert_order(e2e, "/app write", "docker compose stop --timeout 45 app")

    assert_order(
      e2e,
      "docker compose up -d --no-build --wait --wait-timeout 180 app",
      "/app verify"
    )
  end

  test "production validates and clamps release-asset limits" do
    {output, status} = read_runtime_storage_config("2147483649", "3600")
    assert status == 0
    assert output =~ "max=2147483648 grace=3600"

    {invalid_max_output, invalid_max_status} = read_runtime_storage_config("0", "3600")
    assert invalid_max_status != 0

    assert invalid_max_output =~
             "FORNACAST_RELEASE_ASSET_MAX_BYTES must be a decimal integer >= 1"

    {invalid_grace_output, invalid_grace_status} = read_runtime_storage_config("1", "3599")
    assert invalid_grace_status != 0

    assert invalid_grace_output =~
             "FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS must be a decimal integer >= 3600"
  end

  defp assert_order(source, first, second) do
    assert position!(source, first) < position!(source, second),
           "expected #{inspect(first)} to appear before #{inspect(second)}"
  end

  defp release_deploy_notes!(workflow) do
    lines = String.split(workflow, "\n")

    start_indexes = marker_indexes(lines, @deploy_notes_start)
    end_indexes = marker_indexes(lines, @deploy_notes_end)

    assert [start_index] = start_indexes
    assert [end_index] = end_indexes
    assert start_index < end_index

    lines
    |> Enum.slice(start_index + 1, end_index - start_index - 1)
    |> Enum.join("\n")
  end

  defp marker_indexes(lines, marker) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      if String.trim(line) == marker, do: [index], else: []
    end)
  end

  defp markdown_section!(source, start_heading, end_heading) do
    with [_, after_start] <- String.split(source, start_heading, parts: 2),
         [section, _after_end] <- String.split(after_start, end_heading, parts: 2) do
      section
    else
      _missing -> flunk("missing Markdown section from #{start_heading} to #{end_heading}")
    end
  end

  defp refute_obsolete_database_claims(source) do
    normalized_source = normalize_whitespace(source)

    for pattern <- @obsolete_database_claims do
      refute normalized_source =~ pattern,
             "found obsolete database claim matching #{inspect(pattern)}"
    end
  end

  defp assert_contains_all(source, values) do
    normalized_source = normalize_whitespace(source)

    for value <- values do
      assert normalized_source =~ normalize_whitespace(value),
             "expected to find #{inspect(value)}"
    end
  end

  defp normalize_whitespace(value), do: String.replace(value, ~r/\s+/, " ")

  defp workflow_step!(workflow, name, next_name) do
    [_, step] = String.split(workflow, "- name: #{name}", parts: 2)
    step |> String.split("- name: #{next_name}", parts: 2) |> hd()
  end

  defp compose_service!(compose, name) do
    case Regex.run(
           ~r/^  #{Regex.escape(name)}:\n(?<body>(?: {4}.*(?:\n|\z))*)/m,
           compose,
           capture: ["body"]
         ) do
      [body] -> body
      _ -> flunk("missing Compose service #{name}")
    end
  end

  defp compose_app_environment(acknowledgement) do
    docker = System.find_executable("docker") || flunk("docker executable not found")

    {output, status} =
      System.cmd(
        docker,
        ["compose", "-f", @compose, "config", "--format", "json"],
        cd: @root,
        env: [
          {"SECRET_KEY_BASE",
           "compose-contract-secret-key-base-00000000000000000000000000000000"},
          {"POSTGRES_DB", "fornacast_prod"},
          {"POSTGRES_USER", "fornacast"},
          {"POSTGRES_PASSWORD", "compose-contract-password"},
          {"FORNACAST_ACKNOWLEDGE_LEGACY_TURSO_DATA", acknowledgement}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    output
    |> JSON.decode!()
    |> get_in(["services", "app", "environment"])
  end

  defp position!(source, value) do
    case :binary.match(source, value) do
      {position, _length} -> position
      :nomatch -> flunk("expected to find #{inspect(value)}")
    end
  end

  defp read_runtime_config(secret_key_base, api_port \\ "4891") do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")
    ecto_ebin = Ecto.Repo.Supervisor |> :code.which() |> to_string() |> Path.dirname()

    System.cmd(
      elixir,
      [
        "-pa",
        ecto_ebin,
        "-e",
        """
        defmodule Fornacast.Repo do
          def __adapter__, do: Ecto.Adapters.Postgres
        end

        config = Config.Reader.read!(#{inspect(@runtime_config)}, env: :prod)

        port =
          config
          |> Keyword.fetch!(:fornacast_api)
          |> Keyword.fetch!(FornacastAPI.Endpoint)
          |> Keyword.fetch!(:http)
          |> Keyword.fetch!(:port)

        IO.puts("api_port=\#{port}")
        """
      ],
      cd: @root,
      env:
        runtime_config_env(
          SECRET_KEY_BASE: secret_key_base,
          FORNACAST_API_PORT: api_port,
          FORNACAST_BASE_URL: "http://localhost:4890",
          FORNACAST_REPO_STORAGE_ROOT: "/tmp/fornacast-runtime-config-repos",
          FORNACAST_SSH_HOST: "localhost",
          FORNACAST_SSH_PORT: "2222",
          FORNACAST_SSH_SYSTEM_DIR: "/tmp/fornacast-runtime-config-ssh"
        ),
      stderr_to_stdout: true
    )
  end

  defp read_runtime_storage_config(max_bytes, grace_seconds) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")
    ecto_ebin = Ecto.Repo.Supervisor |> :code.which() |> to_string() |> Path.dirname()

    System.cmd(
      elixir,
      [
        "-pa",
        ecto_ebin,
        "-e",
        """
        defmodule Fornacast.Repo do
          def __adapter__, do: Ecto.Adapters.Postgres
        end

        config = Config.Reader.read!(#{inspect(@runtime_config)}, env: :prod)
        values = Keyword.fetch!(config, :fornacast)
        IO.puts("max=\#{values[:release_asset_max_bytes]} grace=\#{values[:release_asset_gc_grace_seconds]}")
        """
      ],
      cd: @root,
      env:
        runtime_config_env(
          SECRET_KEY_BASE: String.duplicate("s", 64),
          FORNACAST_BASE_URL: "http://localhost:4890",
          FORNACAST_REPO_STORAGE_ROOT: "/tmp/fornacast-runtime-config-repos",
          FORNACAST_SSH_HOST: "localhost",
          FORNACAST_SSH_PORT: "2222",
          FORNACAST_SSH_SYSTEM_DIR: "/tmp/fornacast-runtime-config-ssh",
          FORNACAST_RELEASE_ASSET_STORAGE_ROOT: "/tmp/fornacast-runtime-assets",
          FORNACAST_RELEASE_ASSET_MAX_BYTES: max_bytes,
          FORNACAST_RELEASE_ASSET_GC_GRACE_SECONDS: grace_seconds
        ),
      stderr_to_stdout: true
    )
  end

  defp runtime_config_env(overrides) do
    @runtime_database_env
    |> Map.new(&{&1, nil})
    |> Map.merge(
      Map.new(
        [
          RELEASE_COMMAND: "start",
          POSTGRES_HOST: "127.0.0.1",
          POSTGRES_PORT: "5432",
          POSTGRES_DB: "fornacast_test",
          POSTGRES_USER: "fornacast_runtime_test",
          POSTGRES_PASSWORD: "fornacast_runtime_test_password"
        ] ++ overrides,
        fn {key, value} -> {to_string(key), value} end
      )
    )
    |> Map.to_list()
  end
end
