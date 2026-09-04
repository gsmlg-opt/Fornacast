defmodule FornacastWeb.OrganizationGitHubSettingsHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeAccounts.Organization
  alias FornacastWeb.OrganizationGitHubSettingsHTML

  test "not-configured view has a dense DuskMoon surface and one primary installation action" do
    view = base_view()

    html =
      render_component(&OrganizationGitHubSettingsHTML.index/1,
        organization: organization(),
        view: view
      )

    assert html =~ "data-organization-github-settings"
    assert html =~ "bg-surface-container-low"
    assert html =~ "GitHub is not configured"
    assert html =~ "No GitHub App installation is connected"
    assert html =~ ~s(action="/organizations/acme/settings/github/install" method="post")
    assert html =~ "Install GitHub App"
    assert length(Regex.scan(~r/<button\b[^>]*class="[^"]*btn-primary/, html)) == 1
    assert length(Regex.scan(~r/<el-dm-card\b/, html)) >= 4
    refute html =~ "daisy"
    refute html =~ ~r/(?:bg|text|border)-(?:red|blue|green|gray|slate|zinc)-\d+/
  end

  test "pending review bootstrap active partial and degraded statuses are explicit" do
    statuses = [
      {:pending_installation, :none, "Installation pending"},
      {:ready_to_bootstrap, :all, "Review permissions and repository scope"},
      {:bootstrapping, :all, "Bootstrap in progress"},
      {:active, :partial, "Active with partial coverage"},
      {:degraded, :all, "GitHub sync degraded"}
    ]

    for {state, coverage, label} <- statuses do
      view = connected_view(state, coverage)

      html =
        render_component(&OrganizationGitHubSettingsHTML.index/1,
          organization: organization(),
          view: view
        )

      assert html =~ label
    end

    partial =
      render_component(&OrganizationGitHubSettingsHTML.index/1,
        organization: organization(),
        view: connected_view(:active, :partial)
      )

    assert partial =~ "Partial repository coverage"

    degraded =
      render_component(&OrganizationGitHubSettingsHTML.index/1,
        organization: organization(),
        view: connected_view(:degraded, :all)
      )

    assert degraded =~ "Synchronization is degraded"
  end

  test "missing permissions installation identity capabilities and policy are visible before bootstrap" do
    view =
      :ready_to_bootstrap
      |> connected_view(:partial)
      |> Map.put(:missing_permissions, [:administration, "pull_requests"])

    html =
      render_component(&OrganizationGitHubSettingsHTML.index/1,
        organization: organization(),
        view: view
      )

    assert html =~ "Missing GitHub App permissions"
    assert html =~ "Administration"
    assert html =~ "Pull requests"
    assert html =~ "acme-inc"
    assert html =~ "88001"
    assert html =~ "99001"
    assert html =~ "Selected"
    assert html =~ "Git"
    assert html =~ "Lfs — Unavailable"
    assert html =~ "Releases — Unavailable"
    assert html =~ "Automatically import newly visible GitHub repositories"
    assert html =~ "Automatically create GitHub repositories for new local repositories"
    assert html =~ "Repository deletion policy"
    assert html =~ "Conflict notification policy"
  end

  test "repository operation and conflict evidence is bounded and safely escaped" do
    view =
      :active
      |> connected_view(:all)
      |> Map.merge(%{
        repository_counts: %{active: 7, degraded: 1},
        repositories: [
          %{
            full_name: "acme/widgets<script>alert(1)</script>",
            github_repository_id: 123_456,
            selected: true,
            state: :active,
            visibility: :private
          }
        ],
        operations: [%{kind: "repository.reconcile", state: :retrying}],
        conflicts: [%{resource: "refs/heads/main", kind: :diverged, state: :open}]
      })

    html =
      render_component(&OrganizationGitHubSettingsHTML.index/1,
        organization: organization(),
        view: view
      )

    assert html =~ "Active 7"
    assert html =~ "Degraded 1"
    assert html =~ "acme/widgets&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>alert(1)</script>"
    assert html =~ "123456"
    assert html =~ ~s(name="github[selected_repository_ids][]" value="123456")
    assert html =~ ~s|aria-label="Synchronize acme/widgets&lt;script&gt;alert(1)&lt;/script&gt;"|
    assert html =~ "Repository.reconcile"
    assert html =~ "Retrying"
    assert html =~ "1 conflict require review"
    assert html =~ ~s(href="/organizations/acme/settings/github/conflicts")
  end

  test "every mutation uses native CSRF forms and method overrides with one primary action" do
    view =
      :ready_to_bootstrap
      |> connected_view(:partial)
      |> put_in([:actions], %{
        update: true,
        bootstrap: true,
        reconcile: true,
        pause: true,
        resume: true,
        disconnect: true
      })

    html =
      render_component(&OrganizationGitHubSettingsHTML.index/1,
        organization: organization(),
        view: view
      )

    base = "/organizations/acme/settings/github"
    assert html =~ ~s(action="#{base}" method="post")
    assert html =~ ~s(name="_method" value="patch")
    assert html =~ ~s(action="#{base}/bootstrap" method="post")
    assert html =~ ~s(action="#{base}/reconcile" method="post")
    assert html =~ ~s(action="#{base}/pause" method="post")
    assert html =~ ~s(action="#{base}/resume" method="post")
    assert html =~ ~s(name="_method" value="delete")
    assert length(Regex.scan(~r/name="_csrf_token"/, html)) == 6
    assert length(Regex.scan(~r/<button\b[^>]*class="[^"]*btn-primary/, html)) == 1
  end

  test "disconnect is an explicit destructive confirmation" do
    html =
      render_component(&OrganizationGitHubSettingsHTML.index/1,
        organization: organization(),
        view: connected_view(:active, :all)
      )

    assert html =~ "Disconnect GitHub"
    assert html =~ "Disconnect this GitHub installation?"
    assert html =~ "Existing repositories remain"
    assert html =~ "Confirm disconnect GitHub"
    assert html =~ ~r/<details\b/
    assert html =~ ~s(aria-describedby="disconnect-github-organization-confirmation")
  end

  test "conflicts screen renders retained conflict evidence and an empty state" do
    with_conflict =
      :conflicted
      |> connected_view(:all)
      |> Map.put(:conflicts, [
        %{resource_identity: "issue:42", conflict_kind: :concurrent_edit, state: :open}
      ])

    html =
      render_component(&OrganizationGitHubSettingsHTML.conflicts/1,
        organization: organization(),
        view: with_conflict
      )

    assert html =~ "GitHub synchronization conflicts"
    assert html =~ "issue:42"
    assert html =~ "Concurrent edit"
    assert html =~ "Open"

    empty =
      render_component(&OrganizationGitHubSettingsHTML.conflicts/1,
        organization: organization(),
        view: base_view()
      )

    assert empty =~ "No outstanding synchronization conflicts."
  end

  defp organization do
    %Organization{id: 71, username: "acme", display_name: "Acme Engineering", state: :active}
  end

  defp base_view do
    %{
      organization: organization(),
      mirror: nil,
      installation: nil,
      coverage: :none,
      missing_permissions: [],
      policy: %{},
      capabilities: %{},
      repository_counts: %{},
      repositories: [],
      operations: [],
      conflicts: [],
      actions: %{install: true}
    }
  end

  defp connected_view(state, coverage) do
    base_view()
    |> Map.merge(%{
      mirror: %{
        state: state,
        last_webhook_at: ~U[2026-09-05 01:00:00Z],
        last_reconciled_at: ~U[2026-09-05 01:05:00Z]
      },
      installation: %{
        account_login: "acme-inc",
        account_id: 88_001,
        installation_id: 99_001,
        repository_selection: if(coverage == :partial, do: :selected, else: :all),
        permissions: %{contents: :write, issues: :write}
      },
      coverage: coverage,
      policy: %{
        repository_selection: if(coverage == :partial, do: :selected, else: :all),
        auto_import_new: true,
        auto_create_remote: false,
        repository_deletion_policy: :retain,
        conflict_notification_policy: :notify
      },
      capabilities: %{
        git: :active,
        issues: :active,
        pulls: :active,
        lfs: :unavailable,
        releases: :unavailable
      },
      repository_counts: %{active: 3},
      actions: %{
        update: true,
        bootstrap: state == :ready_to_bootstrap,
        reconcile: state in [:active, :degraded, :conflicted],
        pause: state == :active,
        resume: state == :paused,
        disconnect: true
      }
    })
  end
end
