defmodule ForgeRepos.RepositoryLifecycleTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.{Adapters.SQL, Multi}
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

  test "repository write version defaults to zero and cannot be injected by create changesets" do
    assert :write_version in Repository.__schema__(:fields)

    base = %Repository{
      owner_user_id: 41,
      storage_path: "@test/41/write-version.git",
      write_version: 77
    }

    attrs = %{
      slug: "write-version",
      name: "Write version",
      visibility: :private,
      default_branch: "main",
      write_version: 99
    }

    for changeset <- [
          Repository.create_changeset(base, attrs),
          Repository.api_create_changeset(base, attrs),
          Repository.import_changeset(
            %Repository{write_version: 77},
            valid_import_attrs() |> Map.put(:write_version, 99)
          )
        ] do
      assert Ecto.Changeset.get_field(changeset, :write_version) == 0
      assert Ecto.Changeset.get_change(changeset, :write_version) == 0
    end
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

  test "database rejects a negative repository write version" do
    {_owner, repository} = repository_fixture("invalid-write-version")
    placeholder = placeholder(1)

    assert {:error, error} =
             SQL.query(
               Repo,
               "update repositories set write_version = #{placeholder} " <>
                 "where id = #{placeholder(2)}",
               [-1, repository.id]
             )

    assert Exception.message(error) =~ "repositories_write_version_nonnegative_check"
  end

  test "mark pushed atomically advances write version for the same observed repository" do
    {_owner, repository} = repository_fixture("mark-pushed-version")
    pushed_at = repository.updated_at

    {first, second} =
      ForgeRepos.with_test_mark_pushed_clock(fn -> pushed_at end, fn ->
        assert {:ok, first} = ForgeRepos.mark_pushed(repository, pushed_at)
        assert {:ok, second} = ForgeRepos.mark_pushed(repository, pushed_at)
        {first, second}
      end)

    assert first.write_version >= 1
    assert second.write_version == 2

    assert %Repository{
             write_version: 2,
             last_pushed_at: ^pushed_at,
             updated_at: ^pushed_at
           } = Repo.get!(Repository, repository.id)
  end

  test "mark pushed rolls back before retrying a post-update busy reload" do
    {_owner, repository} = repository_fixture("mark-pushed-busy-reload")
    pushed_at = repository.updated_at
    hook_key = {__MODULE__, make_ref()}
    Process.put(hook_key, :busy)

    try do
      hook = fn ->
        if Process.get(hook_key) == :busy do
          Process.put(hook_key, :ready)
          raise Turso.Error, code: :busy, message: "injected post-update busy"
        end
      end

      result =
        ForgeRepos.with_test_mark_pushed_after_update_hook(hook, fn ->
          ForgeRepos.mark_pushed(repository, pushed_at)
        end)

      {expected_write_version, expected_pushed_at} =
        if postgres?() do
          assert {:error, :unavailable} = result
          {0, nil}
        else
          assert {:ok, %Repository{write_version: 1}} = result
          {1, pushed_at}
        end

      assert %Repository{
               write_version: ^expected_write_version,
               last_pushed_at: ^expected_pushed_at
             } = Repo.get!(Repository, repository.id)
    after
      Process.delete(hook_key)
    end
  end

  test "mark pushed rolls back when the post-update reload stays unavailable" do
    {_owner, repository} = repository_fixture("mark-pushed-unavailable-reload")
    pushed_at = DateTime.add(repository.updated_at, 10, :second)

    hook = fn ->
      raise Turso.Error, code: :busy, message: "injected persistent post-update busy"
    end

    assert {:error, :unavailable} =
             ForgeRepos.with_test_mark_pushed_after_update_hook(hook, fn ->
               ForgeRepos.mark_pushed(repository, pushed_at)
             end)

    assert %Repository{
             lifecycle: :ready,
             write_version: 0,
             last_pushed_at: nil,
             updated_at: original_updated_at
           } = Repo.get!(Repository, repository.id)

    assert original_updated_at == repository.updated_at
  end

  test "mark pushed rolls back and reports stale when lifecycle changes before reload" do
    {_owner, repository} = repository_fixture("mark-pushed-stale-reload")
    pushed_at = DateTime.add(repository.updated_at, 10, :second)

    hook = fn ->
      assert {1, _rows} =
               Repo.update_all(
                 from(candidate in Repository, where: candidate.id == ^repository.id),
                 set: [lifecycle: :tombstoned]
               )
    end

    assert {:error, :stale_repository} =
             ForgeRepos.with_test_mark_pushed_after_update_hook(hook, fn ->
               ForgeRepos.mark_pushed(repository, pushed_at)
             end)

    assert %Repository{
             lifecycle: :ready,
             write_version: 0,
             last_pushed_at: nil,
             updated_at: original_updated_at
           } = Repo.get!(Repository, repository.id)

    assert original_updated_at == repository.updated_at
  end

  test "import shadow contributor is SQL-only private and rolls back with its caller" do
    {owner, _ordinary} = repository_fixture("import-shadow-contributor")
    item_id = System.unique_integer([:positive])

    assert {:ok, %{shadow: shadow}} =
             Multi.new()
             |> ForgeRepos.create_import_shadow(:shadow, owner.id, %{
               item_id: item_id,
               generation: 2
             })
             |> Repo.transaction()

    assert %Repository{
             owner_user_id: owner_id,
             lifecycle: :importing,
             visibility: :private,
             generation: 2,
             write_version: 0,
             deleted_at: nil
           } = shadow

    assert owner_id == owner.id
    assert Repository.canonical_slug?(shadow.slug)
    assert shadow.slug != "import-shadow-contributor"
    assert Fornacast.Storage.validate_relative_storage_path(shadow.storage_path) == :ok

    staged_path =
      Path.expand(Path.join(Fornacast.Config.repo_storage_root(), shadow.storage_path))

    refute File.exists?(staged_path)

    importing_before =
      Repo.aggregate(
        from(repository in Repository, where: repository.lifecycle == :importing),
        :count
      )

    assert {:error, :injected_failure, :rollback, _changes} =
             Multi.new()
             |> ForgeRepos.create_import_shadow(:shadow, owner.id, %{
               item_id: item_id + 1,
               generation: 1
             })
             |> Multi.error(:injected_failure, :rollback)
             |> Repo.transaction()

    assert Repo.aggregate(
             from(repository in Repository, where: repository.lifecycle == :importing),
             :count
           ) == importing_before

    Repo.delete!(shadow)
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

