defmodule FornacastWeb.AppearanceSettingsControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Fornacast.Repo
  alias Phoenix.SessionProcess

  @endpoint FornacastWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)

    username = "appearance-#{System.unique_integer([:positive])}"

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    on_exit(fn ->
      for {id, _pid} <- SessionProcess.list_session() do
        SessionProcess.terminate(id)
      end
    end)

    %{user: user}
  end

  test "Appearance displays the stored choice and active navigation", %{user: user} do
    {:ok, user} = ForgeAccounts.update_user_appearance(user, %{theme_preference: "moonlight"})
    conn = authenticated(user) |> get("/settings/appearance")
    html = html_response(conn, 200)

    assert html =~
             ~s(<a href="/settings/appearance" class="active" aria-current="page">Appearance</a>)

    assert html =~ ~s(data-theme="moonlight" data-theme-preference="moonlight")
    assert html =~ ~s(name="appearance[theme_preference]")
    assert html =~ ~s(action="/settings/appearance")
    assert html =~ ~s(name="_csrf_token")
    assert html =~ "Save changes"
    document = LazyHTML.from_document(html)

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#appearance-theme option[selected]"),
             "value"
           ) == ["moonlight"]

    assert LazyHTML.attribute(LazyHTML.query(document, "#appearance-theme option"), "value") == [
             "auto",
             "sunshine",
             "moonlight"
           ]

    refute html =~ "theme-menu"
  end

  test "save persists the account preference and updates existing sibling sessions", %{user: user} do
    initial = authenticated(user) |> get("/settings/appearance")
    sibling = authenticated(user) |> get("/settings/appearance")

    refute Plug.Conn.get_session(initial, :session_id) ==
             Plug.Conn.get_session(sibling, :session_id)

    saved =
      initial
      |> recycle()
      |> patch("/settings/appearance", %{
        "appearance" => %{"theme_preference" => "moonlight", "role" => "admin"}
      })

    assert redirected_to(saved, 303) == "/settings/appearance"
    assert %{theme_preference: "moonlight", role: :user} = Repo.reload!(user)

    same_session = saved |> recycle() |> get("/settings/appearance")
    assert html_response(same_session, 200) =~ "Appearance settings saved."
    assert html_response(same_session, 200) =~ ~s(data-theme-preference="moonlight")

    sibling = sibling |> recycle() |> get("/settings/appearance")
    assert html_response(sibling, 200) =~ ~s(data-theme-preference="moonlight")

    fresh_session = authenticated(user) |> get("/settings")
    assert html_response(fresh_session, 200) =~ ~s(data-theme-preference="moonlight")
  end

  test "invalid or missing choices preserve the stored and cached preference", %{user: user} do
    {:ok, user} = ForgeAccounts.update_user_appearance(user, %{theme_preference: "moonlight"})
    initial = authenticated(user) |> get("/settings/appearance")

    for params <- [
          %{},
          %{"appearance" => %{}},
          %{"appearance" => %{"theme_preference" => "dark"}},
          %{"appearance" => "bad"}
        ] do
      conn = initial |> recycle() |> patch("/settings/appearance", params)
      html = html_response(conn, 422)
      assert html =~ "Choose Auto, Sunshine, or Moonlight."
      assert html =~ ~s(data-theme-preference="moonlight")
      assert %{theme_preference: "moonlight"} = Repo.reload!(user)
    end
  end

  test "anonymous pages always load auto and Appearance requires login" do
    html = build_conn() |> get("/login") |> html_response(200)
    assert html =~ ~s(data-theme-preference="auto")
    refute html =~ "theme-menu"

    assert build_conn() |> get("/settings/appearance") |> redirected_to() == "/login"

    assert build_conn()
           |> patch("/settings/appearance", %{
             "appearance" => %{"theme_preference" => "moonlight"}
           })
           |> redirected_to() == "/login"
  end

  test "repository rendering uses the same session preference", %{user: user} do
    {:ok, user} = ForgeAccounts.update_user_appearance(user, %{theme_preference: "moonlight"})
    conn = authenticated(user) |> get("/settings/appearance")
    conn = %{conn | state: :unset, resp_body: nil}
    rendered = FornacastWeb.HTML.repository_page(conn, "Repository", {:safe, "<p>Repository</p>"})
    assert rendered.resp_body =~ ~s(data-theme="moonlight" data-theme-preference="moonlight")
    refute rendered.resp_body =~ "theme-menu"
  end

  defp authenticated(user), do: build_conn() |> Plug.Test.init_test_session(user_id: user.id)
end
