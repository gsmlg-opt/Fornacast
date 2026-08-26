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
  @visibilities [:private, :public]
  @conflict_actions [:skip, :rename, :replace]
  @max_id 9_223_372_036_854_775_807
  @count_fields [:imported_count, :skipped_count, :warning_count, :failure_count]
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
    publishing: [:published, :awaiting_credential, :cancel_requested, :failed],
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
    |> validate_number(:lock_version, greater_than: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:cleanup_attempt_count, greater_than_or_equal_to: 0)
    |> validate_counts()
    |> validate_strings()
    |> validate_repository_evidence()
    |> validate_maps()
    |> validate_source_metadata()
    |> validate_conflict_fingerprint()
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
        |> validate_maps()
        |> normalize_resume_state(item.state, target)
        |> maybe_clear_terminal_lease(target, Keyword.fetch!(options, :clear_lease?))
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
        |> validate_maps()
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
