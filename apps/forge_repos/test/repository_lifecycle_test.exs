defmodule ForgeRepos.RepositoryLifecycleTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  setup do
    if postgres?(), do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "ordinary changesets remain ready generation one and ignore import-only fields" do
    import_only = %{
      lifecycle: :importing,
      generation: 7,
      storage_reclaimed_at: ~U[2026-08-26 00:00:00Z]
    }

    create_attrs =
      Map.merge(
        %{
          name: "Ordinary",
          slug: "ordinary",
          visibility: :private,
          default_branch: "main"
        },
        import_only
      )

    base = %Repository{
      owner_user_id: 41,
      storage_path: "@test/41/ordinary.git"
    }

    for changeset <- [
          Repository.create_changeset(base, create_attrs),
          Repository.api_create_changeset(base, create_attrs),
          Repository.api_update_changeset(
            %Repository{base | slug: "ordinary", name: "Ordinary"},
            import_only
          )
        ] do
      assert Ecto.Changeset.get_field(changeset, :lifecycle) == :ready
      assert Ecto.Changeset.get_field(changeset, :generation) == 1
      assert Ecto.Changeset.get_field(changeset, :storage_reclaimed_at) == nil
      refute Map.has_key?(changeset.changes, :lifecycle)
      refute Map.has_key?(changeset.changes, :generation)
      refute Map.has_key?(changeset.changes, :storage_reclaimed_at)
    end
  end

  test "import changeset accepts only an importing private shadow with a positive generation" do
    changeset = Repository.import_changeset(%Repository{}, valid_import_attrs())

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :lifecycle) == :importing
    assert Ecto.Changeset.get_field(changeset, :visibility) == :private
    assert Ecto.Changeset.get_field(changeset, :generation) == 2
    assert Ecto.Changeset.get_field(changeset, :storage_reclaimed_at) == nil
    refute Map.has_key?(changeset.changes, :storage_reclaimed_at)
    refute Map.has_key?(changeset.changes, :description)
    refute Map.has_key?(changeset.changes, :default_branch)
    refute Map.has_key?(changeset.changes, :has_issues)
    refute Map.has_key?(changeset.changes, :allow_merge_commit)
  end

  test "import changeset rejects non-importing, public, non-positive, and incomplete shadows" do
    for {field, value} <- [
          {:lifecycle, :ready},
          {:lifecycle, :tombstoned},
          {:visibility, :public},
          {:generation, 0},
          {:generation, -1}
        ] do
      changeset =
        %Repository{}
        |> Repository.import_changeset(Map.put(valid_import_attrs(), field, value))

      refute changeset.valid?, "expected #{field}=#{inspect(value)} to be rejected"
      assert Keyword.has_key?(changeset.errors, field)
    end

    for field <- ~w(owner_user_id slug name visibility storage_path lifecycle generation)a do
      changeset =
        Repository.import_changeset(%Repository{}, Map.delete(valid_import_attrs(), field))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "import changeset rejects persisted repositories even when import fields are valid" do
    persisted = %Repository{
      id: 91,
      owner_user_id: 41,
      slug: "ready-repository",
      name: "Ready repository",
      visibility: :private,
      storage_path: "@ready/41/repository.git",
      lifecycle: :ready,
      generation: 1
    }

    changeset =
      Repository.import_changeset(persisted, %{
        lifecycle: :importing,
        visibility: :private,
        generation: 2
      })

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :id)
  end

  test "import changeset requires every import field from attrs, not prepopulated struct data" do
    prepopulated = %Repository{
      owner_user_id: 41,
      slug: "prepopulated-shadow",
      name: "Prepopulated shadow",
      visibility: :private,
      storage_path: "@imports/41/prepopulated.git",
      lifecycle: :importing,
      generation: 2
    }

    changeset =
      Repository.import_changeset(prepopulated, %{
        lifecycle: :importing,
        visibility: :private,
        generation: 2
      })

    refute changeset.valid?

    for field <- ~w(owner_user_id slug name storage_path)a do
      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "ordinary persisted repositories default ready at generation one" do
    {_owner, repository} = repository_fixture("ordinary-default")

    assert repository.lifecycle == :ready
    assert repository.generation == 1
    assert repository.storage_reclaimed_at == nil
  end

  test "database rejects an unknown repository lifecycle" do
    {_owner, repository} = repository_fixture("invalid-lifecycle")
    placeholder = placeholder(1)

    assert {:error, error} =
             SQL.query(
               Repo,
               "update repositories set lifecycle = #{placeholder} where id = #{placeholder(2)}",
               ["unknown", repository.id]
             )

    assert Exception.message(error) =~ "repositories_lifecycle_check"
  end

  test "database rejects repository generation zero" do
    {_owner, repository} = repository_fixture("invalid-generation")
    placeholder = placeholder(1)

    assert {:error, error} =
             SQL.query(
               Repo,
               "update repositories set generation = #{placeholder} where id = #{placeholder(2)}",
               [0, repository.id]
             )

    assert Exception.message(error) =~ "repositories_generation_positive_check"
  end

  defp valid_import_attrs do
    %{
      owner_user_id: 41,
      slug: "import-41-shadow",
      name: "Import shadow",
      description: "must be ignored",
      visibility: :private,
      storage_path: "@imports/41/shadow.git",
      default_branch: "ignored",
      has_issues: false,
      allow_merge_commit: false,
      lifecycle: :importing,
      generation: 2,
      storage_reclaimed_at: ~U[2026-08-26 00:00:00Z]
    }
  end

  defp repository_fixture(label) do
    suffix = System.unique_integer([:positive])
    username = "#{label}-#{suffix}"

    {:ok, owner} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    repository =
      %Repository{owner_user_id: owner.id, storage_path: "@test/#{owner.id}/#{label}.git"}
      |> Repository.create_changeset(%{
        slug: label,
        name: label,
        visibility: :private,
        default_branch: "main"
      })
      |> Repo.insert!()

    unless postgres?() do
      owner_id = owner.id
      repository_id = repository.id

      on_exit(fn ->
        SQL.query!(Repo, "delete from repositories where id = ?", [repository_id])
        SQL.query!(Repo, "delete from users where id = ?", [owner_id])
      end)
    end

    {owner, repository}
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp placeholder(index) do
    if postgres?(), do: "$#{index}", else: "?"
  end
