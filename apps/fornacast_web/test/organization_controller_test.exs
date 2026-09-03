defmodule FornacastWeb.OrganizationControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ForgeAccounts.{OrganizationMember, User}
  alias Fornacast.Repo

  @endpoint FornacastWeb.Endpoint
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    if postgres?(), do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    owner = user_fixture("namespace-owner")
    viewer = user_fixture("namespace-viewer")
    suffix = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)

    {:ok, public} =
      ForgeRepos.create_repository(owner, %{
        slug: "public-#{suffix}",
        name: "public-#{suffix}",
        visibility: :public
      })

    {:ok, private} =
      ForgeRepos.create_repository(owner, %{
        slug: "private-#{suffix}",
        name: "private-#{suffix}",
        visibility: :private
      })

    %{owner: owner, viewer: viewer, public: public, private: private}
  end

  test "an authenticated namespace page lists only repositories visible to its actor", %{
    owner: owner,
    viewer: viewer,
    public: public,
    private: private
  } do
    viewer_conn =
      viewer
      |> request_conn()
      |> get("/#{owner.username}")

    viewer_html = html_response(viewer_conn, 200)

    assert viewer_html =~ public.slug
    refute viewer_html =~ private.slug
    assert_private_no_store(viewer_conn)

    owner_conn =
      owner
      |> request_conn()
      |> get("/#{owner.username}")

    owner_html = html_response(owner_conn, 200)

    assert owner_html =~ public.slug
    assert owner_html =~ private.slug
    assert_private_no_store(owner_conn)
  end

  test "an organization namespace hides importing private repositories from members", %{
    owner: owner,
    viewer: viewer,
    public: public,
    private: private
  } do
    suffix = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)

    {:ok, organization} =
      ForgeAccounts.create_organization(owner, %{
        username: "org-#{suffix}",
        display_name: "Org #{suffix}",
        description: "Organization namespace"
      })

    Repo.insert!(%OrganizationMember{
      organization_id: organization.id,
      user_id: viewer.id,
      role: :member
    })

    {:ok, org_public} =
      ForgeRepos.create_repository(organization, %{
        slug: "org-public-#{suffix}",
        name: "org-public-#{suffix}",
        visibility: :public
      })

    {:ok, org_private} =
      ForgeRepos.create_repository(organization, %{
        slug: "org-private-#{suffix}",
        name: "org-private-#{suffix}",
        visibility: :private
      })

    {:ok, importing_shadow} =
      ForgeRepos.create_repository(organization, %{
        slug: "org-importing-#{suffix}",
        name: "org-importing-#{suffix}",
        visibility: :private
      })

    importing_shadow =
      importing_shadow
      |> Ecto.Changeset.change(
        lifecycle: :importing,
        storage_path: "../org-importing-#{suffix}.git"
      )
      |> Repo.update!()

    viewer_conn =
      viewer
      |> request_conn()
      |> get("/#{organization.username}")

    viewer_html = html_response(viewer_conn, 200)

    assert viewer_html =~ org_public.slug
    assert viewer_html =~ org_private.slug
    refute viewer_html =~ importing_shadow.slug
    refute viewer_html =~ public.slug
    refute viewer_html =~ private.slug
    assert_private_no_store(viewer_conn)
  end

  defp request_conn(user) do
    build_conn()
    |> Plug.Test.init_test_session(user_id: user.id)
  end

  defp user_fixture(prefix) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Repo.insert!(%User{
      username: "#{prefix}-#{suffix}",
      email: "#{prefix}-#{suffix}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp assert_private_no_store(conn) do
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert Plug.Conn.get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
end
