defmodule ForgeAccounts.GitHubCredentialVerificationMigrationRepo do
  @moduledoc false

  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Turso)

  use Ecto.Repo,
    otp_app: :fornacast,
    adapter: @adapter
end

defmodule ForgeAccounts.GitHubCredentialVerificationMigrationTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.GitHubCredentialVerificationMigrationRepo
  alias Fornacast.Repo

  @credential_version 20_260_825_000_200
  @import_version 20_260_825_000_300
  @verification_version 20_260_825_000_350
  @provisional_source_version 20_260_825_000_360
  @migrations_path Path.expand("../../fornacast/priv/repo/migrations", __DIR__)
  @credential_migration Path.join(
                          @migrations_path,
                          "20260825000200_create_github_credentials.exs"
                        )

  setup do
    database_run(&reset_database!/0)
    :ok
  end

  test "an installed 00200/00300 schema upgrades existing credentials and reverses cleanly" do
    credential_id =
      database_run(fn ->
        actor = user_fixture()
        identity = identity_fixture(actor)

        {:ok, account} =
          ForgeAccounts.save_github_account(
            actor,
            profile(identity.github_user_id, identity.login),
            "github_pat_migration_seed",
            %{}
          )

        credential_id(account.identity_id)
      end)

    repo = start_migration_repo!()

    assert migration_applied?(repo, @verification_version)
    assert column_exists?(repo, "github_credentials", "verification_version")

    if postgres?() do
      assert [@provisional_source_version] =
               Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, log: false)

      assert [@verification_version] =
               Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, log: false)

      assert_upgrade_baseline(repo, credential_id)
      migrate_verification_up!(repo)
      assert_upgraded_credential(repo, credential_id)

      assert [@verification_version] =
               Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, log: false)

      assert_upgrade_baseline(repo, credential_id)
      migrate_verification_up!(repo)
      assert_upgraded_credential(repo, credential_id)

      assert [@provisional_source_version] =
               Ecto.Migrator.run(repo, @migrations_path, :up,
                 to: @provisional_source_version,
                 log: false
               )
    else
      assert_raise RuntimeError,
                   "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved",
                   fn ->
                     Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, log: false)
                   end

      assert migration_applied?(repo, @verification_version)
      assert column_exists?(repo, "github_credentials", "verification_version")

      remove_turso_verification_version!(repo)
      delete_migration_record!(repo, @verification_version)
      assert_upgrade_baseline(repo, credential_id)

      migrate_verification_up!(repo)
      assert_upgraded_credential(repo, credential_id)

      remove_turso_verification_version!(repo)
      refute column_exists?(repo, "github_credentials", "verification_version")
      assert credential_exists?(repo, credential_id)

      add_turso_verification_version!(repo)
      assert migration_applied?(repo, @verification_version)
      assert_upgraded_credential(repo, credential_id)
    end
  end

  test "fresh schema keeps 00200 immutable and records the forward migration after 00300" do
    repo = start_migration_repo!()

    refute File.read!(@credential_migration) =~ "verification_version"
    assert @credential_version < @import_version
    assert @import_version < @verification_version
    assert @verification_version < @provisional_source_version
    assert migration_applied?(repo, @credential_version)
    assert migration_applied?(repo, @import_version)
    assert migration_applied?(repo, @verification_version)
    assert migration_applied?(repo, @provisional_source_version)
    assert column_exists?(repo, "github_credentials", "verification_version")
  end

  defp assert_upgrade_baseline(repo, credential_id) do
    assert migration_applied?(repo, @credential_version)
    assert migration_applied?(repo, @import_version)
    refute migration_applied?(repo, @verification_version)
    refute column_exists?(repo, "github_credentials", "verification_version")
    assert credential_exists?(repo, credential_id)
  end

  defp migrate_verification_up!(repo) do
    assert [@verification_version] =
             Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @verification_version,
               log: false
             )
  end

  defp assert_upgraded_credential(repo, credential_id) do
    assert migration_applied?(repo, @verification_version)
    assert column_exists?(repo, "github_credentials", "verification_version")
    assert verification_version(repo, credential_id) == 1
    assert_version_constraint!(repo, credential_id)
  end

  defp assert_version_constraint!(repo, credential_id) do
    placeholder = if postgres?(), do: "$1", else: "?"

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               repo,
               "update github_credentials set verification_version = 0 where id = #{placeholder}",
               [credential_id]
             )

    assert Exception.message(error) =~ "github_credentials_verification_version_check"
    assert verification_version(repo, credential_id) == 1
  end

  defp remove_turso_verification_version!(repo) do
    Ecto.Adapters.SQL.query!(
      repo,
      "alter table github_credentials drop column verification_version",
      []
    )
  end

  defp add_turso_verification_version!(repo) do
    Ecto.Adapters.SQL.query!(
      repo,
      "alter table github_credentials add column verification_version integer " <>
        "not null default 1 constraint github_credentials_verification_version_check " <>
        "check (verification_version > 0)",
      []
    )
  end

  defp delete_migration_record!(repo, version) do
    Ecto.Adapters.SQL.query!(
      repo,
      "delete from schema_migrations where version = ?",
      [version]
    )
  end

  defp credential_id(identity_id) do
    placeholder = if postgres?(), do: "$1", else: "?"

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "select id from github_credentials where github_identity_id = #{placeholder}",
        [identity_id]
      )

    id
  end

  defp credential_exists?(repo, credential_id) do
    placeholder = if postgres?(), do: "$1", else: "?"

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select id from github_credentials where id = #{placeholder}",
        [credential_id]
      )

    rows == [[credential_id]]
  end

  defp verification_version(repo, credential_id) do
    placeholder = if postgres?(), do: "$1", else: "?"

    %{rows: [[version]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select verification_version from github_credentials where id = #{placeholder}",
        [credential_id]
      )

    version
  end

  defp migration_applied?(repo, version) do
    placeholder = if postgres?(), do: "$1", else: "?"

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select version from schema_migrations where version = #{placeholder}",
        [version]
      )

    rows == [[version]]
  end

  defp column_exists?(repo, table, column) do
    if postgres?() do
      %{rows: [[exists?]]} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select exists (select 1 from information_schema.columns " <>
            "where table_schema = current_schema() and table_name = $1 and column_name = $2)",
          [table, column]
        )

      exists?
    else
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(repo, "select name from pragma_table_info(?)", [table])

      [column] in rows
    end
  end

  defp start_migration_repo! do
    case Process.whereis(GitHubCredentialVerificationMigrationRepo) do
      nil ->
        config =
          Repo.config()
          |> Keyword.delete(:name)
          |> Keyword.put(:pool, DBConnection.ConnectionPool)
          |> Keyword.put(:pool_size, 2)

        start_supervised!({GitHubCredentialVerificationMigrationRepo, config})
        GitHubCredentialVerificationMigrationRepo

      _pid ->
        GitHubCredentialVerificationMigrationRepo
    end
  end

  defp profile(id, login) do
    %{
      github_user_id: id,
      login: login,
      avatar_url: "https://avatars.githubusercontent.com/u/#{id}",
      profile_url: "https://github.com/#{login}"
    }
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        profile(9_930_000_000 + suffix, "migration-#{suffix}"),
        DateTime.utc_now(:second)
      )

    {:ok, identity} = ForgeAccounts.link_github_identity(actor, identity)
    identity
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "migration-user-#{suffix}",
        email: "migration-user-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp reset_database! do
    for table <- [
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "github_credentials",
          "github_identities",
          "audit_events",
          "repository_collaborators",
          "repositories",
          "organization_members",
          "api_keys",
          "ssh_keys",
          "users"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp database_run(callback) do
    if postgres?(), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, callback), else: callback.()
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
