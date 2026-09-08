defmodule ForgePulls.PullSyncModelTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias ForgePulls.PullRequest

  defp attrs do
    %{
      issue_id: 1,
      repository_id: 2,
      head_ref: "refs/heads/feature",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40),
      inserted_at: ~U[2026-09-07 00:00:00Z],
      updated_at: ~U[2026-09-07 00:00:00Z]
    }
  end

  defp issue, do: %ForgeIssues.Issue{id: 1, repository_id: 2, kind: :pull_request}
  defp repository, do: %ForgeRepos.Repository{id: 2}
  defp new_pull, do: %PullRequest{issue_id: 1, repository_id: 2}

  test "local creation defaults to its own head repository and ignores submitted identity" do
    changeset =
      PullRequest.create_changeset(%PullRequest{}, Map.put(attrs(), :head_repository_id, 99))

    assert changeset.valid?
    pull = Changeset.apply_changes(changeset)
    assert Map.get(pull, :head_repository_id) == 2
    assert Map.get(pull, :draft) == false
  end

  test "existing import contract defaults to same repository and accepts draft" do
    changeset =
      PullRequest.import_changeset(
        new_pull(),
        Map.put(attrs(), :draft, true),
        issue(),
        repository()
      )

    assert changeset.valid?
    pull = Changeset.apply_changes(changeset)
    assert Map.get(pull, :head_repository_id) == 2
    assert Map.get(pull, :draft) == true
  end

  test "trusted import distinguishes represented and external heads from attrs" do
    for head_id <- [3, nil] do
      changeset =
        PullRequest.import_changeset(
          new_pull(),
          Map.put(attrs(), :head_repository_id, 99),
          issue(),
          repository(),
          head_id
        )

      assert changeset.valid?
      assert Map.get(Changeset.apply_changes(changeset), :head_repository_id) == head_id
    end
  end

  test "loaded head identity cannot be changed through update or trusted reimport" do
    pull = struct(PullRequest, Map.merge(attrs(), %{id: 1, head_repository_id: 3}))

    assert {"is immutable", _} =
             PullRequest.update_changeset(pull, %{head_repository_id: 4}).errors[
               :head_repository_id
             ]

    assert {"is immutable", _} =
             PullRequest.update_changeset(pull, %{"head_repository_id" => nil}).errors[
               :head_repository_id
             ]

    assert {"is immutable", _} =
             PullRequest.import_changeset(pull, attrs(), issue(), repository(), 4).errors[
               :head_repository_id
             ]

    assert PullRequest.import_changeset(pull, attrs(), issue(), repository(), 3).valid?
  end

  test "draft is a non-null boolean and trusted head IDs are positive integers" do
    for draft <- [nil, "invalid"] do
      refute PullRequest.import_changeset(
               new_pull(),
               Map.put(attrs(), :draft, draft),
               issue(),
               repository()
             ).valid?
    end

    for head_id <- [0, -1, "3", 9_223_372_036_854_775_808] do
      refute PullRequest.import_changeset(new_pull(), attrs(), issue(), repository(), head_id).valid?
    end
  end

  test "same branch name is allowed across represented or external heads but not the same repository" do
    same_name = %{attrs() | head_ref: "refs/heads/main"}

    for head_id <- [3, nil] do
      assert PullRequest.import_changeset(new_pull(), same_name, issue(), repository(), head_id).valid?
    end

    refute PullRequest.import_changeset(new_pull(), same_name, issue(), repository(), 2).valid?
  end
end
