defmodule ForgeMirrors.GitHubAppInstallationTest do
  use ExUnit.Case, async: false

  alias Fornacast.Repo
  alias ForgeMirrors.GitHubAppInstallation

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "persists exact provider installation metadata without any credential field" do
    observed_at = ~U[2026-09-04 10:00:00Z]

    assert {:ok, %GitHubAppInstallation{} = installation} =
             ForgeMirrors.observe_github_app_installation(attrs(observed_at))

    assert installation.github_installation_id == 44
    assert installation.github_account_id == 99
    assert installation.github_account_login == "octo-org"
    assert installation.account_type == :organization
    assert installation.repository_selection == :all
    assert installation.permissions == %{"contents" => "write", "metadata" => "read"}
    assert installation.state == :active
    assert DateTime.compare(installation.last_verified_at, observed_at) == :eq

    fields = GitHubAppInstallation.__schema__(:fields)
    assert GitHubAppInstallation.__schema__(:type, :last_verified_at) == :utc_datetime_usec
    refute Enum.any?(fields, &(&1 in [:token, :access_token, :private_key, :webhook_secret]))
  end

  test "newer observations update mutable selection, permissions, login, and state" do
    first_at = ~U[2026-09-04 10:00:00Z]
    assert {:ok, first} = ForgeMirrors.observe_github_app_installation(attrs(first_at))

    newer =
      attrs(DateTime.add(first_at, 60))
      |> Map.merge(%{
        github_account_login: "renamed-org",
        repository_selection: :selected,
        permissions: %{"contents" => "read"},
        state: :suspended
      })

    assert {:ok, suspended} = ForgeMirrors.observe_github_app_installation(newer)
    assert suspended.id == first.id
    assert suspended.github_account_login == "renamed-org"
    assert suspended.repository_selection == :selected
    assert suspended.permissions == %{"contents" => "read"}
    assert suspended.state == :suspended

    assert {:ok, active} =
             ForgeMirrors.observe_github_app_installation(%{
               newer
               | state: :active,
                 last_verified_at: DateTime.add(first_at, 120)
             })

    assert active.state == :active
  end

  test "a microsecond-newer observation within the same second is not lost" do
    first_at = ~U[2026-09-04 10:00:00.000001Z]
    newer_at = ~U[2026-09-04 10:00:00.000002Z]

    assert {:ok, first} = ForgeMirrors.observe_github_app_installation(attrs(first_at))
    assert first.last_verified_at == first_at

    assert {:ok, updated} =
             ForgeMirrors.observe_github_app_installation(
               attrs(newer_at)
               |> Map.put(:github_account_login, "microsecond-newer")
             )

    assert updated.id == first.id
    assert updated.github_account_login == "microsecond-newer"
    assert updated.last_verified_at == newer_at
  end

  test "older and equal observations cannot overwrite newer provider state" do
    newer_at = ~U[2026-09-04 10:02:00Z]

    assert {:ok, current} =
             ForgeMirrors.observe_github_app_installation(
               attrs(newer_at)
               |> Map.merge(%{
                 github_account_login: "new-login",
                 repository_selection: :selected,
                 permissions: %{"issues" => "write"}
               })
             )

    for observed_at <- [DateTime.add(newer_at, -60), newer_at] do
      assert {:ok, unchanged} =
               ForgeMirrors.observe_github_app_installation(
                 attrs(observed_at)
                 |> Map.put(:github_account_login, "stale-login")
               )

      assert unchanged.id == current.id
      assert unchanged.github_account_login == "new-login"
      assert unchanged.repository_selection == :selected
      assert unchanged.permissions == %{"issues" => "write"}
    end
  end

  test "concurrent first observations converge on the newest provider observation" do
    parent = self()
    first_at = ~U[2026-09-04 10:00:00Z]

    tasks =
      for {observed_at, login} <- [
            {first_at, "old-login"},
            {DateTime.add(first_at, 60), "new-login"}
          ] do
        Task.async(fn ->
          receive do: (:run -> :ok)

          ForgeMirrors.observe_github_app_installation(
            attrs(observed_at)
            |> Map.put(:github_account_login, login)
          )
        end)
      end

    Enum.each(tasks, fn task ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, task.pid)
      send(task.pid, :run)
    end)

    assert Enum.all?(tasks, fn task ->
             match?({:ok, %GitHubAppInstallation{}}, Task.await(task))
           end)

    assert {:ok, installation} = ForgeMirrors.get_github_app_installation(44)
    assert installation.github_account_login == "new-login"
    assert DateTime.compare(installation.last_verified_at, DateTime.add(first_at, 60)) == :eq
  end

  test "installation, account identity and account type are immutable" do
    observed_at = ~U[2026-09-04 10:00:00Z]
    assert {:ok, _installation} = ForgeMirrors.observe_github_app_installation(attrs(observed_at))

    for mutation <- [
          %{github_account_id: 100},
          %{account_type: :user}
        ] do
      assert {:error, :identity_mismatch} =
               ForgeMirrors.observe_github_app_installation(
                 attrs(DateTime.add(observed_at, 60))
                 |> Map.merge(mutation)
               )
    end
  end

  test "revocation is terminal even when a newer active observation arrives" do
    observed_at = ~U[2026-09-04 10:00:00Z]
    assert {:ok, active} = ForgeMirrors.observe_github_app_installation(attrs(observed_at))

    assert {:ok, revoked} =
             ForgeMirrors.revoke_github_app_installation(
               active.github_installation_id,
               DateTime.add(observed_at, 60)
             )

    assert revoked.state == :revoked

    assert {:error, :invalid_transition} =
             ForgeMirrors.observe_github_app_installation(attrs(DateTime.add(observed_at, 120)))

    assert {:error, :invalid_transition} =
             ForgeMirrors.suspend_github_app_installation(
               active.github_installation_id,
               DateTime.add(observed_at, 180)
             )
  end

  test "database constraints reject malformed durable metadata" do
    assert {:error, changeset} =
             ForgeMirrors.observe_github_app_installation(
               attrs(~U[2026-09-04 10:00:00Z])
               |> Map.merge(%{repository_selection: :selected, permissions: %{}})
             )

    assert errors_on(changeset).permissions
  end

  defp attrs(observed_at) do
    %{
      github_installation_id: 44,
      github_account_id: 99,
      github_account_login: "octo-org",
      account_type: :organization,
      repository_selection: :all,
      permissions: %{"contents" => "write", "metadata" => "read"},
      state: :active,
      last_verified_at: observed_at
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