defmodule ForgeRepos.RepositoryLifecycleMigrationTestSupport do
  @moduledoc false

  @dual_failure_diagnostic "PostgreSQL migration restore failed after test body failure; preserving original failure"

  def with_restore(body, restore) when is_function(body, 0) and is_function(restore, 0) do
    body_outcome = capture_outcome(body)
    restore_outcome = capture_outcome(restore)

    case {body_outcome, restore_outcome} do
      {{:ok, result}, {:ok, _restore_result}} ->
        result

      {{:error, kind, reason, stacktrace}, {:ok, _restore_result}} ->
        :erlang.raise(kind, reason, stacktrace)

      {{:ok, _result}, {:error, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {{:error, kind, reason, stacktrace},
       {:error, _restore_kind, _restore_reason, _restore_stack}} ->
        IO.puts(:stderr, @dual_failure_diagnostic)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  def dual_failure_diagnostic, do: @dual_failure_diagnostic

  defp capture_outcome(fun) do
    try do
      {:ok, fun.()}
    catch
      kind, reason -> {:error, kind, reason, __STACKTRACE__}
    end
  end
end

defmodule ForgeRepos.RepositoryLifecycleMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgeRepos.RepositoryLifecycleMigrationRepo, as: MigrationRepo
  alias ForgeRepos.RepositoryLifecycleMigrationTestSupport, as: MigrationTestSupport
  alias Fornacast.Repo

  @version 20_260_825_000_400
  @write_version 20_260_825_000_410
  @staged_path_version 20_260_825_000_420
  @cleanup_recovery_version 20_260_825_000_430
  @cleanup_selector_version 20_260_831_000_100
  @pre_version 20_260_825_000_370
  @migrations_path Path.expand("../../fornacast/priv/repo/migrations", __DIR__)
  @migration_path Path.join(
                    @migrations_path,
                    "20260825000400_add_repository_import_lifecycle.exs"
                  )
  @write_migration_path Path.join(
                          @migrations_path,
                          "20260825000410_add_repository_write_version.exs"
                        )
  @staged_path_migration_path Path.join(
                                @migrations_path,
                                "20260825000420_expand_github_import_staged_storage_path.exs"
                              )

  test "00400 declares explicit adapter-safe up and down paths" do
    source = File.read!(@migration_path)

    assert source =~ "def up do"
    assert source =~ "def down do"
    assert source =~ "# TODO(upstream): gsmlg-dev/concord#81"
    refute source =~ "def change do"
  end

  test "00410 declares explicit adapter-safe up and down paths" do
    source = File.read!(@write_migration_path)

    assert source =~ "def up do"
    assert source =~ "def down do"
    assert source =~ "# TODO(upstream): gsmlg-dev/concord#81"
    refute source =~ "def change do"
  end

  test "00420 declares the PostgreSQL text expansion and pre-DDL Turso rollback guard" do
    source = File.read!(@staged_path_migration_path)

    assert source =~ "def up do"
    assert source =~ "def down do"
    assert source =~ "ALTER COLUMN staged_storage_path TYPE text"
    assert source =~ "ALTER COLUMN staged_storage_path TYPE varchar(255)"
    assert source =~ "# TODO(upstream): gsmlg-dev/concord#81"
    refute source =~ "def change do"
  end

  test "migration restore reports its failure without masking the original failure" do
    original = RuntimeError.exception("original migration test failure")
    restore = RuntimeError.exception("sensitive restore failure detail")
    original_stacktrace = [{__MODULE__, :original_migration_failure, 0, []}]

    diagnostic =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        result =
          try do
            MigrationTestSupport.with_restore(
              fn -> :erlang.raise(:error, original, original_stacktrace) end,
              fn -> raise restore end
            )
          rescue
            exception -> {exception, __STACKTRACE__}
          end

        assert {^original, ^original_stacktrace} = result
      end)

    assert diagnostic =~ MigrationTestSupport.dual_failure_diagnostic()
    refute diagnostic =~ restore.message
  end

  @tag :tmp_dir
  test "00400 upgrades an existing repository and preserves repository index contracts",
       context do
    migration_repo = start_migration_repo!(context)
    seed = repository_seed()

    with_complete_restore(
      migration_repo,
      fn ->
        if postgres?() and migration_applied?(migration_repo, @cleanup_selector_version) do
          assert [@cleanup_selector_version] =
                   migrate_down(migration_repo, @cleanup_selector_version)
        end

        if postgres?() and migration_applied?(migration_repo, @cleanup_recovery_version) do
          assert [@cleanup_recovery_version] =
                   migrate_down(migration_repo, @cleanup_recovery_version)
        end

        if postgres?() and migration_applied?(migration_repo, @staged_path_version) do
          assert [@staged_path_version] = migrate_down(migration_repo, @staged_path_version)
        end

        if postgres?() and migration_applied?(migration_repo, @write_version) do
          assert [@write_version] = migrate_down(migration_repo, @write_version)
        end

        if postgres?() and migration_applied?(migration_repo, @version) do
          assert [@version] = migrate_down(migration_repo, @version)
        end

        refute column_exists?(migration_repo, "lifecycle")
        seeded = seed_pre_00400_repository!(migration_repo, seed)

        assert [@version] = migrate_up(migration_repo, @version)
        assert repository_projection(migration_repo, seeded.repository_id) == {"ready", 1, nil}
        assert_final_schema!(migration_repo)
      end,
      fn -> delete_seed!(migration_repo, seed) end
    )
  end

  @tag :tmp_dir
  test "00400 rollback is pre-DDL guarded on Turso and exact on PostgreSQL", context do
    migration_repo = start_migration_repo!(context)

    with_complete_restore(migration_repo, fn ->
      if postgres?() and migration_applied?(migration_repo, @cleanup_selector_version) do
        assert [@cleanup_selector_version] =
                 migrate_down(migration_repo, @cleanup_selector_version)
      end

      if postgres?() and migration_applied?(migration_repo, @cleanup_recovery_version) do
        assert [@cleanup_recovery_version] =
                 migrate_down(migration_repo, @cleanup_recovery_version)
      end

      if postgres?() and migration_applied?(migration_repo, @staged_path_version) do
        assert [@staged_path_version] = migrate_down(migration_repo, @staged_path_version)
      end

      if postgres?() and migration_applied?(migration_repo, @write_version) do
        assert [@write_version] = migrate_down(migration_repo, @write_version)
      end

      ensure_up!(migration_repo, @version)

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
    end)
  end

  @tag :tmp_dir
  test "00410 upgrades existing repository and import-item write observations", context do
    migration_repo = start_migration_repo!(context)
    seed = write_version_seed()

    with_complete_restore(
      migration_repo,
      fn ->
        if postgres?() and migration_applied?(migration_repo, @cleanup_selector_version) do
          assert [@cleanup_selector_version] =
                   migrate_down(migration_repo, @cleanup_selector_version)
        end

        if postgres?() and migration_applied?(migration_repo, @cleanup_recovery_version) do
          assert [@cleanup_recovery_version] =
                   migrate_down(migration_repo, @cleanup_recovery_version)
        end

        if postgres?() and migration_applied?(migration_repo, @staged_path_version) do
          assert [@staged_path_version] = migrate_down(migration_repo, @staged_path_version)
        end

        if postgres?() and migration_applied?(migration_repo, @write_version) do
          assert [@write_version] = migrate_down(migration_repo, @write_version)
        end

        ensure_up!(migration_repo, @version)
        refute table_column_exists?(migration_repo, "repositories", "write_version")

        refute table_column_exists?(
                 migration_repo,
                 "github_import_repository_items",
                 "replacement_write_version"
               )

        seeded = seed_pre_00410_rows!(migration_repo, seed)

        assert [@write_version] = migrate_up(migration_repo, @write_version)
        assert write_version_projection(migration_repo, seeded) == {0, nil}
        assert_write_version_schema!(migration_repo)
      end,
      fn -> delete_write_version_seed!(migration_repo, seed) end
    )
  end

  @tag :tmp_dir
  test "00410 rollback is pre-DDL guarded on Turso and exact on PostgreSQL", context do
    migration_repo = start_migration_repo!(context)

    with_complete_restore(migration_repo, fn ->
      ensure_up!(migration_repo, @version)
      ensure_up!(migration_repo, @write_version)

      if postgres?() and migration_applied?(migration_repo, @cleanup_selector_version) do
        assert [@cleanup_selector_version] =
                 migrate_down(migration_repo, @cleanup_selector_version)
      end

      if postgres?() and migration_applied?(migration_repo, @cleanup_recovery_version) do
        assert [@cleanup_recovery_version] =
                 migrate_down(migration_repo, @cleanup_recovery_version)
      end

      if postgres?() and migration_applied?(migration_repo, @staged_path_version) do
        assert [@staged_path_version] = migrate_down(migration_repo, @staged_path_version)
      end

      if postgres?() do
        assert [@write_version] = migrate_down(migration_repo, @write_version)
        refute migration_applied?(migration_repo, @write_version)
        refute table_column_exists?(migration_repo, "repositories", "write_version")

        refute table_column_exists?(
                 migration_repo,
                 "github_import_repository_items",
                 "replacement_write_version"
               )

        refute constraint_exists?(migration_repo, "repositories_write_version_nonnegative_check")

        refute constraint_exists?(
                 migration_repo,
                 "github_import_repository_items",
                 "github_import_items_replacement_write_version_nonnegative_check"
               )

        assert [@write_version] = migrate_up(migration_repo, @write_version)
        assert_write_version_schema!(migration_repo)
      else
        assert_raise RuntimeError,
                     "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved",
                     fn -> migrate_down(migration_repo, @write_version) end

        assert migration_applied?(migration_repo, @write_version)
        assert_write_version_schema!(migration_repo)
      end
    end)
  end

  @tag :tmp_dir
  test "00420 preserves long staged paths and has an exact adapter lifecycle", context do
    migration_repo = start_migration_repo!(context)

    with_complete_restore(migration_repo, fn ->
      ensure_up!(migration_repo, @version)
      ensure_up!(migration_repo, @write_version)

      if postgres?() and migration_applied?(migration_repo, @cleanup_selector_version) do
        assert [@cleanup_selector_version] =
                 migrate_down(migration_repo, @cleanup_selector_version)
      end

      if postgres?() and migration_applied?(migration_repo, @cleanup_recovery_version) do
        assert [@cleanup_recovery_version] =
                 migrate_down(migration_repo, @cleanup_recovery_version)
      end

      if postgres?() and migration_applied?(migration_repo, @staged_path_version) do
        assert [@staged_path_version] = migrate_down(migration_repo, @staged_path_version)
      end

      if postgres?() do
        assert staged_path_column_type(migration_repo) == {"character varying", 255}
      else
        assert staged_path_column_type(migration_repo) == {"TEXT", nil}
      end

      assert [@staged_path_version] = migrate_up(migration_repo, @staged_path_version)

      assert staged_path_column_type(migration_repo) ==
               if(postgres?(), do: {"text", nil}, else: {"TEXT", nil})

      if postgres?() do
        seed = write_version_seed()
        seeded = seed_pre_00410_rows!(migration_repo, seed)
        long_path = "/staging/" <> String.duplicate("a", 300) <> ".git"

        MigrationTestSupport.with_restore(
          fn ->
            update_staged_path!(migration_repo, seeded.item_id, long_path)
            assert staged_path_value(migration_repo, seeded.item_id) == long_path

            assert_raise Postgrex.Error, ~r/staged_storage_path exceeds varchar\(255\)/, fn ->
              migrate_down(migration_repo, @staged_path_version)
            end

            assert migration_applied?(migration_repo, @staged_path_version)
            assert staged_path_column_type(migration_repo) == {"text", nil}
            assert staged_path_value(migration_repo, seeded.item_id) == long_path

            update_staged_path!(migration_repo, seeded.item_id, nil)
            assert [@staged_path_version] = migrate_down(migration_repo, @staged_path_version)
            assert staged_path_column_type(migration_repo) == {"character varying", 255}

            assert [@staged_path_version] = migrate_up(migration_repo, @staged_path_version)
            assert staged_path_column_type(migration_repo) == {"text", nil}
            update_staged_path!(migration_repo, seeded.item_id, long_path)
            assert staged_path_value(migration_repo, seeded.item_id) == long_path
          end,
          fn ->
            ensure_up!(migration_repo, @staged_path_version)
            delete_write_version_seed!(migration_repo, seed)
          end
        )
      else
        assert_raise RuntimeError,
                     "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved",
                     fn -> migrate_down(migration_repo, @staged_path_version) end

        assert migration_applied?(migration_repo, @staged_path_version)
        assert staged_path_column_type(migration_repo) == {"TEXT", nil}
      end
    end)
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

  defp write_version_seed do
    suffix = System.unique_integer([:positive])

    %{
      suffix: suffix,
      username: "write-version-upgrade-#{suffix}",
      slug: "write-version-#{suffix}"
    }
  end

  defp seed_pre_00410_rows!(repo, seed) do
    %{repository_id: repository_id} = seed_pre_00400_repository!(repo, seed)
    now = database_datetime(DateTime.utc_now(:second))
    user_id = select_id!(repo, "users", "username", seed.username)

    identity_params = [
      "user",
      8_900_000_000 + seed.suffix,
      seed.username,
      user_id,
      now,
      now
    ]

    SQL.query!(
      repo,
      "insert into github_identities " <>
        "(kind, github_user_id, login, local_user_id, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(identity_params)), ", ")})",
      identity_params
    )

    identity_id = select_id!(repo, "github_identities", "login", seed.username)

    run_params = [
      user_id,
      "repository",
      identity_id,
      "one_time",
      8_900_000_000 + seed.suffix,
      seed.username,
      9_900_000_000 + seed.suffix,
      "#{seed.username}/#{seed.slug}",
      "existing",
      seed.username,
      "awaiting_resolution",
      now,
      now
    ]

    SQL.query!(
      repo,
      "insert into github_import_runs " <>
        "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
        "source_owner_github_id, source_owner_login, source_repository_github_id, " <>
        "source_repository_full_name, destination_organization_action, " <>
        "destination_organization_slug, state, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(run_params)), ", ")})",
      run_params
    )

    run_id = select_id!(repo, "github_import_runs", "source_owner_login", seed.username)

    item_params = [
      run_id,
      9_900_000_000 + seed.suffix,
      "#{seed.username}/#{seed.slug}",
      seed.slug,
      now,
      "queued",
      now,
      now
    ]

    SQL.query!(
      repo,
      "insert into github_import_repository_items " <>
        "(import_run_id, github_repository_id, source_full_name, source_name, " <>
        "source_observed_at, state, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(item_params)), ", ")})",
      item_params
    )

    item_id =
      select_id!(
        repo,
        "github_import_repository_items",
        "github_repository_id",
        9_900_000_000 + seed.suffix
      )

    %{
      repository_id: repository_id,
      item_id: item_id,
      run_id: run_id,
      identity_id: identity_id
    }
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

  defp assert_write_version_schema!(repo) do
    assert table_column_contract(repo, "repositories", "write_version") == {false, "0"}

    assert table_column_contract(
             repo,
             "github_import_repository_items",
             "replacement_write_version"
           ) == {true, nil}

    assert constraint_exists?(repo, "repositories_write_version_nonnegative_check")

    assert constraint_exists?(
             repo,
             "github_import_repository_items",
             "github_import_items_replacement_write_version_nonnegative_check"
           )
  end

  defp write_version_projection(repo, seeded) do
    repository_placeholder = List.first(placeholders(1))
    item_placeholder = List.first(placeholders(1))

    %{rows: [[write_version]]} =
      SQL.query!(
        repo,
        "select write_version from repositories where id = #{repository_placeholder}",
        [seeded.repository_id]
      )

    %{rows: [[replacement_write_version]]} =
      SQL.query!(
        repo,
        "select replacement_write_version from github_import_repository_items " <>
          "where id = #{item_placeholder}",
        [seeded.item_id]
      )

    {write_version, replacement_write_version}
  end

  defp staged_path_column_type(repo) do
    if postgres?() do
      %{rows: [[type, length]]} =
        SQL.query!(
          repo,
          "select data_type, character_maximum_length from information_schema.columns " <>
            "where table_schema = current_schema() and " <>
            "table_name = 'github_import_repository_items' and " <>
            "column_name = 'staged_storage_path'",
          []
        )

      {type, length}
    else
      %{rows: rows} =
        SQL.query!(repo, "pragma table_info('github_import_repository_items')", [])

      row = Enum.find(rows, &(Enum.at(&1, 1) == "staged_storage_path"))
      {Enum.at(row, 2), nil}
    end
  end

  defp update_staged_path!(repo, item_id, value) do
    [value_placeholder, id_placeholder] = placeholders(2)

    SQL.query!(
      repo,
      "update github_import_repository_items " <>
        "set staged_storage_path = #{value_placeholder} where id = #{id_placeholder}",
      [value, item_id]
    )
  end

  defp staged_path_value(repo, item_id) do
    placeholder = List.first(placeholders(1))

    %{rows: [[value]]} =
      SQL.query!(
        repo,
        "select staged_storage_path from github_import_repository_items " <>
          "where id = #{placeholder}",
        [item_id]
      )

    value
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
    table_column_contract(repo, "repositories", column)
  end

  defp table_column_contract(repo, table, column) do
    if postgres?() do
      %{rows: [[nullable, default]]} =
        SQL.query!(
          repo,
          "select is_nullable, column_default from information_schema.columns " <>
            "where table_schema = current_schema() and table_name = $1 and column_name = $2",
          [table, column]
        )

      {nullable == "YES", normalize_default(default)}
    else
      %{rows: rows} = SQL.query!(repo, "pragma table_info('#{table}')", [])
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

  defp constraint_exists?(repo, name), do: constraint_exists?(repo, "repositories", name)

  defp constraint_exists?(repo, table, name) do
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
          [table]
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
    table_column_exists?(repo, "repositories", column)
  end

  defp table_column_exists?(repo, table, column) do
    if postgres?() do
      %{rows: [[exists?]]} =
        SQL.query!(
          repo,
          "select exists (select 1 from information_schema.columns " <>
            "where table_schema = current_schema() and table_name = $1 and column_name = $2)",
          [table, column]
        )

      exists?
    else
      %{rows: rows} = SQL.query!(repo, "pragma table_info('#{table}')", [])
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

  defp with_complete_restore(repo, body, cleanup \\ fn -> :ok end) do
    if postgres?() do
      MigrationTestSupport.with_restore(body, fn ->
        ensure_up!(repo, @version)
        ensure_up!(repo, @write_version)
        ensure_up!(repo, @staged_path_version)
        ensure_up!(repo, @cleanup_recovery_version)
        ensure_up!(repo, @cleanup_selector_version)
        cleanup.()
      end)
    else
      body.()
    end
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

  defp delete_write_version_seed!(repo, seed) do
    SQL.query!(
      repo,
      "delete from github_import_repository_items where import_run_id in " <>
        "(select id from github_import_runs where source_owner_login = $1)",
      [seed.username]
    )

    SQL.query!(repo, "delete from github_import_runs where source_owner_login = $1", [
      seed.username
    ])

    SQL.query!(repo, "delete from github_identities where login = $1", [seed.username])
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
