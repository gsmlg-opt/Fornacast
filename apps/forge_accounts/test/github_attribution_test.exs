defmodule ForgeAccounts.GitHubAttributionTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{ExternalAttribution, User}
  alias Fornacast.Repo

  setup do
    reset_database!()
    actor = user_fixture("attribution-actor-#{System.unique_integer([:positive])}")
    %{actor: actor}
  end

  test "an unlinked identity renders Github:<login>" do
    identity = observe_identity!("octocat")

    assert %ExternalAttribution{username: "Github:octocat"} =
             ForgeAccounts.resolve_attributions([{:github, identity.id}])[
               {:github, identity.id}
             ]

    refute ForgeAccounts.linked_user_id_for_github_identity(identity.id)
  end

  test "ghost renders Github:ghost" do
    ghost = ForgeAccounts.github_deleted_identity()

    assert %ExternalAttribution{username: "Github:ghost"} =
             ForgeAccounts.resolve_attributions([{:github, ghost.id}])[
               {:github, ghost.id}
             ]
  end

  test "linking switches presentation to the local user and unlinking switches back", %{
    actor: actor
  } do
    identity = observe_identity!("linked-user")

    assert {:ok, linked} = ForgeAccounts.link_github_identity(actor, identity)

    assert %User{id: actor_id} =
             ForgeAccounts.resolve_attributions([{:github, linked.id}])[
               {:github, linked.id}
             ]

    assert actor_id == actor.id

    assert {:ok, unlinked} = ForgeAccounts.unlink_github_identity(actor, linked)

    assert %ExternalAttribution{username: "Github:linked-user"} =
             ForgeAccounts.resolve_attributions([{:github, unlinked.id}])[
               {:github, unlinked.id}
             ]
  end

  test "resolve_attributions batches local users and github identities", %{actor: actor} do
    identity = observe_identity!("batch-user")
    assert {:ok, linked} = ForgeAccounts.link_github_identity(actor, identity)

    resolved =
      ForgeAccounts.resolve_attributions([
        {:user, actor.id},
        {:github, linked.id}
      ])

    assert %User{id: actor_id} = resolved[{:user, actor.id}]
    assert actor_id == actor.id
    assert %User{id: ^actor_id} = resolved[{:github, linked.id}]
  end

  defp observe_identity!(login) do
    suffix = System.unique_integer([:positive])

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(
               %{
                 github_user_id: 9_200_000_000 + suffix,
                 login: login,
                 avatar_url: nil,
                 profile_url: nil
               },
               DateTime.utc_now(:second)
             )

    identity
  end

  defp user_fixture(username) do
    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(
          ~w(github_credentials github_identities audit_events users),
          &Ecto.Adapters.SQL.query!(Repo, "delete from #{&1}", [])
        )
    end
  end
end
