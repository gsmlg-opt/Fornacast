defmodule ForgeIssues.ExternalAuthorCapabilitiesTest do
  use ExUnit.Case, async: false
  import ForgeIssues.Fixtures
  alias Ecto.Multi
  alias ForgeRepos.Collaborator
  alias Fornacast.Repo

  setup do
    reset_database!()
    owner = user_fixture("external-owner-#{System.unique_integer([:positive])}")
    repository = repository_fixture(owner)
    writer = user_fixture("external-writer-#{System.unique_integer([:positive])}")
    reader = user_fixture("external-reader-#{System.unique_integer([:positive])}")
    grant(repository, writer, :write)
    grant(repository, reader, :read)

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{"id" => 4567, "login" => reader.username},
        ~U[2026-09-01 00:00:00Z]
      )

    {:ok, %{issue: issue}} =
      Multi.new()
      |> ForgeIssues.import_identity_multi(:issue, repository, identity, :issue, %{
        number: 7,
        title: "Imported",
        body: "Source",
        state: :open,
        inserted_at: ~U[2026-09-01 00:00:00Z],
        updated_at: ~U[2026-09-01 00:00:00Z]
      })
      |> Repo.transaction()

    %{
      owner: owner,
      writer: writer,
      reader: reader,
      repository: repository,
      identity: identity,
      issue: issue
    }
  end

  test "owners and write collaborators can edit unlinked external issues without claiming authorship",
       ctx do
    for actor <- [ctx.owner, ctx.writer] do
      assert {:ok, changed} =
               ForgeIssues.update(
                 actor,
                 ctx.owner.username,
                 ctx.repository.slug,
                 ctx.issue.number,
                 %{
                   title: "Maintained",
                   state: :closed,
                   state_reason: :completed,
                   labels: ["bug"]
                 },
                 %{}
               )

      assert changed.title == "Maintained"
      assert changed.state == :closed
      assert [%{name: "bug"}] = changed.labels
      assert changed.author_github_identity_id == ctx.identity.id
      assert changed.author_user_id == nil
    end
  end

  test "owners and write collaborators can update and delete unlinked external comments", ctx do
    for actor <- [ctx.owner, ctx.writer] do
      comment = comment(ctx)

      assert {:ok, changed} =
               ForgeIssues.update_comment(
                 actor,
                 ctx.owner.username,
                 ctx.repository.slug,
                 comment.id,
                 %{body: "Maintained"},
                 %{}
               )

      assert changed.body == "Maintained"
      assert changed.author_github_identity_id == ctx.identity.id

      assert :ok =
               ForgeIssues.delete_comment(
                 actor,
                 ctx.owner.username,
                 ctx.repository.slug,
                 comment.id,
                 %{}
               )
    end
  end

  test "rendered issue and comment capabilities agree with independent writer authority", ctx do
    comment = comment(ctx)

    for actor <- [ctx.owner, ctx.writer] do
      assert {:ok,
              %{capabilities: %{can_edit: true, can_close: true, can_manage_relationships: true}}} =
               ForgeIssues.get(actor, ctx.owner.username, ctx.repository.slug, ctx.issue.number)

      assert {:ok, %{capabilities: %{can_edit: true, can_delete: true}}} =
               ForgeIssues.get_comment(actor, ctx.owner.username, ctx.repository.slug, comment.id)
    end
  end

  test "a matching login grants no author capability and linking grants only existing reader-author rights",
       ctx do
    comment = comment(ctx)

    assert {:error, :forbidden} =
             ForgeIssues.update(
               ctx.reader,
               ctx.owner.username,
               ctx.repository.slug,
               ctx.issue.number,
               %{title: "No link"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgeIssues.update_comment(
               ctx.reader,
               ctx.owner.username,
               ctx.repository.slug,
               comment.id,
               %{body: "No link"},
               %{}
             )

    assert {:ok, %{capabilities: %{can_edit: false, can_manage_relationships: false}}} =
             ForgeIssues.get(
               ctx.reader,
               ctx.owner.username,
               ctx.repository.slug,
               ctx.issue.number
             )

    assert {:ok, linked} = ForgeAccounts.link_github_identity(ctx.reader, ctx.identity)

    assert {:ok, updated} =
             ForgeIssues.update(
               ctx.reader,
               ctx.owner.username,
               ctx.repository.slug,
               ctx.issue.number,
               %{title: "Author edit", labels: ["bug"], assignees: [ctx.reader.username]},
               %{}
             )

    assert updated.title == "Author edit"
    assert updated.labels == []
    assert updated.assignees == []

    assert {:ok, _} =
             ForgeIssues.update_comment(
               ctx.reader,
               ctx.owner.username,
               ctx.repository.slug,
               comment.id,
               %{body: "Author edit"},
               %{}
             )

    assert {:ok, _} = ForgeAccounts.unlink_github_identity(ctx.reader, linked)

    assert {:error, :forbidden} =
             ForgeIssues.update(
               ctx.reader,
               ctx.owner.username,
               ctx.repository.slug,
               ctx.issue.number,
               %{title: "Unlinked"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgeIssues.delete_comment(
               ctx.reader,
               ctx.owner.username,
               ctx.repository.slug,
               comment.id,
               %{}
             )

    assert {:ok, _} =
             ForgeIssues.update(
               ctx.writer,
               ctx.owner.username,
               ctx.repository.slug,
               ctx.issue.number,
               %{title: "Still a writer"},
               %{}
             )
  end

  test "linked identity does not grant private repository access", ctx do
    outsider = user_fixture("external-outsider-#{System.unique_integer([:positive])}")
    assert {:ok, _} = ForgeAccounts.link_github_identity(outsider, ctx.identity)
    comment = comment(ctx)

    assert {:error, :not_found} =
             ForgeIssues.get(outsider, ctx.owner.username, ctx.repository.slug, ctx.issue.number)

    assert {:error, :not_found} =
             ForgeIssues.update(
               outsider,
               ctx.owner.username,
               ctx.repository.slug,
               ctx.issue.number,
               %{title: "Not authorized"},
               %{}
             )

    assert {:error, :not_found} =
             ForgeIssues.update_comment(
               outsider,
               ctx.owner.username,
               ctx.repository.slug,
               comment.id,
               %{body: "Not authorized"},
               %{}
             )
  end

  defp comment(ctx) do
    {:ok, %{comment: comment}} =
      Multi.new()
      |> ForgeIssues.import_comment_multi(:comment, ctx.issue, ctx.identity, %{
        body: "Imported",
        inserted_at: ~U[2026-09-01 00:00:00Z],
        updated_at: ~U[2026-09-01 00:00:00Z]
      })
      |> Repo.transaction()

    comment
  end

  defp grant(repository, actor, role),
    do:
      %Collaborator{}
      |> Collaborator.changeset(%{repository_id: repository.id, user_id: actor.id, role: role})
      |> Repo.insert!()
end
