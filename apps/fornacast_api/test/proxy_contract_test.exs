defmodule FornacastAPI.ProxyContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  test "Nginx routes both API prefixes to the API listener without rewriting them" do
    nginx = read!("deploy/nginx/fornacast.conf")

    assert nginx =~ ~r/upstream fornacast_web\s*\{\s*server app:4890;\s*\}/s
    assert nginx =~ ~r/upstream fornacast_api\s*\{\s*server app:4001;\s*\}/s

    api_location = location!(nginx, ~r/\^\/\(api\/v3\|api\/uploads\)\(\/\|\$\)/)
    assert api_location =~ "proxy_pass http://fornacast_api;"
    refute api_location =~ ~r/proxy_pass\s+http:\/\/fornacast_api\//
    refute api_location =~ ~r/\brewrite\b/

    web_location = location!(nginx, "/")
    assert web_location =~ "proxy_pass http://fornacast_web;"
    refute web_location =~ "fornacast_api"
    refute web_location =~ ~r/\brewrite\b/
  end

  test "Nginx pins trusted-edge forwarding and unbuffered streaming" do
    nginx = read!("deploy/nginx/fornacast.conf")

    assert nginx =~ ~r/map \$http_upgrade \$connection_upgrade\s*\{/s

    for location <- [
          location!(nginx, ~r/\^\/\(api\/v3\|api\/uploads\)\(\/\|\$\)/),
          location!(nginx, "/")
        ] do
      assert location =~ "client_max_body_size 0;"
      assert location =~ "proxy_http_version 1.1;"
      assert location =~ "proxy_request_buffering off;"
      assert location =~ "proxy_buffering off;"
      assert location =~ ~s(proxy_set_header Forwarded "";)
      assert location =~ "proxy_set_header X-Forwarded-For $remote_addr;"
      assert location =~ "proxy_set_header Host $host;"
      assert location =~ "proxy_set_header X-Forwarded-Proto $scheme;"
      assert location =~ "proxy_set_header X-Forwarded-Host $host;"
    end

    web_location = location!(nginx, "/")
    assert web_location =~ "proxy_set_header Upgrade $http_upgrade;"
    assert web_location =~ "proxy_set_header Connection $connection_upgrade;"
  end

  test "the release image exposes distinct web, API, and SSH listeners" do
    dockerfile = read!("Dockerfile")

    assert dockerfile =~ "ARG DEBIAN_IMAGE=debian:trixie-slim"

    assert dockerfile =~
             ~r/ENV HOME=\/app \\\n+\s+PORT=4890 \\\n+\s+FORNACAST_API_BIND_IP=0\.0\.0\.0 \\\n+\s+FORNACAST_API_PORT=4001 /s

    assert dockerfile =~ "EXPOSE 4890 4001 2222"
    refute dockerfile =~ "EXPOSE 4000 2222"
  end

  test "Compose publishes only Nginx HTTP and attaches every service to the trusted network" do
    compose = read!("docker-compose.yml")

    assert compose =~ "PORT: 4890"
    assert compose =~ "FORNACAST_API_BIND_IP: 0.0.0.0"
    assert compose =~ "FORNACAST_API_PORT: 4001"
    assert compose =~ "FORNACAST_API_TRUSTED_PROXIES: 172.30.0.0/24"
    assert compose =~ ~s(FORNACAST_BASE_URL: ${FORNACAST_BASE_URL:-http://localhost:4000})

    app = service!(compose, "app")

    assert app =~
             ~r/expose:\s*\n\s+- ["']?4890["']?\s*\n\s+- ["']?4001["']?\s*\n\s+- ["']?2222["']?/s

    assert app =~ ~r/ports:\s*\n\s+- ["']2222:2222["']/s
    refute app =~ ~r/["']4000:(?:4000|4890)["']/
    assert app =~ ~r/networks:\s*\n\s+- fornacast-internal/s

    nginx = service!(compose, "nginx")
    assert nginx =~ "image: nginx:1.29-alpine"
    assert nginx =~ ~r/depends_on:\s*\n\s+- app/s

    assert nginx =~
             ~r/["']?\.\/deploy\/nginx\/fornacast\.conf:\/etc\/nginx\/conf\.d\/default\.conf:ro["']?/

    assert nginx =~ ~r/ports:\s*\n\s+- ["']4000:8080["']/s
    assert nginx =~ ~r/networks:\s*\n\s+- fornacast-internal/s

    db = service!(compose, "db")
    assert db =~ ~r/networks:\s*\n\s+- fornacast-internal/s

    assert compose =~
             ~r/^networks:\s*\n\s+fornacast-internal:\s*\n\s+driver: bridge\s*\n\s+ipam:\s*\n\s+config:\s*\n\s+- subnet: 172\.30\.0\.0\/24/m
  end

  test "the public proxy smoke is bounded and checks both API versions, uploads, and web health" do
    script_path = path("scripts/api_proxy_smoke.sh")
    script = File.read!(script_path)
    mode = script_path |> File.stat!() |> Map.fetch!(:mode) |> Bitwise.band(0o777)

    assert mode == 0o755
    assert script =~ "#!/bin/sh\nset -eu"
    assert script =~ "trap 'rm -f \"$headers\" \"$body\"' EXIT"
    assert script =~ "--connect-timeout"
    assert script =~ "--max-time"
    assert script =~ "$(date +%s) + 60"
    assert script =~ "502|503"
    assert script =~ ~s('["2022-11-28","2026-03-10"]')
    assert script =~ "x-github-api-version-selected: 2022-11-28"
    assert script =~ "x-github-api-version: 2026-03-10"
    assert script =~ "x-github-api-version-selected: 2026-03-10"
    assert script =~ "/api/uploads/not-a-resource"
    assert script =~ "x-github-request-id:"
    assert script =~ "/health"
  end

  test "README distinguishes direct listeners from the same-origin Compose API" do
    readme = read!("README.md")

    assert readme =~ "http://localhost:4890"
    assert readme =~ "http://localhost:4001/api/v3"
    assert readme =~ "http://localhost:4000/api/v3"
    assert readme =~ "http://localhost:4000/api/uploads"
    assert readme =~ "User-Agent"
    assert readme =~ "X-GitHub-Api-Version"
    assert readme =~ "Authorization: Bearer $FORNACAST_TOKEN"
    assert readme =~ "Authorization: token $FORNACAST_TOKEN"

    for scope <- ["repo", "public_repo", "read:org", "write:org"] do
      assert readme =~ "`#{scope}`"
    end

    assert readme =~ ~r/legacy/i
    assert readme =~ "read-only"
    assert readme =~ "domain authorization"
    assert readme =~ "same origin"
    assert readme =~ "auto_init"
    assert readme =~ "compatibility gate"
  end

  test "direct-release E2E binds and proves both listeners" do
    workflow = read!(".github/workflows/e2e.yml")

    assert workflow =~ ~s(FORNACAST_API_BIND_IP: "127.0.0.1")
    assert workflow =~ ~s(FORNACAST_API_PORT: "4101")
    assert workflow =~ ~s(http://127.0.0.1:${PORT}/health)
    assert workflow =~ ~s(http://127.0.0.1:${FORNACAST_API_PORT}/health)
  end

  defp location!(nginx, matcher) do
    header =
      case matcher do
        %Regex{} -> Regex.source(matcher)
        literal -> Regex.escape(literal)
      end

    case Regex.run(~r/location\s+(?:~\s+)?#{header}\s*\{(?<body>.*?)\n\s*\}/s, nginx,
           capture: ["body"]
         ) do
      [body] -> body
      _ -> flunk("missing Nginx location matching #{inspect(matcher)}")
    end
  end

  defp service!(compose, name) do
    case Regex.run(
           ~r/^  #{Regex.escape(name)}:\n(?<body>(?: {4}.*(?:\n|\z))*)/m,
           compose,
           capture: ["body"]
         ) do
      [body] -> body
      _ -> flunk("missing Compose service #{name}")
    end
  end

  defp read!(relative), do: relative |> path() |> File.read!()
  defp path(relative), do: Path.join(@root, relative)
end
