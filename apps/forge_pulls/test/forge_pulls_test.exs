defmodule ForgePullsTest do
  use ExUnit.Case, async: true

  alias ForgePulls.{MergeOperation, PullRequest}

  test "pull requests require distinct canonical branch refs and immutable repository identity" do
    pull = %PullRequest{repository_id: 10}

    changeset =
      PullRequest.create_changeset(pull, %{
        issue_id: 1,
        repository_id: 11,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    assert %{repository_id: ["is immutable"]} = errors_on(changeset)

    invalid_ref =
      PullRequest.create_changeset(%PullRequest{repository_id: 10}, %{
        issue_id: 1,
        head_ref: "feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    assert %{head_ref: ["must be a canonical branch ref"]} = errors_on(invalid_ref)

    equal_refs =
      PullRequest.create_changeset(%PullRequest{repository_id: 10}, %{
        issue_id: 1,
        head_ref: "refs/heads/main",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    assert %{base_ref: ["must differ from head ref"]} = errors_on(equal_refs)
  end

  test "pull requests accept valid Unicode nested branches and reject Git-invalid ref forms" do
    valid_refs = ["refs/heads/feature/東京", "refs/heads/release/v1"]

    for ref <- valid_refs do
      changeset =
        PullRequest.create_changeset(%PullRequest{repository_id: 10}, valid_pull_attrs(%{head_ref: ref}))

      refute Map.has_key?(errors_on(changeset), :head_ref)
    end

    invalid_refs = [
      "refs/heads/..",
      "refs/heads/feature..next",
      "refs/heads/feature name",
      "refs/heads/feature\nnext",
      "refs/heads/feature~next",
      "refs/heads/feature^next",
      "refs/heads/feature:next",
      "refs/heads/feature?next",
      "refs/heads/feature*next",
      "refs/heads/feature[next",
      "refs/heads/feature\\next",
      "refs/heads/feature@{next",
      "refs/heads//feature",
      "refs/heads/feature/",
      "refs/heads/./feature",
      "refs/heads/feature/../next",
      "refs/heads/feature.",
      "refs/heads/feature.lock"
    ]

    for ref <- invalid_refs do
      changeset =
        PullRequest.create_changeset(%PullRequest{repository_id: 10}, valid_pull_attrs(%{head_ref: ref}))

      assert %{head_ref: ["must be a canonical branch ref"]} = errors_on(changeset)
    end
  end

  test "merge operations only move through durable next states and redact failure reasons" do
    operation = %MergeOperation{state: :prepared, failure_reason: "private git error"}

    assert %{state: ["is not a valid transition"]} =
             operation |> MergeOperation.transition_changeset(:completed) |> errors_on()

    assert %{state: :merge_written} =
             operation |> MergeOperation.transition_changeset(:merge_written) |> Ecto.Changeset.apply_changes()

    assert %{failure_reason: nil} = MergeOperation.public(operation)
  end

  test "merge operation preparation only accepts the prepared state" do
    attrs = %{
      pull_request_id: 1,
      repository_id: 1,
      request_id: "request-1",
      base_ref: "refs/heads/main",
      head_ref: "refs/heads/feature",
      expected_base_oid: String.duplicate("a", 40),
      expected_head_oid: String.duplicate("b", 40),
      state: :merge_written
    }

    assert %{state: ["is invalid"]} =
             %MergeOperation{} |> MergeOperation.prepare_changeset(attrs) |> errors_on()
  end

  test "dedicated merge transitions accept only their immediate next state" do
    prepared = %MergeOperation{state: :prepared}
    merge_written = %MergeOperation{state: :merge_written}
    ref_advanced = %MergeOperation{state: :ref_advanced}

    assert %{state: :merge_written} =
             prepared |> MergeOperation.merge_written_changeset() |> Ecto.Changeset.apply_changes()

    assert %{state: :ref_advanced} =
             merge_written
             |> MergeOperation.ref_advanced_changeset()
             |> Ecto.Changeset.apply_changes()

    assert %{state: :completed} =
             ref_advanced |> MergeOperation.completed_changeset() |> Ecto.Changeset.apply_changes()

    failed = MergeOperation.failed_changeset(prepared, "failure\n\u0000reason")
    assert %{state: :failed, failure_reason: "failure reason"} = Ecto.Changeset.apply_changes(failed)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        replacement = if is_list(value), do: inspect(value), else: to_string(value)
        String.replace(acc, "%{#{key}}", replacement)
      end)
    end)
  end

  defp valid_pull_attrs(overrides) do
    Map.merge(
      %{
        issue_id: 1,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      },
      overrides
    )
  end
end