end

defmodule ForgeRepos.RepositoryLifecycleMigrationRepo do
  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Turso)

  use Ecto.Repo,
    otp_app: :fornacast,
    adapter: @adapter
end

defmodule ForgeRepos.RepositoryLifecycleMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgeRepos.RepositoryLifecycleMigrationRepo, as: MigrationRepo
  alias Fornacast.Repo

  @version 20_260_825_000_400
  @pre_version 20_260_825_000_370
  @migrations_path Path.expand("../../fornacast/priv/repo/migrations", __DIR__)
  @migration_path Path.join(
                    @migrations_path,
                    "20260825000400_add_repository_import_lifecycle.exs"
                  )

  test "00400 declares explicit adapter-safe up and down paths" do
    source = File.read!(@migration_path)

    assert source =~ "def up do"
    assert source =~ "def down do"
    assert source =~ "# TODO(upstream): gsmlg-dev/concord#81"
    refute source =~ "def change do"
  end

  @tag :tmp_dir
  test "00400 upgrades an existing repository and preserves repository index contracts",
       context do
    migration_repo = start_migration_repo!(context)
    seed = repository_seed()

    try do
      if postgres?() and migration_applied?(migration_repo, @version) do
        assert [@version] = migrate_down(migration_repo, @version)
      end

      refute column_exists?(migration_repo, "lifecycle")
      seeded = seed_pre_00400_repository!(migration_repo, seed)

      assert [@version] = migrate_up(migration_repo, @version)
      assert repository_projection(migration_repo, seeded.repository_id) == {"ready", 1, nil}
      assert_final_schema!(migration_repo)
    after
      if postgres?() do
        ensure_up!(migration_repo, @version)
        delete_seed!(migration_repo, seed)
      end
    end
  end

  @tag :tmp_dir
  test "00400 rollback is pre-DDL guarded on Turso and exact on PostgreSQL", context do
    migration_repo = start_migration_repo!(context)
    ensure_up!(migration_repo, @version)

    try do
      if postgres?() do
        assert [@version] = migrate_down(migration_repo, @version)
        refute migration_applied?(migration_repo, @version)
        refute column_exists?(migration_repo, "lifecycle")
        refute column_exists?(migration_repo, "generation")
        refute column_exists?(migration_repo, "storage_reclaimed_at")
        refute constraint_exists?(migration_repo, "repositories_lifecycle_check")
        refute constraint_exists?(migration_repo, "repositories_generation_positive_check")
        refute index_exists?(migration_repo, "repositories_import_cleanup_index")
        assert active_owner_slug_index_preserved?(migration_repo)

        assert [@version] = migrate_up(migration_repo, @version)
        assert_final_schema!(migration_repo)
      else
        assert_raise RuntimeError,
                     "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved",
                     fn -> migrate_down(migration_repo, @version) end

        assert migration_applied?(migration_repo, @version)
        assert_final_schema!(migration_repo)
      end
    after
      if postgres?(), do: ensure_up!(migration_repo, @version)
    end
  end

  defp start_migration_repo!(context) do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    config =
      if postgres?(),
        do: config,
        else:
          Keyword.put(config, :database, Path.join(context.tmp_dir, "repository-lifecycle.db"))

    start_supervised!({MigrationRepo, config})

    unless postgres?() do
      assert Enum.member?(migrate_up(MigrationRepo, @pre_version), @pre_version)
    end

    MigrationRepo
  end

  defp repository_seed do
    suffix = System.unique_integer([:positive])
    %{username: "lifecycle-upgrade-#{suffix}", slug: "upgrade-#{suffix}"}
  end

  defp seed_pre_00400_repository!(repo, seed) do
    now = database_datetime(DateTime.utc_now(:second))

    user_params = [
      seed.username,
      "#{seed.username}@example.test",
      "not-used",
      "user",
      "active",
      "user",
      now,
      now
    ]

    SQL.query!(
      repo,
      "insert into users " <>
        "(username, email, password_hash, role, state, kind, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(user_params)), ", ")})",
      user_params
    )

    user_id = select_id!(repo, "users", "username", seed.username)

    repository_params = [
      user_id,
      seed.slug,
      "Upgrade repository",
      "private",
      "@upgrade/#{user_id}/#{seed.slug}.git",
      "main",
      true,
      true,
      now,
      now
    ]

    SQL.query!(
      repo,
      "insert into repositories " <>
        "(owner_user_id, slug, name, visibility, storage_path, default_branch, " <>
        "has_issues, allow_merge_commit, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(repository_params)), ", ")})",
      repository_params
    )

    %{repository_id: select_id!(repo, "repositories", "slug", seed.slug)}
  end

  defp assert_final_schema!(repo) do
    assert column_contract(repo, "lifecycle") == {false, "ready"}
    assert column_contract(repo, "generation") == {false, "1"}
    assert column_contract(repo, "storage_reclaimed_at") == {true, nil}

    assert constraint_exists?(repo, "repositories_lifecycle_check")
    assert constraint_exists?(repo, "repositories_generation_positive_check")

    assert index_columns(repo, "repositories_import_cleanup_index") == [
             "lifecycle",
             "deleted_at",
             "storage_reclaimed_at",
             "id"
           ]

    assert active_owner_slug_index_preserved?(repo)
  end

  defp repository_projection(repo, repository_id) do
    placeholder = List.first(placeholders(1))

    %{rows: [[lifecycle, generation, reclaimed_at]]} =
      SQL.query!(
        repo,
        "select lifecycle, generation, storage_reclaimed_at from repositories " <>
          "where id = #{placeholder}",
        [repository_id]
      )

    {lifecycle, generation, reclaimed_at}
  end

  defp column_contract(repo, column) do
    if postgres?() do
      %{rows: [[nullable, default]]} =
        SQL.query!(
          repo,
          "select is_nullable, column_default from information_schema.columns " <>
            "where table_schema = current_schema() and table_name = $1 and column_name = $2",
          ["repositories", column]
        )

      {nullable == "YES", normalize_default(default)}
    else
      %{rows: rows} = SQL.query!(repo, "pragma table_info('repositories')", [])
      row = Enum.find(rows, &(Enum.at(&1, 1) == column))
      {Enum.at(row, 3) == 0, normalize_default(Enum.at(row, 4))}
    end
  end

  defp normalize_default(nil), do: nil

  defp normalize_default(default) do
    default
    |> to_string()
    |> String.replace(~r/::[a-z ]+$/, "")
    |> String.trim("'")
    |> String.trim("(")
    |> String.trim(")")
    |> String.trim("'")
  end

  defp constraint_exists?(repo, name) do
    if postgres?() do
      %{rows: [[exists?]]} =
        SQL.query!(repo, "select exists (select 1 from pg_constraint where conname = $1)", [
          name
        ])

      exists?
    else
      %{rows: [[sql]]} =
        SQL.query!(
          repo,
          "select sql from sqlite_schema where type = 'table' and name = ?",
          ["repositories"]
        )

      String.contains?(sql, name)
    end
  end

  defp index_columns(repo, name) do
    if postgres?() do
      %{rows: rows} =
        SQL.query!(
          repo,
          "select a.attname from pg_class i " <>
            "join pg_index ix on i.oid = ix.indexrelid " <>
            "join pg_class t on t.oid = ix.indrelid " <>
            "join unnest(ix.indkey) with ordinality as keys(attnum, ord) on true " <>
            "join pg_attribute a on a.attrelid = t.oid and a.attnum = keys.attnum " <>
            "where i.relname = $1 and t.relname = 'repositories' order by keys.ord",
          [name]
        )

      Enum.map(rows, &List.first/1)
    else
      %{rows: rows} = SQL.query!(repo, "pragma index_info('#{name}')", [])
      Enum.map(rows, &Enum.at(&1, 2))
    end
  end

  defp index_exists?(repo, name) do
    if postgres?() do
      %{rows: [[exists?]]} =
        SQL.query!(
          repo,
          "select exists (select 1 from pg_indexes " <>
            "where schemaname = current_schema() and tablename = 'repositories' " <>
            "and indexname = $1)",
          [name]
        )

      exists?
    else
      %{rows: rows} =
        SQL.query!(
          repo,
          "select name from sqlite_schema where type = 'index' and name = ?",
          [name]
        )

      rows == [[name]]
    end
  end

  defp active_owner_slug_index_preserved?(repo) do
    if postgres?() do
      %{rows: rows} =
        SQL.query!(
          repo,
          "select indexdef from pg_indexes " <>
            "where schemaname = current_schema() and tablename = 'repositories' " <>
            "and indexname = 'repositories_owner_user_id_slug_index'",
          []
        )

      match?([[definition]] when is_binary(definition), rows) and
        rows
        |> hd()
        |> hd()
        |> String.downcase()
        |> String.contains?("where (deleted_at is null)")
    else
      %{rows: rows} =
        SQL.query!(
          repo,
          "select sql from sqlite_schema where type = 'index' and " <>
            "name = 'repositories_owner_user_id_slug_index'",
          []
        )

      match?([[definition]] when is_binary(definition), rows) and
        rows |> hd() |> hd() |> String.downcase() |> String.contains?("where deleted_at is null")
    end
  end

  defp column_exists?(repo, column) do
    if postgres?() do
      %{rows: [[exists?]]} =
        SQL.query!(
          repo,
          "select exists (select 1 from information_schema.columns " <>
            "where table_schema = current_schema() and table_name = $1 and column_name = $2)",
          ["repositories", column]
        )

      exists?
    else
      %{rows: rows} = SQL.query!(repo, "pragma table_info('repositories')", [])
      Enum.any?(rows, &(Enum.at(&1, 1) == column))
    end
  end

  defp migration_applied?(repo, version) do
    placeholder = List.first(placeholders(1))

    %{rows: rows} =
      SQL.query!(repo, "select version from schema_migrations where version = #{placeholder}", [
        version
      ])

    rows == [[version]]
  end

  defp migrate_up(repo, version),
    do: Ecto.Migrator.run(repo, @migrations_path, :up, to: version, log: false)

  defp migrate_down(repo, version),
    do: Ecto.Migrator.run(repo, @migrations_path, :down, to: version, log: false)

  defp ensure_up!(repo, version) do
    unless migration_applied?(repo, version), do: migrate_up(repo, version)
  end

  defp select_id!(repo, table, field, value) do
    placeholder = List.first(placeholders(1))

    %{rows: [[id]]} =
      SQL.query!(repo, "select id from #{table} where #{field} = #{placeholder}", [value])

    id
  end

  defp delete_seed!(repo, seed) do
    SQL.query!(repo, "delete from repositories where slug = $1", [seed.slug])
    SQL.query!(repo, "delete from users where username = $1", [seed.username])
  end

  defp placeholders(count) do
    if postgres?(), do: Enum.map(1..count, &"$#{&1}"), else: List.duplicate("?", count)
  end

  defp database_datetime(%DateTime{} = value) do
    naive = DateTime.to_naive(value)
    if postgres?(), do: naive, else: NaiveDateTime.to_iso8601(naive)
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
