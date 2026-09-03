defmodule ForgeImports.ImportSecurityTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ForgeAccounts.{OrganizationMember, User}
  alias Fornacast.{Page, Repo}

  @endpoint FornacastWeb.Endpoint
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    if postgres?(), do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    owner = user_fixture("import-security-owner")
    member = user_fixture("import-security-member")
    outsider = user_fixture("import-security-outsider")
    suffix = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)

    {:ok, organization} =
      ForgeAccounts.create_organization(owner, %{
        username: "import-org-#{suffix}",
        display_name: "Import Org #{suffix}",
        description: "Imported organization namespace"
      })

    for user <- [member] do
      Repo.insert!(%OrganizationMember{
        organization_id: organization.id,
        user_id: user.id,
        role: :member
      })
    end

    {:ok, public} =
      ForgeRepos.create_repository(organization, %{
        slug: "public-#{suffix}",
        name: "public-#{suffix}",
        visibility: :public
      })

    {:ok, private} =
      ForgeRepos.create_repository(organization, %{
        slug: "private-#{suffix}",
        name: "private-#{suffix}",
        visibility: :private
      })

    {:ok, shadow} =
      ForgeRepos.create_repository(organization, %{
        slug: "importing-private-#{suffix}",
        name: "importing-private-#{suffix}",
        visibility: :private
      })

    importing_private =
      shadow
      |> Ecto.Changeset.change(
        lifecycle: :importing,
        storage_path: "../importing-private-#{suffix}.git"
      )
      |> Repo.update!()

    %{
      owner: owner,
      member: member,
      outsider: outsider,
      organization: organization,
      public: public,
      private: private,
      importing_private: importing_private,
      suffix: suffix
    }
  end

  test "organization namespace pages hide importing private repositories from outsiders", %{
    organization: organization,
    outsider: outsider,
    public: public,
    importing_private: importing_private
  } do
    conn =
      outsider
      |> request_conn()
      |> get("/#{organization.username}")

    html = html_response(conn, 200)

    assert html =~ public.slug
    refute html =~ importing_private.slug
    refute html =~ importing_private.name
    assert_private_no_store(conn)
  end

  test "organization namespace pages hide importing private repositories from members", %{
    organization: organization,
    member: member,
    public: public,
    private: private,
    importing_private: importing_private
  } do
    conn =
      member
      |> request_conn()
      |> get("/#{organization.username}")

    html = html_response(conn, 200)

    assert html =~ public.slug
    assert html =~ private.slug
    refute html =~ importing_private.slug
    refute html =~ importing_private.name
    assert_private_no_store(conn)
  end

  test "organization owners see ready repositories but not importing shadows", %{
    organization: organization,
    owner: owner,
    public: public,
    private: private,
    importing_private: importing_private
  } do
    conn =
      owner
      |> request_conn()
      |> get("/#{organization.username}")

    html = html_response(conn, 200)

    assert html =~ public.slug
    assert html =~ private.slug
    refute html =~ importing_private.slug
    refute html =~ importing_private.name
    assert_private_no_store(conn)
  end

  test "repository views exclude importing lifecycle rows for arbitrary authenticated users", %{
    organization: organization,
    owner: owner,
    outsider: outsider,
    public: public,
    importing_private: importing_private
  } do
    assert {:ok, %Page{entries: outsider_entries}} =
             ForgeRepos.list_account_repository_views(outsider, organization,
               page: 1,
               per_page: 100
             )

    outsider_ids = MapSet.new(outsider_entries, & &1.repository.id)
    assert public.id in outsider_ids
    refute importing_private.id in outsider_ids

    assert {:error, :not_found} = ForgeRepos.repository_view(outsider, importing_private)

    assert {:ok, %Page{entries: entries}} =
             ForgeRepos.list_account_repository_views(owner, organization,
               visibility_ceiling: :all,
               page: 1,
               per_page: 100
             )

    visible_ids = MapSet.new(entries, & &1.repository.id)
    assert public.id in visible_ids
    refute importing_private.id in visible_ids
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
