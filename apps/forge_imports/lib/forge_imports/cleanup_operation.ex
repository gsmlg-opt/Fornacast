defmodule ForgeImports.CleanupOperation do
  use Ecto.Schema

  import Ecto.Changeset

  alias Fornacast.Storage

  @states [:cleanup_pending, :cleanup_blocked, :cleanup_complete]
  @terminal_states [:cleanup_blocked, :cleanup_complete]
  @kinds [:remote_quarantine, :unpublished_shadow, :replacement_tombstone]
  @outcome_keys ~w(root_identity anchored_identity anchored_absence)
  @create_fields [
    :repository_id,
    :repository_item_id,
    :source_lock_version,
    :kind,
    :operation_id,
    :evidence,
    :eligible_at,
    :next_attempt_at
  ]
  @lease_mutable_fields [
    :state,
    :evidence,
    :next_attempt_at,
    :attempt_count,
    :last_error,
    :effect_started_at,
    :effect_finished_at,
    :completed_at
  ]

  @replacement_keys ~w(
    version kind repository_id repository_generation repository_write_version
    repository_storage_path repository_deleted_at repository_updated_at item_id
    item_lock_version attempt_number attempt_decision attempt_fingerprint
    publication_operation_id publication_marker new_repository_id
    new_repository_generation publication_audit_id
  )
  @unpublished_keys ~w(
    version kind repository_id repository_generation repository_write_version
    repository_storage_path repository_updated_at item_id item_lock_version item_state
    run_id run_state attempt_number attempt_state attempt_decision attempt_fingerprint
    publication_evidence predecessor_item_id successor_item_id adopter_item_id
  )
  @remote_keys ~w(
    version kind repository_id repository_generation repository_storage_path item_id
    item_lock_version requested_path quarantine_path mode major_device minor_device inode
    remote_failure_kind
  )
  @committed_marker_keys ~w(
    version state attempt_number action hidden_repository_id operation_id request_metadata
    repository_id owner_user_id slug generation replaced_repository_id run_id
    published_count_after run_lock_version_after
  )
  @terminal_item_states ~w(completed skipped canceled failed published)
  @terminal_run_states ~w(completed completed_with_warnings canceled failed)
  @terminal_attempt_states ~w(completed failed canceled destination_changed)

  @derive {Inspect, except: [:evidence, :last_error]}
  schema "github_import_repository_cleanups" do
    field :repository_id, :integer
    field :repository_item_id, :integer
    field :source_lock_version, :integer
    field :kind, Ecto.Enum, values: @kinds
    field :state, Ecto.Enum, values: @states, default: :cleanup_pending
    field :operation_id, :string
    field :evidence, :map
    field :eligible_at, :utc_datetime
    field :next_attempt_at, :utc_datetime
    field :attempt_count, :integer, default: 0
    field :last_error, :string, redact: true
    field :effect_started_at, :utc_datetime
    field :effect_finished_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :lock_version, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def states, do: @states
  def terminal_states, do: @terminal_states
  def kinds, do: @kinds

  def deterministic_operation_id(kind, repository_id, item_id, source_lock_version)
      when kind in @kinds and is_integer(repository_id) and repository_id > 0 and
             is_integer(item_id) and item_id > 0 and is_integer(source_lock_version) and
             source_lock_version > 0 do
    "github-import-cleanup:#{kind}:#{repository_id}:#{item_id}:#{source_lock_version}"
  end

  def deterministic_operation_id(_kind, _repository_id, _item_id, _source_lock_version),
    do: nil

  def attempt_fingerprint(item_id, attempt_number, decision)
      when is_integer(item_id) and item_id > 0 and is_integer(attempt_number) and
             attempt_number > 0 and is_map(decision) do
    sha256({item_id, attempt_number, decision})
  end

  def attempt_fingerprint(_item_id, _attempt_number, _decision), do: nil

  def root_projection(storage_root, identity)
      when is_binary(storage_root) and is_map(identity) do
    sha256({:fornacast_cleanup_root, 1, storage_root, identity})
  end

  def path_projection(storage_root, relative_segments, identity)
      when is_binary(storage_root) and is_list(relative_segments) and is_map(identity) do
    sha256({:fornacast_cleanup_path, 1, storage_root, relative_segments, identity})
  end

  def create_changeset(%__MODULE__{id: nil} = operation, attrs) when is_map(attrs) do
    operation
    |> cast(attrs, @create_fields)
    |> reject_unknown_attrs(attrs, @create_fields)
    |> put_change(:state, :cleanup_pending)
    |> put_change(:attempt_count, 0)
    |> put_change(:last_error, nil)
    |> put_change(:effect_started_at, nil)
    |> put_change(:effect_finished_at, nil)
    |> put_change(:completed_at, nil)
    |> put_change(:lease_owner, nil)
    |> put_change(:lease_expires_at, nil)
    |> put_change(:lock_version, 0)
    |> validate_contract()
    |> unique_constraint(:operation_id)
    |> unique_constraint([:repository_item_id, :kind, :source_lock_version],
      name: :github_import_cleanups_item_kind_version_index
    )
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:repository_item_id)
  end

  def create_changeset(operation, _attrs),
    do: operation |> change() |> add_error(:base, "is invalid")

  def lease_update_changeset(%__MODULE__{} = operation, updates) when is_list(updates) do
    if exact_update_fields?(updates) do
      operation
      |> cast(Map.new(updates), @lease_mutable_fields)
      |> validate_enrichment_immutable(operation)
      |> validate_transition(operation)
      |> validate_contract()
    else
      operation |> change() |> add_error(:base, "contains immutable fields")
    end
  end

  def lease_update_changeset(operation, _updates),
    do: operation |> change() |> add_error(:base, "is invalid")

  defp validate_contract(changeset) do
    changeset
    |> validate_required([
      :repository_id,
      :repository_item_id,
      :source_lock_version,
      :kind,
      :state,
      :operation_id,
      :evidence,
      :eligible_at,
      :attempt_count,
      :lock_version
    ])
    |> validate_number(:repository_id, greater_than: 0)
    |> validate_number(:repository_item_id, greater_than: 0)
    |> validate_number(:source_lock_version, greater_than: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:lock_version, greater_than_or_equal_to: 0)
    |> validate_operation_id()
    |> validate_error()
    |> validate_evidence()
    |> validate_lifecycle()
  end

  defp validate_operation_id(changeset) do
    expected =
      deterministic_operation_id(
        get_field(changeset, :kind),
        get_field(changeset, :repository_id),
        get_field(changeset, :repository_item_id),
        get_field(changeset, :source_lock_version)
      )

    if is_binary(expected) and get_field(changeset, :operation_id) == expected,
      do: changeset,
      else: add_error(changeset, :operation_id, "does not match cleanup identity")
  end

  defp validate_error(changeset) do
    validate_change(changeset, :last_error, fn :last_error, value ->
      if ForgeImports.SafeValue.safe_string?(value, 120, classified?: true),
        do: [],
        else: [last_error: "contains unsafe classification"]
    end)
  end

  defp validate_evidence(changeset) do
    if valid_evidence?(changeset, get_field(changeset, :evidence)),
      do: changeset,
      else: add_error(changeset, :evidence, "is invalid")
  end

  defp valid_evidence?(changeset, evidence) when is_map(evidence) do
    kind = get_field(changeset, :kind)
    base_keys = base_keys(kind)

    exact_evidence_keys?(evidence, base_keys) and
      evidence["version"] == 1 and evidence["kind"] == Atom.to_string(kind) and
      evidence["repository_id"] == get_field(changeset, :repository_id) and
      evidence["item_id"] == get_field(changeset, :repository_item_id) and
      evidence["item_lock_version"] == get_field(changeset, :source_lock_version) and
      valid_base_evidence?(kind, evidence) and valid_outcome?(changeset, evidence)
  end

  defp valid_evidence?(_changeset, _evidence), do: false

  defp valid_base_evidence?(:remote_quarantine, evidence) do
    positive?(evidence["repository_generation"]) and
      valid_path?(evidence["repository_storage_path"]) and
      valid_path?(evidence["requested_path"]) and valid_path?(evidence["quarantine_path"]) and
      nonnegative?(evidence["mode"]) and nonnegative?(evidence["major_device"]) and
      nonnegative?(evidence["minor_device"]) and positive?(evidence["inode"]) and
      classified?(evidence["remote_failure_kind"])
  end

  defp valid_base_evidence?(:unpublished_shadow, evidence) do
    positive?(evidence["repository_generation"]) and
      nonnegative?(evidence["repository_write_version"]) and
      valid_path?(evidence["repository_storage_path"]) and
      timestamp?(evidence["repository_updated_at"]) and
      evidence["item_state"] in @terminal_item_states and positive?(evidence["run_id"]) and
      evidence["run_state"] in @terminal_run_states and positive?(evidence["attempt_number"]) and
      evidence["attempt_state"] in @terminal_attempt_states and
      valid_attempt_decision?(evidence) and
      evidence["attempt_fingerprint"] ==
        attempt_fingerprint(
          evidence["item_id"],
          evidence["attempt_number"],
          evidence["attempt_decision"]
        ) and
      evidence["publication_evidence"] == %{} and
      Enum.all?(~w(predecessor_item_id successor_item_id adopter_item_id), fn key ->
        is_nil(evidence[key]) or positive?(evidence[key])
      end)
  end

  defp valid_base_evidence?(:replacement_tombstone, evidence) do
    marker = evidence["publication_marker"]

    positive?(evidence["repository_generation"]) and
      nonnegative?(evidence["repository_write_version"]) and
      valid_path?(evidence["repository_storage_path"]) and
      timestamp?(evidence["repository_deleted_at"]) and
      timestamp?(evidence["repository_updated_at"]) and
      positive?(evidence["attempt_number"]) and valid_attempt_decision?(evidence) and
      evidence["attempt_fingerprint"] ==
        attempt_fingerprint(
          evidence["item_id"],
          evidence["attempt_number"],
          evidence["attempt_decision"]
        ) and
      valid_committed_marker?(marker) and
      evidence["publication_operation_id"] == marker["operation_id"] and
      evidence["new_repository_id"] == marker["repository_id"] and
      evidence["new_repository_generation"] == marker["generation"] and
      marker["attempt_number"] == evidence["attempt_number"] and
      marker["action"] == evidence["attempt_decision"]["action"] and
      positive?(evidence["publication_audit_id"])
  end

  defp valid_base_evidence?(_kind, _evidence), do: false

  defp valid_committed_marker?(marker) when is_map(marker) do
    Map.keys(marker) |> Enum.sort() == Enum.sort(@committed_marker_keys) and
      marker["version"] == 1 and marker["state"] == "committed" and
      positive?(marker["attempt_number"]) and marker["action"] in ~w(create rename replace) and
      positive?(marker["hidden_repository_id"]) and safe_text?(marker["operation_id"], 255) and
      is_map(marker["request_metadata"]) and positive?(marker["repository_id"]) and
      positive?(marker["owner_user_id"]) and safe_text?(marker["slug"], 63) and
      positive?(marker["generation"]) and
      (is_nil(marker["replaced_repository_id"]) or positive?(marker["replaced_repository_id"])) and
      positive?(marker["run_id"]) and nonnegative?(marker["published_count_after"]) and
      positive?(marker["run_lock_version_after"])
  end

  defp valid_committed_marker?(_marker), do: false

  defp valid_outcome?(changeset, evidence) do
    started? = not is_nil(get_field(changeset, :effect_started_at))
    root = Map.get(evidence, "root_identity")
    target = Map.get(evidence, "anchored_identity")
    absence = Map.get(evidence, "anchored_absence")

    if started? do
      (valid_identity?(root) and valid_identity?(target) and is_nil(absence)) or
        (is_nil(root) and is_nil(target) and
           not is_nil(get_field(changeset, :effect_finished_at)) and
           valid_absence?(changeset, evidence, absence))
    else
      is_nil(root) and is_nil(target) and is_nil(absence)
    end
  end

  defp valid_absence?(changeset, evidence, absence) when is_map(absence) do
    identity = absence["root_identity"]
    relative_path = cleanup_relative_path(evidence)
    storage_root = cleanup_storage_root()
    observed_at = parse_timestamp(absence["observed_at"])
    started_at = get_field(changeset, :effect_started_at)
    finished_at = get_field(changeset, :effect_finished_at)

    Map.keys(absence) |> Enum.sort() ==
      Enum.sort(~w(version observed_at root_identity root_projection path_projection)) and
      absence["version"] == 1 and match?(%DateTime{}, observed_at) and
      DateTime.compare(started_at, observed_at) in [:lt, :eq] and
      DateTime.compare(observed_at, finished_at) in [:lt, :eq] and valid_identity?(identity) and
      absence["root_projection"] == root_projection(storage_root, atom_identity(identity)) and
      absence["path_projection"] ==
        path_projection(storage_root, Path.split(relative_path), atom_identity(identity))
  end

  defp valid_absence?(_changeset, _evidence, _absence), do: false

  defp valid_identity?(identity) when is_map(identity) do
    Map.keys(identity) |> Enum.sort() == Enum.sort(~w(mode major_device minor_device inode)) and
      nonnegative?(identity["mode"]) and nonnegative?(identity["major_device"]) and
      nonnegative?(identity["minor_device"]) and positive?(identity["inode"])
  end

  defp valid_identity?(_identity), do: false

  defp validate_lifecycle(changeset) do
    state = get_field(changeset, :state)
    next_attempt_at = get_field(changeset, :next_attempt_at)
    last_error = get_field(changeset, :last_error)
    started = get_field(changeset, :effect_started_at)
    finished = get_field(changeset, :effect_finished_at)
    completed = get_field(changeset, :completed_at)
    owner = get_field(changeset, :lease_owner)
    expires = get_field(changeset, :lease_expires_at)

    valid? =
      paired?(owner, expires) and ordered?(started, finished, completed) and
        case state do
          :cleanup_pending ->
            not is_nil(next_attempt_at) and is_nil(completed)

          :cleanup_blocked ->
            classified?(last_error) and is_nil(owner) and is_nil(next_attempt_at) and
              is_nil(completed)

          :cleanup_complete ->
            is_nil(owner) and is_nil(next_attempt_at) and is_nil(last_error) and
              match?(%DateTime{}, started) and match?(%DateTime{}, finished) and
              match?(%DateTime{}, completed)

          _ ->
            false
        end

    if valid?,
      do: changeset,
      else: add_error(changeset, :state, "has inconsistent lifecycle fields")
  end

  defp validate_transition(changeset, operation) do
    target = get_field(changeset, :state)

    cond do
      operation.state != :cleanup_pending -> add_error(changeset, :state, "is terminal")
      target not in @states -> add_error(changeset, :state, "is invalid")
      true -> changeset
    end
  end

  defp validate_enrichment_immutable(changeset, operation) do
    case fetch_change(changeset, :evidence) do
      {:ok, evidence} when is_map(evidence) ->
        old_base = Map.drop(operation.evidence || %{}, @outcome_keys)
        new_base = Map.drop(evidence, @outcome_keys)
        old_outcome = Map.take(operation.evidence || %{}, @outcome_keys)
        new_outcome = Map.take(evidence, @outcome_keys)

        if old_base == new_base and (old_outcome == %{} or old_outcome == new_outcome),
          do: changeset,
          else: add_error(changeset, :evidence, "changes immutable cleanup evidence")

      {:ok, _invalid} ->
        add_error(changeset, :evidence, "is invalid")

      :error ->
        changeset
    end
  end

  defp exact_update_fields?(updates) do
    Keyword.keyword?(updates) and updates != [] and
      length(Keyword.keys(updates)) == length(Enum.uniq(Keyword.keys(updates))) and
      Enum.all?(Keyword.keys(updates), &(&1 in @lease_mutable_fields))
  end

  defp reject_unknown_attrs(changeset, attrs, allowed) do
    allowed_strings = Enum.map(allowed, &Atom.to_string/1)

    if Enum.all?(Map.keys(attrs), fn key -> key in allowed or key in allowed_strings end),
      do: changeset,
      else: add_error(changeset, :base, "contains unsupported fields")
  end

  defp exact_evidence_keys?(evidence, base_keys) do
    keys = Map.keys(evidence)

    Enum.sort(keys) in [
      Enum.sort(base_keys),
      Enum.sort(base_keys ++ ~w(root_identity anchored_identity)),
      Enum.sort(base_keys ++ ~w(anchored_absence))
    ]
  end

  defp base_keys(:remote_quarantine), do: @remote_keys
  defp base_keys(:unpublished_shadow), do: @unpublished_keys
  defp base_keys(:replacement_tombstone), do: @replacement_keys
  defp base_keys(_kind), do: []

  defp cleanup_relative_path(%{"kind" => "remote_quarantine", "quarantine_path" => path}),
    do: path

  defp cleanup_relative_path(%{"repository_storage_path" => path}), do: path
  defp cleanup_relative_path(_evidence), do: ""

  defp cleanup_storage_root do
    Application.get_env(:fornacast, :repo_storage_root, "tmp/repos") |> Path.expand()
  end

  defp atom_identity(identity) do
    %{
      mode: identity["mode"],
      major_device: identity["major_device"],
      minor_device: identity["minor_device"],
      inode: identity["inode"]
    }
  end

  defp ordered?(nil, nil, nil), do: true
  defp ordered?(%DateTime{}, nil, nil), do: true

  defp ordered?(%DateTime{} = started, %DateTime{} = finished, nil),
    do: DateTime.compare(started, finished) in [:lt, :eq]

  defp ordered?(%DateTime{} = started, %DateTime{} = finished, %DateTime{} = completed),
    do:
      DateTime.compare(started, finished) in [:lt, :eq] and
        DateTime.compare(finished, completed) in [:lt, :eq]

  defp ordered?(_started, _finished, _completed), do: false

  defp paired?(nil, nil), do: true
  defp paired?(owner, %DateTime{}) when is_binary(owner) and owner != "", do: true
  defp paired?(_owner, _expires), do: false

  defp valid_path?(value) do
    safe_text?(value, 1_024) and ForgeImports.SafeValue.github_secret_free?(value) and
      Storage.validate_relative_storage_path(value) == :ok
  end

  defp classified?(value),
    do: ForgeImports.SafeValue.safe_string?(value, 120, classified?: true)

  defp safe_text?(value, max),
    do: ForgeImports.SafeValue.safe_string?(value, max, required?: true)

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))

  defp timestamp?(_value), do: false

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> DateTime.truncate(datetime, :second)
      _invalid -> nil
    end
  end

  defp parse_timestamp(_value), do: nil

  defp valid_attempt_decision?(evidence) do
    %ForgeImports.ImportAttempt{}
    |> ForgeImports.ImportAttempt.create_changeset(%{
      repository_item_id: evidence["item_id"],
      attempt_number: evidence["attempt_number"],
      state: :running,
      decision: evidence["attempt_decision"],
      started_at: ~U[2000-01-01 00:00:00Z]
    })
    |> Map.fetch!(:valid?)
  end

  defp positive?(value), do: is_integer(value) and value > 0
  defp nonnegative?(value), do: is_integer(value) and value >= 0

  defp sha256(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
  end
end
