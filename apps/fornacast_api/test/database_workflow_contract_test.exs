defmodule FornacastAPI.DatabaseWorkflowContractTest do
  use ExUnit.Case, async: true

  @workflow Path.expand("../../../.github/workflows/test.yml", __DIR__)

  test "unit tests run against Turso and PostgreSQL with isolated caches" do
    workflow = File.read!(@workflow)

    assert workflow =~ "fail-fast: false"

    assert workflow =~
             ~r/database_adapter:\s*\n\s*- turso\s*\n\s*- postgres\s*\n\s*env:/

    assert workflow =~
             ~s(FORNACAST_DATABASE_ADAPTER: ${{ matrix.database_adapter }})

    assert workflow =~
             ~r/key:.*\$\{\{ matrix\.database_adapter \}\}.*hashFiles/s

    assert workflow =~
             ~r/restore-keys:\s*\|\s*\n\s*\$\{\{ runner\.os \}\}-test-\$\{\{ matrix\.database_adapter \}\}-\$\{\{ env\.MIX_ENV \}\}-/
  end

  test "the matrix has a healthy PostgreSQL 17 test service" do
    workflow = File.read!(@workflow)

    assert workflow =~
             ~r/^    services:\n      postgres:\n        image: postgres:17\n        env:\n          POSTGRES_DB: fornacast_test\n          POSTGRES_USER: postgres\n          POSTGRES_PASSWORD: postgres\n/m

    assert workflow =~ ~r/ports:\s*\n\s*- 5432:5432/
    assert workflow =~ "pg_isready -U postgres -d fornacast_test"
    assert workflow =~ "--health-retries 5"
  end
end
