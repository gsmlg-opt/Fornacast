defmodule FornacastAPI.SerializationTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test, only: [conn: 2]

  alias ForgeAccounts.{AccountView, Organization, User}
  alias ForgeRepos.Repository
  alias FornacastAPI.{Pagination, Serializer, URL}

  @versions ["2022-11-28", "2026-03-10"]
  @base_url "https://forge.test"

  setup do
    previous_base_url = Application.fetch_env!(:fornacast, :base_url)
    previous_ssh_host = Application.fetch_env!(:fornacast, :ssh_host)
    previous_ssh_port = Application.fetch_env!(:fornacast, :ssh_port)
    Application.put_env(:fornacast, :base_url, @base_url)
    Application.put_env(:fornacast, :ssh_host, "ssh.forge.test")
    Application.put_env(:fornacast, :ssh_port, 2223)

    on_exit(fn ->
      Application.put_env(:fornacast, :base_url, previous_base_url)
      Application.put_env(:fornacast, :ssh_host, previous_ssh_host)
      Application.put_env(:fornacast, :ssh_port, previous_ssh_port)
    end)
  end

  describe "Fornacast.Page" do
    test "enforces all fields and computes a ceiling page count" do
      assert_raise ArgumentError, ~r/must also be given/, fn ->
        struct!(Fornacast.Page, entries: [])
      end

      page =
        struct!(Fornacast.Page,
          entries: [:one, :two],
          total: 151,
          page: 2,
          per_page: 50
        )

      assert page.entries == [:one, :two]
      assert page.total == 151
      assert page.page == 2
      assert page.per_page == 50
      assert Fornacast.Page.total_pages(page) == 4

      empty_page = struct!(Fornacast.Page, entries: [], total: 0, page: 1, per_page: 30)
      assert Fornacast.Page.total_pages(empty_page) == 1
    end
  end

  describe "pagination parsing" do
    test "parses explicit values and supplies GitHub-compatible defaults" do
      assert Pagination.parse(%{"page" => "2", "per_page" => "50"}) ==
               {:ok, [page: 2, per_page: 50]}

      assert Pagination.parse(%{}) == {:ok, [page: 1, per_page: 30]}

      assert Pagination.parse(%{"page" => "01", "ignored" => "value"}) ==
               {:ok, [page: 1, per_page: 30]}
    end

    test "rejects anything except full-string positive base-10 integers" do
      invalid_values = ["0", "-1", "+1", "1.0", " 1", "1 ", "1x", "2\n", 1, nil]

      for field <- ["page", "per_page"], value <- invalid_values do
        assert Pagination.parse(%{field => value}) ==
                 {:error,
                  {:validation, [%{resource: "Pagination", field: field, code: :invalid}]}}
      end

      assert Pagination.parse(%{"per_page" => "101"}) ==
               {:error,
                {:validation, [%{resource: "Pagination", field: "per_page", code: :invalid}]}}
    end

    test "returns both invalid fields in deterministic page then per_page order" do
      assert Pagination.parse(%{"page" => "0", "per_page" => "101"}) ==
               {:error,
                {:validation,
                 [
                   %{resource: "Pagination", field: "page", code: :invalid},
                   %{resource: "Pagination", field: "per_page", code: :invalid}
                 ]}}
    end
  end

  describe "pagination Link headers" do
    test "uses only the supplied canonical URL and orders middle-page relations" do
      page = struct!(Fornacast.Page, entries: [], total: 151, page: 2, per_page: 50)
      request = conn(:get, "https://attacker.invalid/api/v3/user/repos")

      response =
        Pagination.put_link_header(
          request,
          page,
          "https://forge.test/api/v3/user/repos?type=all"
        )

      assert get_resp_header(response, "link") == [
               "<https://forge.test/api/v3/user/repos?page=3&per_page=50&type=all>; rel=\"next\", " <>
                 "<https://forge.test/api/v3/user/repos?page=1&per_page=50&type=all>; rel=\"prev\", " <>
                 "<https://forge.test/api/v3/user/repos?page=1&per_page=50&type=all>; rel=\"first\", " <>
                 "<https://forge.test/api/v3/user/repos?page=4&per_page=50&type=all>; rel=\"last\""
             ]
    end

    test "replaces pagination pairs, preserves duplicate pairs, sorts, and RFC3986-encodes" do
      page = struct!(Fornacast.Page, entries: [], total: 151, page: 2, per_page: 50)

      response =
        Pagination.put_link_header(
          conn(:get, "https://attacker.invalid/spoofed"),
          page,
          "https://forge.test/api/v3/user/repos?z=last&tag=b&tag=a&per_page=9&page=9&q=a%20b&q=a%2Fb"
        )

      prefix = "https://forge.test/api/v3/user/repos?"
      suffix = "&per_page=50&q=a%20b&q=a%2Fb&tag=a&tag=b&z=last"

      assert get_resp_header(response, "link") == [
               "<#{prefix}page=3#{suffix}>; rel=\"next\", " <>
                 "<#{prefix}page=1#{suffix}>; rel=\"prev\", " <>
                 "<#{prefix}page=1#{suffix}>; rel=\"first\", " <>
                 "<#{prefix}page=4#{suffix}>; rel=\"last\""
             ]
    end

    test "emits only applicable relations and omits an empty header" do
      first = struct!(Fornacast.Page, entries: [], total: 3, page: 1, per_page: 1)
      last = struct!(Fornacast.Page, entries: [], total: 3, page: 3, per_page: 1)
      only = struct!(Fornacast.Page, entries: [], total: 1, page: 1, per_page: 30)
      url = "https://forge.test/api/v3/user/repos"

      assert [first_link] =
               conn(:get, "https://attacker.invalid")
               |> Pagination.put_link_header(first, url)
               |> get_resp_header("link")

      assert first_link =~ ~s(rel="next")
      assert first_link =~ ~s(rel="last")
      refute first_link =~ ~s(rel="prev")
      refute first_link =~ ~s(rel="first")

      assert [last_link] =
               conn(:get, "https://attacker.invalid")
               |> Pagination.put_link_header(last, url)
               |> get_resp_header("link")

      assert last_link =~ ~s(rel="prev")
      assert last_link =~ ~s(rel="first")
      refute last_link =~ ~s(rel="next")
      refute last_link =~ ~s(rel="last")

      assert [] =
               conn(:get, "https://attacker.invalid")
               |> Pagination.put_link_header(only, url)
               |> get_resp_header("link")
    end

    test "clamps previous and last links for empty and nonempty out-of-range pages" do
      url = "https://forge.test/api/v3/user/repos"

      for {page, expected} <- [
            {struct!(Fornacast.Page, entries: [], total: 3, page: 4, per_page: 1),
             "<#{url}?page=3&per_page=1>; rel=\"prev\", " <>
               "<#{url}?page=1&per_page=1>; rel=\"first\", " <>
               "<#{url}?page=3&per_page=1>; rel=\"last\""},
            {struct!(Fornacast.Page, entries: [], total: 0, page: 2, per_page: 30),
             "<#{url}?page=1&per_page=30>; rel=\"prev\", " <>
               "<#{url}?page=1&per_page=30>; rel=\"first\", " <>
               "<#{url}?page=1&per_page=30>; rel=\"last\""}
          ] do
        assert [link] =
                 conn(:get, "https://attacker.invalid")
                 |> Pagination.put_link_header(page, url)
                 |> get_resp_header("link")

        assert link == expected
      end
    end
  end

  describe "public URL construction" do
    test "builds API, upload, and web URLs from the configured base" do
      assert URL.api("/versions") == "https://forge.test/api/v3/versions"

      assert URL.upload("/repos/octocat/hello/assets") ==
               "https://forge.test/api/uploads/repos/octocat/hello/assets"

      assert URL.web("/octocat/hello") == "https://forge.test/octocat/hello"
    end

    test "clears base credentials, path, query, and fragment" do
      Application.put_env(
        :fornacast,
        :base_url,
        "https://user:secret@forge.test:8443/untrusted?host=attacker.invalid#fragment"
      )

      assert URL.api("/versions") == "https://forge.test:8443/api/v3/versions"
      assert URL.upload("/asset") == "https://forge.test:8443/api/uploads/asset"
      assert URL.web("/about") == "https://forge.test:8443/about"
    end

    test "rejects unsafe or non-HTTP configured base URLs before URL construction" do
      invalid_base_urls = [
        "ftp://forge.test",
        "javascript:alert(1)",
        "//forge.test",
        "https://",
        "https:/missing-host",
        "https://forge.test\r\nx-injected: true",
        "https://forge.test/path\0suffix",
        "https://forge.test/path\tsuffix"
      ]

      for base_url <- invalid_base_urls do
        Application.put_env(:fornacast, :base_url, base_url)

        assert_raise ArgumentError,
                     ~r/configured base URL must be an absolute HTTP or HTTPS URL with a nonempty host and no ASCII control characters/,
                     fn -> URL.api("/versions") end
      end
    end

    test "percent-encodes every dynamic path segment" do
      encoded = "a%2Fb%20c%3F%23%E9%9B%AA"

      assert URL.user("a/b c?#雪") == "https://forge.test/api/v3/users/#{encoded}"
      assert URL.organization("a/b c?#雪") == "https://forge.test/api/v3/orgs/#{encoded}"

      assert URL.repository("a/b c?#雪", "r/e p?#雪") ==
               "https://forge.test/api/v3/repos/#{encoded}/r%2Fe%20p%3F%23%E9%9B%AA"
    end

    test "rejects malformed path arguments clearly" do
      for helper <- [:api, :upload, :web] do
        assert_raise ArgumentError, ~r/path must be a string beginning with \/,/, fn ->
          apply(URL, helper, ["missing-leading-slash"])
        end

        assert_raise ArgumentError, ~r/path must be a string beginning with \/,/, fn ->
          apply(URL, helper, [123])
        end
      end

      assert_raise ArgumentError, ~r/path segment must be a string/, fn -> URL.user(123) end
    end
  end

  describe "versioned serializers" do
    test "requires account views with real non-negative repository counts" do
      user = account()

      assert AccountView.new(user, 7, 2) == %AccountView{
               account: user,
               public_repos: 7,
               private_repos: 2,
               two_factor_authentication: false
             }

      assert_raise ArgumentError, ~r/must also be given/, fn ->
        struct!(AccountView, account: user, public_repos: 7)
      end

      for {public_repos, private_repos} <- [{-1, 2}, {7, -1}, {"7", 2}, {7, nil}] do
        assert_raise ArgumentError, ~r/non-negative integer repository counts/, fn ->
          AccountView.new(user, public_repos, private_repos)
        end
      end

      assert_raise ArgumentError, ~r/User or Organization account/, fn ->
        AccountView.new(%{}, 7, 2)
      end

      for wrong_kind <- [
            %{account() | kind: :organization},
            %{organization() | kind: :user}
          ] do
        assert_raise ArgumentError, ~r/struct and kind must identify the same account type/, fn ->
          AccountView.new(wrong_kind, 7, 2)
        end
      end
    end

    test "enforces resource-specific account types" do
      malformed =
        struct!(AccountView,
          account: organization(),
          public_repos: -1,
          private_repos: 2
        )

      wrong_kind_user_view =
        struct!(AccountView,
          account: %{account() | kind: :organization},
          public_repos: 7,
          private_repos: 2
        )

      wrong_kind_organization_view =
        struct!(AccountView,
          account: %{organization() | kind: :user},
          public_repos: 5,
          private_repos: 3
        )

      for version <- @versions do
        assert Serializer.render(version, :organization_simple, organization()).login == "acme"

        for {resource, value, message} <- [
              {:public_user, account(), ~r/valid user ForgeAccounts.AccountView/},
              {:private_user, account(), ~r/valid user ForgeAccounts.AccountView/},
              {:public_user, organization_view(), ~r/valid user ForgeAccounts.AccountView/},
              {:private_user, organization_view(), ~r/valid user ForgeAccounts.AccountView/},
              {:public_user, wrong_kind_user_view, ~r/valid user ForgeAccounts.AccountView/},
              {:private_user, wrong_kind_user_view, ~r/valid user ForgeAccounts.AccountView/},
              {:organization_full, account_view(),
               ~r/valid organization ForgeAccounts.AccountView/},
              {:organization_full, malformed, ~r/valid organization ForgeAccounts.AccountView/},
              {:organization_full, wrong_kind_organization_view,
               ~r/valid organization ForgeAccounts.AccountView/},
              {:organization_simple, account(), ~r/correctly typed ForgeAccounts.Organization/},
              {:organization_simple, %{organization() | kind: :user},
               ~r/correctly typed ForgeAccounts.Organization/}
            ] do
          assert_raise ArgumentError, message, fn ->
            Serializer.render(version, resource, value)
          end
        end
      end
    end

    test "both explicit modules render every declared resource" do
      resources = [
        simple_user: account(),
        public_user: account_view(),
        private_user: account_view(),
        organization_simple: organization(),
        organization_full: organization_view(),
        minimal_repository: repository_view(),
        repository: repository_view(),
        full_repository: repository_view(),
        rate_limit: rate_bucket(),
        error: error()
      ]

      for {version, module} <- serializer_modules(), {resource, value} <- resources do
        assert output = apply(module, :render, [resource, value, []])
        assert output == Serializer.render(version, resource, value)
        assert is_map(output)
      end
    end

    test "every generated resource URL ignores request host data" do
      attacker_conn = conn(:get, "https://attacker.invalid/api/v3/user")

      resources = [
        simple_user: account(),
        public_user: account_view(),
        private_user: account_view(),
        organization_simple: organization(),
        organization_full: organization_view(),
        minimal_repository: repository_view(),
        repository: repository_view(),
        full_repository: repository_view()
      ]

      for version <- @versions, {resource, value} <- resources do
        version
        |> Serializer.render(resource, value, conn: attacker_conn)
        |> assert_all_urls_are_public()
      end
    end

    test "renders real account and organization fields with canonical related URLs" do
      for version <- @versions do
        public_user = Serializer.render(version, :public_user, account_view())
        private_user = Serializer.render(version, :private_user, account_view())
        organization = Serializer.render(version, :organization_full, organization_view())

        assert public_user.login == "octocat"
        assert public_user.id == 42
        assert public_user.name == "Octo Cat"
        assert public_user.bio == "Builds small forges"
        assert public_user.email == nil
        refute JSON.encode!(public_user) =~ "octocat@example.test"
        assert public_user.public_repos == 7
        assert public_user.site_admin
        assert public_user.created_at == "2026-03-10T08:00:00Z"
        assert public_user.updated_at == "2026-03-11T09:30:00Z"
        assert private_user.email == "octocat@example.test"
        assert private_user.total_private_repos == 2
        refute private_user.two_factor_authentication

        assert organization.login == "acme"
        assert organization.name == "Acme Forge"
        assert organization.description == "An example organization"
        assert organization.public_repos == 5
        assert organization.created_at == "2026-03-08T01:02:03Z"

        assert_all_urls_are_public(public_user)
        assert_all_urls_are_public(private_user)
        assert_all_urls_are_public(organization)
      end
    end

    test "renders real repository fields and every GitHub-style URL template" do
      for version <- @versions do
        repository = Serializer.render(version, :full_repository, repository_view())

        assert repository.id == 99
        assert repository.name == "Hello World"
        assert repository.full_name == "octocat/hello-world"
        assert repository.description == "A repository fixture"
        assert repository.private
        assert repository.visibility == "private"
        assert repository.default_branch == "trunk"
        assert repository.size == 512

        assert repository.permissions ==
                 %{admin: true, maintain: false, pull: true, push: true, triage: false}

        assert repository.created_at == "2026-03-09T10:00:00Z"
        assert repository.updated_at == "2026-03-10T11:00:00Z"
        assert repository.pushed_at == "2026-03-10T10:30:00Z"
        assert repository.clone_url == "https://forge.test/octocat/hello-world.git"
        assert repository.git_url == "https://forge.test/octocat/hello-world.git"
        assert repository.svn_url == "https://forge.test/octocat/hello-world.git"

        assert repository.ssh_url ==
                 "ssh://octocat@ssh.forge.test:2223/octocat/hello-world.git"

        assert repository.archive_url =~ "/{archive_format}{/ref}"
        assert repository.assignees_url =~ "/assignees{/user}"
        assert repository.blobs_url =~ "/git/blobs{/sha}"
        assert repository.branches_url =~ "/branches{/branch}"
        assert repository.collaborators_url =~ "/collaborators{/collaborator}"
        assert repository.comments_url =~ "/comments{/number}"
        assert repository.commits_url =~ "/commits{/sha}"
        assert repository.compare_url =~ "/compare/{base}...{head}"
        assert repository.contents_url =~ "/contents/{+path}"
        assert repository.git_commits_url =~ "/git/commits{/sha}"
        assert repository.git_refs_url =~ "/git/refs{/sha}"
        assert repository.git_tags_url =~ "/git/tags{/sha}"
        assert repository.issue_comment_url =~ "/issues/comments{/number}"
        assert repository.issue_events_url =~ "/issues/events{/number}"
        assert repository.issues_url =~ "/issues{/number}"
        assert repository.keys_url =~ "/keys{/key_id}"
        assert repository.labels_url =~ "/labels{/name}"
        assert repository.milestones_url =~ "/milestones{/number}"
        assert repository.notifications_url =~ "/notifications{?since,all,participating}"
        assert repository.pulls_url =~ "/pulls{/number}"
        assert repository.releases_url =~ "/releases{/id}"
        assert repository.statuses_url =~ "/statuses/{sha}"
        assert repository.trees_url =~ "/git/trees{/sha}"

        for key <-
              ~w(contributors_url deployments_url downloads_url events_url forks_url hooks_url languages_url merges_url stargazers_url subscribers_url subscription_url tags_url teams_url)a do
          assert is_binary(Map.fetch!(repository, key))
        end

        repository |> Map.delete(:ssh_url) |> assert_all_urls_are_public()
      end
    end

    test "uses the authenticated actor in organization repository SSH clone URLs" do
      actor = %{account() | id: 7, username: "collaborator"}

      for version <- @versions do
        anonymous_repository =
          Serializer.render(version, :full_repository, repository_view(organization()))

        authenticated_repository =
          Serializer.render(
            version,
            :full_repository,
            repository_view(organization()),
            actor: actor
          )

        assert anonymous_repository.owner.login == "acme"
        assert anonymous_repository.owner.type == "Organization"
        refute anonymous_repository.owner.site_admin
        assert anonymous_repository.full_name == "acme/hello-world"

        assert anonymous_repository.ssh_url ==
                 "ssh://acme@ssh.forge.test:2223/acme/hello-world.git"

        assert authenticated_repository.ssh_url ==
                 "ssh://collaborator@ssh.forge.test:2223/acme/hello-world.git"

        assert authenticated_repository.clone_url == "https://forge.test/acme/hello-world.git"
        authenticated_repository |> Map.delete(:ssh_url) |> assert_all_urls_are_public()
      end
    end

    test "uses inert values for unsupported repository features and pins version keys" do
      repository_2022 = Serializer.render("2022-11-28", :repository, repository_view())
      repository_2026 = Serializer.render("2026-03-10", :repository, repository_view())

      for repository <- [repository_2022, repository_2026] do
        refute repository.fork
        assert repository.forks == 0
        assert repository.forks_count == 0
        assert repository.watchers == 0
        assert repository.watchers_count == 0
        assert repository.stargazers_count == 0
        assert repository.open_issues == 0
        assert repository.open_issues_count == 0
        refute repository.has_projects
        refute repository.has_wiki
        refute repository.has_pages
        refute repository.has_discussions
        refute repository.allow_squash_merge
        refute repository.allow_rebase_merge
        refute repository.archived
        refute repository.disabled
        assert repository.mirror_url == nil
        assert repository.homepage == nil
        assert repository.language == nil
        assert repository.license == nil
        assert repository.topics == []
      end

      assert repository_2022.has_downloads == false
      refute Map.has_key?(repository_2026, :has_downloads)
      assert Map.keys(repository_2022) -- Map.keys(repository_2026) == [:has_downloads]
      assert Map.keys(repository_2026) -- Map.keys(repository_2022) == []
    end

    test "bounds repository size to a non-negative 32-bit value" do
      too_large = put_in(repository_view(), [:size_kib], 9_999_999_999)
      negative = put_in(repository_view(), [:size_kib], -1)

      assert Serializer.render("2022-11-28", :repository, too_large).size == 2_147_483_647
      assert Serializer.render("2026-03-10", :repository, negative).size == 0
    end

    test "pins the rate-limit shape per version" do
      bucket = rate_bucket()
      core = %{limit: 5_000, remaining: 4_999, reset: 1_800_000_000, used: 1}

      assert Serializer.render("2022-11-28", :rate_limit, bucket) == %{
               resources: %{core: core},
               rate: core
             }

      assert Serializer.render("2026-03-10", :rate_limit, bucket) == %{
               resources: %{core: core}
             }
    end

    test "keeps stable error fields and includes validation errors only when present" do
      for version <- @versions do
        assert Serializer.render(version, :error, error()) == %{
                 message: "Validation Failed",
                 documentation_url: "https://docs.example.test/validation",
                 errors: [
                   %{resource: "Repository", field: "name", code: "missing_field"}
                 ]
               }

        sensitive_validation =
          FornacastAPI.Error.new(
            422,
            "Validation Failed",
            "https://docs.example.test/validation",
            errors: [
              %{
                resource: "Repository",
                field: "name",
                code: :invalid,
                message: "has an invalid format",
                index: 7,
                value: "fc_pat_secret-value"
              }
            ]
          )

        assert Serializer.render(version, :error, sensitive_validation).errors == [
                 %{
                   resource: "Repository",
                   field: "name",
                   code: "invalid",
                   message: "has an invalid format"
                 }
               ]

        refute version
               |> Serializer.render(:error, sensitive_validation)
               |> JSON.encode!()
               |> String.contains?("fc_pat_secret-value")

        basic =
          FornacastAPI.Error.new(
            404,
            "Not Found",
            "https://docs.example.test/not-found"
          )

        assert Serializer.render(version, :error, basic) == %{
                 message: "Not Found",
                 documentation_url: "https://docs.example.test/not-found"
               }
      end
    end

    test "fails clearly for unknown versions and resources" do
      assert_raise KeyError, fn ->
        Serializer.render("2099-01-01", :public_user, account_view())
      end

      for {_version, module} <- serializer_modules() do
        assert_raise ArgumentError, ~r/unsupported serializer resource/, fn ->
          module.render(:unsupported, %{}, [])
        end
      end
    end
  end

  defp serializer_modules do
    [
      {"2022-11-28", FornacastAPI.Serializers.V2022_11_28},
      {"2026-03-10", FornacastAPI.Serializers.V2026_03_10}
    ]
  end

  defp account do
    %User{
      id: 42,
      username: "octocat",
      display_name: "Octo Cat",
      description: "Builds small forges",
      email: "octocat@example.test",
      kind: :user,
      role: :admin,
      inserted_at: ~U[2026-03-10 08:00:00Z],
      updated_at: ~U[2026-03-11 09:30:00Z]
    }
  end

  defp account_view, do: AccountView.new(account(), 7, 2)

  defp organization do
    %Organization{
      id: 84,
      username: "acme",
      display_name: "Acme Forge",
      description: "An example organization",
      kind: :organization,
      inserted_at: ~U[2026-03-08 01:02:03Z],
      updated_at: ~U[2026-03-09 04:05:06Z]
    }
  end

  defp organization_view, do: AccountView.new(organization(), 5, 3)

  defp repository_view(owner \\ account()) do
    %{
      repository: %Repository{
        id: 99,
        owner_user_id: owner.id,
        slug: "hello-world",
        name: "Hello World",
        description: "A repository fixture",
        visibility: :private,
        default_branch: "trunk",
        storage_path: "@hashed/00/00/hello-world.git",
        last_pushed_at: ~U[2026-03-10 10:30:00Z],
        inserted_at: ~U[2026-03-09 10:00:00Z],
        updated_at: ~U[2026-03-10 11:00:00Z]
      },
      owner: owner,
      permissions: %{
        admin: true,
        pull: true,
        push: true
      },
      size_kib: 512
    }
  end

  defp rate_bucket do
    %{
      limit: 5_000,
      remaining: 4_999,
      reset: 1_800_000_000,
      used: 1,
      resource: "core"
    }
  end

  defp error do
    FornacastAPI.Error.new(
      422,
      "Validation Failed",
      "https://docs.example.test/validation",
      errors: [%{resource: "Repository", field: "name", code: :missing_field}]
    )
  end

  defp assert_all_urls_are_public(value) do
    for url <- collect_urls(value) do
      assert String.starts_with?(url, Fornacast.Config.base_url())
      refute url =~ "attacker.invalid"
    end
  end

  defp collect_urls(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} ->
      key = Atom.to_string(key)

      own =
        if key != "ssh_url" and (key == "url" or String.ends_with?(key, "_url")) and
             is_binary(nested),
           do: [nested],
           else: []

      own ++ collect_urls(nested)
    end)
  end

  defp collect_urls(value) when is_list(value), do: Enum.flat_map(value, &collect_urls/1)
  defp collect_urls(_value), do: []
end
