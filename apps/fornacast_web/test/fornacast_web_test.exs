defmodule FornacastWebTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint FornacastWeb.Endpoint
  @ed25519_public_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINUKfpNn72l8H0YnXfbkh6s4aAcrMmVsBWPfyPppa1i8 gao@mac-mini"

  setup do
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    :ok
  end

  test "HTML escaping protects repository content in inline pages" do
    assert FornacastWeb.HTML.escape(~s|<script>alert("x")</script>|) ==
             "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"
  end

  test "badge helper maps repository visibility to DuskMoon variants" do
    assert FornacastWeb.HTML.badge(:public, "public") ==
             ~s(<span class="badge badge-success">public</span>)

    assert FornacastWeb.HTML.badge(:private, "private") ==
             ~s(<span class="badge badge-secondary">private</span>)

    assert FornacastWeb.HTML.badge("Default") == ~s(<span class="badge">Default</span>)
  end

  @tag :tmp_dir
  test "authenticated shell renders workspace navigation in the appbar", %{tmp_dir: tmp_dir} do
    reset_database!()
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-shell@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, organization} =
             ForgeAccounts.create_organization(user, %{
               username: "acme",
               display_name: "ACME Engineering"
             })

    assert {:ok, _repo} =
             ForgeRepos.create_repository(user, %{
               name: "Personal app",
               slug: "personal-app"
             })

    assert {:ok, _org_repo} =
             ForgeRepos.create_repository(organization, %{
               name: "Org service",
               slug: "org-service"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> get("/")

    html = html_response(conn, 200)

    assert html =~
             ~s(<a class="brand-mark" href="/" aria-label="Fornacast dashboard">Fornacast</a>)

    assert html =~ ~s(<nav class="appbar-nav" aria-label="Workspace">)
    assert html =~ ~s(<a class="nav-link" href="/issues">Issues</a>)
    assert html =~ ~s(<a class="nav-link" href="/pulls">Pull Requests</a>)
    assert html =~ ~s(<details class="repo-menu">)
    assert html =~ ~s(<summary class="repo-menu-trigger" aria-label="User repositories")
    assert html =~ ~s(<span>User Repos</span>)
    assert html =~ ~s(<a class="repo-menu-item" href="/alice">alice</a>)
    assert html =~ ~s(<a class="repo-menu-item" href="/acme">ACME Engineering</a>)
    assert html =~ ~s(<details class="appbar-create-menu">)

    assert html =~
             ~s(<summary class="create-menu-trigger" aria-label="Create new" title="Create new">)

    assert html =~ ~s(<a class="create-menu-item" href="/repos/new">)
    assert html =~ ~s(<a class="create-menu-item" href="/repos/import">)
    assert html =~ ~s(<a class="create-menu-item" href="/organizations/new">)
    assert html =~ ~s(<details class="theme-menu">)
    assert html =~ ~s(<button type="button" class="theme-menu-item" data-theme-choice="auto")
    assert html =~ ~s(<button type="button" class="theme-menu-item" data-theme-choice="sunshine")
    assert html =~ ~s(<button type="button" class="theme-menu-item" data-theme-choice="moonlight")
    assert html =~ ~s(<details class="account-menu">)
    assert html =~ ~s(<a class="account-menu-item" href="/alice">Profile</a>)
    assert html =~ ~s(<a class="account-menu-item" href="/settings/ssh-keys">Settings</a>)
    assert html =~ ~s(<form action="/logout" method="post" class="account-menu-logout">)
    refute html =~ ~s(<a class="nav-link" href="/">Dashboard</a>)
    refute html =~ ~s(<a class="nav-link" href="/repos/new">New repository</a>)
    refute html =~ ~s(<a class="nav-link" href="/organizations/new">New organization</a>)
    refute html =~ ~s(<a class="nav-link" href="/ssh-keys">SSH keys</a>)
    refute html =~ ~s(<p class="repo-menu-owner">)
    refute html =~ ~s(<a class="repo-menu-item" href="/alice/personal-app")
    refute html =~ ~s(<a class="repo-menu-item" href="/acme/org-service")
    refute html =~ ~s(data-theme-toggle)
    refute html =~ ~s(class="account-pill")
    refute html =~ ~s(class="appbar-logout")
    refute html =~ ~s(<aside class="app-rail)
  end

  test "SSH keys are available from settings" do
    reset_database!()

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-settings@example.com",
               password: "correct horse battery staple"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> get("/settings/ssh-keys")

    html = html_response(conn, 200)
    assert html =~ "<h1>SSH keys</h1>"
    assert html =~ ~s(<form action="/settings/ssh-keys" method="post">)
    assert html =~ ~s(<a href="/settings/api-keys">API keys</a>)
  end

  test "API key settings create named scoped keys and reveal the secret once" do
    reset_database!()

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-api-keys@example.com",
               password: "correct horse battery staple"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> post("/settings/api-keys", %{
        "api_key" => %{
          "name" => "deploy & release",
          "scopes" => %{"repo:read" => "true", "repo:write" => "true"},
          "expires_at" => "2030-01-02T03:04:05"
        }
      })

    html = html_response(conn, 201)
    [secret] = Regex.run(~r/fc_pat_[A-Za-z0-9_-]+/, html)

    assert Enum.count(Regex.scan(~r/#{Regex.escape(secret)}/, html)) == 1
    assert html =~ "deploy &amp; release"
    assert html =~ "repo:read"
    assert html =~ "repo:write"
    assert html =~ "2030-01-02 03:04:05Z"
    assert Plug.Conn.get_resp_header(conn, "location") == []
    refute inspect(Plug.Conn.get_session(conn)) =~ secret
    refute html =~ "token_hash"

    assert [%{name: "deploy & release", scopes: scopes, token_hash: nil}] =
             ForgeAccounts.list_user_api_keys(user)

    assert scopes == %{"repo:read" => true, "repo:write" => true}
  end

  test "API key settings list multiple keys with metadata and allow owner revocation" do
    reset_database!()

    assert {:ok, alice} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-api-list@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, bob} =
             ForgeAccounts.create_user(%{
               username: "bob",
               email: "bob-api-list@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, first, _secret} =
             ForgeAccounts.create_api_key(alice, %{name: "laptop", scopes: ["repo:read"]})

    assert {:ok, second, _secret} =
             ForgeAccounts.create_api_key(alice, %{
               name: "automation",
               scopes: ["repo:write"],
               expires_at: "2031-04-05T06:07:08Z"
             })

    alice_conn = build_conn() |> Plug.Test.init_test_session(user_id: alice.id)
    html = alice_conn |> get("/settings/api-keys") |> html_response(200)

    assert html =~ "laptop"
    assert html =~ "automation"
    assert html =~ first.token_prefix
    assert html =~ second.token_prefix
    assert html =~ "repo:read"
    assert html =~ "repo:write"
    assert html =~ DateTime.to_string(second.inserted_at)
    assert html =~ "2031-04-05 06:07:08Z"
    assert html =~ ~s(action="/settings/api-keys/#{first.id}")

    bob_conn = build_conn() |> Plug.Test.init_test_session(user_id: bob.id)
    denied = delete(bob_conn, "/settings/api-keys/#{first.id}")
    assert redirected_to(denied) == "/settings/api-keys"
    assert is_nil(Fornacast.Repo.get!(ForgeAccounts.APIKey, first.id).revoked_at)

    revoked = delete(alice_conn, "/settings/api-keys/#{first.id}")
    assert redirected_to(revoked) == "/settings/api-keys"
    refute is_nil(Fornacast.Repo.get!(ForgeAccounts.APIKey, first.id).revoked_at)
  end

  test "API key validation errors are human-readable and escaped" do
    reset_database!()

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-api-errors@example.com",
               password: "correct horse battery staple"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> post("/settings/api-keys", %{
        "api_key" => %{"name" => "<script>alert(1)</script>", "scopes" => %{}}
      })

    html = html_response(conn, 422)
    assert html =~ "Scopes must contain repo:read or repo:write"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>alert(1)</script>"
    refute html =~ "scopes: {"
  end

  test "invalid SSH keys render human-readable validation errors" do
    reset_database!()

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-ssh-errors@example.com",
               password: "correct horse battery staple"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> post("/settings/ssh-keys", %{
        "ssh_key" => %{"title" => "invalid", "public_key" => "ssh-dss not-a-key"}
      })

    html = html_response(conn, 422)
    assert html =~ "Public key must use ssh-ed25519 or ssh-rsa"
    refute html =~ "public_key: {"
    refute html =~ "validation:"
  end

  test "malformed decoded SSH key blobs return validation errors" do
    reset_database!()

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-malformed-ssh@example.com",
               password: "correct horse battery staple"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> post("/settings/ssh-keys", %{
        "ssh_key" => %{"title" => "malformed", "public_key" => "ssh-rsa Z2FyYmFnZQ=="}
      })

    assert html_response(conn, 422) =~ "Public key is not a valid OpenSSH public key"
  end

  test "multiple SSH key errors are escaped once and rendered as readable text" do
    reset_database!()

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-multiple-ssh-errors@example.com",
               password: "correct horse battery staple"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> post("/settings/ssh-keys", %{
        "ssh_key" => %{"title" => "", "public_key" => "ssh-rsa <script>alert(1)</script>"}
      })

    html = html_response(conn, 422)
    assert html =~ "Title can&#39;t be blank; Public key is not a valid OpenSSH public key"
    refute html =~ "&lt;br&gt;"
    refute html =~ "can&amp;#39;t"
    refute html =~ "<script>alert(1)</script>"
  end

  test "appbar issue and pull request routes render demo pages" do
    reset_database!()

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-workbench@example.com",
               password: "correct horse battery staple"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)

    assert html_response(get(conn, "/issues"), 200) =~ "<h1>Issues</h1>"
    assert html_response(get(conn, "/pulls"), 200) =~ "<h1>Pull Requests</h1>"
  end

  test "authenticated import repository page is reachable from the create menu" do
    reset_database!()

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-import@example.com",
               password: "correct horse battery staple"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> get("/repos/import")

    assert html_response(conn, 200) =~ "<h1>Import repository</h1>"
  end

  @tag :tmp_dir
  test "health endpoint reports database, storage, and SSH daemon status", %{tmp_dir: tmp_dir} do
    reset_database!()
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    health = get(build_conn(), "/health")

    assert %{
             "status" => "ok",
             "checks" => %{
               "app" => "ok",
               "database" => "ok",
               "repository_storage" => "ok",
               "ssh_daemon" => "disabled"
             }
           } = json_response(health, 200)
  end

  @tag :tmp_dir
  test "repository browser renders README, source, raw file, and commit metadata", %{
    tmp_dir: tmp_dir
  } do
    reset_database!()
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-web@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "web repository"
             })

    work_path = Path.join(tmp_dir, "work")
    repo_path = ForgeRepos.absolute_storage_path(repo)

    git!(["init", work_path])
    File.mkdir_p!(Path.join(work_path, "docs"))
    File.write!(Path.join(work_path, "README.md"), "# Demo\n\n<script>alert('x')</script>\n")
    File.write!(Path.join([work_path, "docs", "guide.txt"]), "hello\n")
    File.write!(Path.join([work_path, "docs", "with#hash.txt"]), "hash path\n")
    File.write!(Path.join(work_path, "asset.bin"), <<0, 1, 2, 3>>)
    File.write!(Path.join(work_path, "large.txt"), String.duplicate("x", 1_048_577))
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "main"])
    git!(["-C", work_path, "tag", "v0.1"])
    git!(["-C", work_path, "push", "origin", "v0.1"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "checkout", "-b", "feature/demo"])
    File.write!(Path.join([work_path, "docs", "branch.txt"]), "feature branch\n")
    git!(["-C", work_path, "add", "docs/branch.txt"])
    git!(["-C", work_path, "commit", "-m", "Feature branch"])
    git!(["-C", work_path, "push", "origin", "feature/demo"])

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)

    overview = get(conn, "/alice/demo")
    overview_body = html_response(overview, 200)
    assert overview_body =~ ~s(class="repo-header")
    assert overview_body =~ "alice / demo"
    assert overview_body =~ ~s(class="repo-tabs")
    assert overview_body =~ ~s(class="readme-panel")
    assert overview_body =~ "<h1>Demo</h1>"
    refute overview_body =~ "<script>"

    source = get(conn, "/alice/demo/src/main/docs")
    source_body = html_response(source, 200)
    assert source_body =~ ~s(class="path-bar")
    assert source_body =~ ~s(class="data-table source-table")
    assert source_body =~ "guide.txt"
    assert source_body =~ "with#hash.txt"
    assert source_body =~ ~s(href="/alice/demo/src/main/docs/with%23hash.txt")

    file = get(conn, "/alice/demo/src/main/docs/guide.txt")
    file_body = html_response(file, 200)
    assert file_body =~ ~s(class="file-panel")
    assert file_body =~ ~s(class="code-block")
    assert file_body =~ "hello"

    hash_file = get(conn, "/alice/demo/src/main/docs/with%23hash.txt")
    hash_file_body = html_response(hash_file, 200)
    assert hash_file_body =~ "hash path"
    assert hash_file_body =~ ~s(href="/alice/demo/raw/main/docs/with%23hash.txt")

    binary = get(conn, "/alice/demo/src/main/asset.bin")
    assert html_response(binary, 200) =~ "Binary or non-UTF-8 files are not rendered inline."

    large = get(conn, "/alice/demo/src/main/large.txt")
    assert html_response(large, 200) =~ "larger than 1048576 bytes"

    raw = get(conn, "/alice/demo/raw/main/docs/guide.txt")
    assert response(raw, 200) == "hello\n"

    commits = get(conn, "/alice/demo/commits/main")
    assert html_response(commits, 200) =~ "Initial commit"

    branches = get(conn, "/alice/demo/branches")
    assert html_response(branches, 200) =~ "main"

    tags = get(conn, "/alice/demo/tags")
    assert html_response(tags, 200) =~ "v0.1"

    feature_file = get(conn, "/alice/demo/src/feature/demo/docs/branch.txt")
    assert html_response(feature_file, 200) =~ "feature branch"

    feature_commits = get(conn, "/alice/demo/commits/feature/demo")
    assert html_response(feature_commits, 200) =~ "Feature branch"

    detail = get(conn, "/alice/demo/commit/#{commit_oid}")
    assert html_response(detail, 200) =~ commit_oid
    assert html_response(detail, 200) =~ "Fornacast Test"
    assert html_response(detail, 200) =~ "Changed files"
    assert html_response(detail, 200) =~ "README.md"
    assert html_response(detail, 200) =~ "diff --git a/README.md b/README.md"
  end

  @tag :tmp_dir
  test "login, SSH key, repository creation, empty state, and private access policy", %{
    tmp_dir: tmp_dir
  } do
    reset_database!()
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-flow@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, bob} =
             ForgeAccounts.create_user(%{
               username: "bob",
               email: "bob-flow@example.com",
               password: "correct horse battery staple"
             })

    login_form = get(build_conn(), "/login")
    login_body = html_response(login_form, 200)
    assert login_body =~ ~s(class="auth-shell")
    assert login_body =~ ~s(class="form-panel")
    assert login_body =~ "Sign in"
    assert login_body =~ ~s(name="session[username]")

    login =
      post(build_conn(), "/login", %{
        "session" => %{
          "username" => "alice",
          "password" => "correct horse battery staple"
        }
      })

    assert redirected_to(login) == "/"

    dashboard =
      login
      |> recycle()
      |> get("/")

    dashboard_body = html_response(dashboard, 200)
    assert dashboard_body =~ ~s(class="app-shell")
    assert dashboard_body =~ ~s(class="appbar-nav")
    assert dashboard_body =~ ~s(class="section-header")
    assert dashboard_body =~ "Repositories"

    key =
      login
      |> recycle()
      |> post("/ssh-keys", %{
        "ssh_key" => %{
          "title" => "laptop",
          "public_key" => @ed25519_public_key
        }
      })

    assert redirected_to(key) == "/ssh-keys"
    assert [%{fingerprint_sha256: "SHA256:" <> _}] = ForgeAccounts.list_user_ssh_keys(user)

    ssh_keys =
      key
      |> recycle()
      |> get("/ssh-keys")

    ssh_keys_body = html_response(ssh_keys, 200)
    assert ssh_keys_body =~ ~s(class="settings-grid")
    assert ssh_keys_body =~ ~s(class="form-panel")
    assert ssh_keys_body =~ ~s(class="data-table key-table")
    assert ssh_keys_body =~ ~s(class="btn btn-error btn-sm")
    assert ssh_keys_body =~ "SHA256:"

    created =
      key
      |> recycle()
      |> post("/repos", %{
        "repository" => %{
          "name" => "Empty",
          "slug" => "empty",
          "description" => "empty repository"
        }
      })

    assert redirected_to(created) == "/alice/empty"

    empty =
      created
      |> recycle()
      |> get("/alice/empty")

    empty_body = html_response(empty, 200)
    assert empty_body =~ ~s(class="repo-header")
    assert empty_body =~ "alice / empty"
    assert empty_body =~ ~s(class="repo-tabs")
    assert empty_body =~ ~s(class="empty-state")
    assert empty_body =~ ~s(class="command-block")
    assert empty_body =~ "git push -u origin main"
    assert empty_body =~ "ssh://alice@"

    forbidden =
      build_conn()
      |> Plug.Test.init_test_session(user_id: bob.id)
      |> get("/alice/empty")

    assert html_response(forbidden, 403) =~ "You do not have access"
  end

  @tag :tmp_dir
  test "repository creation supports organization namespaces", %{tmp_dir: tmp_dir} do
    reset_database!()
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-org-web@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, bob} =
             ForgeAccounts.create_user(%{
               username: "bob",
               email: "bob-org-web@example.com",
               password: "correct horse battery staple"
             })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)

    created_org =
      post(conn, "/organizations", %{
        "organization" => %{
          "username" => "Acme",
          "display_name" => "ACME Engineering"
        }
      })

    assert redirected_to(created_org) == "/acme"

    invalid_repo =
      created_org
      |> recycle()
      |> post("/repos", %{
        "repository" => %{
          "owner" => "acme",
          "name" => "",
          "slug" => "draft",
          "description" => "keep these values",
          "visibility" => "public"
        }
      })

    invalid_body = html_response(invalid_repo, 422)
    assert invalid_body =~ ~s(<option value="acme" selected>)
    assert invalid_body =~ ~s(name="repository[slug]" value="draft")
    assert invalid_body =~ ~s(>keep these values</textarea>)
    assert invalid_body =~ ~s(<option value="public" selected>)

    created_repo =
      created_org
      |> recycle()
      |> post("/repos", %{
        "repository" => %{
          "owner" => "acme",
          "name" => "Empty",
          "slug" => "empty",
          "description" => "organization repository"
        }
      })

    assert redirected_to(created_repo) == "/acme/empty"

    empty =
      created_repo
      |> recycle()
      |> get("/acme/empty")

    body = html_response(empty, 200)
    assert body =~ "ACME Engineering"
    assert body =~ "ssh://alice@"
    assert body =~ "/acme/empty.git"
    refute body =~ "ssh://acme@"

    forbidden =
      build_conn()
      |> Plug.Test.init_test_session(user_id: bob.id)
      |> get("/acme/empty")

    assert html_response(forbidden, 403) =~ "You do not have access"
  end

  @tag :tmp_dir
  test "repository browser renders content pushed over Fornacast SSH", %{tmp_dir: tmp_dir} do
    reset_database!()
    share_database!()

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    system_dir = Path.join(tmp_dir, "ssh")
    key_path = Path.join(tmp_dir, "id_rsa")
    work_path = Path.join(tmp_dir, "work")
    {private_key_pem, public_key} = rsa_private_and_public_key()

    File.write!(key_path, private_key_pem)
    File.chmod!(key_path, 0o600)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-web-ssh@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(user, %{
               title: "generated",
               public_key: public_key
             })

    assert {:ok, _repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "web repository from ssh push"
             })

    assert {:ok, pid} =
             GitTransport.start_ssh_daemon(
               bind_ip: "127.0.0.1",
               port: 0,
               system_dir: system_dir
             )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    port = GitTransport.Daemon.port(pid)
    remote_url = "ssh://alice@127.0.0.1:#{port}/alice/demo.git"
    ssh_env = git_ssh_env(tmp_dir, key_path)

    git!(["init", work_path])
    File.mkdir_p!(Path.join(work_path, "lib"))
    File.write!(Path.join(work_path, "README.md"), "# Pushed README\n")
    File.write!(Path.join([work_path, "lib", "demo.ex"]), "defmodule Demo, do: :ok\n")
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "Initial SSH push"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", remote_url])
    git!(["-C", work_path, "push", "-u", "origin", "main"], ssh_env)
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)

    overview = get(conn, "/alice/demo")
    assert html_response(overview, 200) =~ "Pushed README"

    source = get(conn, "/alice/demo/src/main/lib")
    assert html_response(source, 200) =~ "demo.ex"

    file = get(conn, "/alice/demo/src/main/lib/demo.ex")
    assert html_response(file, 200) =~ "defmodule Demo"

    commits = get(conn, "/alice/demo/commits/main")
    assert html_response(commits, 200) =~ "Initial SSH push"

    detail = get(conn, "/alice/demo/commit/#{commit_oid}")
    assert html_response(detail, 200) =~ "diff --git a/README.md b/README.md"
  end

  @tag :tmp_dir
  test "git clone works over smart HTTP upload-pack for a public repository", %{tmp_dir: tmp_dir} do
    reset_database!()
    share_database!()

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-web-http@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "http clone repository",
               visibility: :public
             })

    work_path = Path.join(tmp_dir, "work")
    clone_path = Path.join(tmp_dir, "clone")
    repo_path = ForgeRepos.absolute_storage_path(repo)

    git!(["init", work_path])
    File.write!(Path.join(work_path, "README.md"), "# Demo\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "main"])

    http_pid =
      start_supervised!(
        {Bandit,
         plug: FornacastWeb.Endpoint,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(http_pid)

    {output, status} =
      git([
        "clone",
        "http://127.0.0.1:#{port}/alice/demo.git",
        clone_path
      ])

    assert status == 0, output
    assert File.read!(Path.join(clone_path, "README.md")) == "# Demo\n"
  end

  @tag :tmp_dir
  test "smart HTTP upload-pack uses Basic auth for private repositories", %{tmp_dir: tmp_dir} do
    reset_database!()

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    password = "correct horse battery staple"

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-web-http-private@example.com",
               password: password
             })

    assert {:ok, _repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "private http repository"
             })

    challenged = get(build_conn(), "/alice/demo.git/info/refs?service=git-upload-pack")

    assert response(challenged, 401) == "Authentication required.\n"

    assert ["Basic realm=\"Fornacast Git\""] =
             Plug.Conn.get_resp_header(challenged, "www-authenticate")

    authorized =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("alice:#{password}"))
      |> get("/alice/demo.git/info/refs?service=git-upload-pack")

    assert response(authorized, 200) =~ "# service=git-upload-pack"

    assert ["application/x-git-upload-pack-advertisement"] =
             Plug.Conn.get_resp_header(authorized, "content-type")
  end

  defp git!(args), do: git!(args, [])

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(
          reset_tables(),
          &Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{&1}", [])
        )
    end
  end

  defp share_database! do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      Ecto.Adapters.SQL.Sandbox.mode(Fornacast.Repo, {:shared, self()})
    end
  end

  defp reset_tables do
    [
      "audit_events",
      "repository_collaborators",
      "repositories",
      "organization_members",
      "api_keys",
      "ssh_keys",
      "users"
    ]
  end

  defp git!(args, extra_env) do
    env =
      [
        {"GIT_AUTHOR_NAME", "Fornacast Test"},
        {"GIT_AUTHOR_EMAIL", "test@example.com"},
        {"GIT_COMMITTER_NAME", "Fornacast Test"},
        {"GIT_COMMITTER_EMAIL", "test@example.com"}
      ] ++ extra_env

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end

  defp git(args) do
    env = [
      {"GIT_AUTHOR_NAME", "Fornacast Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Fornacast Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"},
      {"GIT_TERMINAL_PROMPT", "0"}
    ]

    System.cmd("git", args, stderr_to_stdout: true, env: env)
  end

  defp git_ssh_env(tmp_dir, key_path) do
    [
      {"GIT_SSH_COMMAND",
       Enum.join(
         [
           "ssh",
           "-F /dev/null",
           "-o IdentitiesOnly=yes",
           "-o KbdInteractiveAuthentication=no",
           "-o LogLevel=ERROR",
           "-o PasswordAuthentication=no",
           "-o PreferredAuthentications=publickey",
           "-o PubkeyAcceptedAlgorithms=rsa-sha2-512,rsa-sha2-256",
           "-o StrictHostKeyChecking=no",
           "-o UserKnownHostsFile=#{Path.join(tmp_dir, "known_hosts")}",
           "-i #{key_path}"
         ],
         " "
       )}
    ]
  end

  defp rsa_private_and_public_key do
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} =
      private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    private_key_pem =
      :RSAPrivateKey
      |> :public_key.pem_entry_encode(private_key)
      |> List.wrap()
      |> :public_key.pem_encode()

    public_key =
      {:RSAPublicKey, modulus, exponent}
      |> List.wrap()
      |> Enum.map(&{&1, [comment: ~c"test"]})
      |> :ssh_file.encode(:auth_keys)
      |> to_string()
      |> String.trim()

    {private_key_pem, public_key}
  end
end
