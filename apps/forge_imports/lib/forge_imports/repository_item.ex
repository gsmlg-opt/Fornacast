defmodule ForgeImports.RepositoryItem do
  use Ecto.Schema

  import Ecto.Changeset

  alias ForgeRepos.Repository
  alias Fornacast.Storage

  @states [
    :queued,
    :awaiting_resolution,
    :staging_git,
    :git_staged,
    :staging_metadata,
    :ready_to_publish,
    :publishing,
    :published,
    :completed,
    :awaiting_credential,
    :cancel_requested,
    :skipped,
    :canceled,
    :failed
  ]
  @terminal_states [:completed, :skipped, :canceled, :failed]
  @destination_drift_states [
    :queued,
    :staging_git,
    :git_staged,
    :staging_metadata,
    :ready_to_publish,
    :publishing,
    :awaiting_credential
  ]
  @visibilities [:private, :public]
  @conflict_actions [:skip, :rename, :replace]
  @max_id 9_223_372_036_854_775_807
  @count_fields [:imported_count, :skipped_count, :warning_count, :failure_count]
  @publication_intent_keys ~w(version state attempt_number action hidden_repository_id operation_id request_metadata)
  @publication_committed_keys @publication_intent_keys ++
                                ~w(repository_id owner_user_id slug generation replaced_repository_id run_id published_count_after run_lock_version_after)
  @source_metadata_keys ~w(
    archived fork visibility default_branch description has_issues allow_merge_commit disabled
    updated_at pushed_at
  )
  @discovery_fields [
    :import_run_id,
    :predecessor_item_id,
    :github_repository_id,
    :source_full_name,
    :source_name,
    :source_metadata,
    :source_observed_at
  ]
  @planning_fields @discovery_fields ++
                     [
                       :destination_owner_id,
                       :destination_slug,
                       :destination_visibility,
                       :state,
                       :wait_reason,
                       :warning_count
                     ]
  @conflict_resolution_fields [
    :destination_slug,
    :conflict_action,
    :replacement_repository_id,
    :replacement_owner_id,
    :replacement_storage_path,
    :replacement_generation,
    :replacement_write_version,
    :replacement_updated_at,
    :replacement_last_pushed_at,
    :state,
    :wait_reason
  ]
  @transition_fields [
    :resume_state,
    :wait_reason,
    :next_attempt_at,
    :attempt_count,
    :failure_kind,
    :failure_detail,
    :checkpoint,
    :source_git,
    :publication_evidence,
    :cleanup_state,
    :cleanup_eligible_at,
    :cleanup_attempt_count,
    :cleanup_error
    | @count_fields
  ]
  @lease_fields [:state | @transition_fields]
  @transitions %{
    queued: [
      :awaiting_resolution,
      :staging_git,
      :awaiting_credential,
      :cancel_requested,
      :skipped,
      :canceled,
      :failed
    ],
    awaiting_resolution: [
      :queued,
      :awaiting_credential,
      :cancel_requested,
      :skipped,
      :canceled,
      :failed
    ],
    staging_git: [:git_staged, :awaiting_credential, :cancel_requested, :failed],
    git_staged: [:staging_metadata, :awaiting_credential, :cancel_requested, :failed],
    staging_metadata: [:ready_to_publish, :awaiting_credential, :cancel_requested, :failed],
    ready_to_publish: [:publishing, :awaiting_credential, :cancel_requested, :failed],
    publishing: [:published],
    published: [:completed],
    awaiting_credential: [
      :queued,
      :awaiting_resolution,
      :staging_git,
      :git_staged,
      :staging_metadata,
      :ready_to_publish,
      :publishing,
      :cancel_requested,
      :canceled,
      :failed
    ],
    cancel_requested: [:canceled, :published, :completed]
  }

  @derive {Inspect,
           except: [
             :replacement_storage_path,
             :staged_storage_path,
             :failure_detail,
             :cleanup_error,
             :source_metadata,
             :wait_reason,
             :failure_kind,
             :cleanup_state,
             :checkpoint,
             :source_git,
             :publication_evidence
           ]}
  schema "github_import_repository_items" do
    field :import_run_id, :integer
    field :predecessor_item_id, :integer
    field :github_repository_id, :integer
    field :source_full_name, :string
    field :source_name, :string
    field :source_metadata, :map, default: %{}
    field :source_observed_at, :utc_datetime
    field :selected, :boolean, default: true
    field :destination_owner_id, :integer
    field :destination_slug, :string
    field :destination_visibility, Ecto.Enum, values: @visibilities
    field :conflict_action, Ecto.Enum, values: @conflict_actions
    field :replacement_repository_id, :integer
    field :replacement_owner_id, :integer
    field :replacement_storage_path, :string, redact: true
    field :replacement_generation, :integer
    field :replacement_write_version, :integer
    field :replacement_updated_at, :utc_datetime
    field :replacement_last_pushed_at, :utc_datetime
    field :hidden_repository_id, :integer
    field :staged_storage_path, :string, redact: true
    field :state, Ecto.Enum, values: @states, default: :queued
    field :resume_state, Ecto.Enum, values: @states
    field :wait_reason, :string
    field :next_attempt_at, :utc_datetime
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :lock_version, :integer, default: 1
    field :attempt_count, :integer, default: 0
    field :failure_kind, :string
    field :failure_detail, :string, redact: true
    field :checkpoint, :map, default: %{}
    field :source_git, :map, default: %{}
    field :publication_evidence, :map, default: %{}
    field :imported_count, :integer, default: 0
    field :skipped_count, :integer, default: 0
    field :warning_count, :integer, default: 0
    field :failure_count, :integer, default: 0
    field :cleanup_state, :string
    field :cleanup_eligible_at, :utc_datetime
    field :cleanup_attempt_count, :integer, default: 0
    field :cleanup_error, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def states, do: @states
  def terminal_states, do: @terminal_states
  def transitions, do: @transitions

  def discovery_changeset(%__MODULE__{id: nil} = item, attrs) when is_map(attrs) do
    build_discovery_changeset(item, attrs, @discovery_fields)
  end

  def discovery_changeset(item, _attrs), do: item |> change() |> add_error(:base, "is invalid")

  @doc false
  def discovery_plan_changeset(%__MODULE__{id: nil} = item, attrs) when is_map(attrs) do
    item
    |> build_discovery_changeset(attrs, @planning_fields)
    |> validate_inclusion(:state, [:queued, :awaiting_resolution])
    |> validate_required([:destination_visibility])
  end

  def discovery_plan_changeset(item, _attrs),
    do: item |> change() |> add_error(:base, "is invalid")

  defp build_discovery_changeset(item, attrs, fields) do
    item
    |> cast(attrs, fields)
    |> put_change(:selected, true)
    |> put_default_change(:state, :queued)
    |> put_change(:resume_state, nil)
    |> put_change(:next_attempt_at, nil)
    |> put_change(:lease_owner, nil)
    |> put_change(:lease_expires_at, nil)
    |> put_change(:lock_version, 1)
    |> put_change(:attempt_count, 0)
    |> put_change(:failure_kind, nil)
    |> put_change(:failure_detail, nil)
    |> put_change(:checkpoint, %{})
    |> put_change(:source_git, %{})
    |> put_change(:publication_evidence, %{})
    |> put_change(:imported_count, 0)
    |> put_change(:skipped_count, 0)
    |> put_change(:failure_count, 0)
    |> put_change(:cleanup_state, nil)
    |> put_change(:cleanup_eligible_at, nil)
    |> put_change(:cleanup_attempt_count, 0)
    |> put_change(:cleanup_error, nil)
    |> validate_persistence()
  end

  @doc false
  def persistence_changeset(item, attrs) when is_map(attrs) do
    item
    |> cast(attrs, [
      :import_run_id,
      :predecessor_item_id,
      :github_repository_id,
      :source_full_name,
      :source_name,
      :source_metadata,
      :source_observed_at,
      :selected,
      :destination_owner_id,
      :destination_slug,
      :destination_visibility,
      :conflict_action,
      :replacement_repository_id,
      :replacement_owner_id,
      :replacement_storage_path,
      :replacement_generation,
      :replacement_write_version,
      :replacement_updated_at,
      :replacement_last_pushed_at,
      :hidden_repository_id,
      :staged_storage_path,
      :state,
      :resume_state,
      :wait_reason,
      :next_attempt_at,
      :lock_version,
      :attempt_count,
      :failure_kind,
      :failure_detail,
      :checkpoint,
      :source_git,
      :publication_evidence,
      :imported_count,
      :skipped_count,
      :warning_count,
      :failure_count,
      :cleanup_state,
      :cleanup_eligible_at,
      :cleanup_attempt_count,
      :cleanup_error
    ])
    |> validate_persistence()
  end

  def persistence_changeset(item, _attrs), do: item |> change() |> add_error(:base, "is invalid")

  defp validate_persistence(changeset) do
    changeset
    |> validate_required([
      :import_run_id,
      :github_repository_id,
      :source_full_name,
      :source_name,
      :source_metadata,
      :source_observed_at,
      :selected,
      :state,
      :lock_version,
      :attempt_count,
      :checkpoint,
      :source_git,
      :publication_evidence,
      :cleanup_attempt_count
    ])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:resume_state, @states)
    |> validate_inclusion(:destination_visibility, @visibilities)
    |> validate_inclusion(:conflict_action, @conflict_actions)
    |> validate_positive_id(:import_run_id)
    |> validate_positive_id(:predecessor_item_id)
    |> validate_positive_id(:github_repository_id)
    |> validate_positive_id(:destination_owner_id)
    |> validate_positive_id(:replacement_repository_id)
    |> validate_positive_id(:replacement_owner_id)
    |> validate_positive_id(:hidden_repository_id)
    |> validate_number(:replacement_generation, greater_than: 0)
    |> validate_number(:replacement_write_version, greater_than_or_equal_to: 0)
    |> validate_number(:lock_version, greater_than: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:cleanup_attempt_count, greater_than_or_equal_to: 0)
    |> validate_counts()
    |> validate_strings()
    |> validate_repository_evidence()
    |> validate_staged_storage_path()
    |> validate_maps()
    |> validate_publication_evidence_shape()
    |> validate_source_metadata()
    |> validate_conflict_fingerprint()
    |> validate_cleanup_coherence()
    |> validate_lifecycle()
    |> validate_resume_state()
    |> map_constraints()
  end

  def selection_changeset(%__MODULE__{state: state} = item, attrs)
      when state in [:queued, :awaiting_resolution] and is_map(attrs) do
    item
    |> cast(attrs, [:selected])
    |> validate_required([:selected])
  end

  def selection_changeset(item, _attrs),
    do: item |> change() |> add_error(:selected, "is immutable after work starts")

  @doc false
  def destination_changeset(%__MODULE__{state: state} = item, attrs)
      when state in [:queued, :awaiting_resolution] and is_map(attrs) do
    item
    |> cast(attrs, [
      :destination_owner_id,
      :destination_slug,
      :destination_visibility,
      :state,
      :wait_reason
    ])
    |> validate_required([:destination_visibility, :state])
    |> validate_inclusion(:state, [:queued, :awaiting_resolution])
    |> validate_inclusion(:destination_visibility, @visibilities)
    |> validate_positive_id(:destination_owner_id)
    |> validate_strings()
    |> validate_repository_evidence()
    |> validate_lifecycle()
    |> map_constraints()
  end

  def destination_changeset(item, _attrs),
    do: item |> change() |> add_error(:state, "cannot change the destination")

  @doc false
  def conflict_resolution_changeset(
        %__MODULE__{selected: true, state: state} = item,
        attrs
      )
      when state in [:queued, :awaiting_resolution] and is_map(attrs) do
    if only_keys?(attrs, @conflict_resolution_fields) do
      item
      |> cast(attrs, @conflict_resolution_fields)
      |> validate_required([:state])
      |> validate_inclusion(:state, [:queued])
      |> validate_inclusion(:conflict_action, @conflict_actions)
      |> validate_positive_id(:replacement_repository_id)
      |> validate_positive_id(:replacement_owner_id)
      |> validate_number(:replacement_generation, greater_than: 0)
      |> validate_number(:replacement_write_version, greater_than_or_equal_to: 0)
      |> validate_strings()
      |> validate_repository_evidence()
      |> validate_conflict_fingerprint()
      |> validate_conflict_resolution()
      |> map_constraints()
    else
      item |> change() |> add_error(:base, "contains immutable fields")
    end
  end

  def conflict_resolution_changeset(item, _attrs),
    do: item |> change() |> add_error(:state, "cannot resolve this repository")

  @doc false
  def freeze_attempt_changeset(
        %__MODULE__{selected: true, state: :queued} = item,
        action,
        attempt_number
      )
      when action in [:create, :skip, :rename, :replace] and is_integer(attempt_number) do
    cond do
      attempt_number != item.attempt_count + 1 ->
        item |> change() |> add_error(:attempt_count, "is stale")

      not coherent_frozen_action?(item, action) ->
        item |> change() |> add_error(:conflict_action, "does not match the resolved decision")

      true ->
        item
        |> change(
          state: if(action == :skip, do: :skipped, else: :queued),
          attempt_count: attempt_number,
          wait_reason: nil,
          next_attempt_at: nil,
          lease_owner: nil,
          lease_expires_at: nil
        )
        |> validate_number(:attempt_count, greater_than: 0)
        |> validate_lifecycle()
    end
  end

  def freeze_attempt_changeset(item, _action, _attempt_number),
    do: item |> change() |> add_error(:state, "cannot freeze this repository")

  @doc false
  def destination_drift_changeset(
        %__MODULE__{selected: true, state: state, cleanup_state: nil} = item,
        action
      )
      when state in @destination_drift_states and state != :staging_git and
             action in [:create, :rename, :replace] do
    if coherent_frozen_action?(item, action) do
      item
      |> change(
        conflict_action: nil,
        replacement_repository_id: nil,
        replacement_owner_id: nil,
        replacement_storage_path: nil,
        replacement_generation: nil,
        replacement_write_version: nil,
        replacement_updated_at: nil,
        replacement_last_pushed_at: nil,
        state: :awaiting_resolution,
        resume_state: nil,
        wait_reason: "destination_changed",
        next_attempt_at: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        failure_kind: nil,
        failure_detail: nil,
        publication_evidence: %{}
      )
      |> validate_conflict_fingerprint()
      |> validate_lifecycle()
      |> validate_resume_state()
    else
      item |> change() |> add_error(:conflict_action, "does not match the frozen decision")
    end
  end

  def destination_drift_changeset(item, _action),
    do: item |> change() |> add_error(:state, "cannot reopen this repository")

  @doc false
  def publication_intent_changeset(
        %__MODULE__{
          selected: true,
          state: :ready_to_publish,
          cleanup_state: nil,
          publication_evidence: evidence
        } = item,
        intent,
        owner,
        %DateTime{} = expires_at
      )
      when is_map(evidence) and map_size(evidence) == 0 and is_map(intent) and is_binary(owner) do
    item
    |> change(
      state: :publishing,
      publication_evidence: intent,
      lease_owner: owner,
      lease_expires_at: DateTime.truncate(expires_at, :second),
      next_attempt_at: nil,
      wait_reason: nil,
      failure_kind: nil,
      failure_detail: nil
    )
    |> validate_maps()
    |> validate_publication_evidence_shape()
    |> validate_lifecycle()
  end

  def publication_intent_changeset(item, _intent, _owner, _expires_at),
    do: item |> change() |> add_error(:state, "cannot admit publication")

  @doc false
  def publication_commit_changeset(
        %__MODULE__{state: :publishing} = item,
        evidence
      )
      when is_map(evidence) do
    item
    |> change(
      state: :published,
      publication_evidence: evidence,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: nil,
      wait_reason: nil,
      failure_kind: nil,
      failure_detail: nil
    )
    |> validate_maps()
    |> validate_publication_evidence_shape()
    |> validate_lifecycle()
  end

  def publication_commit_changeset(item, _evidence),
    do: item |> change() |> add_error(:state, "cannot commit publication")

  @doc false
  def frozen_resume_changeset(%__MODULE__{state: :queued} = item, target)
      when target in [:queued, :git_staged, :ready_to_publish] do
    item
    |> change(state: target, next_attempt_at: nil, wait_reason: nil)
    |> validate_lifecycle()
  end

  def frozen_resume_changeset(item, _target),
    do: item |> change() |> add_error(:state, "cannot resume this repository")

  @doc false
  def staging_intent_changeset(
        %__MODULE__{
          selected: true,
          state: :queued,
          hidden_repository_id: nil,
          staged_storage_path: nil,
          cleanup_state: nil,
          attempt_count: attempt_count
        } = item,
        hidden_repository_id,
        staged_storage_path
      )
      when is_integer(attempt_count) and attempt_count > 0 and is_integer(hidden_repository_id) and
             hidden_repository_id > 0 and is_binary(staged_storage_path) do
    item
    |> change(
      hidden_repository_id: hidden_repository_id,
      staged_storage_path: staged_storage_path,
      state: :staging_git,
      wait_reason: nil,
      next_attempt_at: nil,
      failure_kind: nil,
      failure_detail: nil
    )
    |> validate_positive_id(:hidden_repository_id)
    |> validate_strings()
    |> validate_staged_storage_path()
    |> validate_lifecycle()
    |> map_constraints()
  end

  def staging_intent_changeset(item, _hidden_repository_id, _staged_storage_path),
    do: item |> change() |> add_error(:state, "cannot stage this repository")

  @doc false
  def destination_owner_activation_changeset(
        %__MODULE__{destination_owner_id: nil, hidden_repository_id: nil} = item,
        organization_id
      )
      when is_integer(organization_id) and organization_id > 0 do
    item
    |> change(destination_owner_id: organization_id)
    |> validate_positive_id(:destination_owner_id)
    |> map_constraints()
  end

  def destination_owner_activation_changeset(item, _organization_id),
    do: item |> change() |> add_error(:destination_owner_id, "cannot be activated")

  @doc false
  def cleanup_pending_changeset(
        %__MODULE__{
          state: :staging_git,
          hidden_repository_id: hidden_repository_id,
          cleanup_state: nil
        } = item,
        attrs
      )
      when is_integer(hidden_repository_id) and hidden_repository_id > 0 and is_map(attrs) do
    item
    |> cast(attrs, [
      :staged_storage_path,
      :checkpoint,
      :cleanup_state,
      :cleanup_eligible_at,
      :cleanup_attempt_count,
      :cleanup_error
    ])
    |> put_change(:next_attempt_at, nil)
    |> put_change(:failure_kind, nil)
    |> put_change(:failure_detail, nil)
    |> validate_required([
      :staged_storage_path,
      :checkpoint,
      :cleanup_state,
      :cleanup_eligible_at,
      :cleanup_attempt_count,
      :cleanup_error
    ])
    |> validate_inclusion(:cleanup_state, ["cleanup_pending"])
    |> validate_number(:cleanup_attempt_count, equal_to: 0)
    |> validate_strings()
    |> validate_staged_storage_path()
    |> validate_maps()
    |> validate_cleanup_checkpoint()
    |> validate_cleanup_coherence()
    |> validate_lifecycle()
    |> map_constraints()
  end

  def cleanup_pending_changeset(item, _attrs),
    do: item |> change() |> add_error(:cleanup_state, "cannot retain cleanup evidence")

  def transition_changeset(item, target, attrs) when is_atom(target) and is_map(attrs) do
    build_transition_changeset(item, target, attrs, clear_lease?: true)
  end

  def transition_changeset(item, _target, _attrs), do: invalid_transition(item, "is invalid")

  defp build_transition_changeset(item, target, attrs, options) do
    cond do
      item.state in @terminal_states ->
        invalid_transition(item, "terminal items are immutable")

      target not in Map.get(@transitions, item.state, []) ->
        invalid_transition(item, "is not an allowed transition")

      not coherent_resume_target?(item, target) ->
        invalid_transition(item, "does not match the persisted resume state")

      not only_keys?(attrs, @transition_fields) ->
        invalid_transition(item, "contains immutable fields")

      true ->
        item
        |> cast(attrs, @transition_fields)
        |> put_change(:state, target)
        |> validate_inclusion(:resume_state, @states)
        |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
        |> validate_number(:cleanup_attempt_count, greater_than_or_equal_to: 0)
        |> validate_counts()
        |> validate_strings()
        |> validate_staged_storage_path()
        |> validate_maps()
        |> normalize_resume_state(item.state, target)
        |> maybe_clear_terminal_lease(target, Keyword.fetch!(options, :clear_lease?))
        |> validate_cleanup_coherence()
        |> validate_lifecycle()
        |> validate_resume_state()
        |> map_constraints()
    end
  end

  def lease_update_changeset(item, updates) when is_list(updates) do
    cond do
      not exact_fields?(updates, @lease_fields) ->
        item |> change() |> add_error(:base, "contains immutable fields")

      Keyword.has_key?(updates, :state) ->
        target = Keyword.fetch!(updates, :state)

        build_transition_changeset(
          item,
          target,
          updates |> Keyword.delete(:state) |> Map.new(),
          clear_lease?: false
        )

      item.state in @terminal_states ->
        invalid_transition(item, "terminal items are immutable")

      true ->
        item
        |> cast(Map.new(updates), @transition_fields)
        |> validate_inclusion(:resume_state, @states)
        |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
        |> validate_number(:cleanup_attempt_count, greater_than_or_equal_to: 0)
        |> validate_counts()
        |> validate_strings()
        |> validate_staged_storage_path()
        |> validate_maps()
        |> validate_cleanup_coherence()
        |> validate_lifecycle()
        |> validate_resume_state()
    end
  end

  def lease_update_changeset(item, _updates),
    do: item |> change() |> add_error(:base, "is invalid")

  defp maybe_clear_terminal_lease(changeset, target, true) when target in @terminal_states do
    changeset
    |> put_change(:lease_owner, nil)
    |> put_change(:lease_expires_at, nil)
  end

  defp maybe_clear_terminal_lease(changeset, target, false) when target in @terminal_states do
    changeset
    |> put_change(:lease_owner, nil)
    |> put_change(:lease_expires_at, nil)
  end

  defp maybe_clear_terminal_lease(changeset, _target, _clear_lease?), do: changeset

  defp validate_lifecycle(changeset) do
    state = get_field(changeset, :state)

    if state in @terminal_states and
         (not is_nil(get_field(changeset, :lease_owner)) or
            not is_nil(get_field(changeset, :lease_expires_at))) do
      add_error(changeset, :lease_owner, "must be absent for a terminal item")
    else
      changeset
    end
  end

  defp validate_resume_state(changeset) do
    state = get_field(changeset, :state)
    resume_state = get_field(changeset, :resume_state)

    resumable_states = [
      :queued,
      :awaiting_resolution,
      :staging_git,
      :git_staged,
      :staging_metadata,
      :ready_to_publish,
      :publishing
    ]

    cond do
      state == :awaiting_credential and resume_state not in resumable_states ->
        add_error(changeset, :resume_state, "is invalid for credential resumption")

      state != :awaiting_credential and not is_nil(resume_state) ->
        add_error(changeset, :resume_state, "must be absent outside credential wait")

      true ->
        changeset
    end
  end

  defp normalize_resume_state(changeset, current_state, :awaiting_credential),
    do: put_change(changeset, :resume_state, current_state)

  defp normalize_resume_state(changeset, :awaiting_credential, _target) do
    changeset
    |> put_change(:resume_state, nil)
    |> put_change(:wait_reason, nil)
    |> put_change(:next_attempt_at, nil)
  end

  defp normalize_resume_state(changeset, _current_state, _target),
    do: put_change(changeset, :resume_state, nil)

  defp coherent_resume_target?(%__MODULE__{state: :awaiting_credential} = item, target)
       when target not in [:cancel_requested, :canceled, :failed],
       do: target == item.resume_state

  defp coherent_resume_target?(_item, _target), do: true

  defp validate_conflict_fingerprint(changeset) do
    required_fields = [
      :replacement_repository_id,
      :replacement_owner_id,
      :replacement_storage_path,
      :replacement_generation,
      :replacement_write_version,
      :replacement_updated_at
    ]

    all_fields = [:replacement_last_pushed_at | required_fields]
    complete? = Enum.all?(required_fields, &(not is_nil(get_field(changeset, &1))))
    any_present? = Enum.any?(all_fields, &(not is_nil(get_field(changeset, &1))))

    cond do
      get_field(changeset, :conflict_action) == :replace and not complete? ->
        add_error(changeset, :conflict_action, "replacement fingerprint is incomplete")

      get_field(changeset, :conflict_action) != :replace and any_present? ->
        add_error(changeset, :conflict_action, "replacement fingerprint requires replace")

      true ->
        changeset
    end
  end

  defp validate_conflict_resolution(changeset) do
    action = get_field(changeset, :conflict_action)
    slug = get_field(changeset, :destination_slug)

    cond do
      action == :skip ->
        changeset

      action in [nil, :rename, :replace] and Repository.canonical_slug?(slug) ->
        changeset

      true ->
        add_error(changeset, :destination_slug, "is required for this decision")
    end
  end

  defp coherent_frozen_action?(%__MODULE__{conflict_action: nil}, :create), do: true
  defp coherent_frozen_action?(%__MODULE__{conflict_action: action}, action), do: true
  defp coherent_frozen_action?(_item, _action), do: false

  defp validate_repository_evidence(changeset) do
    changeset
    |> validate_change(:destination_slug, fn :destination_slug, slug ->
      if Repository.canonical_slug?(slug),
        do: [],
        else: [destination_slug: "must be a canonical repository slug"]
    end)
    |> validate_change(:replacement_storage_path, fn :replacement_storage_path, path ->
      if ForgeImports.SafeValue.safe_string?(path, 1_024, required?: true) and
           ForgeImports.SafeValue.github_secret_free?(path) and
           Storage.validate_relative_storage_path(path) == :ok,
         do: [],
         else: [replacement_storage_path: "must be a safe relative repository path"]
    end)
  end

  defp validate_staged_storage_path(changeset) do
    validate_change(changeset, :staged_storage_path, fn :staged_storage_path, path ->
      root = Fornacast.Config.repo_storage_root()
      expanded = if is_binary(path), do: Path.expand(path), else: nil

      if ForgeImports.SafeValue.safe_string?(path, 1_024, required?: true) and
           ForgeImports.SafeValue.github_secret_free?(path) and Path.type(path) == :absolute and
           expanded == path and String.starts_with?(path, root <> "/"),
         do: [],
         else: [staged_storage_path: "must be a contained absolute staging path"]
    end)
  end

  defp validate_cleanup_checkpoint(changeset) do
    validate_change(changeset, :checkpoint, fn :checkpoint, checkpoint ->
      case checkpoint do
        %{
          "cleanup_identity" => %{
            "mode" => 0o700,
            "major_device" => major_device,
            "minor_device" => minor_device,
            "inode" => inode
          }
        }
        when is_integer(major_device) and major_device >= 0 and is_integer(minor_device) and
               minor_device >= 0 and is_integer(inode) and inode > 0 ->
          []

        _invalid ->
          [checkpoint: "must contain exact cleanup identity evidence"]
      end
    end)
  end

  defp validate_cleanup_coherence(changeset) do
    cleanup_state = get_field(changeset, :cleanup_state)
    cleanup_error = get_field(changeset, :cleanup_error)
    cleanup_eligible_at = get_field(changeset, :cleanup_eligible_at)
    cleanup_attempt_count = get_field(changeset, :cleanup_attempt_count)
    checkpoint = get_field(changeset, :checkpoint) || %{}
    staged_path = get_field(changeset, :staged_storage_path)
    cleanup_identity? = valid_cleanup_identity?(Map.get(checkpoint, "cleanup_identity"))

    cond do
      is_nil(cleanup_state) and
          (not is_nil(cleanup_error) or not is_nil(cleanup_eligible_at) or
             cleanup_attempt_count != 0 or Map.has_key?(checkpoint, "cleanup_identity")) ->
        add_error(changeset, :cleanup_state, "is required for cleanup evidence")

      cleanup_state == "cleanup_pending" and
          (get_field(changeset, :state) != :staging_git or
             not is_integer(get_field(changeset, :hidden_repository_id)) or
             not is_binary(staged_path) or not cleanup_slot_name?(staged_path) or
             not ForgeImports.SafeValue.safe_string?(cleanup_error, 1_024,
               required?: true,
               classified?: true
             ) or not match?(%DateTime{}, cleanup_eligible_at) or
             not is_integer(cleanup_attempt_count) or cleanup_attempt_count < 0 or
             not cleanup_identity?) ->
        add_error(changeset, :cleanup_state, "has malformed cleanup evidence")

      cleanup_state not in [nil, "cleanup_pending"] ->
        add_error(changeset, :cleanup_state, "is invalid")

      true ->
        changeset
    end
  end

  defp valid_cleanup_identity?(%{
         "mode" => 0o700,
         "major_device" => major_device,
         "minor_device" => minor_device,
         "inode" => inode
       }) do
    is_integer(major_device) and major_device >= 0 and is_integer(minor_device) and
      minor_device >= 0 and is_integer(inode) and inode > 0
  end

  defp valid_cleanup_identity?(_identity), do: false

  defp cleanup_slot_name?(path) do
    Path.basename(path) =~ ~r/\A\.fornacast-cleanup-v1-[A-Za-z0-9_-]{43}\z/
  end

  defp validate_source_metadata(changeset) do
    validate_change(changeset, :source_metadata, fn :source_metadata, metadata ->
      cond do
        not is_map(metadata) ->
          [source_metadata: "must be a map"]

        map_size(metadata) > length(@source_metadata_keys) ->
          [source_metadata: "has too many entries"]

        encoded_size(metadata) > 8_192 ->
          [source_metadata: "is too large"]

        Enum.any?(Map.keys(metadata), &(to_string(&1) not in @source_metadata_keys)) ->
          [source_metadata: "contains unsupported keys"]

        not typed_source_metadata?(metadata) ->
          [source_metadata: "contains invalid values"]

        true ->
          []
      end
    end)
  end

  defp validate_maps(changeset) do
    Enum.reduce([:checkpoint, :source_git, :publication_evidence], changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        cond do
          not is_map(value) -> [{field, "must be a map"}]
          map_size(value) > 64 -> [{field, "has too many entries"}]
          encoded_size(value) > 32_768 -> [{field, "is too large"}]
          not ForgeImports.SafeValue.safe_nested?(value) -> [{field, "contains unsafe values"}]
          true -> []
        end
      end)
    end)
  end

  defp validate_publication_evidence_shape(changeset) do
    state = get_field(changeset, :state)
    evidence = get_field(changeset, :publication_evidence)
    item = changeset.data

    valid? =
      case state do
        :publishing ->
          valid_publication_intent?(evidence, item)

        state when state in [:published, :completed] ->
          valid_committed_publication?(evidence, item)

        _other ->
          true
      end

    if valid?,
      do: changeset,
      else: add_error(changeset, :publication_evidence, "is inconsistent with publication state")
  end

  defp valid_publication_intent?(evidence, item) do
    is_map(evidence) and exact_map_keys?(evidence, @publication_intent_keys) and
      evidence["version"] == 1 and evidence["state"] == "intent" and
      positive_integer?(evidence["attempt_number"]) and
      evidence["action"] in ["create", "rename", "replace"] and
      evidence["hidden_repository_id"] == item.hidden_repository_id and
      evidence["operation_id"] ==
        "github-import-publication-#{item.id}-#{evidence["attempt_number"]}" and
      canonical_request_metadata?(evidence["request_metadata"])
  end

  defp valid_committed_publication?(evidence, item) do
    valid_publication_intent?(
      Map.put(evidence || %{}, "state", "intent")
      |> Map.drop(@publication_committed_keys -- @publication_intent_keys),
      item
    ) and
      exact_map_keys?(evidence, @publication_committed_keys) and evidence["state"] == "committed" and
      evidence["repository_id"] == item.hidden_repository_id and
      positive_integer?(evidence["owner_user_id"]) and
      ForgeRepos.Repository.canonical_slug?(evidence["slug"]) and
      positive_integer?(evidence["generation"]) and
      (is_nil(evidence["replaced_repository_id"]) or
         positive_integer?(evidence["replaced_repository_id"])) and
      positive_integer?(evidence["run_id"]) and
      nonnegative_integer?(evidence["published_count_after"]) and
      positive_integer?(evidence["run_lock_version_after"])
  end

  defp canonical_request_metadata?(metadata) when is_map(metadata) do
    case ForgeAccounts.validate_github_request_metadata(metadata) do
      {:ok, normalized} -> Map.delete(normalized, "operation_id") == metadata
      {:error, :invalid_request_metadata} -> false
    end
  end

  defp canonical_request_metadata?(_metadata), do: false

  defp exact_map_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0

  defp validate_counts(changeset) do
    Enum.reduce(@count_fields, changeset, fn field, acc ->
      validate_number(acc, field, greater_than_or_equal_to: 0)
    end)
  end

  defp validate_strings(changeset) do
    changeset =
      [
        source_full_name: 512,
        source_name: 255,
        destination_slug: 255,
        replacement_storage_path: 1_024,
        staged_storage_path: 1_024
      ]
      |> Enum.reduce(changeset, fn {field, max}, acc -> validate_safe_string(acc, field, max) end)

    changeset =
      Enum.reduce(
        [wait_reason: 120, failure_kind: 120, cleanup_state: 120, cleanup_error: 1_024],
        changeset,
        fn {field, max}, acc -> validate_classified_string(acc, field, max) end
      )

    validate_change(changeset, :failure_detail, fn :failure_detail, value ->
      if ForgeImports.SafeValue.safe_string?(value, 1_024, classified?: true),
        do: [],
        else: [failure_detail: "contains unsafe detail"]
    end)
  end

  defp map_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:import_run_id)
    |> foreign_key_constraint(:predecessor_item_id)
    |> foreign_key_constraint(:hidden_repository_id)
    |> foreign_key_constraint(:destination_owner_id)
    |> unique_constraint([:import_run_id, :github_repository_id],
      name:
        ~r/^github_import_(?:items_run_repository|repository_items_\(import_run_id_github_repository_id\)(?: \(\d+\))?)_index$/,
      error_key: :github_repository_id
    )
    |> check_constraint(:state, name: :github_import_items_state_check)
    |> check_constraint(:state, name: :github_import_items_terminal_lease_check)
    |> check_constraint(:resume_state,
      name: :github_import_items_resume_state_coherence_check
    )
    |> check_constraint(:github_repository_id,
      name: :github_import_items_repository_id_positive_check
    )
    |> check_constraint(:replacement_write_version,
      name: :github_import_items_replacement_write_version_nonnegative_check
    )
  end

  defp validate_positive_id(changeset, field) do
    validate_number(changeset, field, greater_than: 0, less_than_or_equal_to: @max_id)
  end

  defp validate_safe_string(changeset, field, max) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not is_binary(value) -> [{field, "is invalid"}]
        :binary.match(value, <<0>>) != :nomatch -> [{field, "contains a NUL byte"}]
        String.length(value) > max -> [{field, "should be at most #{max} character(s)"}]
        true -> []
      end
    end)
  end

  defp validate_classified_string(changeset, field, max) do
    validate_change(changeset, field, fn ^field, value ->
      if ForgeImports.SafeValue.safe_string?(value, max, classified?: true),
        do: [],
        else: [{field, "contains unsafe classification"}]
    end)
  end

  defp typed_source_metadata?(metadata) do
    Enum.all?(metadata, fn {key, value} ->
      case to_string(key) do
        key when key in ~w(archived fork has_issues allow_merge_commit disabled) ->
          is_boolean(value)

        key when key in ~w(visibility default_branch description) ->
          is_nil(value) or
            valid_source_text?(key, value)

        key when key in ~w(updated_at pushed_at) ->
          is_nil(value) or valid_source_datetime?(value)

        _unsupported ->
          false
      end
    end)
  end

  defp valid_source_text?("visibility", value),
    do: value in ~w(public private internal)

  defp valid_source_text?("default_branch", value),
    do: ForgeImports.SafeValue.github_source_text?(value, 255, required?: true)

  defp valid_source_text?("description", value),
    do: ForgeImports.SafeValue.github_source_text?(value, 2_048)

  defp valid_source_datetime?(value) when is_binary(value) do
    match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp valid_source_datetime?(_value), do: false

  defp encoded_size(value), do: value |> :erlang.term_to_binary() |> byte_size()

  defp put_default_change(changeset, field, value) do
    if Map.has_key?(changeset.changes, field),
      do: changeset,
      else: put_change(changeset, field, value)
  end

  defp only_keys?(attrs, allowed) do
    Enum.all?(Map.keys(attrs), fn
      key when is_atom(key) -> key in allowed
      key when is_binary(key) -> Enum.any?(allowed, &(Atom.to_string(&1) == key))
      _ -> false
    end)
  end

  defp exact_fields?(updates, allowed) do
    Keyword.keyword?(updates) and updates != [] and
      length(Keyword.keys(updates)) == length(Enum.uniq(Keyword.keys(updates))) and
      Enum.all?(Keyword.keys(updates), &(&1 in allowed))
  end

  defp invalid_transition(item, message), do: item |> change() |> add_error(:state, message)
end
