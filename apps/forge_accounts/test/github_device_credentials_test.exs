defmodule ForgeAccounts.GitHubDeviceCredentialsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ForgeAccounts.GitHubCredential
  alias Fornacast.{AuditEvent, Repo}

  setup do
    :ok = SQL.Sandbox.checkout(Repo, sandbox: false)
    reset_database!()
    on_exit(fn -> SQL.Sandbox.unboxed_run(Repo, &reset_database!/0) end)
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "device-#{suffix}",
        email: "device-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    %{actor: actor}
  end

  test "encrypts both tokens and returns safe lifecycle fields", %{actor: actor} do
    token = token()
    assert {:ok, view} = ForgeAccounts.save_github_device_account(actor, profile(), token, %{})
    credential = credential(view)
    assert view.credential_kind == :github_app_user
    assert view.expires_at == token.expires_at
    refute view.reconnect_required
    assert credential.credential_kind == :github_app_user
    assert credential.client_id == token.client_id
    assert credential.token_generation == 1
    assert credential.ciphertext != token.access_token
    assert credential.refresh_ciphertext != token.refresh_token
    refute inspect(credential) =~ token.access_token
    refute inspect(credential) =~ token.refresh_token
    refute inspect(view) =~ token.refresh_token
    refute inspect(Repo.all(AuditEvent)) =~ token.refresh_token
    assert_access(actor, view, token.access_token)
  end

  test "device save rejects an unauthenticated actor without raising" do
    assert {:error, :forbidden} =
             ForgeAccounts.save_github_device_account(nil, profile(), token(), %{})
  end

  test "device authorization replaces a PAT through its captured generation", %{actor: actor} do
    {:ok, view} = ForgeAccounts.save_github_account(actor, profile(), "old-manual-pat", %{})
    old = credential(view)
    {:ok, checked} = ForgeAccounts.validate_github_link_request(actor, %{})

    assert {:ok, connected} =
             ForgeAccounts.save_github_device_account(
               actor,
               profile(),
               token(),
               %{},
               checked.references
             )

    assert connected.credential_kind == :github_app_user
    assert credential(view).id == old.id
    assert credential(view).verification_version > old.verification_version
    assert credential(view).token_generation > old.token_generation

    assert {:error, :stale} =
             ForgeAccounts.save_github_device_account(
               actor,
               profile(),
               token(),
               %{},
               checked.references
             )
  end

  test "refresh rejects mismatched client bindings and reused one-use material", %{actor: actor} do
    for replacement <- [
          token(%{client_id: "different-client", refresh_token: "new-refresh"}),
          token()
        ] do
      {:ok, view} =
        ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

      assert {:error, :reauthorization_required} =
               refresh(actor, view, fn _, _ -> {:ok, replacement} end)

      assert credential(view).status == :invalid
    end
  end

  test "a rejected old refresh cannot invalidate a concurrent PAT replacement", %{actor: actor} do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    task = blocked_refresh(actor, view, {:error, :invalid_grant})
    assert_receive {:refresh_started, pid}

    assert {:ok, _} =
             ForgeAccounts.replace_github_credential(
               actor,
               view.identity_id,
               profile(),
               "replacement-pat",
               %{}
             )

    send(pid, :finish_refresh)
    assert {:error, :stale} = Task.await(task)
    assert credential(view).status == :valid
    assert_access(actor, view, "replacement-pat")
  end

  test "deletion and resaving during a refresh cannot resurrect the deleted row", %{actor: actor} do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    old_id = credential(view).id
    task = blocked_refresh(actor, view)
    assert_receive {:refresh_started, pid}
    assert {:ok, _} = ForgeAccounts.delete_github_credential(actor, view.identity_id, %{})
    assert {:ok, _} = ForgeAccounts.save_github_account(actor, profile(), "resaved-pat", %{})
    send(pid, :finish_refresh)
    assert {:error, :stale} = Task.await(task)
    assert credential(view).id != old_id
    assert_access(actor, view, "resaved-pat")
  end

  test "refresh ciphertext is purpose bound and a failed decrypt never dispatches", %{
    actor: actor
  } do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    saved = credential(view)

    Repo.update_all(from(c in GitHubCredential, where: c.id == ^saved.id),
      set: [
        refresh_ciphertext: saved.ciphertext,
        refresh_nonce: saved.nonce,
        refresh_tag: saved.tag,
        refresh_key_id: saved.key_id
      ]
    )

    assert {:error, :credential_service_unavailable} =
             refresh(actor, view, fn _, _ -> flunk("unbound refresh dispatched") end)

    assert is_nil(credential(view).refresh_claim_id)
  end

  test "ownership and captured snapshots prevent cross-user or stale reauthorization", %{
    actor: actor
  } do
    {:ok, checked} = ForgeAccounts.validate_github_link_request(actor, %{})
    {:ok, view} = ForgeAccounts.save_github_device_account(actor, profile(), token(), %{})

    assert {:error, :stale} =
             ForgeAccounts.save_github_device_account(
               actor,
               profile(),
               token(),
               %{},
               checked.references
             )

    {:ok, other} =
      ForgeAccounts.create_user(%{
        username: "other-device",
        email: "other-device@example.test",
        password: "correct horse battery staple"
      })

    assert {:error, :already_linked} =
             ForgeAccounts.save_github_device_account(other, profile(), token(), %{})

    assert {:error, :not_found} = refresh(other, view, fn _, _ -> flunk("cross-user refresh") end)
  end

  test "rejects refresh-token leaks in submitted profile and request metadata", %{actor: actor} do
    value = token(%{refresh_token: "opaque-refresh-value"})

    assert {:error, :invalid_response} =
             ForgeAccounts.save_github_device_account(
               actor,
               %{profile() | login: value.refresh_token},
               value,
               %{}
             )

    assert {:error, :invalid_request_metadata} =
             ForgeAccounts.save_github_device_account(actor, profile(), value, %{
               request_id: value.refresh_token
             })

    refute Repo.exists?(GitHubCredential)
  end

  test "PAT replacement clears the device lifecycle and remains usable", %{actor: actor} do
    {:ok, view} = ForgeAccounts.save_github_device_account(actor, profile(), token(), %{})
    old = credential(view)

    assert {:ok, pat_view} =
             ForgeAccounts.replace_github_credential(
               actor,
               view.identity_id,
               profile(),
               "manual-pat",
               %{}
             )

    current = credential(view)
    assert current.credential_kind == :pat

    for field <- [
          :client_id,
          :expires_at,
          :refresh_expires_at,
          :refresh_ciphertext,
          :refresh_nonce,
          :refresh_tag,
          :refresh_key_id,
          :refresh_claim_id,
          :refresh_claimed_at
        ],
        do: assert(is_nil(Map.fetch!(current, field)))

    assert current.verification_version > old.verification_version
    assert current.token_generation > old.token_generation
    assert pat_view.credential_kind == :pat
    assert :ok = refresh(actor, view, fn _, _ -> flunk("PAT must not refresh") end)
    assert_access(actor, view, "manual-pat")
  end

  test "fresh device credentials avoid provider refresh", %{actor: actor} do
    {:ok, view} = ForgeAccounts.save_github_device_account(actor, profile(), token(), %{})
    assert :ok = refresh(actor, view, fn _, _ -> flunk("fresh token refreshed") end)
  end

  test "rotation persists both tokens atomically without changing authorization version", %{
    actor: actor
  } do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    old = credential(view)
    {:ok, reference} = ForgeAccounts.github_account_reference(actor, view.identity_id)
    renewed = token(%{access_token: "renewed-access", refresh_token: "renewed-refresh"})

    assert :ok =
             refresh(actor, view, fn refresh, client ->
               refute Repo.in_transaction?()
               assert refresh == expiring_token().refresh_token
               assert client == renewed.client_id
               {:ok, renewed}
             end)

    current = credential(view)
    assert current.verification_version == old.verification_version
    assert current.token_generation == old.token_generation + 1
    refute current.refresh_ciphertext == old.refresh_ciphertext
    assert is_nil(current.refresh_claim_id)
    {:ok, new_reference} = ForgeAccounts.github_account_reference(actor, view.identity_id)
    refute new_reference.credential.generation_digest == reference.credential.generation_digest

    assert {:error, :stale} =
             ForgeAccounts.mark_github_credential_invalid(
               actor,
               view.identity_id,
               reference.credential,
               %{}
             )

    assert_access(actor, view, renewed.access_token)
  end

  test "expired saved access token cannot bypass refresh coordination", %{actor: actor} do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    expire_access(view)

    assert {:error, :reauthorization_required} =
             ForgeAccounts.with_github_credential(actor, view.identity_id, fn _ ->
               flunk("expired access escaped")
             end)

    assert {:error, :reauthorization_required} =
             ForgeAccounts.with_github_import_credential(
               actor,
               view.identity_id,
               credential(view).id,
               fn _, _ -> flunk("expired import access escaped") end
             )

    assert {:error, :reauthorization_required} =
             ForgeAccounts.with_github_credential_for_verification(actor, view.identity_id, fn _,
                                                                                               _ ->
               flunk("expired verification access escaped")
             end)

    assert :ok =
             refresh(actor, view, fn _, _ -> {:ok, token(%{refresh_token: "rotated-refresh"})} end)
  end

  test "expired refresh and rejected or ambiguous calls require reconnection", %{actor: actor} do
    for outcome <- [:expired, :invalid_grant, :transport_error, :raise, :malformed] do
      {:ok, view} =
        ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

      if outcome == :expired do
        Repo.update_all(from(c in GitHubCredential, where: c.id == ^credential(view).id),
          set: [refresh_expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
        )
      end

      assert {:error, :reauthorization_required} =
               refresh(actor, view, fn _, _ ->
                 case outcome do
                   :expired -> flunk("expired refresh sent to provider")
                   :raise -> raise "refresh failed with #{expiring_token().refresh_token}"
                   :malformed -> {:ok, %{access_token: "incomplete"}}
                   reason -> {:error, reason}
                 end
               end)

      assert credential(view).status == :invalid
      assert {:ok, [safe]} = ForgeAccounts.list_github_accounts(actor)
      assert safe.reconnect_required

      assert {:error, :reauthorization_required} =
               refresh(actor, view, fn _, _ -> flunk("one-use token retried") end)
    end
  end

  test "persisted abandoned claims require reconnection instead of reusing token", %{actor: actor} do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    Repo.update_all(from(c in GitHubCredential, where: c.id == ^credential(view).id),
      set: [
        refresh_claim_id: Ecto.UUID.generate(),
        refresh_claimed_at: DateTime.add(DateTime.utc_now(:second), -120)
      ]
    )

    assert {:error, :reauthorization_required} =
             refresh(actor, view, fn _, _ -> flunk("ambiguous refresh retried") end)

    assert credential(view).status == :invalid
  end

  test "persisted claims serialize independent callers", %{actor: actor} do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    task = blocked_refresh(actor, view)
    assert_receive {:refresh_started, pid}
    assert :ok = SQL.Sandbox.checkin(Repo)
    :ok = SQL.Sandbox.checkout(Repo, sandbox: false)

    assert {:error, :refresh_in_progress} =
             refresh(actor, view, fn _, _ -> flunk("concurrent refresh") end)

    send(pid, :finish_refresh)
    assert :ok = Task.await(task)
    assert :ok = refresh(actor, view, fn _, _ -> flunk("already renewed") end)
  end

  test "plain and conditional verification writes cannot release an in-flight refresh claim", %{
    actor: actor
  } do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    {:ok, reference} = ForgeAccounts.github_account_reference(actor, view.identity_id)
    task = blocked_refresh(actor, view)
    assert_receive {:refresh_started, pid}

    try do
      claim_id = credential(view).refresh_claim_id

      assert {:error, :refresh_in_progress} =
               ForgeAccounts.refresh_github_account_if_current(
                 actor,
                 view.identity_id,
                 reference.credential,
                 profile(),
                 %{}
               )

      assert {:error, :refresh_in_progress} =
               ForgeAccounts.refresh_github_account(
                 actor,
                 view.identity_id,
                 profile(),
                 %{}
               )

      assert {:error, :refresh_in_progress} =
               ForgeAccounts.mark_github_credential_invalid(
                 actor,
                 view.identity_id,
                 reference.credential,
                 %{}
               )

      assert credential(view).refresh_claim_id == claim_id

      assert {:error, :refresh_in_progress} =
               refresh(actor, view, fn _, _ -> flunk("one-use token sent twice") end)
    after
      send(pid, :finish_refresh)
      result = Task.await(task)
      send(self(), {:refresh_completed, result})
    end

    assert_receive {:refresh_completed, :ok}
    assert_access(actor, view, "rotated-access")
    assert credential(view).verification_version == reference.credential.verification_version
  end

  test "replacement during provider work fences the old refresh result", %{actor: actor} do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    task = blocked_refresh(actor, view)
    assert_receive {:refresh_started, pid}

    assert {:ok, _} =
             ForgeAccounts.replace_github_credential(
               actor,
               view.identity_id,
               profile(),
               "replacement-pat",
               %{}
             )

    send(pid, :finish_refresh)
    assert {:error, :stale} = Task.await(task)
    assert_access(actor, view, "replacement-pat")
  end

  test "unlinking during provider work prevents resurrection", %{actor: actor} do
    {:ok, view} =
      ForgeAccounts.save_github_device_account(actor, profile(), expiring_token(), %{})

    task = blocked_refresh(actor, view)
    assert_receive {:refresh_started, pid}
    assert {:ok, _} = ForgeAccounts.unlink_github_account(actor, view.identity_id, %{})
    send(pid, :finish_refresh)
    assert {:error, reason} = Task.await(task)
    assert reason in [:not_found, :stale]
    refute Repo.get_by(GitHubCredential, github_identity_id: view.identity_id)
  end

  test "refresh material cannot leak through saved profile checks or callbacks", %{actor: actor} do
    token = token(%{refresh_token: "unmarked-private-refresh"})
    {:ok, view} = ForgeAccounts.save_github_device_account(actor, profile(), token, %{})

    assert {:error, :invalid_response} =
             ForgeAccounts.validate_github_external_profile(actor, %{login: token.refresh_token})

    assert {:error, :invalid_request_metadata} =
             ForgeAccounts.validate_github_link_request(actor, %{request_id: token.refresh_token})

    assert {:error, :unsafe_credential_result} =
             ForgeAccounts.with_github_credential(actor, view.identity_id, fn _ ->
               {:error, String.to_atom(token.refresh_token)}
             end)
  end

  defp refresh(actor, view, callback),
    do:
      ForgeAccounts.refresh_github_credential(
        actor,
        view.identity_id,
        credential(view).id,
        callback
      )

  defp credential(view), do: Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)

  defp expire_access(view),
    do:
      Repo.update_all(from(c in GitHubCredential, where: c.id == ^credential(view).id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
      )

  defp assert_access(actor, view, expected) do
    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential(actor, view.identity_id, fn token ->
               assert token == expected
               :ok
             end)
  end

  defp blocked_refresh(
         actor,
         view,
         result \\ {:ok,
          token(%{access_token: "rotated-access", refresh_token: "rotated-refresh"})}
       ) do
    parent = self()

    Task.async(fn ->
      :ok = SQL.Sandbox.checkout(Repo, sandbox: false)

      try do
        refresh(actor, view, fn _, _ ->
          send(parent, {:refresh_started, self()})

          receive do
            :finish_refresh -> result
          after
            5_000 -> raise "refresh barrier timed out"
          end
        end)
      after
        SQL.Sandbox.checkin(Repo)
      end
    end)
  end

  defp token(overrides \\ %{}) do
    Map.merge(
      %{
        client_id: "Iv23lizCVE3E24s7fCA0",
        access_token: "test-device-access",
        refresh_token: "test-device-refresh",
        expires_at: DateTime.add(DateTime.utc_now(:second), 3_600),
        refresh_expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
      },
      overrides
    )
  end

  defp expiring_token, do: token(%{expires_at: DateTime.add(DateTime.utc_now(:second), 30)})

  defp profile,
    do: %{
      github_user_id: 9_000_000_001,
      login: "octocat",
      avatar_url: "https://avatars.githubusercontent.com/u/9000000001",
      profile_url: "https://github.com/octocat"
    }

  defp reset_database! do
    for table <- [
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "organization_pat_configurations",
          "github_credentials",
          "github_identities",
          "audit_events",
          "repository_collaborators",
          "repositories",
          "organization_members",
          "api_keys",
          "ssh_keys",
          "users"
        ],
        do: SQL.query!(Repo, "delete from #{table}", [])
  end
end
