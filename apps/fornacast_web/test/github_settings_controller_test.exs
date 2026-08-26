defmodule FornacastWeb.GitHubSettingsControllerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, get_session: 1, get_session: 2, put_req_header: 3]

  alias ForgeAccounts.{GitHubAccountView, User}
  alias Fornacast.Repo

  @endpoint FornacastWeb.Endpoint
  @pat "submitted-settings-secret"

  defmodule TestImports do
    def reset do
      Process.put({__MODULE__, :accounts}, {:ok, []})
      Process.put({__MODULE__, :results}, %{})
      Process.put({__MODULE__, :calls}, [])
    end

    def accounts(result), do: Process.put({__MODULE__, :accounts}, result)

    def result(operation, result) do
      Process.put(
        {__MODULE__, :results},
        Map.put(Process.get({__MODULE__, :results}, %{}), operation, result)
      )
    end

    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    def list_github_accounts(actor) do
      record(:list, [actor])
      Process.get({__MODULE__, :accounts}, {:ok, []}) |> resolve_result()
    end

    def link_github_account(actor, pat, metadata) do
      record(:link, [actor, pat, metadata])
      operation_result(:link)
    end

    def reverify_github_account(actor, identity_id, metadata) do
      record(:reverify, [actor, identity_id, metadata])
      operation_result(:reverify)
    end

    def replace_github_credential(actor, identity_id, pat, metadata) do
      record(:replace, [actor, identity_id, pat, metadata])
      operation_result(:replace)
    end

    def delete_github_credential(actor, identity_id, metadata) do
      record(:delete_credential, [actor, identity_id, metadata])
      operation_result(:delete_credential)
    end

    def unlink_github_account(actor, identity_id, metadata) do
      record(:unlink, [actor, identity_id, metadata])
      operation_result(:unlink)
    end

    defp operation_result(operation) do
      Process.get({__MODULE__, :results}, %{})
      |> Map.get(operation, {:ok, :updated})
      |> resolve_result()
    end

    defp resolve_result({:raise, exception, message}), do: raise(exception, message: message)

    defp resolve_result({:raise_turso, code, message}),
      do: raise(Turso.Error, code: code, message: message)

    defp resolve_result(result), do: result

    defp record(operation, args) do
      Process.put(
        {__MODULE__, :calls},
        [{operation, args} | Process.get({__MODULE__, :calls}, [])]
      )
    end
  end

  setup do
    if postgres?(), do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)
    TestImports.reset()

    %{actor: user_fixture("github-settings")}
  end

  test "GET lists multiple owner-scoped GitHub accounts without exposing credentials", %{
    actor: actor
  } do
    TestImports.accounts({:ok, [account(41, "octocat"), account(42, "hubot", false)]})

    conn = request_conn(actor) |> get("/settings/github")
    html = html_response(conn, 200)

    assert html =~ "Github:octocat"
    assert html =~ "Github:hubot"
    assert html =~ "https://github.com/octocat"
    assert html =~ ~s(action="/settings/github/41/reverify")
    assert html =~ ~s(action="/settings/github/41/credential")
    assert html =~ ~s(action="/settings/github/42")
    assert html =~ ~s(name="github_account[pat]")
    assert html =~ ~s(type="password")
    assert html =~ ~s(autocomplete="new-password")
    refute html =~ "ciphertext"
    refute html =~ "nonce"
    refute html =~ "authentication tag"
    assert_private_no_store(conn)

    assert [{:list, [%User{id: actor_id}]}] = TestImports.calls()
    assert actor_id == actor.id
  end

  test "link submits the PAT once, redirects safely, and leaks it nowhere in the response", %{
    actor: actor
  } do
    TestImports.result(:link, {:ok, account(41, "octocat")})
    parent = self()

    log =
      capture_log(fn ->
        conn =
          request_conn(actor)
          |> post("/settings/github", %{"github_account" => %{"pat" => @pat}})

        send(parent, {:link_conn, conn})
      end)

    assert_receive {:link_conn, conn}
    assert redirected_to(conn, 303) == "/settings/github"
    assert_private_no_store(conn)

    assert [{:link, [%User{id: actor_id}, @pat, metadata]}] = mutation_calls()
    assert actor_id == actor.id
    assert metadata.user_agent == "github-settings-controller-test"
    assert metadata.ip_address == "127.0.0.1"
    refute inspect(metadata) =~ @pat

    refute conn.resp_body =~ @pat
    refute inspect(get_session(conn)) =~ @pat
    refute inspect(conn.assigns) =~ @pat
    refute inspect(conn.resp_headers) =~ @pat
    refute inspect(Map.get(conn.assigns, :flash, %{})) =~ @pat
    refute log =~ @pat
  end

  test "reverify redirects on success and renders a stable invalid-credential error", %{
    actor: actor
  } do
    TestImports.result(:reverify, {:ok, account(41, "octocat")})

    success = request_conn(actor) |> post("/settings/github/41/reverify", %{})
    assert redirected_to(success, 303) == "/settings/github"
    assert_private_no_store(success)
    assert [{:reverify, [%User{id: actor_id}, 41, _metadata]}] = mutation_calls()
    assert actor_id == actor.id

    TestImports.reset()
    TestImports.accounts({:ok, [account(41, "octocat")]})
    TestImports.result(:reverify, {:error, :invalid_credential})

    invalid = request_conn(actor) |> post("/settings/github/41/reverify", %{})
    html = html_response(invalid, 422)

    assert html =~ "GitHub rejected the personal access token."
    refute html =~ ":invalid_credential"
    assert_private_no_store(invalid)
  end

  test "create and replace use the same action-neutral invalid-credential message", %{
    actor: actor
  } do
    for {operation, request, reason} <- [
          {:link, :create, :invalid_credential},
          {:replace, :replace, :credential_invalid}
        ] do
      TestImports.reset()
      TestImports.result(operation, {:error, reason})

      conn = mutation_request(request, actor)
      html = html_response(conn, 422)

      assert html =~ "GitHub rejected the personal access token."
      refute html =~ "saved GitHub credential"
      assert_private_no_store(conn)
    end
  end

  test "sanitized service exceptions become leak-free unavailable responses", %{actor: actor} do
    cases = [
      {:link, :create, ForgeImports.GitHubAccounts.CredentialVerificationError},
      {:replace, :replace, ForgeAccounts.GitHubAccounts.CredentialCallbackError},
      {:reverify, :reverify, DBConnection.ConnectionError}
    ]

    for {operation, request, exception} <- cases do
      TestImports.reset()
      TestImports.accounts({:ok, [account(41, "octocat")]})
      TestImports.result(operation, {:raise, exception, "internal failure #{@pat}"})
      parent = self()

      log =
        capture_log(fn ->
          send(parent, {:exception_conn, operation, mutation_request(request, actor)})
        end)

      assert_receive {:exception_conn, ^operation, conn}
      html = html_response(conn, 503)

      assert html =~ "GitHub account settings are temporarily unavailable."
      refute secret_surfaces(conn) =~ @pat
      refute log =~ @pat
      assert_private_no_store(conn)
    end
  end

  test "programming exceptions are not swallowed by the service boundary", %{actor: actor} do
    TestImports.result(:link, {:raise, RuntimeError, "programming failure"})

    assert_raise RuntimeError, "programming failure", fn ->
      mutation_request(:create, actor)
    end
  end

  test "recoverable Turso failures become leak-free unavailable responses", %{actor: actor} do
    for code <- [:busy, :io, :corrupt] do
      TestImports.reset()
      TestImports.accounts({:ok, [account(41, "octocat")]})
      TestImports.result(:link, {:raise_turso, code, "adapter failure #{@pat}"})
      parent = self()

      log =
        capture_log(fn ->
          send(parent, {:turso_conn, code, mutation_request(:create, actor)})
        end)

      assert_receive {:turso_conn, ^code, conn}
      html = html_response(conn, 503)

      assert html =~ "GitHub account settings are temporarily unavailable."
      refute secret_surfaces(conn) =~ @pat
      refute log =~ @pat
      assert_private_no_store(conn)
    end
  end

  test "non-recoverable Turso and programming errors still propagate", %{actor: actor} do
    for code <- [:error, :constraint, :misuse, :invalid_param, nil] do
      TestImports.reset()
      TestImports.result(:link, {:raise_turso, code, "non-recoverable adapter failure"})

      error =
        assert_raise Turso.Error, "non-recoverable adapter failure", fn ->
          mutation_request(:create, actor)
        end

      assert error.code == code
    end
  end

  test "replace sends a PAT only for the exact selected identity", %{actor: actor} do
    TestImports.result(:replace, {:ok, account(41, "octocat-renamed")})

    conn =
      request_conn(actor)
      |> put("/settings/github/41/credential", %{
        "github_account" => %{"pat" => @pat}
      })

    assert redirected_to(conn, 303) == "/settings/github"
    assert [{:replace, [%User{id: actor_id}, 41, @pat, _metadata]}] = mutation_calls()
    assert actor_id == actor.id
    assert_private_no_store(conn)
    refute secret_surfaces(conn) =~ @pat
  end

  test "delete credential retains the link route while unlink uses its distinct route", %{
    actor: actor
  } do
    TestImports.result(:delete_credential, {:ok, account(41, "octocat", false)})

    deleted = request_conn(actor) |> delete("/settings/github/41/credential")
    assert redirected_to(deleted, 303) == "/settings/github"
    assert [{:delete_credential, [%User{id: actor_id}, 41, _metadata]}] = mutation_calls()
    assert actor_id == actor.id
    refute Enum.any?(mutation_calls(), &match?({:unlink, _args}, &1))
    assert_private_no_store(deleted)

    TestImports.reset()
    TestImports.result(:unlink, {:ok, account(41, "octocat", false)})

    unlinked = request_conn(actor) |> delete("/settings/github/41")
    assert redirected_to(unlinked, 303) == "/settings/github"
    assert [{:unlink, [%User{id: ^actor_id}, 41, _metadata]}] = mutation_calls()
    assert_private_no_store(unlinked)
  end

  test "foreign and forbidden identities share the same masked response", %{actor: actor} do
    bodies =
      for reason <- [:not_found, :forbidden] do
        TestImports.reset()
        TestImports.result(:reverify, {:error, reason})

        conn = request_conn(actor) |> post("/settings/github/987654/reverify", %{})
        html = html_response(conn, 404)

        assert html =~ "GitHub account not found."
        refute html =~ Atom.to_string(reason)
        assert_private_no_store(conn)
        mask_csrf(html)
      end

    assert [body, body] = bodies
  end

  test "unavailable vault and unexpected failures render stable service errors", %{actor: actor} do
    for reason <- [:credential_service_unavailable, :account_update_failed] do
      TestImports.reset()
      TestImports.accounts({:ok, [account(41, "octocat")]})
      TestImports.result(:replace, {:error, reason})

      conn =
        request_conn(actor)
        |> put("/settings/github/41/credential", %{
          "github_account" => %{"pat" => @pat}
        })

      html = html_response(conn, 503)
      assert html =~ "GitHub account settings are temporarily unavailable."
      refute html =~ Atom.to_string(reason)
      refute secret_surfaces(conn) =~ @pat
      assert_private_no_store(conn)
    end
  end

  test "invalid forms and identity IDs fail safely without calling a mutation", %{actor: actor} do
    for {method, path, params, status} <- [
          {:post, "/settings/github", %{"github_account" => "forged"}, 422},
          {:put, "/settings/github/41/credential", %{"github_account" => %{}}, 422},
          {:post, "/settings/github/not-an-id/reverify", %{}, 404},
          {:post, "/settings/github/0/reverify", %{}, 404},
          {:post, "/settings/github/-1/reverify", %{}, 404},
          {:post, "/settings/github/+41/reverify", %{}, 404},
          {:post, "/settings/github/041/reverify", %{}, 404},
          {:post, "/settings/github/41x/reverify", %{}, 404},
          {:post, "/settings/github/9223372036854775808/reverify", %{}, 404}
        ] do
      TestImports.reset()
      conn = request(method, request_conn(actor), path, params)
      assert html_response(conn, status) =~ expected_error(status)
      assert mutation_calls() == []
      assert_private_no_store(conn)
    end
  end

  test "PAT parsing rejects whitespace, NUL, empty, and oversized values before service access",
       %{
         actor: actor
       } do
    for pat <- [
          "",
          " surrounded ",
          "inside space",
          "submitted-bad\0value",
          "line\nbreak",
          "tab\tinside",
          "delete" <> <<127>>,
          "non-ascii-é",
          :binary.copy("p", 4_097)
        ] do
      TestImports.reset()

      conn =
        request_conn(actor)
        |> post("/settings/github", %{"github_account" => %{"pat" => pat}})

      assert html_response(conn, 422) =~ "Enter a GitHub personal access token."
      assert mutation_calls() == []
      if pat != "", do: refute(secret_surfaces(conn) =~ pat)
      assert_private_no_store(conn)
    end
  end

  test "expected domain error classes map to fixed status and message allowlists", %{actor: actor} do
    unavailable = "GitHub account settings are temporarily unavailable."

    cases =
      [
        {:invalid_credential, 422, "GitHub rejected the personal access token."},
        {:credential_invalid, 422, "GitHub rejected the personal access token."},
        {:identity_mismatch, 422, "That PAT belongs to a different GitHub account."},
        {:already_linked, 409, "That GitHub account cannot be linked."},
        {:credential_in_use, 409, "This saved PAT is in use by an active import."},
        {:busy, 409, "The GitHub account changed or is busy. Refresh and try again."},
        {:stale, 409, "The GitHub account changed or is busy. Refresh and try again."},
        {:request_gate_busy, 409,
         "The GitHub account changed or is busy. Refresh and try again."},
        {:duplicate_operation, 409,
         "The GitHub account changed or is busy. Refresh and try again."},
        {:primary_rate_limit, 503, "GitHub is rate limiting requests. Try again later."},
        {:secondary_rate_limit, 503, "GitHub is rate limiting requests. Try again later."}
      ] ++
        for reason <- [
              :credential_service_unavailable,
              :unsafe_credential_result,
              :invalid_operation_id,
              :invalid_request_metadata,
              :invalid_request,
              :upstream_unavailable,
              :unexpected_status,
              :transport,
              :timeout,
              :host_unavailable,
              :unsafe_host,
              :response_too_large,
              :invalid_json,
              :invalid_response,
              :invalid_pagination,
              :pagination_limit,
              :account_update_failed
            ],
            do: {reason, 503, unavailable}

    for {reason, status, message} <- cases do
      TestImports.reset()
      TestImports.result(:reverify, {:error, reason})

      conn = request_conn(actor) |> post("/settings/github/41/reverify", %{})
      html = html_response(conn, status)

      assert html =~ message
      refute html =~ inspect(reason)
      assert_private_no_store(conn)
    end
  end

  test "the browser pipeline enforces a real CSRF token for mutations", %{actor: actor} do
    form = request_conn(actor) |> get("/settings/github")
    token = extract_csrf_token(form.resp_body)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      form
      |> recycle_request(actor)
      |> with_production_csrf()
      |> post("/settings/github", %{"github_account" => %{"pat" => @pat}})
    end

    TestImports.result(:link, {:ok, account(41, "octocat")})

    accepted =
      form
      |> recycle_request(actor)
      |> with_production_csrf()
      |> post("/settings/github", %{
        "_csrf_token" => token,
        "github_account" => %{"pat" => @pat}
      })

    assert redirected_to(accepted, 303) == "/settings/github"
    assert_private_no_store(accepted)
  end

  test "unauthenticated and disabled users cannot reach GitHub account operations", %{
    actor: actor
  } do
    anonymous = request_conn(nil) |> get("/settings/github")
    assert redirected_to(anonymous) == "/login"
    assert_private_no_store(anonymous)
    assert mutation_calls() == []

    actor
    |> User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    disabled = request_conn(actor) |> post("/settings/github/41/reverify", %{})
    assert redirected_to(disabled) == "/login"
    assert get_session(disabled, :user_id) == nil
    assert mutation_calls() == []
    assert_private_no_store(disabled)
  end

  test "the no-store pipeline precedes setup redirects", %{actor: actor} do
    Fornacast.Setup.reset!()

    conn = request_conn(actor) |> get("/settings/github")

    assert redirected_to(conn) == "/setup"
    assert TestImports.calls() == []
    assert_private_no_store(conn)
  end

  test "a failed account listing is non-cacheable and sanitized", %{actor: actor} do
    TestImports.accounts({:error, :credential_service_unavailable})

    conn = request_conn(actor) |> get("/settings/github")
    html = html_response(conn, 503)

    assert html =~ "GitHub account settings are temporarily unavailable."
    refute html =~ "credential_service_unavailable"
    assert_private_no_store(conn)
  end

  test "SSH-key and API-key settings link to GitHub and do not cache reads or redirects", %{
    actor: actor
  } do
    for path <- ["/settings/ssh-keys", "/settings/api-keys"] do
      conn = request_conn(actor) |> get(path)
      assert html_response(conn, 200) =~ ~s(href="/settings/github">GitHub</a>)
      assert_private_no_store(conn)
    end

    for path <- ["/settings/ssh-keys/999999", "/settings/api-keys/999999"] do
      conn = request_conn(actor) |> delete(path)
      assert conn.status == 302
      assert_private_no_store(conn)
    end
  end

  defp request(method, conn, path, params) do
    case method do
      :post -> post(conn, path, params)
      :put -> put(conn, path, params)
    end
  end

  defp mutation_request(:create, actor) do
    request_conn(actor)
    |> post("/settings/github", %{"github_account" => %{"pat" => @pat}})
  end

  defp mutation_request(:replace, actor) do
    request_conn(actor)
    |> put("/settings/github/41/credential", %{"github_account" => %{"pat" => @pat}})
  end

  defp mutation_request(:reverify, actor) do
    request_conn(actor) |> post("/settings/github/41/reverify", %{})
  end

  defp request_conn(user) do
    conn =
      build_conn()
      |> put_req_header("user-agent", "github-settings-controller-test")
      |> Plug.Conn.put_private(:forge_imports, TestImports)

    if user, do: Plug.Test.init_test_session(conn, user_id: user.id), else: conn
  end

  defp recycle_request(conn, actor) do
    conn
    |> recycle()
    |> put_req_header("user-agent", "github-settings-controller-test")
    |> Plug.Conn.put_private(:forge_imports, TestImports)
    |> Plug.Test.init_test_session(user_id: actor.id)
  end

  defp with_production_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp extract_csrf_token(html) do
    [_full, token] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html)
    token
  end

  defp mutation_calls do
    Enum.reject(TestImports.calls(), &match?({:list, _args}, &1))
  end

  defp secret_surfaces(conn) do
    [
      conn.resp_body,
      inspect(get_session(conn)),
      inspect(conn.assigns),
      inspect(conn.resp_headers),
      inspect(Map.get(conn.assigns, :flash, %{}))
    ]
    |> Enum.join("\n")
  end

  defp assert_private_no_store(conn) do
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp expected_error(404), do: "GitHub account not found."
  defp expected_error(422), do: "Enter a GitHub personal access token."

  defp mask_csrf(html) do
    html
    |> then(&Regex.replace(~r/value="[^\"]+"/, &1, ~s(value="token")))
    |> then(&Regex.replace(~r/content="[^\"]+"/, &1, ~s(content="token")))
  end

  defp account(identity_id, login, credential_present \\ true) do
    %GitHubAccountView{
      identity_id: identity_id,
      github_user_id: 90_000 + identity_id,
      login: login,
      display_name: "Github:#{login}",
      avatar_url: "https://avatars.githubusercontent.com/u/#{90_000 + identity_id}",
      profile_url: "https://github.com/#{login}",
      credential_present: credential_present,
      credential_status: if(credential_present, do: :valid),
      identity_last_verified_at: ~U[2026-08-26 08:00:00Z],
      credential_last_verified_at: if(credential_present, do: ~U[2026-08-26 08:01:00Z])
    }
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

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
end
