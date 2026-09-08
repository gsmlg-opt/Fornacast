defmodule ForgePulls.SyncOutboxTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Multi
  alias Fornacast.{DomainOutboxEvent, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "pull-events-#{suffix}",
        email: "pull-events-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{name: "events", slug: "events", visibility: :private})

    path = ForgeRepos.absolute_storage_path(repository)

    {tree, 0} =
      System.cmd("git", ["--git-dir=#{path}", "hash-object", "-t", "tree", "-w", "/dev/null"])

    {base, 0} =
      System.cmd("git", ["--git-dir=#{path}", "commit-tree", String.trim(tree), "-m", "base"])

    {head, 0} =
      System.cmd("git", [
        "--git-dir=#{path}",
        "commit-tree",
        String.trim(tree),
        "-p",
        String.trim(base),
        "-m",
        "head"
      ])

    for {ref, oid} <- [{"main", base}, {"other", base}, {"feature", head}] do
      {_, 0} =
        System.cmd("git", [
          "--git-dir=#{path}",
          "update-ref",
          "refs/heads/#{ref}",
          String.trim(oid)
        ])
    end

    %{actor: actor, repository: repository, base: String.trim(base), head: String.trim(head)}
  end

  test "local creation emits exactly one canonical issue event and ignores spoofed provenance",
       ctx do
    pull = create_pull(ctx)
    assert [event] = events(ctx)
    assert event.event_type == "issue.created"
    assert event.aggregate_type == "issue"
    assert event.aggregate_id == to_string(pull.issue_id)
    assert event.origin == :fornacast
    assert event.causation_id == nil
    assert pull.draft

    assert event.payload == %{
             "repository_id" => ctx.repository.id,
             "issue_id" => pull.issue_id,
             "issue_number" => pull.issue.number,
             "issue_kind" => "pull_request",
             "sync_version" => pull.issue.sync_version
           }
  end

  test "each local metadata or base update emits one event at the new canonical version", ctx do
    pull = create_pull(ctx)

    Enum.reduce(
      [%{title: "Edited"}, %{body: "Body"}, %{base: "other"}, %{draft: false}, %{state: :closed}],
      pull,
      fn attrs, pull ->
        before = events(ctx)

        assert {:ok, updated} =
                 ForgePulls.update_pull_request(
                   ctx.repository,
                   pull,
                   ctx.actor,
                   Map.merge(attrs, %{origin: :github, causation_id: "spoofed"}),
                   %{origin: :github}
                 )

        assert length(events(ctx)) == length(before) + 1
        event = List.last(events(ctx))
        assert event.event_type == "issue.updated"
        assert event.origin == :fornacast
        assert event.causation_id == nil
        assert event.payload["sync_version"] == updated.issue.sync_version
        assert updated.issue.sync_version == pull.issue.sync_version + 1
        if Map.has_key?(attrs, :draft), do: assert(updated.draft == attrs.draft)
        refute Map.has_key?(event.payload, "body")
        updated
      end
    )
  end

  test "downstream creation rollback removes canonical identity extension and event", ctx do
    assert {:error, :later, :rollback, _} =
             ForgePulls.Mutations.create_multi(
               ctx.actor,
               ctx.repository,
               %{title: "Rollback"},
               %{
                 head_ref: "refs/heads/feature",
                 base_ref: "refs/heads/main",
                 head_sha: ctx.head,
                 base_sha: ctx.base
               },
               %{}
             )
             |> Multi.error(:later, :rollback)
             |> Repo.transaction()

    assert events(ctx) == []
    refute Repo.exists?(from i in ForgeIssues.Issue, where: i.repository_id == ^ctx.repository.id)

    refute Repo.exists?(
             from p in ForgePulls.PullRequest, where: p.repository_id == ^ctx.repository.id
           )
  end

  test "enclosing update rollback preserves issue version and event count", ctx do
    pull = create_pull(ctx)
    before = events(ctx)

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        ForgePulls.update_pull_request(
                          ctx.repository,
                          pull,
                          ctx.actor,
                          %{title: "Rollback"},
                          %{}
                        )

               Repo.rollback(:rollback)
             end)

    assert events(ctx) == before
    assert Repo.get!(ForgeIssues.Issue, pull.issue_id).sync_version == pull.issue.sync_version
  end

  test "local draft input rejects non-booleans without writing an event", ctx do
    assert {:error, {:validation, _}} =
             ForgePulls.create_pull_request(
               ctx.repository,
               ctx.actor,
               %{title: "Bad", head: "feature", base: "main", draft: "true"},
               %{}
             )

    assert events(ctx) == []
    pull = create_pull(ctx)
    before = events(ctx)

    assert {:error, {:validation, _}} =
             ForgePulls.update_pull_request(ctx.repository, pull, ctx.actor, %{draft: nil}, %{})

    assert events(ctx) == before
  end

  defp create_pull(ctx) do
    {:ok, pull} =
      ForgePulls.create_pull_request(
        ctx.repository,
        ctx.actor,
        %{
          title: "Local",
          head: "feature",
          base: "main",
          draft: true,
          origin: :github,
          causation_id: "spoofed"
        },
        %{origin: :github}
      )

    pull
  end

  defp events(ctx),
    do:
      Repo.all(
        from e in DomainOutboxEvent,
          where: e.aggregate_type == "issue" and e.payload["repository_id"] == ^ctx.repository.id,
          order_by: e.id
      )
end
