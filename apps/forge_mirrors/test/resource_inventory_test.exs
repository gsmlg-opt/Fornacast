defmodule ForgeMirrors.ResourceInventoryTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.{MirrorResourceState, ResourceInventory}
  alias Fornacast.Repo

  @observed_at ~U[2026-09-01 00:00:00Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture()
    binding = repository_mirror_fixture(organization)
    %{organization: organization, binding: binding}
  end

  test "keyset pages are bounded, replayable and pinned before later insertions", ctx do
    mappings = for number <- 1..205, do: mapping(ctx, %{github_number: number})
    assert {:ok, first} = ResourceInventory.page(ctx.binding.id, :issue)
    assert Enum.map(first.observations, & &1.github_number) == Enum.to_list(1..100)

    assert first.next_cursor == %{
             "repository_mirror_id" => ctx.binding.id,
             "resource_kind" => "issue",
             "after_id" => Enum.at(mappings, 99).id,
             "through_id" => List.last(mappings).id
           }

    mapping(ctx, %{github_number: 999})

    assert {:ok, second} = ResourceInventory.page(ctx.binding.id, :issue, first.next_cursor)
    assert Enum.map(second.observations, & &1.github_number) == Enum.to_list(101..200)
    assert second.next_cursor["through_id"] == first.next_cursor["through_id"]
    assert {:ok, ^second} = ResourceInventory.page(ctx.binding.id, :issue, first.next_cursor)
    assert {:ok, third} = ResourceInventory.page(ctx.binding.id, :issue, second.next_cursor)
    assert Enum.map(third.observations, & &1.github_number) == Enum.to_list(201..205)
    assert third.next_cursor == nil
  end

  test "canonical PR issue companions are not ordinary issue reconciliation candidates", ctx do
    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: ctx.binding.repository_id,
        number: 7,
        kind: :pull_request,
        title: "PR",
        author_user_id: user_fixture()
      })

    mapping(ctx, %{local_resource_id: issue.id, github_number: 7})
    ordinary = mapping(ctx)

    assert {:ok, %{observations: [observation], next_cursor: nil}} =
             ResourceInventory.page(ctx.binding.id, :issue)

    assert observation.github_object_id == ordinary.github_object_id
  end

  test "pull reconciliation pages bound identities and pins its high water mark",
       ctx do
    attrs = %{
      resource_kind: :pull,
      local_resource_type: "ForgePulls.PullRequest",
      state: :unsupported
    }

    first = mapping(ctx, Map.put(attrs, :github_number, 1))
    second = mapping(ctx, Map.put(attrs, :github_number, 2))
    confirmed = mapping(ctx, Map.merge(attrs, %{state: :confirmed, github_number: 4}))
    mapping(ctx, %{attrs | state: :conflicted})
    assert {:ok, page} = ResourceInventory.page(ctx.binding.id, :pull, nil, 1)
    assert [observation] = page.observations
    assert observation.github_object_id == first.github_object_id
    mapping(ctx, Map.put(attrs, :github_number, 3))

    assert {:ok, %{observations: [last], next_cursor: final_cursor}} =
             ResourceInventory.page(ctx.binding.id, :pull, page.next_cursor, 1)

    assert last.github_object_id == second.github_object_id

    assert {:ok, %{observations: [last], next_cursor: nil}} =
             ResourceInventory.page(ctx.binding.id, :pull, final_cursor, 1)

    assert last.github_object_id == confirmed.github_object_id

    assert {:error, :invalid_argument} =
             ResourceInventory.page(ctx.binding.id, :issue, page.next_cursor)
  end

  test "cursor scope and limits are validated before enumeration", ctx do
    mapping(ctx)
    mapping(ctx)
    {:ok, page} = ResourceInventory.page(ctx.binding.id, :issue, nil, 1)
    other = repository_mirror_fixture(ctx.organization)

    assert {:error, :invalid_argument} =
             ResourceInventory.page(other.id, :issue, page.next_cursor)

    assert {:error, :invalid_argument} =
             ResourceInventory.page(ctx.binding.id, :issue_comment, page.next_cursor)

    for cursor <- [
          %{},
          Map.put(page.next_cursor, "extra", true),
          %{page.next_cursor | "after_id" => -1},
          %{page.next_cursor | "after_id" => page.next_cursor["through_id"] + 1},
          %{page.next_cursor | "through_id" => 9_223_372_036_854_775_808}
        ] do
      assert {:error, :invalid_argument} = ResourceInventory.page(ctx.binding.id, :issue, cursor)
    end

    for limit <- [0, 101, -1, "100"],
        do:
          assert(
            {:error, :invalid_argument} =
              ResourceInventory.page(ctx.binding.id, :issue, nil, limit)
          )

    assert {:error, :invalid_argument} = ResourceInventory.page(ctx.binding.id, :label)
    assert {:error, :invalid_argument} = ResourceInventory.page(9_223_372_036_854_775_808, :issue)

    assert {:error, :unbound_repository} =
             ResourceInventory.page(9_223_372_036_854_775_807, :issue)
  end

  test "only provider-bound live mappings in the requested repository and kind are observed",
       ctx do
    confirmed = mapping(ctx)

    pending =
      mapping(ctx, %{
        state: :pending,
        local_resource_id: nil,
        local_resource_type: nil,
        confirmed_remote_updated_at: nil
      })

    mapping(ctx, %{state: :pending, github_object_id: nil})
    for state <- [:deleted, :unsupported, :conflicted], do: mapping(ctx, %{state: state})
    other = repository_mirror_fixture(ctx.organization)
    mapping(%{ctx | binding: other})

    comment =
      mapping(ctx, %{
        resource_kind: :issue_comment,
        local_resource_type: "ForgeIssues.Comment",
        github_number: 7
      })

    assert {:ok, %{observations: [first, second], next_cursor: nil}} =
             ResourceInventory.page(ctx.binding.id, :issue)

    assert first.github_object_id == confirmed.github_object_id
    assert first.remote_updated_at == @observed_at
    assert second.github_object_id == pending.github_object_id
    assert second.remote_updated_at == ~U[1970-01-01 00:00:00Z]

    assert {:ok, %{observations: [observation], next_cursor: nil}} =
             ResourceInventory.page(ctx.binding.id, :issue_comment)

    assert observation.github_object_id == comment.github_object_id
    assert observation.github_number == 7
    assert observation.github_issue_id == nil
  end

  test "an invalid routed mapping fails the page instead of silently omitting it", ctx do
    invalid = mapping(ctx, %{github_number: nil})
    assert {:error, :invalid_mapping} = ResourceInventory.page(ctx.binding.id, :issue)

    invalid
    |> Ecto.Changeset.change(github_number: 7, local_resource_type: "ForgeIssues.Comment")
    |> Repo.update!()

    assert {:error, :invalid_mapping} = ResourceInventory.page(ctx.binding.id, :issue)
  end

  test "confirmed mappings require complete immutable identities", ctx do
    row = mapping(ctx, %{github_object_id: nil})
    assert {:error, :invalid_mapping} = ResourceInventory.page(ctx.binding.id, :issue)
    row |> Ecto.Changeset.change(github_object_id: 9999, local_resource_id: nil) |> Repo.update!()
    assert {:error, :invalid_mapping} = ResourceInventory.page(ctx.binding.id, :issue)
  end

  test "observations contain only bounded routing metadata, never baseline content", ctx do
    mapping(ctx, %{confirmed_snapshot: %{"body" => String.duplicate("private", 10_000)}})
    assert {:ok, %{observations: [observation]}} = ResourceInventory.page(ctx.binding.id, :issue)

    assert Enum.sort(Map.keys(observation)) == [
             :github_issue_id,
             :github_number,
             :github_object_id,
             :remote_updated_at
           ]
  end

  test "removing a previously emitted mapping does not shift the next page", ctx do
    first_mapping = mapping(ctx, %{github_number: 1})
    second_mapping = mapping(ctx, %{github_number: 2})
    {:ok, first} = ResourceInventory.page(ctx.binding.id, :issue, nil, 1)
    Repo.delete!(first_mapping)

    assert {:ok, %{observations: [observation], next_cursor: nil}} =
             ResourceInventory.page(ctx.binding.id, :issue, first.next_cursor, 1)

    assert observation.github_object_id == second_mapping.github_object_id
  end

  test "an empty inventory completes without a synthetic continuation", ctx do
    assert {:ok, %{observations: [], next_cursor: nil}} =
             ResourceInventory.page(ctx.binding.id, :issue)

    assert {:ok, %{observations: [], next_cursor: nil}} =
             ResourceInventory.page(ctx.binding.id, :issue_comment)
  end

  defp mapping(ctx, attrs \\ %{}) do
    unique = System.unique_integer([:positive, :monotonic]) + 1_000_000

    defaults = %{
      repository_mirror_id: ctx.binding.id,
      resource_kind: :issue,
      local_resource_type: "ForgeIssues.Issue",
      local_resource_id: unique,
      github_object_id: unique,
      github_number: unique,
      confirmed_local_version: 1,
      confirmed_remote_updated_at: @observed_at,
      state: :confirmed
    }

    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
