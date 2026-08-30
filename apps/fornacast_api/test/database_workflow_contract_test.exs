defmodule FornacastAPI.DatabaseWorkflowContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @ci_workflow Path.join(@root, ".github/workflows/ci.yml")
  @test_workflow Path.join(@root, ".github/workflows/test.yml")

  test "format and build jobs compile PostgreSQL with adapter-qualified caches" do
    workflow = File.read!(@ci_workflow)
    format_job = workflow_job!(workflow, "format", "build")
    build_job = workflow_job!(workflow, "build")

    for job <- [format_job, build_job] do
      assert job =~ "FORNACAST_DATABASE_ADAPTER: postgres"
      assert job =~ ~r/key:.*-postgres-.*hashFiles/s
      assert job =~ ~r/restore-keys:\s*\|\s*\n\s*.*-postgres-/
    end

    refute workflow =~ "FORNACAST_DATABASE_ADAPTER: turso"
    refute workflow =~ "\n    services:\n"
  end

  test "unit tests run once against a healthy PostgreSQL 17 service" do
    workflow = File.read!(@test_workflow)
    unit_job = workflow_job!(workflow, "unit")

    assert unit_job =~ "name: Unit Tests (PostgreSQL)"
    assert unit_job =~ "FORNACAST_DATABASE_ADAPTER: postgres"
    assert unit_job =~ "MIX_ENV: test"
    assert unit_job =~ "PGHOST: localhost"
    assert unit_job =~ ~r/PGPORT: ["']?5432["']?/
    assert unit_job =~ "POSTGRES_DB: fornacast_test"
    assert unit_job =~ "POSTGRES_TEST_DB: fornacast_test"
    assert unit_job =~ "POSTGRES_USER: postgres"
    assert unit_job =~ "POSTGRES_PASSWORD: postgres"
    refute unit_job =~ "strategy:"
    refute workflow =~ "matrix."
    refute workflow =~ "turso"
    assert length(:binary.matches(workflow, "image: postgres:17")) == 1

    assert unit_job =~
             ~r/services:\s*\n\s+postgres:\s*\n\s+image: postgres:17\s*\n\s+env:\s*\n\s+POSTGRES_DB: fornacast_test\s*\n\s+POSTGRES_USER: postgres\s*\n\s+POSTGRES_PASSWORD: postgres/s

    assert unit_job =~ ~r/ports:\s*\n\s*- 5432:5432/
    assert unit_job =~ "pg_isready -U postgres -d fornacast_test"
    assert unit_job =~ "--health-interval 10s"
    assert unit_job =~ "--health-timeout 5s"
    assert unit_job =~ "--health-retries 5"
    assert unit_job =~ ~r/key:.*-postgres-.*hashFiles/s
    assert unit_job =~ ~r/restore-keys:\s*\|\s*\n\s*.*-postgres-/
    assert unit_job =~ "~/.cargo/git"
    assert unit_job =~ "~/.cargo/registry"
    assert unit_job =~ "run: mix test"
  end

  defp workflow_job!(workflow, job, next_job \\ nil) do
    [_, body] = String.split(workflow, "  #{job}:\n", parts: 2)

    case next_job do
      nil -> body
      next_job -> body |> String.split("  #{next_job}:\n", parts: 2) |> hd()
    end
  end
end
