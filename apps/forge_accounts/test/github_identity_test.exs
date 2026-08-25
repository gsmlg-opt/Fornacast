defmodule ForgeAccounts.GitHubIdentityTest do
  use ExUnit.Case, async: false

  alias Ecto.Changeset
  alias ForgeAccounts.{GitHubIdentity, GitHubIdentityWrite, Organization, User}
  alias Ecto.Adapters.SQL
  alias Fornacast.Repo

  setup do
    reset_database!()
  end

  test "repeated observation uses the stable 64-bit ID while refreshing mutable profile fields" do
    observed_at = ~U[2026-08-25 01:02:03Z]

    assert {:ok, first} =
             ForgeAccounts.observe_github_identity(
               profile(9_000_000_001, "alice-gh"),
               observed_at
             )

    assert first.github_user_id == 9_000_000_001
    assert first.login == "alice-gh"
    assert first.avatar_url == "https://avatars.githubusercontent.com/u/9000000001"
    assert first.profile_url == "https://github.com/alice-gh"
    assert first.last_observed_at == observed_at

    assert {:ok, refreshed} =
             ForgeAccounts.observe_github_identity(
               profile(9_000_000_001, "alice-renamed",
                 avatar_url: "https://github.com/images/alice.png"
               ),
               ~U[2026-08-25 02:03:04Z]
             )

    assert refreshed.id == first.id
    assert refreshed.login == "alice-renamed"
    assert refreshed.avatar_url == "https://github.com/images/alice.png"
    assert refreshed.profile_url == "https://github.com/alice-renamed"
    assert refreshed.last_observed_at == ~U[2026-08-25 02:03:04Z]

    assert Enum.any?(
             GitHubIdentity.observed_changeset(
               %GitHubIdentity{},
               profile(9_000_000_001, "alice-gh")
             ).constraints,
             &(&1.constraint == "github_identities_user_id_index" and
                 &1.field == :github_user_id and &1.type == :unique)
           )
  end

  test "a delayed older observation cannot regress newer GitHub profile data" do
    newer_at = ~U[2026-08-25 02:00:00Z]
    older_at = ~U[2026-08-25 01:00:00Z]

    assert {:ok, newest} =
             ForgeAccounts.observe_github_identity(
               profile(9_000_000_001, "new-login", avatar_url: "https://github.com/new-avatar"),
               newer_at
             )

    assert {:ok, returned} =
             ForgeAccounts.observe_github_identity(
               profile(9_000_000_001, "old-login", avatar_url: "https://github.com/old-avatar"),
               older_at
             )

    assert returned.id == newest.id
    assert returned.login == "new-login"
    assert returned.avatar_url == "https://github.com/new-avatar"
    assert returned.last_verified_at == newer_at
    assert returned.last_observed_at == newer_at
    assert returned.updated_at == newest.updated_at
  end

  test "concurrent observations retain the newest profile data" do
    prepare_independent_identity_concurrency!()

    results =
      run_independent_workers(
        [
          {profile(9_000_000_001, "old-login"), ~U[2026-08-25 01:00:00Z]},
          {profile(9_000_000_001, "new-login"), ~U[2026-08-25 02:00:00Z]}
        ],
        fn {profile, observed_at} ->
          ForgeAccounts.observe_github_identity(profile, observed_at)
        end
      )

    assert Enum.all?(results, &match?({:ok, %GitHubIdentity{}}, &1))

    assert %GitHubIdentity{login: "new-login", last_observed_at: ~U[2026-08-25 02:00:00Z]} =
             independent_identity!(github_user_id: 9_000_000_001)
  end

  test "repeated observation remains usable inside a PostgreSQL outer transaction" do
    if postgres?() do
      prepare_independent_identity_concurrency!()

      SQL.Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %GitHubIdentity{login: "new-login"}} =
                 Repo.transaction(fn ->
                   assert {:ok, _} =
                            ForgeAccounts.observe_github_identity(
                              profile(9_000_000_001, "old-login"),
                              ~U[2026-08-25 01:00:00Z]
                            )

                   assert {:ok, identity} =
                            ForgeAccounts.observe_github_identity(
                              profile(9_000_000_001, "new-login"),
                              ~U[2026-08-25 02:00:00Z]
                            )

                   assert %{rows: [[1]]} = SQL.query!(Repo, "SELECT 1", [])
                   identity
                 end)
      end)
    else
      assert true
    end
  end

  test "a fresh observation parses on PostgreSQL" do
    if postgres?() do
      prepare_independent_identity_concurrency!()

      SQL.Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %GitHubIdentity{login: "fresh-login"}} =
                 ForgeAccounts.observe_github_identity(
                   profile(9_000_000_099, "fresh-login"),
                   ~U[2026-08-25 03:00:00Z]
                 )
      end)
    else
      assert true
    end
  end

  test "round-trips allowlisted profile URLs longer than 255 characters" do
    long_path = String.duplicate("a", 300)

    attrs =
      profile(9_000_000_001, "octocat",
        avatar_url: "https://avatars.githubusercontent.com/#{long_path}",
        profile_url: "https://github.com/#{long_path}"
      )

    assert {:ok, identity} = ForgeAccounts.observe_github_identity(attrs, now())
    assert identity.avatar_url == attrs.avatar_url
    assert identity.profile_url == attrs.profile_url
    assert String.length(identity.avatar_url) > 255
    assert String.length(identity.profile_url) > 255
  end

  test "validates GitHub profile strings and trusted HTTPS URLs" do
    valid = GitHubIdentity.observed_changeset(%GitHubIdentity{}, profile(42, "octocat"))
    assert valid.valid?

    for attrs <- [
          %{login: ""},
          %{login: "octo\0cat"},
          %{login: String.duplicate("a", 256)},
          %{profile_url: "http://github.com/octocat"},
          %{profile_url: "https://example.com/octocat"},
          %{profile_url: "https:foo"},
          %{profile_url: "https://"},
          %{avatar_url: "http://avatars.githubusercontent.com/u/42"},
          %{avatar_url: "https://example.com/u/42"},
          %{avatar_url: "https:foo"},
          %{avatar_url: "https://"},
          %{avatar_url: "https://avatars.githubusercontent.com/u/42\0"}
        ] do
      changeset =
        GitHubIdentity.observed_changeset(
          %GitHubIdentity{},
          Map.merge(profile(42, "octocat"), attrs)
        )

      refute changeset.valid?
    end

    assert GitHubIdentity.observed_changeset(
             %GitHubIdentity{},
             profile(42, "octocat", avatar_url: nil, profile_url: nil)
           ).valid?
  end

  test "rejects GitHub IDs outside signed 64-bit range" do
    for github_user_id <- [-1, 9_223_372_036_854_775_808] do
      changeset =
        GitHubIdentity.observed_changeset(%GitHubIdentity{}, profile(github_user_id, "octocat"))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :github_user_id)
    end
  end

  test "one local user links multiple identities while one identity links once" do
    user = user_fixture("alice")

    assert {:ok, first} =
             ForgeAccounts.observe_github_identity(profile(9_000_000_001, "alice-gh"), now())

    assert {:ok, second} =
             ForgeAccounts.observe_github_identity(profile(9_000_000_002, "alice-work"), now())

    assert {:ok, %{local_user_id: user_id}} = ForgeAccounts.link_github_identity(user, first)
    assert user_id == user.id
    assert {:ok, %{local_user_id: user_id}} = ForgeAccounts.link_github_identity(user, second)
    assert user_id == user.id

    assert [9_000_000_001, 9_000_000_002] =
             ForgeAccounts.list_github_identities(user) |> Enum.map(& &1.github_user_id)
  end

  test "linking by a second user masks the existing link and same-user relinking is idempotent" do
    first_user = user_fixture("alice")
    second_user = user_fixture("bob")

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(profile(9_000_000_001, "alice-gh"), now())

    assert {:ok, linked} = ForgeAccounts.link_github_identity(first_user, identity)

    assert {:ok, %{id: linked_id, local_user_id: local_user_id}} =
             ForgeAccounts.link_github_identity(first_user, linked)

    assert linked_id == linked.id
    assert local_user_id == first_user.id
    assert {:error, :already_linked} = ForgeAccounts.link_github_identity(second_user, identity)
  end

  test "same-user relinking reloads current persisted identity data" do
    user = user_fixture("alice")

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(profile(9_000_000_001, "old-login"), now())

    assert {:ok, stale_link} = ForgeAccounts.link_github_identity(user, identity)

    assert {:ok, %GitHubIdentity{local_user_id: local_user_id}} =
             ForgeAccounts.observe_github_identity(
               profile(9_000_000_001, "new-login"),
               ~U[2026-08-25 02:00:00Z]
             )

    assert local_user_id == user.id

    assert {:ok, %GitHubIdentity{login: "new-login", local_user_id: local_user_id}} =
             ForgeAccounts.link_github_identity(user, stale_link)

    assert local_user_id == user.id
  end

  test "unlinking an active local user preserves the observed identity" do
    user = user_fixture("alice")

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(profile(9_000_000_001, "alice-gh"), now())

    assert {:ok, linked} = ForgeAccounts.link_github_identity(user, identity)

    assert {:ok, %{id: identity_id, local_user_id: nil}} =
             ForgeAccounts.unlink_github_identity(user, linked)

    assert identity_id == identity.id
    assert Repo.get!(GitHubIdentity, identity.id).github_user_id == 9_000_000_001
    assert [] = ForgeAccounts.list_github_identities(user)
  end

  test "unlink does not repeat a committed write when its reload is Turso-busy" do
    if turso?() do
      user = user_fixture("alice")

      assert {:ok, identity} =
               ForgeAccounts.observe_github_identity(profile(9_000_000_001, "alice-gh"), now())

      assert {:ok, linked} = ForgeAccounts.link_github_identity(user, identity)

      hook_key = {ForgeAccounts, :github_identity_read_hook}
      Process.put(hook_key, :busy_once)
      on_exit(fn -> Process.delete(hook_key) end)

      assert {:ok, %GitHubIdentity{local_user_id: nil}} =
               ForgeAccounts.unlink_github_identity(user, linked)

      assert Process.get(hook_key) == :used
    else
      assert true
    end
  end

  test "disabled and organization accounts cannot link or unlink identities" do
    disabled_user = user_fixture("disabled", state: :disabled)
    active_user = user_fixture("active")
    organization = organization_fixture("acme")

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(profile(9_000_000_001, "alice-gh"), now())

    assert {:error, :forbidden} = ForgeAccounts.link_github_identity(disabled_user, identity)
    assert {:error, :forbidden} = ForgeAccounts.link_github_identity(organization, identity)
    assert {:ok, linked} = ForgeAccounts.link_github_identity(active_user, identity)
    assert {:error, :forbidden} = ForgeAccounts.unlink_github_identity(disabled_user, linked)
    assert {:error, :forbidden} = ForgeAccounts.unlink_github_identity(organization, linked)
  end

  test "deleted authors share a non-linkable ghost sentinel" do
    assert %GitHubIdentity{
             kind: :deleted,
             login: "ghost",
             github_user_id: nil,
             local_user_id: nil
           } =
             first = ForgeAccounts.github_deleted_identity()

    assert %GitHubIdentity{id: first_id} = ForgeAccounts.github_deleted_identity()
    assert first_id == first.id
    assert GitHubIdentity.display_name(first) == "Github:ghost"
    assert {:error, :forbidden} = ForgeAccounts.link_github_identity(user_fixture("alice"), first)
  end

  test "concurrent deleted identity requests return one ghost row" do
    prepare_independent_identity_concurrency!()

    ids =
      run_independent_workers(1..8, fn _ -> ForgeAccounts.github_deleted_identity() end)
      |> Enum.map(fn %GitHubIdentity{id: id, kind: :deleted, login: "ghost"} -> id end)

    assert [id] = Enum.uniq(ids)
    assert %GitHubIdentity{id: ^id} = independent_identity!(kind: :deleted)
  end

  test "GitHub identity writes retry only Turso busy errors" do
    counter = :counters.new(1, [])

    busy_once = fn ->
      case :counters.get(counter, 1) do
        0 ->
          :counters.add(counter, 1, 1)
          raise Turso.Error, code: :busy, message: "database is locked"

        _ ->
          :ok
      end
    end

    if turso?() do
      assert :ok = GitHubIdentityWrite.with_retry(busy_once)
      assert :counters.get(counter, 1) == 1
    else
      assert_raise Turso.Error, "database is locked", fn ->
        GitHubIdentityWrite.with_retry(busy_once)
      end

      assert :counters.get(counter, 1) == 1
    end
  end

  test "GitHub identity writes do not retry non-busy errors" do
    counter = :counters.new(1, [])

    assert_raise Turso.Error, "constraint failed", fn ->
      GitHubIdentityWrite.with_retry(fn ->
        :counters.add(counter, 1, 1)
        raise Turso.Error, code: :constraint, message: "constraint failed"
      end)
    end

    assert :counters.get(counter, 1) == 1
  end

  test "Turso ghost creation recovers after a writer lock exceeds the old retry window" do
    if turso?() do
      lock = hold_turso_writer_lock()
      assert_receive :turso_writer_locked, 5_000

      ghost = Task.async(fn -> ForgeAccounts.github_deleted_identity() end)
      assert nil == Task.yield(ghost, 100)
      send(lock.pid, :release_turso_writer_lock)

      assert %GitHubIdentity{kind: :deleted} = Task.await(ghost, 5_000)
      assert {:ok, :released} = Task.await(lock, 5_000)
    else
      assert true
    end
  end

  test "Turso ghost creation exhausts bounded busy retries" do
    if turso?() do
      lock = hold_turso_writer_lock()
      assert_receive :turso_writer_locked, 5_000

      assert_raise Turso.Error, "database is locked", fn ->
        ForgeAccounts.github_deleted_identity()
      end

      send(lock.pid, :release_turso_writer_lock)
      assert {:ok, :released} = Task.await(lock, 5_000)
    else
      assert true
    end
  end

  test "database constraints enforce ordinary and deleted identity invariants" do
    assert {:error, %Changeset{errors: [github_user_id: {_, metadata}]}} =
             Repo.insert(
               %GitHubIdentity{}
               |> Changeset.change(%{kind: :user, github_user_id: nil, login: "missing-id"})
               |> Changeset.check_constraint(:github_user_id,
                 name: ~r/github_identities_user_id_required_check/
               )
             )

    assert metadata[:constraint] == :check

    assert {:error, %Changeset{errors: [github_user_id: {_, metadata}]}} =
             Repo.insert(
               %GitHubIdentity{}
               |> Changeset.change(%{
                 kind: :deleted,
                 github_user_id: 99,
                 login: "ghost",
                 local_user_id: nil
               })
               |> Changeset.check_constraint(:github_user_id,
                 name: ~r/github_identities_deleted_sentinel_check/
               )
             )

    assert metadata[:constraint] == :check

    assert {:error, %Changeset{errors: [login: {_, metadata}]}} =
             Repo.insert(
               %GitHubIdentity{}
               |> Changeset.change(%{
                 kind: :deleted,
                 github_user_id: nil,
                 login: "not-ghost",
                 local_user_id: nil
               })
               |> Changeset.check_constraint(:login,
                 name: ~r/github_identities_deleted_sentinel_check/
               )
             )

    assert metadata[:constraint] == :check

    local_user = user_fixture("alice")

    assert {:error, %Changeset{errors: [local_user_id: {_, metadata}]}} =
             Repo.insert(
               %GitHubIdentity{}
               |> Changeset.change(%{
                 kind: :deleted,
                 github_user_id: nil,
                 login: "ghost",
                 local_user_id: local_user.id
               })
               |> Changeset.check_constraint(:local_user_id,
                 name: ~r/github_identities_deleted_sentinel_check/
               )
             )

    assert metadata[:constraint] == :check
  end

  test "identity changesets expose stable presentation labels" do
    identity = %GitHubIdentity{kind: :user, login: "octocat"}

    assert GitHubIdentity.display_name(identity) == "Github:octocat"
    assert GitHubIdentity.link_changeset(identity, 123).valid?

    assert Changeset.get_change(
             GitHubIdentity.unlink_changeset(%{identity | local_user_id: 123}),
             :local_user_id
           ) == nil

    refute GitHubIdentity.link_changeset(%GitHubIdentity{kind: :deleted, login: "ghost"}, 123).valid?

    assert GitHubIdentity.deleted_changeset(%GitHubIdentity{}).valid?
  end

  defp profile(github_user_id, login, overrides \\ []) do
    %{
      github_user_id: github_user_id,
      login: login,
      avatar_url: "https://avatars.githubusercontent.com/u/#{github_user_id}",
      profile_url: "https://github.com/#{login}"
    }
    |> Map.merge(Map.new(overrides))
  end

  defp now, do: ~U[2026-08-25 01:00:00Z]

  defp user_fixture(username, opts \\ []) do
    Repo.insert!(%User{
      username: username,
      email: "#{username}@example.test",
      password_hash: "test-password-hash",
      kind: :user,
      role: :user,
      state: Keyword.get(opts, :state, :active)
    })
  end

  defp organization_fixture(username) do
    Repo.insert!(%Organization{
      username: username,
      email: "organization+#{username}@fornacast.invalid",
      password_hash: "organization-account",
      kind: :organization,
      state: :active
    })
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(reset_tables(), &Ecto.Adapters.SQL.query!(Repo, "delete from #{&1}", []))
    end
  end

  defp reset_tables do
    [
      "github_identities",
      "audit_events",
      "repository_collaborators",
      "repositories",
      "organization_members",
      "api_keys",
      "ssh_keys",
      "users"
    ]
  end

  defp prepare_independent_identity_concurrency! do
    if postgres?() do
      SQL.Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(GitHubIdentity) end)

      on_exit(fn ->
        SQL.Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(GitHubIdentity) end)
      end)
    end
  end

  defp independent_identity!(criteria) do
    if postgres?() do
      SQL.Sandbox.unboxed_run(Repo, fn -> Repo.get_by!(GitHubIdentity, criteria) end)
    else
      Repo.get_by!(GitHubIdentity, criteria)
    end
  end

  defp run_independent_workers(inputs, worker) do
    parent = self()
    ready_ref = make_ref()

    tasks =
      for input <- inputs do
        Task.async(fn ->
          _backend_pid = independent_connection!(ready_ref, parent)

          receive do
            {:go, ^ready_ref} ->
              try do
                worker.(input)
              after
                independent_checkin()
              end
          end
        end)
      end

    backend_pids = await_independent_workers(tasks, ready_ref)
    if postgres?(), do: assert(MapSet.size(MapSet.new(backend_pids)) > 1)

    Enum.each(tasks, fn task -> send(task.pid, {:go, ready_ref}) end)
    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  defp independent_connection!(ready_ref, parent) do
    backend_pid =
      if postgres?() do
        :ok = SQL.Sandbox.checkout(Repo, sandbox: false)
        %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
        backend_pid
      end

    send(parent, {ready_ref, self(), backend_pid})
    backend_pid
  end

  defp independent_checkin do
    if postgres?(), do: :ok = SQL.Sandbox.checkin(Repo)
  end

  defp await_independent_workers(tasks, ready_ref) do
    Enum.map(tasks, fn task ->
      receive do
        {^ready_ref, worker_pid, backend_pid} when worker_pid == task.pid -> backend_pid
      after
        15_000 -> flunk("independent identity worker did not reach the start barrier")
      end
    end)
  end

  defp hold_turso_writer_lock do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.insert!(
          GitHubIdentity.observed_changeset(
            %GitHubIdentity{},
            profile(9_000_000_099, "lock-holder",
              last_observed_at: now(),
              last_verified_at: now()
            )
          )
        )

        send(parent, :turso_writer_locked)

        receive do
          :release_turso_writer_lock -> :released
        end
      end)
    end)
  end

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]

  defp turso?, do: not postgres?()
end
