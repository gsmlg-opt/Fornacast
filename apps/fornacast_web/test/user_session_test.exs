defmodule FornacastWeb.UserSessionTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_session: 2]

  alias ForgeAccounts.User
  alias Fornacast.Repo
  alias FornacastWeb.{Plugs.CurrentUser, UserSession}
  alias Phoenix.SessionProcess

  @endpoint FornacastWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()

    on_exit(fn ->
      Fornacast.Setup.reset!()

      for {id, _pid} <- SessionProcess.list_session(), String.starts_with?(id, "fornacast_") do
        SessionProcess.terminate(id)
      end
    end)

    %{user: user_fixture("moonlight")}
  end

  test "requests check identity but read appearance from the shared user process", %{user: user} do
    track_queries()
    conn = current_user_conn(user)
    assert conn.assigns.current_user.theme_preference == "moonlight"
    assert Enum.count(queries(), &configuration_query?/1) == 1

    conn = CurrentUser.call(conn, [])
    assert conn.assigns.current_user.theme_preference == "moonlight"
    repeated_queries = queries()
    assert Enum.any?(repeated_queries, &String.contains?(&1, "users"))
    refute Enum.any?(repeated_queries, &configuration_query?/1)

    user_pid = process_pid(UserSession.user_process_id(user))
    session_pid = process_pid(get_session(conn, :session_id))
    assert user_pid != session_pid
    assert :sys.get_state(user_pid) == %{user_id: user.id, theme_preference: "moonlight"}
    assert :sys.get_state(session_pid) == %{user_id: user.id}
  end

  test "two logins create exactly one user process and two distinct session processes", %{
    user: user
  } do
    first = login_conn(user)
    second = login_conn(user)
    user_pid = process_pid(UserSession.user_process_id(user))
    first_pid = process_pid(get_session(first, :session_id))
    second_pid = process_pid(get_session(second, :session_id))

    assert length(Enum.uniq([user_pid, first_pid, second_pid])) == 3
    assert length(user_processes(user)) == 1
    assert length(session_processes(user)) == 2
    assert :sys.get_state(first_pid) == %{user_id: user.id}
    assert :sys.get_state(second_pid) == %{user_id: user.id}
  end

  test "another login uses cached user configuration without configuration SQL", %{user: user} do
    first = login_conn(user)
    user_pid = process_pid(UserSession.user_process_id(user))

    assert {:ok, updated} =
             ForgeAccounts.update_user_appearance(user, %{theme_preference: "sunshine"})

    track_queries()
    second = login_conn(updated) |> CurrentUser.call([])

    assert second.assigns.current_user.theme_preference == "moonlight"
    assert process_pid(UserSession.user_process_id(user)) == user_pid
    assert get_session(first, :session_id) != get_session(second, :session_id)
    refute Enum.any?(queries(), &configuration_query?/1)
  end

  test "saving appearance updates the shared user process for every session without SQL", %{
    user: user
  } do
    first = current_user_conn(user)
    second = current_user_conn(user)
    assert {:ok, first} = UserSession.save_appearance(first, %{theme_preference: "auto"})
    track_queries()

    first = CurrentUser.call(first, [])
    second = CurrentUser.call(second, [])
    assert first.assigns.current_user.theme_preference == "auto"
    assert second.assigns.current_user.theme_preference == "auto"
    refute Enum.any?(queries(), &configuration_query?/1)
    assert length(user_processes(user)) == 1
  end

  test "logout retires only its session and leaves the user and another session alive", %{
    user: user
  } do
    first = login_conn(user)
    second = login_conn(user)
    user_id = UserSession.user_process_id(user)
    first_id = get_session(first, :session_id)
    second_id = get_session(second, :session_id)
    user_pid = process_pid(user_id)
    second_pid = process_pid(second_id)

    assert {:ok, first} = UserSession.log_out(first)
    assert get_session(first, :session_id) == nil
    assert_removed(first_id)
    assert process_pid(user_id) == user_pid
    assert process_pid(second_id) == second_pid
    assert_metadata_present(user_id)
    assert_metadata_present(second_id)
    assert CurrentUser.call(second, []).assigns.current_user.theme_preference == "moonlight"
  end

  test "ownership mismatch rotates the session and keeps user processes isolated", %{user: user} do
    owner_conn = current_user_conn(user)
    owner_id = get_session(owner_conn, :session_id)
    owner_pid = process_pid(owner_id)
    user_pid = process_pid(UserSession.user_process_id(user))
    other = user_fixture("sunshine")

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: other.id, session_id: owner_id)
      |> CurrentUser.call([])

    assert get_session(conn, :session_id) != owner_id
    assert conn.assigns.current_user.id == other.id
    assert conn.assigns.current_user.theme_preference == "sunshine"
    assert process_pid(owner_id) == owner_pid
    assert process_pid(UserSession.user_process_id(user)) == user_pid
    assert :sys.get_state(user_pid).theme_preference == "moonlight"
    assert process_pid(UserSession.user_process_id(other)) != user_pid
  end

  test "missing session rotates its token without reloading live user configuration", %{
    user: user
  } do
    conn = current_user_conn(user)
    old_id = get_session(conn, :session_id)
    user_pid = process_pid(UserSession.user_process_id(user))
    assert {:ok, _} = ForgeAccounts.update_user_appearance(user, %{theme_preference: "sunshine"})
    assert :ok = SessionProcess.terminate(old_id)
    assert_removed(old_id)
    track_queries()
    conn = CurrentUser.call(conn, [])

    assert get_session(conn, :session_id) != old_id
    assert_removed(old_id)
    assert_metadata_present(get_session(conn, :session_id))
    assert process_pid(UserSession.user_process_id(user)) == user_pid
    assert conn.assigns.current_user.theme_preference == "moonlight"
    refute Enum.any?(queries(), &configuration_query?/1)
  end

  test "missing user process reloads once while both session processes remain", %{user: user} do
    first = current_user_conn(user)
    second = current_user_conn(user)
    first_pid = process_pid(get_session(first, :session_id))
    second_pid = process_pid(get_session(second, :session_id))
    user_id = UserSession.user_process_id(user)
    old_pid = process_pid(user_id)
    assert {:ok, _} = ForgeAccounts.update_user_appearance(user, %{theme_preference: "sunshine"})
    assert :ok = SessionProcess.terminate(user_id)
    assert_removed(user_id)
    track_queries()

    first = CurrentUser.call(first, [])
    second = CurrentUser.call(second, [])
    assert first.assigns.current_user.theme_preference == "sunshine"
    assert second.assigns.current_user.theme_preference == "sunshine"
    assert Enum.count(queries(), &configuration_query?/1) == 1
    assert process_pid(user_id) != old_pid
    assert process_pid(get_session(first, :session_id)) == first_pid
    assert process_pid(get_session(second, :session_id)) == second_pid
    assert_metadata_present(user_id)
  end

  test "expired user process reloads once without expiring either session", %{user: user} do
    first = current_user_conn(user)
    second = current_user_conn(user)
    user_id = UserSession.user_process_id(user)
    old_pid = process_pid(user_id)
    first_id = get_session(first, :session_id)
    second_id = get_session(second, :session_id)
    assert {:ok, _} = ForgeAccounts.update_user_appearance(user, %{theme_preference: "sunshine"})
    expire_process(user_id)
    assert SessionProcess.started?(first_id)
    assert SessionProcess.started?(second_id)
    track_queries()

    first = CurrentUser.call(first, [])
    second = CurrentUser.call(second, [])
    assert first.assigns.current_user.theme_preference == "sunshine"
    assert second.assigns.current_user.theme_preference == "sunshine"
    assert Enum.count(queries(), &configuration_query?/1) == 1
    assert process_pid(user_id) != old_pid
    assert get_session(first, :session_id) == first_id
    assert get_session(second, :session_id) == second_id
    assert_metadata_present(user_id)
  end

  test "crashed user process reloads once while session processes stay alive", %{user: user} do
    first = current_user_conn(user)
    second = current_user_conn(user)
    user_id = UserSession.user_process_id(user)
    old_pid = process_pid(user_id)
    assert {:ok, _} = ForgeAccounts.update_user_appearance(user, %{theme_preference: "sunshine"})
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}
    await_missing(user_id)
    track_queries()

    first = CurrentUser.call(first, [])
    second = CurrentUser.call(second, [])
    assert first.assigns.current_user.theme_preference == "sunshine"
    assert second.assigns.current_user.theme_preference == "sunshine"
    assert Enum.count(queries(), &configuration_query?/1) == 1
    assert_metadata_present(user_id)
    assert SessionProcess.started?(get_session(first, :session_id))
    assert SessionProcess.started?(get_session(second, :session_id))
  end

  test "user reconstruction waits for an overlapping upstream cleanup callback", %{user: user} do
    conn = current_user_conn(user)
    id = UserSession.user_process_id(user)
    old_pid = process_pid(id)
    assert {:ok, _} = ForgeAccounts.update_user_appearance(user, %{theme_preference: "sunshine"})
    cleanup_pid = Process.whereis(SessionProcess.Cleanup)
    handler_id = {__MODULE__, :cleanup_barrier, make_ref()}
    release_key = {handler_id, :released}
    previous_ttl = Application.get_env(:phoenix_session_process, :session_ttl)

    :ok =
      :telemetry.attach(
        handler_id,
        [:phoenix, :session_process, :stop],
        &__MODULE__.pause_cleanup_stop/4,
        %{id: id, cleanup_pid: cleanup_pid, test_pid: self()}
      )

    try do
      Application.put_env(:phoenix_session_process, :session_ttl, 1)
      Process.sleep(5)
      send(cleanup_pid, {:cleanup_session, id})
      assert_receive {:cleanup_paused, ^cleanup_pid}, 500
      restore_ttl(previous_ttl)
      await_missing(id)
      track_queries()
      test_pid = self()

      [task] =
        start_requests([
          fn ->
            send(test_pid, :reader_started)
            hydrated = CurrentUser.call(conn, [])
            send(test_pid, :reader_finished)
            hydrated
          end
        ])

      assert_receive :reader_started
      refute_receive :reader_finished, 100
      assert {:error, :not_found} = SessionProcess.find_session(id)
      Process.put(release_key, true)
      send(cleanup_pid, :resume_cleanup)
      conn = Task.await(task)

      assert conn.assigns.current_user.theme_preference == "sunshine"
      assert process_pid(id) != old_pid
      assert Enum.count(queries(), &configuration_query?/1) == 1
      assert_metadata_present(id)
    after
      unless Process.delete(release_key), do: send(cleanup_pid, :resume_cleanup)
      :telemetry.detach(handler_id)
      restore_ttl(previous_ttl)
    end
  end

  test "concurrent first requests initialize user configuration exactly once", %{user: user} do
    track_queries()
    tasks = start_requests([fn -> current_user_conn(user) end, fn -> current_user_conn(user) end])
    conns = Enum.map(tasks, &Task.await/1)

    assert Enum.all?(conns, &(&1.assigns.current_user.theme_preference == "moonlight"))
    assert Enum.count(queries(), &configuration_query?/1) == 1
    assert length(user_processes(user)) == 1
    assert length(session_processes(user)) == 2
    assert_metadata_present(UserSession.user_process_id(user))
  end

  test "concurrent saves and a reader leave all sessions consistent with durable configuration",
       %{user: user} do
    first = current_user_conn(user)
    second = current_user_conn(user)

    tasks =
      start_requests([
        fn -> UserSession.save_appearance(first, %{theme_preference: "sunshine"}) end,
        fn -> UserSession.save_appearance(second, %{theme_preference: "auto"}) end,
        fn -> CurrentUser.call(second, []) end
      ])

    [first_result, second_result, _read_result] = Enum.map(tasks, &Task.await/1)
    assert {:ok, _} = first_result
    assert {:ok, _} = second_result
    stored_theme = ForgeAccounts.get_user(user.id).theme_preference
    track_queries()

    assert CurrentUser.call(first, []).assigns.current_user.theme_preference == stored_theme
    assert CurrentUser.call(second, []).assigns.current_user.theme_preference == stored_theme
    refute Enum.any?(queries(), &configuration_query?/1)
    assert length(user_processes(user)) == 1
  end

  test "put_appearance initializes a missing user process from the saved user without a reload",
       %{user: user} do
    conn = current_user_conn(user)
    user_id = UserSession.user_process_id(user)

    assert {:ok, updated} =
             ForgeAccounts.update_user_appearance(user, %{theme_preference: "auto"})

    assert :ok = SessionProcess.terminate(user_id)
    track_queries()

    assert {:ok, conn} = UserSession.put_appearance(conn, updated)
    assert CurrentUser.call(conn, []).assigns.current_user.theme_preference == "auto"
    refute Enum.any?(queries(), &configuration_query?/1)
    assert_metadata_present(user_id)
  end

  test "login rotation and HTTP logout retain the shared user process", %{user: user} do
    conn = current_user_conn(user) |> get("/login")
    old_id = get_session(conn, :session_id)
    user_pid = process_pid(UserSession.user_process_id(user))

    conn =
      conn
      |> recycle()
      |> post("/login", %{
        "session" => %{"username" => user.username, "password" => "session-test-password"}
      })

    assert redirected_to(conn) == "/"
    new_id = get_session(conn, :session_id)
    assert new_id != old_id
    assert_removed(old_id)
    assert_metadata_present(new_id)
    assert process_pid(UserSession.user_process_id(user)) == user_pid

    conn = conn |> recycle() |> delete("/logout")
    assert redirected_to(conn) == "/login"
    assert_removed(new_id)
    assert process_pid(UserSession.user_process_id(user)) == user_pid
  end

  test "disabled identity retires its session without treating shared user state as authorization",
       %{user: user} do
    conn = current_user_conn(user)
    other_conn = current_user_conn(user)
    session_id = get_session(conn, :session_id)
    other_id = get_session(other_conn, :session_id)
    user_pid = process_pid(UserSession.user_process_id(user))
    user |> User.state_changeset(%{state: :disabled}) |> Repo.update!()
    conn = CurrentUser.call(conn, [])

    assert conn.assigns.current_user == nil
    assert get_session(conn, :user_id) == nil
    assert get_session(conn, :session_id) == nil
    assert_removed(session_id)
    assert process_pid(UserSession.user_process_id(user)) == user_pid
    assert SessionProcess.started?(other_id)
    assert CurrentUser.call(other_conn, []).assigns.current_user == nil
    assert_removed(other_id)
  end

  test "anonymous requests create neither a user nor a session process" do
    before = SessionProcess.session_info().count
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> CurrentUser.call([])
    assert conn.assigns.current_user == nil
    assert get_session(conn, :session_id) == nil
    assert SessionProcess.session_info().count == before
  end

  defp process_pid(id) do
    assert {:ok, pid} = SessionProcess.find_session(id)
    pid
  end

  defp user_processes(user) do
    Enum.filter(SessionProcess.list_session(), fn {id, _} ->
      id == UserSession.user_process_id(user)
    end)
  end

  defp session_processes(user) do
    Enum.filter(SessionProcess.list_session(), fn {id, pid} ->
      String.starts_with?(id, "fornacast_session_") and :sys.get_state(pid) == %{user_id: user.id}
    end)
  end

  defp login_conn(user) do
    assert {:ok, conn} =
             UserSession.log_in(build_conn() |> Plug.Test.init_test_session(%{}), user)

    conn
  end

  defp current_user_conn(user) do
    build_conn() |> Plug.Test.init_test_session(user_id: user.id) |> CurrentUser.call([])
  end

  defp assert_removed(id) do
    refute SessionProcess.started?(id)
    assert {:error, :not_found} = SessionProcess.ActivityTracker.get_last_activity(id)
    refute Map.has_key?(:sys.get_state(SessionProcess.Cleanup).timers, id)
  end

  defp assert_metadata_present(id) do
    assert SessionProcess.started?(id)
    assert {:ok, _timestamp} = SessionProcess.ActivityTracker.get_last_activity(id)
    assert Map.has_key?(:sys.get_state(SessionProcess.Cleanup).timers, id)
  end

  defp expire_process(id) do
    pid = process_pid(id)
    monitor = Process.monitor(pid)
    previous_ttl = Application.get_env(:phoenix_session_process, :session_ttl)

    try do
      Application.put_env(:phoenix_session_process, :session_ttl, 1)
      Process.sleep(5)
      send(SessionProcess.Cleanup, {:cleanup_session, id})
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 500
    after
      restore_ttl(previous_ttl)
    end
  end

  defp restore_ttl(nil), do: Application.delete_env(:phoenix_session_process, :session_ttl)
  defp restore_ttl(ttl), do: Application.put_env(:phoenix_session_process, :session_ttl, ttl)

  defp start_requests(functions) do
    tasks =
      for function <- functions do
        Task.async(fn ->
          receive do
            :run -> function.()
          end
        end)
      end

    for task <- tasks do
      :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
      send(task.pid, :run)
    end

    tasks
  end

  defp user_fixture(theme) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      username: "session-#{suffix}",
      email: "session-#{suffix}@example.test",
      password_hash: Bcrypt.hash_pwd_salt("session-test-password"),
      theme_preference: theme
    })
  end

  defp track_queries do
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:fornacast, :repo, :query],
        &__MODULE__.record_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def record_query(_event, _measurements, %{query: query}, test_pid) do
    send(test_pid, {:session_query, query})
  end

  def pause_cleanup_stop(_event, _measurements, %{session_id: id}, %{id: id} = config) do
    if self() == config.cleanup_pid do
      send(config.test_pid, {:cleanup_paused, self()})

      receive do
        :resume_cleanup -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  def pause_cleanup_stop(_event, _measurements, _metadata, _config), do: :ok

  defp queries(acc \\ []) do
    receive do
      {:session_query, query} -> queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp configuration_query?(query) do
    String.contains?(query, "users") and String.contains?(query, "theme_preference")
  end

  defp await_missing(id, attempts \\ 50)
  defp await_missing(_id, 0), do: flunk("crashed process remained registered")

  defp await_missing(id, attempts) do
    if SessionProcess.started?(id) do
      Process.sleep(10)
      await_missing(id, attempts - 1)
    else
      :ok
    end
  end
end
