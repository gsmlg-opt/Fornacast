defmodule ForgeRepos.DomainOutboxProducersTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias Fornacast.{DomainOutboxEvent, Repo}

  @moduletag :tmp_dir

  setup context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, context.tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    owner =
      Repo.insert!(%User{
        username: "outbox-#{System.unique_integer([:positive])}",
        email: "outbox-#{System.unique_integer([:positive])}@example.com",
        password_hash: "unused",
        kind: :user,
        state: :active
      })

    %{owner: owner}
  end

  test "browser repository creation atomically emits a provider-neutral event", %{owner: owner} do
    assert {:ok, repository} =
             ForgeRepos.create_repository(owner, %{name: "Outbox", slug: "outbox"})

    assert %DomainOutboxEvent{
             aggregate_type: "repository",
             aggregate_id: aggregate_id,
             event_type: "repository.created",
             origin: :fornacast,
             payload: payload,
             state: :pending
           } = repository_event(repository.id, "repository.created")

    assert aggregate_id == Integer.to_string(repository.id)

    assert payload == %{
             "default_branch" => "main",
             "generation" => 1,
             "owner_id" => owner.id,
             "repository_id" => repository.id,
             "slug" => "outbox",
             "visibility" => "private"
           }
  end

  test "API repository creation propagates causation metadata", %{owner: owner} do
    assert {:ok, repository} =
             ForgeRepos.create_api_repository(
               owner,
               owner,
               %{"name" => "API outbox"},
               %{
                 causation_id: "request:create-123",
                 correlation_id: "sync:repository-create"
               }
             )

    assert %DomainOutboxEvent{
             event_type: "repository.created",
             origin: :fornacast,
             causation_id: "request:create-123",
             correlation_id: "sync:repository-create"
           } = repository_event(repository.id, "repository.created")
  end

  test "API repository update emits in the mutation transaction", %{owner: owner} do
    assert {:ok, repository} =
             ForgeRepos.create_api_repository(owner, owner, %{"name" => "Updated outbox"}, %{})

    assert {:ok, updated} =
             ForgeRepos.update_api_repository(
               owner,
               repository,
               %{"description" => "synchronized description"},
               %{causation_id: "request:update-123"}
             )

    assert %DomainOutboxEvent{
             event_type: "repository.updated",
             origin: :fornacast,
             causation_id: "request:update-123",
             payload: %{
               "repository_id" => repository_id,
               "slug" => "updated-outbox"
             }
           } = repository_event(updated.id, "repository.updated")

    assert repository_id == updated.id
  end

  test "a failed repository mutation leaves no outbox event", %{owner: owner} do
    assert {:error, _reason} =
             ForgeRepos.create_api_repository(
               owner,
               owner,
               %{"name" => "Rolled back outbox"},
               %{ip_address: {:invalid, :address}}
             )

    refute ForgeRepos.get_repository(owner.username, "rolled-back-outbox")
    assert Repo.aggregate(DomainOutboxEvent, :count, :id) == 0
  end

  defp repository_event(repository_id, event_type) do
    Repo.one(
      from event in DomainOutboxEvent,
        where:
          event.aggregate_type == "repository" and
            event.aggregate_id == ^Integer.to_string(repository_id) and
            event.event_type == ^event_type
    )
  end
end
