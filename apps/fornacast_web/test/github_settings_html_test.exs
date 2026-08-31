defmodule FornacastWeb.GitHubSettingsHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeAccounts.GitHubAccountView
  alias FornacastWeb.GitHubSettingsHTML

  test "settings use DuskMoon hierarchy with one primary link action and safe account metadata" do
    html =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [account(41, "octocat", :valid), account(42, "hubot", :invalid)],
        error: nil
      )

    assert html =~ "data-github-settings"
    assert html =~ "bg-surface-container-low"
    assert length(Regex.scan(~r/<el-dm-card\b/, html)) == 3
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
    assert length(Regex.scan(~r/<button\b[^>]*class="[^"]*btn-primary/, html)) == 1
    assert html =~ ~s(<ul class="grid gap-4" data-github-account-list role="list">)
    assert length(Regex.scan(~r/<article\b/, html)) == 2
    assert length(Regex.scan(~r/<time\b[^>]*datetime="2026-08-26T08:0[01]:00Z"/, html)) == 4
    refute html =~ ~r/\bgap-(?:1|3|6)\b/
    refute html =~ ~r/(?:bg|text|border)-(?:red|blue|green|gray|slate|zinc)-\d+/
    refute html =~ "daisy"
  end

  test "PAT fields are write-only password inputs and every mutation has CSRF protection" do
    html =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [account(41, "octocat", :valid)],
        error: nil
      )

    pat_inputs = Regex.scan(~r/<input\b[^>]*name="github_account\[pat\]"[^>]*>/, html)
    assert length(pat_inputs) == 2

    assert length(Regex.scan(~r/phx-feedback-for="github_account\[pat\]"/, html)) == 2
    assert length(Regex.scan(~r/<label\b[^>]*class="form-label/, html)) == 2
    assert html =~ ~s(for="github-account-pat")
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

    assert length(Regex.scan(~r/name="_csrf_token"/, html)) == 5
    assert html =~ ~s(action="/settings/github" method="post")
    assert html =~ ~s(action="/settings/github/41/reverify" method="post")
    assert html =~ ~s(action="/settings/github/41/credential" method="post")
    assert html =~ ~s(name="_method" value="put")
    assert length(Regex.scan(~r/name="_method" value="delete"/, html)) == 2
  end

  test "credential deletion and unlink are distinct destructive confirmed actions" do
    html =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [account(41, "octocat", :valid)],
        error: nil
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
        error: nil
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
    empty = render_component(&GitHubSettingsHTML.index/1, accounts: [], error: nil)
    assert empty =~ "No linked GitHub accounts"

    error =
      render_component(&GitHubSettingsHTML.index/1,
        accounts: [],
        error: "Could not verify <script>alert(1)</script>"
      )

    assert error =~ "Could not verify &lt;script&gt;alert(1)&lt;/script&gt;"
    refute error =~ "<script>alert(1)</script>"
    assert error =~ ~s(<el-dm-alert id="github-settings-error" type="error")
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
