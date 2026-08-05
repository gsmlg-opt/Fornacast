defmodule ForgePullsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgePulls.{MergeOperation, PullRequest}
  alias Fornacast.Repo

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
        PullRequest.create_changeset(
          %PullRequest{repository_id: 10},
          valid_pull_attrs(%{head_ref: ref})
        )

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
        PullRequest.create_changeset(
          %PullRequest{repository_id: 10},
          valid_pull_attrs(%{head_ref: ref})
        )

      assert %{head_ref: ["must be a canonical branch ref"]} = errors_on(changeset)
    end
  end

  test "merge operations only move through durable next states and redact failure reasons" do
    operation = %MergeOperation{state: :prepared, failure_reason: "private git error"}

    assert %{state: ["is not a valid transition"]} =
             operation |> MergeOperation.transition_changeset(:completed) |> errors_on()

    assert %{state: :merge_written} =
             operation
             |> MergeOperation.transition_changeset(:merge_written)
             |> Ecto.Changeset.apply_changes()

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
             prepared
             |> MergeOperation.merge_written_changeset()
             |> Ecto.Changeset.apply_changes()

    assert %{state: :ref_advanced} =
             merge_written
             |> MergeOperation.ref_advanced_changeset()
             |> Ecto.Changeset.apply_changes()

    assert %{state: :completed} =
             ref_advanced
             |> MergeOperation.completed_changeset()
             |> Ecto.Changeset.apply_changes()

    failed = MergeOperation.failed_changeset(prepared, "failure\n\u0000reason")

    assert %{state: :failed, failure_reason: "failure reason"} =
             Ecto.Changeset.apply_changes(failed)

    for {operation, target} <- [
          {prepared, :ref_advanced},
          {prepared, :completed},
          {merge_written, :prepared},
          {merge_written, :completed},
          {ref_advanced, :prepared},
          {%MergeOperation{state: :completed}, :failed},
          {%MergeOperation{state: :failed}, :prepared}
        ] do
      assert %{state: ["is not a valid transition"]} =
               operation |> MergeOperation.transition_changeset(target) |> errors_on()
    end
  end

  test "the active adapter migration has every pull durable column" do
    expected_pull_columns = ~w(
      id issue_id repository_id head_ref base_ref head_sha base_sha mergeable mergeable_state
      merged_at merged_by_user_id merge_commit_sha inserted_at updated_at
    )

    expected_operation_columns = ~w(
      id pull_request_id repository_id actor_user_id request_id base_ref head_ref expected_base_oid
      expected_head_oid merge_oid state lease_owner lease_expires_at failure_reason lock_version
      inserted_at updated_at
    )

    assert expected_pull_columns -- column_names("pull_requests") == []
    assert expected_operation_columns -- column_names("pull_merge_operations") == []
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

  defp column_names(table) do
    case Application.fetch_env!(:fornacast, :database_adapter) do
      value when value in ["turso", "libsql"] ->
        %{rows: rows} = SQL.query!(Repo, "select name from pragma_table_info(?)", [table])
        Enum.map(rows, &hd/1)

      value when value in ["postgres", "postgresql"] ->
        %{rows: rows} =
          SQL.query!(
            Repo,
            "select column_name from information_schema.columns where table_schema = 'public' and table_name = $1",
            [table]
          )

        Enum.map(rows, &hd/1)
    end
  end
end
