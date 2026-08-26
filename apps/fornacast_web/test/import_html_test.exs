defmodule FornacastWeb.ImportHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeAccounts.GitHubAccountView
  alias ForgeImports.RunView
  alias FornacastWeb.ImportHTML

  @run_states [
    :discovering,
    :awaiting_resolution,
    :ready,
    :running,
    :awaiting_credential,
    :cancel_requested,
    :completed,
    :completed_with_warnings,
    :canceled,
    :failed
  ]

  test "repository and organization forms use DuskMoon hierarchy and native secure inputs" do
    repository =
      render_component(&ImportHTML.repository/1,
        accounts: [account(41, "octocat")],
        organizations: [],
        error: nil
      )

    organization =
      render_component(&ImportHTML.organization/1,
        accounts: [account(41, "octocat")],
        organizations: [%{id: 51, username: "acme"}],
        error: nil
      )

    assert repository =~ "data-repository-import"
    assert organization =~ "data-organization-import"
    assert length(Regex.scan(~r/<el-dm-card\b/, repository)) >= 1
    assert length(Regex.scan(~r/<el-dm-card\b/, organization)) >= 1
    assert repository =~ ~s(action="/repos/import/discover" method="post")
    assert organization =~ ~s(action="/organizations/import/discover" method="post")
    assert repository =~ ~s(name="import[source]")
    assert organization =~ ~s(name="import[organization]")

    for html <- [repository, organization] do
      [pat_input] = Regex.run(~r/<input\b[^>]*name="import\[pat\]"[^>]*>/, html)
      assert pat_input =~ ~s(type="password")
      assert pat_input =~ ~s(autocomplete="new-password")
      assert pat_input =~ ~s(spellcheck="false")
      assert pat_input =~ ~s(autocapitalize="none")
      assert pat_input =~ ~s(maxlength="4096")
      refute pat_input =~ ~r/\bvalue=/
      assert html =~ ~s(name="_csrf_token")
      refute html =~ ~r/\bgap-(?:1|3|5|6|7|8|9|10|11|12)\b/
      refute html =~ ~r/(?:bg|text|border)-(?:red|blue|green|gray|slate|zinc)-\d+/
      refute html =~ "daisy"
      refute html =~ ~r/<img\b/
      refute html =~ ~r/<el-dm-button\b/
    end

    assert organization =~ ~s(name="import[destination_action]")
    assert organization =~ ~s(value="new")
    assert organization =~ ~s(value="existing")
    assert organization =~ ~s(value="51")
    assert length(Regex.scan(~r/<fieldset\b/, organization)) >= 2
    assert length(Regex.scan(~r/<legend\b/, organization)) >= 2
  end

  test "show renders only the safe run projection with every repository and collision warning" do
    view = run_view()

    html =
      render_component(&ImportHTML.show/1,
        run: view,
        organizations: [%{id: 51, username: "acme"}],
        error: nil
      )

    assert html =~ "data-import-run"
    assert html =~ "Import plan"
    assert html =~ "Awaiting resolution"
    assert html =~ "octo"
    assert html =~ "octo/alpha"
    assert html =~ "octo/beta"
    assert html =~ "octo-local"
    assert html =~ "Selected"
    assert html =~ "2"
    assert html =~ "Repository conflict"
    assert html =~ "Unsupported releases"
    assert html =~ "GitHub releases are not imported"
    assert length(Regex.scan(~r/name="selection\[repository_ids\]\[\]"/, html)) == 2
    assert length(Regex.scan(~r/name="selection\[repository_ids\]\[\]"[^>]*checked/, html)) == 2
    assert html =~ ~s(action="/imports/91/selection" method="post")
    assert html =~ ~s(action="/imports/91/destination" method="post")
    assert length(Regex.scan(~r/name="_method" value="patch"/, html)) == 2
    assert length(Regex.scan(~r/name="_csrf_token"/, html)) == 2
    assert length(Regex.scan(~r/<time\b[^>]*datetime="2026-08-26T07:0[01]:00Z"/, html)) == 2
    assert html =~ ~r/<h2\b[^>]*>Import plan<\/h2>/
    assert html =~ ~r/<h3\b[^>]*>Repositories<\/h3>/
    assert html =~ ~r/<table\b/
    assert html =~ ~r/<caption\b[^>]*>Discovered repositories<\/caption>/
    assert html =~ ~s(id="repository-selection-9001")
    assert html =~ ~s(for="repository-selection-9001")
    assert html =~ ~s(href="/imports/91")

    refute html =~ "github_pat_projection_secret"
    refute html =~ "/srv/fornacast/private/import-91"
    refute html =~ "opaque-internal-evidence"
    refute html =~ "credential_envelope"
    refute html =~ ~r/<img\b/
    refute html =~ ~r/>\s*(?:Start|Cancel|Retry)(?: import)?\s*</i
    refute html =~ ~r/<el-dm-button\b/
    refute html =~ ~r/\bgap-(?:1|3|5|6|7|8|9|10|11|12)\b/
    refute html =~ ~r/(?:bg|text|border)-(?:red|blue|green|gray|slate|zinc)-\d+/
    refute html =~ "daisy"
  end

  test "show respects persisted selection and renders stable empty/error states" do
    view = run_view()
    [first, second] = view.repositories
    view = %{view | repositories: [first, %{second | selected: false}]}

    html =
      render_component(&ImportHTML.show/1,
        run: view,
        organizations: [],
        error: "Choices changed."
      )

    [alpha, beta] =
      Regex.scan(
        ~r/<input\b[^>]*name="selection\[repository_ids\]\[\]"[^>]*>/,
        html
      )

    assert hd(alpha) =~ ~s(value="9001")
    assert hd(alpha) =~ "checked"
    assert hd(beta) =~ ~s(value="9002")
    refute hd(beta) =~ "checked"
    assert html =~ "Choices changed."
    assert html =~ ~s(role="alert")
    assert html =~ "No owned organizations are available."
  end

  test "existing organization destination leaves the inactive new slug exactly blank" do
    view = run_view()

    view = %{
      view
      | destination: %{
          organization_action: :existing,
          organization_slug: "acme",
          organization_id: 51
        }
    }

    html =
      render_component(&ImportHTML.show/1,
        run: view,
        organizations: [%{id: 51, username: "acme"}],
        error: nil
      )

    [slug_input] = Regex.run(~r/<input\b[^>]*name="destination\[slug\]"[^>]*>/, html)
    refute slug_input =~ ~r/\bvalue=/
    [organization_option] = Regex.run(~r/<option\b[^>]*value="51"[^>]*>acme<\/option>/, html)
    assert organization_option =~ "selected"
  end

  test "show exposes mutation forms only while awaiting resolution across every run state" do
    for state <- @run_states do
      run = %{run_view() | state: state}

      html =
        render_component(&ImportHTML.show/1,
          run: run,
          organizations: [%{id: 51, username: "acme"}],
          error: nil
        )

      assert html =~ ~s(href="/imports/91")
      refute html =~ ~r/>\s*(?:Start|Cancel|Retry)(?: import)?\s*</i

      if state == :awaiting_resolution do
        assert html =~ ~s(action="/imports/91/destination")
        assert html =~ ~s(action="/imports/91/selection")
        assert html =~ ~s(name="selection[repository_ids][]")
      else
        refute html =~ ~s(action="/imports/91/destination")
        refute html =~ ~s(action="/imports/91/selection")
        refute html =~ ~s(name="selection[repository_ids][]")
        assert html =~ ~s(data-import-read-only="#{state}")
      end
    end
  end

  test "discovering and zero-result resolution have distinct semantic empty states" do
    discovering = %{
      run_view()
      | state: :discovering,
        repositories: [],
        reports: [],
        counts: %{selected: 0, published: 0, skipped: 0, warnings: 0, failures: 0}
    }

    discovering_html =
      render_component(&ImportHTML.show/1,
        run: discovering,
        organizations: [],
        error: nil
      )

    assert discovering_html =~ ~s(data-import-state-info="discovering")
    assert discovering_html =~ "GitHub repository discovery is in progress."
    assert discovering_html =~ ~s(href="/imports/91")
    refute discovering_html =~ "No repositories were discovered."
    refute discovering_html =~ ~s(action="/imports/91/destination")
    refute discovering_html =~ ~s(action="/imports/91/selection")

    awaiting = %{
      discovering
      | state: :awaiting_resolution,
        destination: %{
          organization_action: :new,
          organization_slug: "imports",
          organization_id: nil,
          organization_status: :invalid,
          organization_classification: "reserved_namespace"
        }
    }

    awaiting_html =
      render_component(&ImportHTML.show/1,
        run: awaiting,
        organizations: [],
        error: nil
      )

    assert awaiting_html =~ ~s(data-import-empty="awaiting_resolution")
    assert awaiting_html =~ "No GitHub repositories are available for selection."
    assert awaiting_html =~ ~s(data-destination-warning="invalid")
    assert awaiting_html =~ ~s(action="/imports/91/destination")
    refute awaiting_html =~ ~s(action="/imports/91/selection")
  end

  test "zero-repository organization conflicts render only persisted safe destination evidence" do
    base = %{
      run_view()
      | repositories: [],
        reports: [],
        counts: %{selected: 0, published: 0, skipped: 0, warnings: 0, failures: 0}
    }

    for {status, classification, label, variant} <- [
          {:invalid, "reserved_namespace", "Reserved namespace", "error"},
          {:conflict, "namespace_conflict", "Namespace conflict", "warning"}
        ] do
      run = %{
        base
        | destination: %{
            organization_action: :new,
            organization_slug: "imports",
            organization_id: nil,
            organization_status: status,
            organization_classification: classification
          }
      }

      html =
        render_component(&ImportHTML.show/1,
          run: run,
          organizations: [],
          error: nil
        )

      assert html =~ ~s(data-destination-warning="#{status}")
      assert html =~ label

      [warning_alert] =
        Regex.run(~r/<el-dm-alert\b[^>]*data-destination-warning="#{status}"[^>]*>/, html)

      assert warning_alert =~ ~s(type="#{variant}")
      refute html =~ "github_pat_destination_secret"
      refute html =~ "credential_envelope"
      refute html =~ ~r/>\s*(?:Start|Cancel|Retry)(?: import)?\s*</i
    end

    clean = render_component(&ImportHTML.show/1, run: base, organizations: [], error: nil)
    refute clean =~ "data-destination-warning"
    refute clean =~ "Reserved namespace"
    refute clean =~ "Namespace conflict"
  end

  defp run_view do
    %RunView{
      id: 91,
      actor_user_id: 11,
      source: %{
        kind: :organization,
        owner_github_id: 8_001,
        owner_login: "octo",
        repository_github_id: nil,
        repository_full_name: nil,
        provenance: %{
          "credential_envelope" => "github_pat_projection_secret",
          "storage_path" => "/srv/fornacast/private/import-91"
        }
      },
      destination: %{
        organization_action: :new,
        organization_slug: "octo-local",
        organization_id: nil,
        organization_status: :clean,
        organization_classification: nil
      },
      state: :awaiting_resolution,
      resume_state: nil,
      wait_reason: nil,
      next_attempt_at: nil,
      terminal_at: nil,
      report_finalized_at: nil,
      counts: %{selected: 2, published: 0, skipped: 0, warnings: 1, failures: 0},
      repositories: [
        %{
          id: 301,
          github_repository_id: 9_001,
          source_full_name: "octo/alpha",
          source_name: "alpha",
          selected: true,
          destination_owner_id: 11,
          destination_slug: "alpha",
          destination_visibility: :private,
          conflict_action: nil,
          state: :queued,
          resume_state: nil,
          wait_reason: nil,
          next_attempt_at: nil,
          attempt_count: 0,
          counts: %{imported: 0, skipped: 0, warnings: 1, failures: 0}
        },
        %{
          id: 302,
          github_repository_id: 9_002,
          source_full_name: "octo/beta",
          source_name: "beta",
          selected: true,
          destination_owner_id: 11,
          destination_slug: "beta",
          destination_visibility: :public,
          conflict_action: nil,
          state: :awaiting_resolution,
          resume_state: nil,
          wait_reason: "repository_conflict",
          next_attempt_at: nil,
          attempt_count: 0,
          counts: %{imported: 0, skipped: 0, warnings: 0, failures: 0}
        }
      ],
      reports: [
        %{
          repository_item_id: 301,
          scope: :repository,
          outcome: :warning,
          classification: "unsupported_releases",
          summary: "GitHub releases are not imported",
          metadata: %{
            "actual" => "opaque-internal-evidence",
            "field" => "credential_envelope"
          },
          source_count: 0
        }
      ],
      inserted_at: ~U[2026-08-26 07:00:00Z],
      updated_at: ~U[2026-08-26 07:01:00Z]
    }
  end

  defp account(identity_id, login) do
    %GitHubAccountView{
      identity_id: identity_id,
      github_user_id: 90_000 + identity_id,
      login: login,
      display_name: "Github:#{login}",
      avatar_url: "https://avatars.githubusercontent.com/u/#{90_000 + identity_id}",
      profile_url: "https://github.com/#{login}",
      credential_present: true,
      credential_status: :valid,
      identity_last_verified_at: ~U[2026-08-26 08:00:00Z],
      credential_last_verified_at: ~U[2026-08-26 08:01:00Z]
    }
  end
end
