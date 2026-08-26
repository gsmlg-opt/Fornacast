defmodule ForgeImports.ImportRun do
  use Ecto.Schema

  import Ecto.Changeset

  @states [
    :discovering,
    :awaiting_resolution,
    :ready,
    :running,
    :awaiting_credential,
    :cancel_requested,
    :completed,
    :completed_with_warnings,
    :canceled,
    :failed
  ]
  @terminal_states [:completed, :completed_with_warnings, :canceled, :failed]
  @source_kinds [:repository, :organization]
  @credential_sources [:saved, :one_time]
  @destination_actions [:new, :existing]
  @max_id 9_223_372_036_854_775_807
  @count_fields [
    :selected_count,
    :published_count,
    :skipped_count,
    :warning_count,
    :failure_count
  ]
  @transition_count_fields [
    :published_count,
    :skipped_count,
    :warning_count,
    :failure_count
  ]
  @source_metadata_keys ~w(name description avatar_url profile_url observed_at)
  @envelope_fields [
    :credential_ciphertext,
    :credential_nonce,
    :credential_tag,
    :credential_key_id
  ]
  @creation_fields [
    :predecessor_run_id,
    :source_kind,
    :github_identity_id,
    :credential_source,
    :github_credential_id,
    :source_owner_github_id,
    :source_owner_login,
    :source_repository_github_id,
    :source_repository_full_name,
    :destination_organization_action,
    :destination_organization_slug,
    :destination_organization_id,
    :request_metadata
  ]
  @transition_fields [
    :resume_state,
    :wait_reason,
    :next_attempt_at,
    :cancellation_requested_at,
    :terminal_at,
    :report_finalized_at,
    :failure_kind,
    :failure_detail
    | @transition_count_fields
  ]
  @discovery_completion_fields [
    :source_owner_github_id,
    :source_owner_login,
    :source_repository_github_id,
    :source_repository_full_name,
    :source_metadata,
    :selected_count
  ]
  @lease_fields [:state | @transition_fields]
  @discovery_lease_fields @lease_fields ++ @discovery_completion_fields
  @transitions %{
    discovering: [:awaiting_resolution, :failed, :canceled],
    awaiting_resolution: [:ready, :awaiting_credential, :canceled],
    ready: [:running, :awaiting_credential, :canceled],
    running: [
      :awaiting_credential,
      :cancel_requested,
      :completed,
      :completed_with_warnings,
      :failed
    ],
    awaiting_credential: [
      :awaiting_resolution,
      :ready,
      :running,
      :cancel_requested,
      :canceled
    ],
    cancel_requested: [:canceled, :completed, :completed_with_warnings]
  }

  @derive {Inspect,
           except:
             @envelope_fields ++
               [:request_metadata, :source_metadata, :failure_detail, :wait_reason, :failure_kind]}
  schema "github_import_runs" do
    field :actor_user_id, :integer
    field :predecessor_run_id, :integer
    field :source_kind, Ecto.Enum, values: @source_kinds
    field :github_identity_id, :integer
    field :credential_source, Ecto.Enum, values: @credential_sources
    field :github_credential_id, :integer
    field :source_owner_github_id, :integer
    field :source_owner_login, :string
    field :source_repository_github_id, :integer
    field :source_repository_full_name, :string
    field :source_metadata, :map, default: %{}
    field :destination_organization_action, Ecto.Enum, values: @destination_actions
    field :destination_organization_slug, :string
    field :destination_organization_id, :integer
    field :state, Ecto.Enum, values: @states, default: :discovering
    field :resume_state, Ecto.Enum, values: @states
    field :wait_reason, :string
    field :next_attempt_at, :utc_datetime
    field :cancellation_requested_at, :utc_datetime
    field :terminal_at, :utc_datetime
    field :report_finalized_at, :utc_datetime
    field :failure_kind, :string
    field :failure_detail, :string
    field :selected_count, :integer, default: 0
    field :published_count, :integer, default: 0
    field :skipped_count, :integer, default: 0
    field :warning_count, :integer, default: 0
    field :failure_count, :integer, default: 0
    field :request_metadata, :map, default: %{}
    field :credential_ciphertext, :binary, redact: true
    field :credential_nonce, :binary, redact: true
    field :credential_tag, :binary, redact: true
    field :credential_key_id, :string, redact: true
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def terminal_states, do: @terminal_states
  def transitions, do: @transitions

  def creation_changeset(%__MODULE__{id: nil} = run, actor_user_id, attrs)
      when is_integer(actor_user_id) and actor_user_id > 0 and is_map(attrs) do
    run
    |> cast(attrs, @creation_fields)
    |> put_change(:actor_user_id, actor_user_id)
    |> put_change(:state, :discovering)
    |> put_change(:resume_state, nil)
    |> put_change(:wait_reason, nil)
    |> put_change(:next_attempt_at, nil)
    |> put_change(:cancellation_requested_at, nil)
    |> put_change(:terminal_at, nil)
    |> put_change(:report_finalized_at, nil)
    |> put_change(:failure_kind, nil)
    |> put_change(:failure_detail, nil)
    |> put_change(:source_metadata, %{})
    |> put_change(:selected_count, 0)
    |> put_change(:published_count, 0)
    |> put_change(:skipped_count, 0)
    |> put_change(:warning_count, 0)
    |> put_change(:failure_count, 0)
    |> put_change(:credential_ciphertext, nil)
    |> put_change(:credential_nonce, nil)
    |> put_change(:credential_tag, nil)
    |> put_change(:credential_key_id, nil)
    |> put_change(:lease_owner, nil)
    |> put_change(:lease_expires_at, nil)
    |> put_change(:lock_version, 1)
    |> validate_persistence()
  end

  def creation_changeset(run, _actor_user_id, _attrs),
    do: run |> change() |> add_error(:base, "is invalid")

  def discovery_changeset(run, attrs) when is_map(attrs) do
    actor_user_id = Map.get(attrs, :actor_user_id) || Map.get(attrs, "actor_user_id")
    creation_changeset(run, actor_user_id, attrs)
  end

  def discovery_changeset(run, _attrs), do: run |> change() |> add_error(:base, "is invalid")

  @doc false
  def persistence_changeset(run, attrs) when is_map(attrs) do
    run
    |> cast(attrs, [
      :actor_user_id,
      :predecessor_run_id,
      :source_kind,
      :github_identity_id,
      :credential_source,
      :github_credential_id,
      :source_owner_github_id,
      :source_owner_login,
      :source_repository_github_id,
      :source_repository_full_name,
      :source_metadata,
      :destination_organization_action,
      :destination_organization_slug,
      :destination_organization_id,
      :state,
      :resume_state,
      :wait_reason,
      :next_attempt_at,
      :cancellation_requested_at,
      :terminal_at,
      :report_finalized_at,
      :failure_kind,
      :failure_detail,
      :selected_count,
      :published_count,
      :skipped_count,
      :warning_count,
      :failure_count,
      :request_metadata,
      :credential_ciphertext,
      :credential_nonce,
      :credential_tag,
      :credential_key_id,
      :lock_version
    ])
    |> validate_persistence()
  end

  def persistence_changeset(run, _attrs), do: run |> change() |> add_error(:base, "is invalid")

  defp validate_persistence(changeset) do
    changeset
    |> validate_required([
      :actor_user_id,
      :source_kind,
      :github_identity_id,
      :credential_source,
      :source_owner_login,
      :source_metadata,
      :state,
      :request_metadata,
      :lock_version
    ])
    |> validate_inclusion(:source_kind, @source_kinds)
    |> validate_inclusion(:credential_source, @credential_sources)
    |> validate_inclusion(:destination_organization_action, @destination_actions)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:resume_state, @states)
    |> validate_positive_id(:actor_user_id)
    |> validate_positive_id(:predecessor_run_id)
    |> validate_positive_id(:github_identity_id)
    |> validate_positive_id(:github_credential_id)
    |> validate_positive_id(:source_owner_github_id)
    |> validate_positive_id(:source_repository_github_id)
    |> validate_positive_id(:destination_organization_id)
    |> validate_counts()
    |> validate_number(:lock_version, greater_than: 0)
    |> validate_strings()
    |> validate_request_metadata()
    |> validate_source_metadata()
    |> validate_source_shape()
    |> validate_credential_consistency()
    |> validate_envelope()
    |> validate_lifecycle()
    |> validate_resume_state()
    |> map_constraints()
  end

  def transition_changeset(run, target, attrs) when is_atom(target) and is_map(attrs) do
    build_transition_changeset(run, target, attrs, clear_lease?: true)
  end

  def transition_changeset(run, _target, _attrs), do: invalid_transition(run, "is invalid")

  @doc false
  def snapshot_selection_changeset(
        %__MODULE__{state: :discovering} = run,
        selected_count,
        attrs
      )
      when is_integer(selected_count) and selected_count >= 0 and is_map(attrs) do
    run
    |> build_transition_changeset(:awaiting_resolution, attrs, clear_lease?: true)
    |> put_change(:selected_count, selected_count)
    |> validate_number(:selected_count, greater_than_or_equal_to: 0)
  end

  def snapshot_selection_changeset(run, _selected_count, _attrs),
    do: invalid_transition(run, "is not a discovery review snapshot")

  def selected_count_changeset(%__MODULE__{state: :awaiting_resolution} = run, count)
      when is_integer(count) and count >= 0 do
    run
    |> change(selected_count: count)
    |> validate_number(:selected_count, greater_than_or_equal_to: 0)
  end

  def selected_count_changeset(run, _count),
    do: run |> change() |> add_error(:selected_count, "is frozen")

  def destination_changeset(
        %__MODULE__{state: :awaiting_resolution, source_kind: :organization} = run,
        attrs
      )
      when is_map(attrs) do
    run
    |> cast(attrs, [
      :destination_organization_action,
      :destination_organization_slug,
      :destination_organization_id
    ])
    |> validate_required([:destination_organization_action])
    |> validate_inclusion(:destination_organization_action, @destination_actions)
    |> validate_positive_id(:destination_organization_id)
    |> validate_strings()
    |> map_constraints()
  end

  def destination_changeset(run, _attrs),
    do: run |> change() |> add_error(:state, "cannot change the destination")

  defp build_transition_changeset(run, target, attrs, options) do
    cond do
      run.state in @terminal_states ->
        invalid_transition(run, "terminal runs are immutable")

      target not in Map.get(@transitions, run.state, []) ->
        invalid_transition(run, "is not an allowed transition")

      not coherent_resume_target?(run, target) ->
        invalid_transition(run, "does not match the persisted resume state")

      not only_keys?(attrs, @transition_fields) ->
        invalid_transition(run, "contains immutable fields")

      true ->
        run
        |> cast(attrs, @transition_fields)
        |> put_change(:state, target)
        |> validate_inclusion(:resume_state, @states)
        |> validate_counts()
        |> validate_strings()
        |> normalize_resume_state(run.state, target)
        |> maybe_mark_terminal(target, Keyword.fetch!(options, :clear_lease?))
        |> validate_lifecycle()
        |> validate_resume_state()
        |> map_constraints()
    end
  end

  def clear_one_time_credential_changeset(run) do
    change(run,
      credential_ciphertext: nil,
      credential_nonce: nil,
      credential_tag: nil,
      credential_key_id: nil
    )
  end

  def one_time_credential_changeset(
        %__MODULE__{credential_source: :one_time, state: state} = run,
        attrs
      )
      when state not in @terminal_states and is_map(attrs) do
    run
    |> cast(attrs, @envelope_fields)
    |> validate_credential_consistency()
    |> validate_envelope()
    |> map_constraints()
  end

  def one_time_credential_changeset(run, _attrs) do
    run
    |> change()
    |> add_error(:credential_source, "cannot attach a one-time credential")
  end

  def lease_update_changeset(run, updates) when is_list(updates) do
    cond do
      discovery_completion?(run, updates) and exact_fields?(updates, @discovery_lease_fields) ->
        build_discovery_completion_changeset(run, updates)

      not exact_fields?(updates, @lease_fields) ->
        run |> change() |> add_error(:base, "contains immutable fields")

      Keyword.has_key?(updates, :state) ->
        target = Keyword.fetch!(updates, :state)

        build_transition_changeset(
          run,
          target,
          updates |> Keyword.delete(:state) |> Map.new(),
          clear_lease?: false
        )

      run.state in @terminal_states ->
        invalid_transition(run, "terminal runs are immutable")

      true ->
        run
        |> cast(Map.new(updates), @transition_fields)
        |> validate_inclusion(:resume_state, @states)
        |> validate_counts()
        |> validate_strings()
        |> validate_lifecycle()
        |> validate_resume_state()
    end
  end

  def lease_update_changeset(run, _updates), do: run |> change() |> add_error(:base, "is invalid")

  defp discovery_completion?(%__MODULE__{state: :discovering}, updates),
    do: Keyword.get(updates, :state) == :awaiting_resolution

  defp discovery_completion?(_run, _updates), do: false

  defp build_discovery_completion_changeset(run, updates) do
    attrs = Map.new(updates)
    source_attrs = Map.take(attrs, @discovery_completion_fields)
    transition_attrs = attrs |> Map.drop(@discovery_completion_fields) |> Map.delete(:state)

    run
    |> build_transition_changeset(:awaiting_resolution, transition_attrs, clear_lease?: false)
    |> cast(source_attrs, @discovery_completion_fields)
    |> validate_required([:source_owner_github_id, :source_owner_login, :source_metadata])
    |> validate_positive_id(:source_owner_github_id)
    |> validate_positive_id(:source_repository_github_id)
    |> validate_counts()
    |> validate_strings()
    |> validate_source_metadata()
    |> validate_source_shape()
    |> map_constraints()
  end

  defp maybe_mark_terminal(changeset, target, clear_lease?) when target in @terminal_states do
    changeset
    |> put_change(:terminal_at, get_field(changeset, :terminal_at) || DateTime.utc_now(:second))
    |> put_change(:credential_ciphertext, nil)
    |> put_change(:credential_nonce, nil)
    |> put_change(:credential_tag, nil)
    |> put_change(:credential_key_id, nil)
    |> put_change(:wait_reason, nil)
    |> put_change(:next_attempt_at, nil)
    |> maybe_clear_lease(clear_lease?)
  end

  defp maybe_mark_terminal(changeset, _target, _clear_lease?),
    do: put_change(changeset, :terminal_at, nil)

  defp maybe_clear_lease(changeset, true) do
    changeset
    |> put_change(:lease_owner, nil)
    |> put_change(:lease_expires_at, nil)
  end

  defp maybe_clear_lease(changeset, false) do
    changeset
    |> put_change(:lease_owner, nil)
    |> put_change(:lease_expires_at, nil)
  end

  defp validate_credential_consistency(changeset) do
    source = get_field(changeset, :credential_source)
    state = get_field(changeset, :state)
    saved_id = get_field(changeset, :github_credential_id)
    envelope = Enum.map(@envelope_fields, &get_field(changeset, &1))
    all_absent? = Enum.all?(envelope, &is_nil/1)
    all_present? = Enum.all?(envelope, &(not is_nil(&1)))

    cond do
      source == :saved and is_nil(saved_id) and
          state not in [:awaiting_credential | @terminal_states] ->
        add_error(changeset, :github_credential_id, "is required for saved credentials")

      source == :saved and not all_absent? ->
        add_error(changeset, :credential_source, "saved credentials cannot carry an envelope")

      source == :one_time and not is_nil(saved_id) ->
        add_error(changeset, :github_credential_id, "must be absent for one-time credentials")

      source == :one_time and not (all_absent? or all_present?) ->
        add_error(changeset, :credential_source, "one-time envelope is incomplete")

      true ->
        changeset
    end
  end

  defp validate_envelope(changeset) do
    changeset
    |> validate_binary_size(:credential_ciphertext, 1, 4_096)
    |> validate_binary_size(:credential_nonce, 12, 12)
    |> validate_binary_size(:credential_tag, 16, 16)
    |> validate_binary_size(:credential_key_id, 1, 255)
  end

  defp validate_lifecycle(changeset) do
    state = get_field(changeset, :state)
    terminal_at = get_field(changeset, :terminal_at)
    lease_owner = get_field(changeset, :lease_owner)
    lease_expires_at = get_field(changeset, :lease_expires_at)

    cond do
      state in @terminal_states and is_nil(terminal_at) ->
        add_error(changeset, :terminal_at, "is required for a terminal run")

      state not in @terminal_states and not is_nil(terminal_at) ->
        add_error(changeset, :terminal_at, "must be absent before terminal")

      state in @terminal_states and (not is_nil(lease_owner) or not is_nil(lease_expires_at)) ->
        add_error(changeset, :lease_owner, "must be absent for a terminal run")

      true ->
        changeset
    end
  end

  defp validate_resume_state(changeset) do
    state = get_field(changeset, :state)
    resume_state = get_field(changeset, :resume_state)

    cond do
      state == :awaiting_credential and
          resume_state not in [:awaiting_resolution, :ready, :running] ->
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

  defp coherent_resume_target?(%__MODULE__{state: :awaiting_credential} = run, target)
       when target not in [:cancel_requested, :canceled],
       do: target == run.resume_state

  defp coherent_resume_target?(_run, _target), do: true

  defp validate_source_shape(changeset) do
    kind = get_field(changeset, :source_kind)
    state = get_field(changeset, :state)
    owner_id = get_field(changeset, :source_owner_github_id)
    repository_id = get_field(changeset, :source_repository_github_id)
    full_name = get_field(changeset, :source_repository_full_name)
    provisional? = state in [:discovering, :failed]

    cond do
      kind == :repository and blank?(full_name) ->
        add_error(changeset, :source_repository_full_name, "repository source is incomplete")

      kind == :repository and not provisional? and (is_nil(owner_id) or is_nil(repository_id)) ->
        add_error(
          changeset,
          :source_repository_github_id,
          "verified repository source is required"
        )

      kind == :organization and (not is_nil(repository_id) or not is_nil(full_name)) ->
        add_error(
          changeset,
          :source_repository_full_name,
          "must be absent for organization source"
        )

      kind == :organization and not provisional? and is_nil(owner_id) ->
        add_error(changeset, :source_owner_github_id, "verified organization source is required")

      true ->
        changeset
    end
  end

  defp validate_counts(changeset) do
    Enum.reduce(@count_fields, changeset, fn field, acc ->
      validate_number(acc, field, greater_than_or_equal_to: 0)
    end)
  end

  defp validate_strings(changeset) do
    changeset =
      [
        source_owner_login: 255,
        source_repository_full_name: 512,
        destination_organization_slug: 255
      ]
      |> Enum.reduce(changeset, fn {field, max}, acc -> validate_safe_string(acc, field, max) end)

    changeset =
      Enum.reduce([wait_reason: 120, failure_kind: 120], changeset, fn {field, max}, acc ->
        validate_classified_string(acc, field, max)
      end)

    validate_change(changeset, :failure_detail, fn :failure_detail, value ->
      if ForgeImports.SafeValue.safe_string?(value, 1_024, classified?: true),
        do: [],
        else: [failure_detail: "contains unsafe detail"]
    end)
  end

  defp validate_request_metadata(changeset) do
    validate_change(changeset, :request_metadata, fn :request_metadata, metadata ->
      case ForgeAccounts.GitHubRequestMetadata.validate(metadata) do
        {:ok, normalized} when normalized == metadata ->
          if Enum.all?(normalized, &safe_request_metadata_field?/1),
            do: [],
            else: [request_metadata: "contains unsafe values"]

        _ ->
          [request_metadata: "contains unsafe values"]
      end
    end)
  end

  defp safe_request_metadata_field?({"request_id", value}),
    do: ForgeImports.SafeValue.safe_string?(value, 255, required?: true, classified?: true)

  defp safe_request_metadata_field?({"operation_id", value}),
    do: ForgeImports.SafeValue.safe_string?(value, 255, required?: true, classified?: true)

  defp safe_request_metadata_field?({"ip_address", value}),
    do: ForgeImports.SafeValue.safe_string?(value, 64, required?: true, classified?: true)

  defp safe_request_metadata_field?({"user_agent", value}),
    do: ForgeImports.SafeValue.safe_string?(value, 2_048, required?: true, classified?: true)

  defp safe_request_metadata_field?(_field), do: false

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

        not valid_source_metadata?(metadata) ->
          [source_metadata: "contains unsafe values"]

        true ->
          []
      end
    end)
  end

  defp valid_source_metadata?(metadata) do
    ForgeAccounts.GitHubProfileSafety.validate(metadata) == :ok and
      Enum.all?(metadata, fn {key, value} ->
        case to_string(key) do
          key when key in ["name", "description"] ->
            is_nil(value) or ForgeImports.SafeValue.github_source_text?(value, 2_048)

          "avatar_url" ->
            is_nil(value) or trusted_url?(value, ["avatars.githubusercontent.com", "github.com"])

          "profile_url" ->
            is_nil(value) or trusted_url?(value, ["github.com"])

          "observed_at" ->
            valid_source_observed_at?(value)

          _ ->
            false
        end
      end)
  end

  defp trusted_url?(value, hosts) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, port: port}}
      when is_binary(host) and port in [nil, 443] ->
        String.downcase(host) in hosts

      _invalid ->
        false
    end
  end

  defp trusted_url?(_value, _hosts), do: false

  defp valid_source_observed_at?(value) when is_binary(value),
    do: match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))

  defp valid_source_observed_at?(_value), do: false

  defp map_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:actor_user_id)
    |> foreign_key_constraint(:predecessor_run_id)
    |> foreign_key_constraint(:github_identity_id)
    |> foreign_key_constraint(:github_credential_id)
    |> foreign_key_constraint(:destination_organization_id)
    |> check_constraint(:source_kind, name: :github_import_runs_source_kind_check)
    |> check_constraint(:source_owner_github_id,
      name: :github_import_runs_verified_source_check
    )
    |> check_constraint(:credential_source, name: :github_import_runs_credential_source_check)
    |> check_constraint(:credential_source,
      name: :github_import_runs_credential_consistency_check
    )
    |> check_constraint(:state, name: :github_import_runs_state_check)
    |> check_constraint(:state, name: :github_import_runs_terminal_envelope_check)
    |> check_constraint(:state, name: :github_import_runs_terminal_at_check)
    |> check_constraint(:state, name: :github_import_runs_terminal_lease_check)
    |> check_constraint(:resume_state,
      name: :github_import_runs_resume_state_coherence_check
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

  defp validate_binary_size(changeset, field, min, max) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and byte_size(value) in min..max,
        do: [],
        else: [{field, "has invalid byte size"}]
    end)
  end

  defp validate_classified_string(changeset, field, max) do
    validate_change(changeset, field, fn ^field, value ->
      if ForgeImports.SafeValue.safe_string?(value, max, classified?: true),
        do: [],
        else: [{field, "contains unsafe classification"}]
    end)
  end

  defp encoded_size(value), do: value |> :erlang.term_to_binary() |> byte_size()
  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp only_keys?(attrs, allowed) do
    Enum.all?(Map.keys(attrs), fn key -> normalize_key(key) in allowed end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key),
    do: Enum.find(@lease_fields, &(Atom.to_string(&1) == key))

  defp normalize_key(_key), do: nil

  defp exact_fields?(updates, allowed) do
    Keyword.keyword?(updates) and updates != [] and
      length(Keyword.keys(updates)) == length(Enum.uniq(Keyword.keys(updates))) and
      Enum.all?(Keyword.keys(updates), &(&1 in allowed))
  end

  defp invalid_transition(run, message), do: run |> change() |> add_error(:state, message)
end
