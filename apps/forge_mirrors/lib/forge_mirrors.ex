defmodule ForgeMirrors do
  @moduledoc """
  Provider-neutral durable organization mirror policy and operation scheduler.

  This context persists intent and confirmed state only. Provider calls and
  domain-specific synchronization engines live in later delivery slices.
  """

  import Ecto.Query

  alias Fornacast.{DomainOutboxEvent, Repo}

  alias ForgeMirrors.{
    MirrorConflict,
    MirrorOperation,
    OrganizationMirror,
    RepositoryMirror
  }

  @max_claim_batch 100

  @type provider :: :github
  @type direction :: :inbound | :outbound
  @type resource_kind :: :organization | :repository | :git | :lfs | :issue | :pull | :release

  @spec create_organization_mirror(map()) ::
          {:ok, OrganizationMirror.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def create_organization_mirror(attrs) when is_map(attrs) do
    changeset = OrganizationMirror.create_changeset(%OrganizationMirror{}, attrs)

    if changeset.valid? do
      organization_id = Ecto.Changeset.get_field(changeset, :organization_id)

      case ForgeAccounts.get_organization(organization_id) do
        %ForgeAccounts.Organization{} -> Repo.insert(changeset)
        nil -> {:error, :not_found}
      end
    else
      {:error, changeset}
    end
  end

  def create_organization_mirror(_attrs),
    do: invalid_changeset(%OrganizationMirror{})

  @spec get_organization_mirror(pos_integer()) ::
          {:ok, OrganizationMirror.t()} | {:error, :not_found | :invalid_argument}
  def get_organization_mirror(id) when is_integer(id) and id > 0 do
    case Repo.get(OrganizationMirror, id) do
      nil -> {:error, :not_found}
      mirror -> {:ok, mirror}
    end
  end

  def get_organization_mirror(_id), do: {:error, :invalid_argument}

  @spec get_organization_mirror_for_organization(pos_integer(), String.t()) ::
          {:ok, OrganizationMirror.t()} | {:error, :not_found | :invalid_argument}
  def get_organization_mirror_for_organization(organization_id, provider \\ "github")

  def get_organization_mirror_for_organization(organization_id, provider)
      when is_integer(organization_id) and organization_id > 0 and is_binary(provider) do
    query =
      from mirror in OrganizationMirror,
        where:
          mirror.organization_id == ^organization_id and mirror.provider == ^provider and
            mirror.state != :revoked,
        order_by: [desc: mirror.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      mirror -> {:ok, mirror}
    end
  end

  def get_organization_mirror_for_organization(_organization_id, _provider),
    do: {:error, :invalid_argument}

  @spec update_organization_mirror(OrganizationMirror.t(), map()) ::
          {:ok, OrganizationMirror.t()} | {:error, Ecto.Changeset.t() | :stale}
  def update_organization_mirror(%OrganizationMirror{} = mirror, attrs) when is_map(attrs) do
    mirror
    |> OrganizationMirror.update_changeset(attrs)
    |> cas_update()
  end

  def update_organization_mirror(_mirror, _attrs), do: {:error, :stale}

  @spec transition_organization_mirror(OrganizationMirror.t(), atom()) ::
          {:ok, OrganizationMirror.t()}
          | {:error, Ecto.Changeset.t() | :invalid_transition | :stale}
  def transition_organization_mirror(%OrganizationMirror{} = mirror, target) do
    if OrganizationMirror.legal_transition?(mirror.state, target) and
         (mirror.state != :paused or target == :revoked) do
      mirror
      |> OrganizationMirror.transition_changeset(target)
      |> cas_update()
    else
      {:error, :invalid_transition}
    end
  end

  def transition_organization_mirror(_mirror, _target), do: {:error, :invalid_transition}

  @spec pause(OrganizationMirror.t()) ::
          {:ok, OrganizationMirror.t()} | {:error, :invalid_transition | :stale}
  def pause(%OrganizationMirror{state: state} = mirror) do
    if OrganizationMirror.legal_transition?(state, :paused) do
      mirror
      |> OrganizationMirror.transition_changeset(:paused, state)
      |> cas_update()
    else
      {:error, :invalid_transition}
    end
  end

  def pause(_mirror), do: {:error, :invalid_transition}

  @spec resume(OrganizationMirror.t()) ::
          {:ok, OrganizationMirror.t()} | {:error, :invalid_transition | :stale}
  def resume(%OrganizationMirror{state: :paused, resume_state: target} = mirror)
      when not is_nil(target) do
    if OrganizationMirror.legal_transition?(:paused, target) do
      mirror
      |> OrganizationMirror.transition_changeset(target)
      |> cas_update()
    else
      {:error, :invalid_transition}
    end
  end

  def resume(_mirror), do: {:error, :invalid_transition}

  @spec bind_repository(map()) ::
          {:ok, RepositoryMirror.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def bind_repository(attrs) when is_map(attrs) do
    changeset = RepositoryMirror.create_changeset(%RepositoryMirror{}, attrs)

    if changeset.valid? do
      with {:ok, _organization_mirror} <- validate_repository_binding_scope(changeset) do
        Repo.insert(changeset)
      end
    else
      {:error, changeset}
    end
  end

  def bind_repository(_attrs), do: invalid_changeset(%RepositoryMirror{})

  @spec get_repository_mirror(pos_integer()) ::
          {:ok, RepositoryMirror.t()} | {:error, :not_found | :invalid_argument}
  def get_repository_mirror(id) when is_integer(id) and id > 0 do
    case Repo.get(RepositoryMirror, id) do
      nil -> {:error, :not_found}
      mirror -> {:ok, mirror}
    end
  end

  def get_repository_mirror(_id), do: {:error, :invalid_argument}

  @spec update_repository_mirror(RepositoryMirror.t(), map()) ::
          {:ok, RepositoryMirror.t()} | {:error, Ecto.Changeset.t() | :not_found | :stale}
  def update_repository_mirror(%RepositoryMirror{} = mirror, attrs) when is_map(attrs) do
    changeset = RepositoryMirror.update_changeset(mirror, attrs)

    if changeset.valid? do
      with {:ok, _organization_mirror} <- validate_repository_binding_scope(changeset) do
        cas_update(changeset)
      end
    else
      {:error, changeset}
    end
  end

  def update_repository_mirror(_mirror, _attrs), do: {:error, :stale}

  @spec transition_repository_mirror(RepositoryMirror.t(), atom()) ::
          {:ok, RepositoryMirror.t()}
          | {:error, Ecto.Changeset.t() | :invalid_transition | :stale}
  def transition_repository_mirror(%RepositoryMirror{} = mirror, target) do
    if RepositoryMirror.legal_transition?(mirror.state, target) do
      mirror
      |> RepositoryMirror.transition_changeset(target)
      |> cas_update()
    else
      {:error, :invalid_transition}
    end
  end

  def transition_repository_mirror(_mirror, _target), do: {:error, :invalid_transition}

  @spec enqueue_operation(map()) ::
          {:ok, MirrorOperation.t()}
          | {:error, Ecto.Changeset.t() | :dedupe_conflict | :not_found}
  def enqueue_operation(attrs) when is_map(attrs) do
    attrs = canonicalize_cursor(attrs)
    changeset = MirrorOperation.enqueue_changeset(%MirrorOperation{}, attrs)

    if changeset.valid? do
      case validate_operation_scope(changeset) do
        :ok -> insert_idempotent_operation(changeset)
        error -> error
      end
    else
      {:error, changeset}
    end
  end

  def enqueue_operation(_attrs), do: invalid_changeset(%MirrorOperation{})

  @spec claim_operations(String.t(), DateTime.t(), pos_integer(), pos_integer()) ::
          {:ok, [MirrorOperation.t()]} | {:error, :invalid_argument | :unavailable}
  def claim_operations(owner, %DateTime{} = now, lease_seconds, limit)
      when is_binary(owner) and is_integer(lease_seconds) and lease_seconds > 0 and
             is_integer(limit) and limit in 1..@max_claim_batch do
    with :ok <- validate_owner(owner), :ok <- validate_utc(now) do
      now = DateTime.truncate(now, :second)
      expires_at = DateTime.add(now, lease_seconds, :second)

      case Repo.transaction(fn -> claim_due_operations(owner, now, expires_at, limit) end) do
        {:ok, operations} -> {:ok, operations}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def claim_operations(_owner, _now, _lease_seconds, _limit), do: {:error, :invalid_argument}

  @spec mark_external_effect(MirrorOperation.t(), DateTime.t(), map()) ::
          {:ok, MirrorOperation.t()}
          | {:error, :lost_lease | :invalid_transition | :invalid_argument | :paused}
  def mark_external_effect(
        %MirrorOperation{state: :processing} = operation,
        %DateTime{} = now,
        marker
      )
      when is_map(marker) and map_size(marker) > 0 do
    with :ok <- validate_utc(now), :ok <- validate_bounded_object(marker) do
      now = DateTime.truncate(now, :second)

      Repo.transaction(fn ->
        with :ok <- lock_effect_scope(operation),
             {:ok, marked} <-
               owned_transition(operation, now, [:processing],
                 state: :effect_pending,
                 external_effect_marker: canonical_map(marker),
                 effect_marked_at: now
               ) do
          marked
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, marked} ->
          {:ok, marked}

        {:error, reason} when reason in [:lost_lease, :invalid_transition, :paused] ->
          {:error, reason}

        {:error, _reason} ->
          {:error, :lost_lease}
      end
    end
  rescue
    _ -> {:error, :lost_lease}
  end

  def mark_external_effect(%MirrorOperation{}, %DateTime{}, _marker),
    do: {:error, :invalid_transition}

  def mark_external_effect(_operation, _now, _marker), do: {:error, :invalid_argument}

  @spec failure_disposition(String.t()) ::
          {:ok, :retry | :degraded | :conflict | :terminal} | {:error, :invalid_argument}
  def failure_disposition(failure_class) do
    case MirrorOperation.failure_disposition(failure_class) do
      {:ok, disposition} -> {:ok, disposition}
      :error -> {:error, :invalid_argument}
    end
  end

  @spec complete_operation(MirrorOperation.t(), DateTime.t()) ::
          {:ok, MirrorOperation.t()}
          | {:error, :lost_lease | :invalid_transition | :invalid_argument}
  def complete_operation(%MirrorOperation{state: state} = operation, %DateTime{} = now)
      when state in [:processing, :effect_pending] do
    with :ok <- validate_utc(now) do
      now = DateTime.truncate(now, :second)

      owned_transition(operation, now, [state],
        state: :completed,
        lease_owner: nil,
        lease_expires_at: nil,
        external_effect_marker: nil,
        effect_marked_at: nil,
        completed_at: now,
        failure_class: nil,
        failure_disposition: nil,
        failure_detail: nil
      )
    end
  end

  def complete_operation(%MirrorOperation{}, %DateTime{}), do: {:error, :invalid_transition}
  def complete_operation(_operation, _now), do: {:error, :invalid_argument}

  @spec retry_operation(
          MirrorOperation.t(),
          DateTime.t(),
          DateTime.t(),
          String.t() | nil,
          keyword()
        ) ::
          {:ok, MirrorOperation.t()}
          | {:error, :lost_lease | :invalid_transition | :invalid_argument}
  def retry_operation(operation, now, next_attempt_at, failure_class, options \\ [])

  def retry_operation(
        %MirrorOperation{state: state} = operation,
        %DateTime{} = now,
        %DateTime{} = next_attempt_at,
        failure_class,
        options
      )
      when state in [:processing, :effect_pending] and is_list(options) do
    with :ok <- validate_utc(now),
         :ok <- validate_utc(next_attempt_at),
         :ok <- validate_retryable_failure_class(failure_class),
         :ok <- validate_keyword(options),
         :ok <- validate_failure_detail(Keyword.get(options, :failure_detail)),
         :ok <- validate_effect_retry(state, options) do
      owned_transition(operation, DateTime.truncate(now, :second), [state],
        state: :pending,
        next_attempt_at: DateTime.truncate(next_attempt_at, :second),
        lease_owner: nil,
        lease_expires_at: nil,
        external_effect_marker: nil,
        effect_marked_at: nil,
        failure_class: failure_class,
        failure_disposition: :retry,
        failure_detail: Keyword.get(options, :failure_detail)
      )
    end
  end

  def retry_operation(%MirrorOperation{}, %DateTime{}, %DateTime{}, _failure_class, _options),
    do: {:error, :invalid_transition}

  def retry_operation(_operation, _now, _next_attempt_at, _failure_class, _options),
    do: {:error, :invalid_argument}

  @spec fail_operation(MirrorOperation.t(), DateTime.t(), String.t(), String.t() | nil) ::
          {:ok, MirrorOperation.t()}
          | {:error, :lost_lease | :invalid_transition | :invalid_argument}
  def fail_operation(operation, now, failure_class, failure_detail \\ nil)

  def fail_operation(
        %MirrorOperation{state: state} = operation,
        %DateTime{} = now,
        failure_class,
        failure_detail
      )
      when state in [:processing, :effect_pending] do
    with :ok <- validate_utc(now),
         {:ok, failure_disposition} <- nonretryable_failure_disposition(failure_class),
         :ok <- validate_failure_detail(failure_detail) do
      owned_transition(operation, DateTime.truncate(now, :second), [state],
        state: :failed,
        lease_owner: nil,
        lease_expires_at: nil,
        external_effect_marker: nil,
        effect_marked_at: nil,
        failure_class: failure_class,
        failure_disposition: failure_disposition,
        failure_detail: failure_detail
      )
    end
  end

  def fail_operation(%MirrorOperation{}, %DateTime{}, _failure_class, _failure_detail),
    do: {:error, :invalid_transition}

  def fail_operation(_operation, _now, _failure_class, _failure_detail),
    do: {:error, :invalid_argument}

  @spec recover_expired_operations(DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_argument | :unavailable}
  def recover_expired_operations(%DateTime{} = now) do
    with :ok <- validate_utc(now) do
      now = DateTime.truncate(now, :second)

      Repo.transaction(fn ->
        {processing_count, _} =
          MirrorOperation
          |> where(
            [operation],
            operation.state == :processing and operation.lease_expires_at <= ^now
          )
          |> Repo.update_all(
            set: [
              state: :pending,
              next_attempt_at: now,
              lease_owner: nil,
              lease_expires_at: nil,
              updated_at: now
            ],
            inc: [lock_version: 1]
          )

        {effect_count, _} =
          MirrorOperation
          |> where(
            [operation],
            operation.state == :effect_pending and not is_nil(operation.lease_expires_at) and
              operation.lease_expires_at <= ^now
          )
          |> Repo.update_all(
            set: [lease_owner: nil, lease_expires_at: nil, updated_at: now],
            inc: [lock_version: 1]
          )

        processing_count + effect_count
      end)
      |> case do
        {:ok, count} -> {:ok, count}
        {:error, _} -> {:error, :unavailable}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def recover_expired_operations(_now), do: {:error, :invalid_argument}

  @spec record_conflict(map()) ::
          {:ok, MirrorConflict.t()}
          | {:error, Ecto.Changeset.t() | :dedupe_conflict | :not_found}
  def record_conflict(attrs) when is_map(attrs) do
    changeset = MirrorConflict.record_changeset(%MirrorConflict{}, attrs)

    if changeset.valid? do
      with :ok <- validate_conflict_scope(changeset) do
        case Repo.insert(changeset) do
          {:ok, conflict} -> {:ok, conflict}
          {:error, %Ecto.Changeset{} = invalid} -> conflict_insert_error(invalid, attrs)
        end
      end
    else
      {:error, changeset}
    end
  end

  def record_conflict(_attrs), do: invalid_changeset(%MirrorConflict{})

  @spec resolve_conflict(MirrorConflict.t(), map(), pos_integer() | nil, DateTime.t()) ::
          {:ok, MirrorConflict.t()}
          | {:error, Ecto.Changeset.t() | :invalid_transition | :stale | :invalid_argument}
  def resolve_conflict(
        %MirrorConflict{state: :open} = conflict,
        resolution,
        user_id,
        %DateTime{} = now
      )
      when is_map(resolution) and (is_nil(user_id) or (is_integer(user_id) and user_id > 0)) do
    with :ok <- validate_utc(now) do
      conflict
      |> MirrorConflict.resolve_changeset(
        canonical_map(resolution),
        user_id,
        DateTime.truncate(now, :second)
      )
      |> cas_update()
      |> resolve_idempotently(conflict.id, canonical_map(resolution))
    end
  end

  def resolve_conflict(%MirrorConflict{state: :resolved} = conflict, resolution, _user_id, _now)
      when is_map(resolution) do
    if conflict.resolution == canonical_map(resolution),
      do: {:ok, conflict},
      else: {:error, :invalid_transition}
  end

  def resolve_conflict(%MirrorConflict{}, _resolution, _user_id, %DateTime{}),
    do: {:error, :invalid_transition}

  def resolve_conflict(_conflict, _resolution, _user_id, _now), do: {:error, :invalid_argument}

  @spec organization_status(pos_integer()) ::
          {:ok, map()} | {:error, :not_found | :invalid_argument}
  def organization_status(id) when is_integer(id) and id > 0 do
    with {:ok, mirror} <- get_organization_mirror(id) do
      repository_states = grouped_counts(RepositoryMirror, :organization_mirror_id, id)
      operation_counts = grouped_counts(MirrorOperation, :organization_mirror_id, id)

      conflict_count =
        Repo.aggregate(
          from(conflict in MirrorConflict,
            where: conflict.organization_mirror_id == ^id and conflict.state == :open
          ),
          :count
        )

      {:ok,
       %{
         mirror: mirror,
         repository_states: repository_states,
         operation_counts: operation_counts,
         open_conflicts: conflict_count,
         last_webhook_at: mirror.last_webhook_at,
         last_reconciled_at: mirror.last_reconciled_at,
         next_reconcile_at: mirror.next_reconcile_at
       }}
    end
  end

  def organization_status(_id), do: {:error, :invalid_argument}

  @spec list_organization_status(pos_integer()) ::
          {:ok, map()} | {:error, :not_found | :invalid_argument}
  def list_organization_status(id), do: organization_status(id)

  @spec schedule_reconciliation(OrganizationMirror.t(), DateTime.t()) ::
          {:ok, MirrorOperation.t()} | {:error, term()}
  def schedule_reconciliation(%OrganizationMirror{} = mirror, %DateTime{} = scheduled_at) do
    with :ok <- validate_utc(scheduled_at) do
      scheduled_at = DateTime.truncate(scheduled_at, :second)

      enqueue_operation(%{
        organization_mirror_id: mirror.id,
        kind: "reconcile.organization_inventory",
        dedupe_key: "reconcile:organization:#{mirror.id}:#{DateTime.to_unix(scheduled_at)}",
        cursor: %{},
        next_attempt_at: scheduled_at
      })
    end
  end

  def schedule_reconciliation(_mirror, _scheduled_at), do: {:error, :invalid_argument}

  @doc false
  def schedule_due_reconciliations(%DateTime{} = now, limit, interval_seconds)
      when is_integer(limit) and limit in 1..@max_claim_batch and is_integer(interval_seconds) and
             interval_seconds > 0 do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      OrganizationMirror
      |> where(
        [mirror],
        mirror.state not in [:paused, :revoked] and not is_nil(mirror.next_reconcile_at) and
          mirror.next_reconcile_at <= ^now
      )
      |> order_by([mirror], asc: mirror.next_reconcile_at, asc: mirror.id)
      |> limit(^limit)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> Repo.all()
      |> Enum.map(&schedule_due_mirror(&1, now, interval_seconds))
    end)
  end

  @doc false
  def materialize_outbox_event(%DomainOutboxEvent{} = event) do
    case repository_id_from_event(event) do
      repository_id when is_integer(repository_id) ->
        RepositoryMirror
        |> join(:inner, [repository], organization in OrganizationMirror,
          on: organization.id == repository.organization_mirror_id
        )
        |> where(
          [repository, organization],
          repository.repository_id == ^repository_id and
            repository.state in [:discovered, :active] and
            organization.state != :revoked
        )
        |> Repo.all()
        |> Enum.reduce_while({:ok, []}, &materialize_for_repository(&1, event, &2))

      _ ->
        {:ok, []}
    end
  end

  defp schedule_due_mirror(mirror, now, interval_seconds) do
    scheduled_at = mirror.next_reconcile_at

    result =
      enqueue_operation(%{
        organization_mirror_id: mirror.id,
        kind: "reconcile.organization_inventory",
        dedupe_key: "periodic-reconcile:#{mirror.id}:#{DateTime.to_unix(scheduled_at)}",
        cursor: %{},
        next_attempt_at: now
      })

    {:ok, _updated} =
      mirror
      |> OrganizationMirror.update_changeset(%{
        next_reconcile_at: DateTime.add(scheduled_at, interval_seconds, :second)
      })
      |> cas_update()

    result
  end

  defp materialize_for_repository(repository, event, {:ok, operations}) do
    case enqueue_operation(%{
           organization_mirror_id: repository.organization_mirror_id,
           repository_mirror_id: repository.id,
           kind: event.event_type,
           dedupe_key: "outbox:#{event.event_id}:#{repository.id}",
           cursor: %{"outbox_event_id" => event.event_id},
           next_attempt_at: event.available_at
         }) do
      {:ok, operation} -> {:cont, {:ok, [operation | operations]}}
      error -> {:halt, error}
    end
  end

  defp insert_idempotent_operation(changeset) do
    case Repo.insert(changeset) do
      {:ok, operation} ->
        {:ok, operation}

      {:error, %Ecto.Changeset{} = invalid} ->
        dedupe_key = Ecto.Changeset.get_field(changeset, :dedupe_key)

        if Keyword.has_key?(invalid.errors, :dedupe_key) do
          existing = Repo.get_by!(MirrorOperation, dedupe_key: dedupe_key)

          if operation_identity(existing) == changeset_identity(changeset),
            do: {:ok, existing},
            else: {:error, :dedupe_conflict}
        else
          {:error, invalid}
        end
    end
  end

  defp operation_identity(operation) do
    {operation.organization_mirror_id, operation.repository_mirror_id, operation.kind,
     operation.cursor}
  end

  defp changeset_identity(changeset) do
    {
      Ecto.Changeset.get_field(changeset, :organization_mirror_id),
      Ecto.Changeset.get_field(changeset, :repository_mirror_id),
      Ecto.Changeset.get_field(changeset, :kind),
      Ecto.Changeset.get_field(changeset, :cursor)
    }
  end

  defp validate_repository_binding_scope(changeset) do
    organization_mirror_id =
      Ecto.Changeset.get_field(changeset, :organization_mirror_id)

    repository_id = Ecto.Changeset.get_field(changeset, :repository_id)

    with %OrganizationMirror{} = organization_mirror <-
           Repo.get(OrganizationMirror, organization_mirror_id),
         %ForgeAccounts.Organization{} <-
           ForgeAccounts.get_organization(organization_mirror.organization_id),
         :ok <-
           validate_local_repository_scope(organization_mirror.organization_id, repository_id) do
      {:ok, organization_mirror}
    else
      _ -> {:error, :not_found}
    end
  end

  defp validate_local_repository_scope(_organization_id, nil), do: :ok

  defp validate_local_repository_scope(organization_id, repository_id) do
    case ForgeRepos.fetch_organization_repository(organization_id, repository_id) do
      {:ok, _repository} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp validate_conflict_scope(changeset) do
    organization_mirror_id =
      Ecto.Changeset.get_field(changeset, :organization_mirror_id)

    repository_mirror_id = Ecto.Changeset.get_field(changeset, :repository_mirror_id)

    with %OrganizationMirror{} <- Repo.get(OrganizationMirror, organization_mirror_id),
         :ok <- validate_repository_scope(repository_mirror_id, organization_mirror_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp validate_operation_scope(changeset) do
    organization_id = Ecto.Changeset.get_field(changeset, :organization_mirror_id)
    repository_id = Ecto.Changeset.get_field(changeset, :repository_mirror_id)

    with %OrganizationMirror{} <- Repo.get(OrganizationMirror, organization_id),
         :ok <- validate_repository_scope(repository_id, organization_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp validate_repository_scope(nil, _organization_id), do: :ok

  defp validate_repository_scope(repository_id, organization_id) do
    case Repo.get(RepositoryMirror, repository_id) do
      %RepositoryMirror{organization_mirror_id: ^organization_id} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp lock_effect_scope(%MirrorOperation{id: id}) when is_integer(id) and id > 0 do
    case Repo.get(MirrorOperation, id) do
      %MirrorOperation{} = persisted ->
        organization =
          OrganizationMirror
          |> where([mirror], mirror.id == ^persisted.organization_mirror_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        repository = lock_effect_repository(persisted.repository_mirror_id)

        with %OrganizationMirror{} = organization <- organization,
             {:ok, repository} <- repository,
             :ok <- validate_effect_organization(organization),
             :ok <- validate_effect_repository(repository) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :lost_lease}
        end

      nil ->
        {:error, :lost_lease}
    end
  end

  defp lock_effect_scope(_operation), do: {:error, :lost_lease}

  defp lock_effect_repository(nil), do: {:ok, nil}

  defp lock_effect_repository(repository_mirror_id) do
    case RepositoryMirror
         |> where([mirror], mirror.id == ^repository_mirror_id)
         |> lock("FOR UPDATE")
         |> Repo.one() do
      %RepositoryMirror{} = repository -> {:ok, repository}
      nil -> {:error, :lost_lease}
    end
  end

  defp validate_effect_organization(%OrganizationMirror{state: :paused}), do: {:error, :paused}

  defp validate_effect_organization(%OrganizationMirror{state: :revoked}),
    do: {:error, :invalid_transition}

  defp validate_effect_organization(%OrganizationMirror{}), do: :ok

  defp validate_effect_repository(nil), do: :ok

  defp validate_effect_repository(%RepositoryMirror{state: state})
       when state in [:discovered, :active],
       do: :ok

  defp validate_effect_repository(%RepositoryMirror{}), do: {:error, :invalid_transition}

  defp claim_due_operations(owner, now, expires_at, limit) do
    sql = """
    select operation.id
    from mirror_operations operation
    join organization_mirrors organization
      on organization.id = operation.organization_mirror_id
    left join repository_mirrors repository
      on repository.id = operation.repository_mirror_id
    where organization.state not in ('paused', 'revoked')
      and (operation.repository_mirror_id is null or repository.state in ('discovered', 'active'))
      and (
        (operation.state = 'pending' and operation.next_attempt_at <= $1)
        or (operation.state = 'processing' and operation.lease_expires_at <= $1)
        or (operation.state = 'effect_pending' and
              (operation.lease_expires_at is null or operation.lease_expires_at <= $1))
      )
      and not exists (
        select 1 from mirror_operations earlier
        where earlier.id < operation.id
          and earlier.state in ('pending', 'processing', 'effect_pending')
          and (
            (operation.repository_mirror_id is not null and
              earlier.repository_mirror_id = operation.repository_mirror_id)
            or
            (operation.repository_mirror_id is null and earlier.repository_mirror_id is null and
              earlier.organization_mirror_id = operation.organization_mirror_id)
          )
      )
      and not exists (
        select 1 from mirror_operations active
        where active.id <> operation.id
          and active.state in ('processing', 'effect_pending')
          and active.lease_expires_at > $1
          and (
            (operation.repository_mirror_id is not null and
              active.repository_mirror_id = operation.repository_mirror_id)
            or
            (operation.repository_mirror_id is null and active.repository_mirror_id is null and
              active.organization_mirror_id = operation.organization_mirror_id)
          )
      )
    order by operation.next_attempt_at, operation.id
    for update of operation skip locked
    limit $2
    """

    %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, [now, limit])
    Enum.map(rows, fn [id] -> claim_operation!(id, owner, now, expires_at) end)
  end

  defp claim_operation!(id, owner, now, expires_at) do
    operation = Repo.get!(MirrorOperation, id)
    state = if operation.state == :effect_pending, do: :effect_pending, else: :processing

    {1, _} =
      MirrorOperation
      |> where(
        [candidate],
        candidate.id == ^id and candidate.lock_version == ^operation.lock_version
      )
      |> Repo.update_all(
        set: [
          state: state,
          lease_owner: owner,
          lease_expires_at: expires_at,
          started_at: operation.started_at || now,
          updated_at: now
        ],
        inc: [attempt_count: 1, lock_version: 1]
      )

    Repo.get!(MirrorOperation, id)
  end

  defp owned_transition(operation, now, states, updates) do
    if owned_capability?(operation) do
      query =
        from candidate in MirrorOperation,
          where:
            candidate.id == ^operation.id and candidate.state in ^states and
              candidate.lease_owner == ^operation.lease_owner and
              candidate.lease_expires_at == ^operation.lease_expires_at and
              candidate.lease_expires_at > fragment("clock_timestamp()") and
              candidate.lock_version == ^operation.lock_version

      case Repo.update_all(query,
             set: Keyword.put(updates, :updated_at, now),
             inc: [lock_version: 1]
           ) do
        {1, _} -> {:ok, Repo.get!(MirrorOperation, operation.id)}
        {0, _} -> {:error, :lost_lease}
      end
    else
      {:error, :lost_lease}
    end
  rescue
    _ -> {:error, :lost_lease}
  end

  defp owned_capability?(%MirrorOperation{
         id: id,
         lease_owner: owner,
         lease_expires_at: %DateTime{},
         lock_version: version
       }) do
    is_integer(id) and is_binary(owner) and owner != "" and is_integer(version)
  end

  defp owned_capability?(_operation), do: false

  defp conflict_insert_error(changeset, attrs) do
    if Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
         opts[:constraint_name] == "mirror_conflicts_one_open_identity_index"
       end) do
      organization_id = attr(attrs, :organization_mirror_id)
      repository_id = attr(attrs, :repository_mirror_id)
      resource_kind = attr(attrs, :resource_kind)
      resource_identity = attr(attrs, :resource_identity)

      query =
        from conflict in MirrorConflict,
          where:
            conflict.organization_mirror_id == ^organization_id and
              conflict.resource_kind == ^resource_kind and
              conflict.resource_identity == ^resource_identity and conflict.state == :open

      query =
        if is_nil(repository_id),
          do: where(query, [conflict], is_nil(conflict.repository_mirror_id)),
          else: where(query, [conflict], conflict.repository_mirror_id == ^repository_id)

      existing = Repo.one!(query)

      expected =
        {
          attr(attrs, :conflict_kind),
          canonical_map(attr(attrs, :baseline_snapshot) || %{}),
          canonical_map(attr(attrs, :local_snapshot) || %{}),
          canonical_map(attr(attrs, :remote_snapshot) || %{})
        }

      actual =
        {existing.conflict_kind, existing.baseline_snapshot, existing.local_snapshot,
         existing.remote_snapshot}

      if expected == actual, do: {:ok, existing}, else: {:error, :dedupe_conflict}
    else
      {:error, changeset}
    end
  end

  defp resolve_idempotently({:error, :stale}, conflict_id, resolution) do
    case Repo.get(MirrorConflict, conflict_id) do
      %MirrorConflict{state: :resolved, resolution: ^resolution} = conflict -> {:ok, conflict}
      _ -> {:error, :stale}
    end
  end

  defp resolve_idempotently(result, _conflict_id, _resolution), do: result

  defp cas_update(changeset) do
    changeset
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update(stale_error_field: :lock_version, stale_error_message: "is stale")
    |> case do
      {:error, %Ecto.Changeset{} = stale} = error ->
        if Keyword.has_key?(stale.errors, :lock_version), do: {:error, :stale}, else: error

      result ->
        result
    end
  end

  defp grouped_counts(schema, foreign_key, id) do
    schema
    |> where([row], field(row, ^foreign_key) == ^id)
    |> group_by([row], row.state)
    |> select([row], {row.state, count(row.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp validate_owner(owner) do
    if byte_size(owner) in 1..255 and owner == String.trim(owner),
      do: :ok,
      else: {:error, :invalid_argument}
  end

  defp validate_utc(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: :ok
  defp validate_utc(_now), do: {:error, :invalid_argument}

  defp validate_retryable_failure_class(failure_class) do
    case failure_disposition(failure_class) do
      {:ok, :retry} -> :ok
      _ -> {:error, :invalid_argument}
    end
  end

  defp nonretryable_failure_disposition(failure_class) do
    case failure_disposition(failure_class) do
      {:ok, :retry} -> {:error, :invalid_argument}
      {:ok, disposition} -> {:ok, disposition}
      {:error, :invalid_argument} = error -> error
    end
  end

  defp validate_failure_detail(nil), do: :ok

  defp validate_failure_detail(detail) when is_binary(detail) do
    if byte_size(detail) in 1..2_048 and detail == String.trim(detail),
      do: :ok,
      else: {:error, :invalid_argument}
  end

  defp validate_failure_detail(_detail), do: {:error, :invalid_argument}

  defp validate_effect_retry(:processing, options) do
    if Keyword.keyword?(options), do: :ok, else: {:error, :invalid_argument}
  end

  defp validate_effect_retry(:effect_pending, options) do
    if Keyword.keyword?(options) and Keyword.get(options, :external_effect_reconciled) == true,
      do: :ok,
      else: {:error, :invalid_transition}
  end

  defp validate_keyword(options) do
    if Keyword.keyword?(options), do: :ok, else: {:error, :invalid_argument}
  end

  defp validate_bounded_object(value) do
    if value |> JSON.encode_to_iodata!() |> IO.iodata_length() <= 65_536,
      do: :ok,
      else: {:error, :invalid_argument}
  rescue
    _ -> {:error, :invalid_argument}
  end

  defp canonicalize_cursor(attrs) do
    cond do
      Map.has_key?(attrs, :cursor) -> Map.update!(attrs, :cursor, &canonicalize_cursor_value/1)
      Map.has_key?(attrs, "cursor") -> Map.update!(attrs, "cursor", &canonicalize_cursor_value/1)
      true -> attrs
    end
  end

  defp canonicalize_cursor_value(value) when is_map(value), do: canonical_map(value)
  defp canonicalize_cursor_value(value), do: value

  defp canonical_map(value) when is_map(value) do
    value |> JSON.encode!() |> JSON.decode!()
  rescue
    _ -> value
  end

  defp repository_id_from_event(%DomainOutboxEvent{
         aggregate_type: "repository",
         aggregate_id: id
       }) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp repository_id_from_event(%DomainOutboxEvent{payload: payload}) when is_map(payload) do
    case Map.get(payload, "repository_id") || Map.get(payload, :repository_id) do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive_integer(value)
      _ -> nil
    end
  end

  defp repository_id_from_event(_event), do: nil

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp attr(attrs, field), do: Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

  defp invalid_changeset(struct) do
    {:error, Ecto.Changeset.add_error(Ecto.Changeset.change(struct), :base, "is invalid")}
  end
end
