defmodule ForgeImports.Scheduler do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.User

  alias ForgeImports.{ImportAttempt, ImportRun, RepositoryItem}
  alias Fornacast.Repo

  @claimable_item_states [
    :queued,
    :staging_git,
    :git_staged,
    :staging_metadata,
    :ready_to_publish,
    :publishing
  ]

  @spec claimable_discovery_ids(DateTime.t(), pos_integer()) :: [pos_integer()]
  def claimable_discovery_ids(%DateTime{} = now, limit)
      when is_integer(limit) and limit in 1..100 do
    now = DateTime.truncate(now, :second)

    ImportRun
    |> where(
      [run],
      run.state == :discovering and
        (is_nil(run.next_attempt_at) or run.next_attempt_at <= ^now) and
        (is_nil(run.lease_expires_at) or run.lease_expires_at <= ^now)
    )
    |> order_by([run], asc: run.id)
    |> limit(^limit)
    |> select([run], run.id)
    |> Repo.all()
  end

  @spec claimable_item_ids(DateTime.t(), pos_integer()) :: [pos_integer()]
  def claimable_item_ids(%DateTime{} = now, limit)
      when is_integer(limit) and limit in 1..100 do
    now = DateTime.truncate(now, :second)

    staging_branch =
      dynamic(
        [item, run, _attempt, actor],
        ((item.state == :queued and is_nil(item.hidden_repository_id) and
            is_nil(item.staged_storage_path)) or
           (item.state == :staging_git and not is_nil(item.hidden_repository_id) and
              not is_nil(item.staged_storage_path)) or
           (item.state in [:git_staged, :staging_metadata] and
              not is_nil(item.hidden_repository_id) and not is_nil(item.staged_storage_path))) and
          is_nil(item.cleanup_state) and
          ((run.state == :running and actor.state == :active and
              (is_nil(run.lease_expires_at) or run.lease_expires_at <= ^now)) or
             (item.state == :staging_git and
                run.state in [
                  :running,
                  :cancel_requested,
                  :canceled,
                  :failed,
                  :completed,
                  :completed_with_warnings
                ] and (run.state != :running or actor.state != :active)))
      )

    fresh_publication_branch =
      dynamic(
        [item, run, _attempt, actor],
        item.state == :ready_to_publish and is_nil(item.cleanup_state) and
          run.state == :running and actor.state == :active and
          (is_nil(run.lease_expires_at) or run.lease_expires_at <= ^now)
      )

    recovery_publication_branch =
      dynamic(
        [item, run, _attempt, _actor],
        item.state == :publishing and
          run.state in [:running, :cancel_requested, :awaiting_credential]
      )

    eligible_branch =
      dynamic(
        [item, run, attempt, actor],
        ^staging_branch or ^fresh_publication_branch or ^recovery_publication_branch
      )

    RepositoryItem
    |> join(:inner, [item], run in ImportRun, on: run.id == item.import_run_id)
    |> join(:inner, [item, _run], attempt in ImportAttempt,
      on:
        attempt.repository_item_id == item.id and
          attempt.attempt_number == item.attempt_count
    )
    |> join(:inner, [_item, run, _attempt], actor in User, on: actor.id == run.actor_user_id)
    |> where(
      [item, run, attempt, actor],
      item.selected == true and
        item.state in ^@claimable_item_states and
        item.attempt_count > 0 and
        (is_nil(item.next_attempt_at) or item.next_attempt_at <= ^now) and
        (is_nil(item.lease_expires_at) or item.lease_expires_at <= ^now) and
        attempt.state == :running and actor.kind == :user
    )
    |> where(^eligible_branch)
    |> order_by([item, _run, _attempt, _actor],
      desc: item.state == :publishing,
      desc: is_nil(item.next_attempt_at),
      asc: item.next_attempt_at,
      asc: item.id
    )
    |> limit(^limit)
    |> select([item, _run, _attempt, _actor], item.id)
    |> Repo.all()
  end

  @spec claimable?(ImportRun.t() | RepositoryItem.t(), DateTime.t()) :: boolean()
  def claimable?(%ImportRun{} = run, %DateTime{} = now) do
    run.id in claimable_discovery_ids(now, 100)
  end

  def claimable?(%RepositoryItem{} = item, %DateTime{} = now) do
    item.id in claimable_item_ids(now, 100)
  end

  def claimable?(_record, _now), do: false
end
