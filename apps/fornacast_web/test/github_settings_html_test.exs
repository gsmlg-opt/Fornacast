defmodule FornacastWeb.GitHubSettingsHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeAccounts.GitHubAccountView
  alias FornacastWeb.GitHubSettingsHTML

  test "settings use compact connection navigation and safe account metadata" do
    html =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [account(41, "octocat", :valid), account(42, "hubot", :invalid)],
        error: nil,
        device_flow: nil
      )

    assert html =~ "data-github-settings"
    assert html =~ "bg-surface-container-low"
    document = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(document, "article.card")) == 2
    assert html =~ ~s(href="/settings/github/device")
    assert html =~ ~s(href="/settings/github/link")
    assert html =~ "Connect with GitHub"
    assert html =~ "Link GitHub account"
    refute html =~ ~s(id="github-device-connect")
    refute html =~ ~s(id="github-link-account")
    assert html =~ "Github:octocat"
    assert html =~ "Github:hubot"
    refute html =~ "https://avatars.githubusercontent.com/u/90041"
    assert html =~ ~s(href="https://github.com/octocat")
    assert html =~ ~s(rel="noopener noreferrer")
    assert html =~ "Credential verified"
    assert html =~ "Credential invalid"
    assert html =~ "Aug 26, 2026"
    assert html =~ ~r/<h2\b[^>]*>Linked accounts<\/h2>/
    refute html =~ ~r/<h2\b[^>]*>GitHub accounts<\/h2>/
    assert length(Regex.scan(~r/<h3\b[^>]*id="github-account-\d+-heading"/, html)) == 2
    assert length(Regex.scan(~r/<a\b[^>]*class="[^"]*btn-primary/, html)) == 1
    assert html =~ ~s(<ul class="grid gap-4" data-github-account-list role="list">)
    assert Enum.count(LazyHTML.query(document, "article[aria-labelledby]")) == 2
    assert length(Regex.scan(~r/<time\b[^>]*datetime="2026-08-26T08:0[01]:00Z"/, html)) == 4
    refute html =~ ~r/\bgap-(?:1|3|6)\b/
    refute html =~ ~r/(?:bg|text|border)-(?:red|blue|green|gray|slate|zinc)-\d+/
    refute html =~ "daisy"
  end

  test "saved PAT replacement fields stay write-only and every account mutation has CSRF protection" do
    html =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [account(41, "octocat", :valid)],
        error: nil,
        device_flow: nil
      )

    pat_inputs = Regex.scan(~r/<input\b[^>]*name="github_account\[pat\]"[^>]*>/, html)
    assert length(pat_inputs) == 1

    assert length(Regex.scan(~r/phx-feedback-for="github_account\[pat\]"/, html)) == 1
    assert length(Regex.scan(~r/<label\b[^>]*class="form-label/, html)) == 1
    refute html =~ ~s(for="github-account-pat")
    assert html =~ ~s(for="github-account-41-replacement-pat")

    for [input] <- pat_inputs do
      assert input =~ ~s(type="password")
      assert input =~ ~s(autocomplete="new-password")
      assert input =~ ~s(maxlength="4096")
      assert input =~ ~s(spellcheck="false")
      assert input =~ ~s(autocapitalize="none")
      assert input =~ ~s(required)
      refute input =~ ~r/\bvalue=/
    end

    assert length(Regex.scan(~r/name="_csrf_token"/, html)) == 4
    refute html =~ ~s(action="/settings/github" method="post")
    assert html =~ ~s(action="/settings/github/41/reverify" method="post")
    assert html =~ ~s(action="/settings/github/41/credential" method="post")
    assert html =~ ~s(name="_method" value="put")
    assert length(Regex.scan(~r/name="_method" value="delete"/, html)) == 2
  end

  test "credential deletion and unlink are distinct destructive confirmed actions" do
    html =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [account(41, "octocat", :valid)],
        error: nil,
        device_flow: nil
      )

    assert html =~ "Delete saved PAT"
    assert html =~ "Unlink account"
    assert html =~ "Delete this saved GitHub PAT?"
    assert html =~ "Unlink this GitHub account?"
    assert html =~ "Historical attribution will remain Github:octocat."
    assert length(Regex.scan(~r/<details\b/, html)) == 2
    refute html =~ "data-dm-confirm-dialog"
    assert html =~ "Confirm delete saved PAT"
    assert html =~ "Confirm unlink account"
  end

  test "an identity without a saved PAT remains linked and has no credential-only actions" do
    html =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [account(41, "octocat", nil)],
        error: nil,
        device_flow: nil
      )

    assert html =~ "Github:octocat"
    assert html =~ "No saved PAT"
    refute html =~ "Saved PAT verified"
    refute html =~ ~s(action="/settings/github/41/reverify")
    refute html =~ ~s(action="/settings/github/41/credential")
    assert html =~ ~s(action="/settings/github/41" method="post")
    assert html =~ "Link the account again above to save a new PAT."
  end

  test "empty and error states are explicit, stable, and escaped" do
    empty =
      render_component(&GitHubSettingsHTML.index/1, accounts: [], error: nil, device_flow: nil)

    assert empty =~ "No linked GitHub accounts"
    refute empty =~ ~s(id="github-saved-connections")

    error =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [],
        error: "Could not verify <script>alert(1)</script>",
        device_flow: nil
      )

    assert error =~ "Could not verify &lt;script&gt;alert(1)&lt;/script&gt;"
    refute error =~ "<script>alert(1)</script>"
    assert error =~ ~s(<el-dm-alert id="github-settings-error" type="error")
  end

  test "GitHub App credentials display their connection and reconnection state" do
    connected = %{account(41, "octocat", :valid) | credential_kind: :github_app_user}

    reconnect = %{
      account(42, "hubot", :invalid)
      | credential_kind: :github_app_user,
        reconnect_required: true
    }

    html =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [connected, reconnect],
        error: nil,
        device_flow: nil
      )

    assert html =~ "GitHub App connected"
    assert html =~ "Reconnect GitHub"
    assert html =~ "Delete this saved GitHub App token?"
    refute html =~ "GitHub GitHub"
  end

  test "saved GitHub App connection is visible above the connect form without an authorization attempt" do
    connected = %{account(41, "octocat", :valid) | credential_kind: :github_app_user}

    reconnect = %{
      account(42, "hubot", :invalid)
      | credential_kind: :github_app_user,
        reconnect_required: true
    }

    html =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [connected, reconnect],
        error: nil,
        device_flow: nil
      )

    summary =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#github-saved-connections")
      |> LazyHTML.text()

    assert summary =~ "@octocat"
    assert summary =~ "GitHub App connected"
    assert summary =~ "@hubot"
    assert summary =~ "Reconnect GitHub"
    assert html =~ ~s(href="#github-account-41")
    {summary_position, _} = :binary.match(html, ~s(id="github-saved-connections"))
    {connect_position, _} = :binary.match(html, ~s(href="/settings/github/device"))
    assert summary_position < connect_position
  end

  test "completed attempts cannot claim a removed or invalid connection is saved" do
    reconnect = %{
      account(42, "hubot", :invalid)
      | credential_kind: :github_app_user,
        reconnect_required: true
    }

    for accounts <- [[], [reconnect]] do
      html =
        render_component(&GitHubSettingsHTML.index/1,
          accounts: accounts,
          error: nil,
          device_flow: %{status: :complete}
        )

      refute html =~ "GitHub connected successfully."
      refute html =~ "Your connection is saved."
      refute html =~ "GitHub App connected"
      refute html =~ "select this saved connection"

      if accounts == [] do
        refute html =~ ~s(id="github-saved-connections")
      else
        assert html =~ "Reconnect GitHub"
      end
    end
  end

  test "Device Flow configuration has its own start, pending, and error states" do
    initial = render_component(&GitHubSettingsHTML.device/1, error: nil, device_flow: nil)
    assert initial =~ ~s(action="/settings/github/device" method="post")
    assert initial =~ ~s(name="_csrf_token")
    assert initial =~ ~s(href="/settings/github")
    assert initial =~ "Back to linked accounts"
    refute initial =~ ~s(name="github_account[pat]")

    pending =
      render_component(&GitHubSettingsHTML.device/1,
        error: nil,
        device_flow: %{
          id: "attempt-id",
          status: :pending,
          user_code: "ABCD-EFGH",
          verification_uri: "https://github.com/login/device",
          interval: 5,
          expires_in: 900
        }
      )

    assert pending =~ "ABCD-EFGH"
    assert pending =~ ~s(data-github-device-poll="true")
    assert pending =~ ~s(data-github-device-id="attempt-id")
    assert pending =~ ~s(href="https://github.com/login/device")
    assert pending =~ ~s(action="/settings/github/device/attempt-id/cancel")

    failed =
      render_component(&GitHubSettingsHTML.device/1,
        error: nil,
        device_flow: %{status: :failed, error: :device_flow_disabled}
      )

    assert failed =~ "Enable Device Flow in the GitHub App settings"
    refute failed =~ ~s(data-github-device-poll="true")
  end

  test "PAT linking has its own write-only configuration form" do
    html = render_component(&GitHubSettingsHTML.link/1, error: nil)
    assert html =~ ~s(action="/settings/github" method="post")
    assert html =~ ~s(href="/settings/github")
    assert html =~ "Back to linked accounts"
    assert length(Regex.scan(~r/name="_csrf_token"/, html)) == 1
    assert html =~ ~s(name="github_account[pat]")
    assert html =~ ~s(type="password")
    assert html =~ ~s(autocomplete="new-password")
    [pat_input] = Regex.run(~r/<input\b[^>]*name="github_account\[pat\]"[^>]*>/, html)
    refute pat_input =~ ~r/\bvalue=/
    refute html =~ ~s(action="/settings/github/device")

    error =
      render_component(&GitHubSettingsHTML.link/1,
        error: "Could not verify <script>alert(1)</script>"
      )

    assert error =~ "Could not verify &lt;script&gt;alert(1)&lt;/script&gt;"
    refute error =~ "<script>alert(1)</script>"
  end

  defp account(identity_id, login, credential_status) do
    credential_present = credential_status in [:valid, :invalid]

    %GitHubAccountView{
      identity_id: identity_id,
      github_user_id: 90_000 + identity_id,
      login: login,
      display_name: "Github:#{login}",
      avatar_url: "https://avatars.githubusercontent.com/u/#{90_000 + identity_id}",
      profile_url: "https://github.com/#{login}",
      credential_present: credential_present,
      credential_status: credential_status,
      identity_last_verified_at: ~U[2026-08-26 08:00:00Z],
      credential_last_verified_at: if(credential_present, do: ~U[2026-08-26 08:01:00Z])
    }
  end
end
