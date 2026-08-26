defmodule ForgeRepos.GitWriteOperation do
  use Ecto.Schema

  import Ecto.Changeset

  @kinds [
    :ref_create,
    :ref_update,
    :content_create,
    :content_update,
    :content_delete,
    :receive_pack
  ]
  @states [:prepared, :object_written, :ref_advanced, :bookkeeping_complete, :failed]
  @failure_reasons ~w(effect_not_started ref_not_advanced unexpected_ref)
  @oid_regex ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @max_target_ref_bytes 255
  @lease_mutable_fields [:state, :failure_reason, :result_blob_oid]
  @transitions %{
    prepared: [:object_written, :failed],
    object_written: [:ref_advanced, :failed],
    ref_advanced: [:bookkeeping_complete]
  }

  @type t :: %__MODULE__{}

  schema "git_write_operations" do
    field :repository_id, :integer
    field :actor_user_id, :integer
    field :request_id, :string
    field :kind, Ecto.Enum, values: @kinds
    field :state, Ecto.Enum, values: @states
    field :target_ref, :string
    field :expected_oid, :string
    field :proposed_oid, :string
    field :result_blob_oid, :string
    field :failure_reason, :string
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :lock_version, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :repository_id,
      :actor_user_id,
      :request_id,
      :kind,
      :state,
      :target_ref,
      :expected_oid,
      :proposed_oid,
      :result_blob_oid,
      :failure_reason,
      :lease_owner,
      :lease_expires_at,
      :lock_version
    ])
    |> normalize_oid(:expected_oid)
    |> normalize_oid(:proposed_oid)
    |> normalize_oid(:result_blob_oid)
    |> validate_required([:repository_id, :request_id, :kind, :state, :target_ref, :proposed_oid])
    |> validate_oid(:expected_oid)
    |> validate_oid(:proposed_oid)
    |> validate_oid(:result_blob_oid)
    |> validate_target_ref()
    |> validate_inclusion(:failure_reason, @failure_reasons)
    |> validate_initial_lifecycle()
    |> validate_number(:lock_version, greater_than_or_equal_to: 0)
    |> unique_constraint([:request_id, :kind, :target_ref],
      # WORKAROUND(upstream): gsmlg-dev/concord#83
      name: request_ref_constraint()
    )
  end

  def lease_update_changeset(operation, updates) when is_list(updates) do
    if exact_fields?(updates, @lease_mutable_fields) do
      operation
      |> cast(Map.new(updates), @lease_mutable_fields)
      |> normalize_oid(:result_blob_oid)
      |> validate_oid(:result_blob_oid)
      |> validate_inclusion(:failure_reason, @failure_reasons)
      |> reject_explicit_nil(:result_blob_oid)
      |> validate_lease_transition()
      |> validate_failure_reason_transition(operation)
      |> validate_result_blob_update(operation)
      |> validate_effective_transition_values(operation)
    else
      operation |> change() |> add_error(:base, "contains immutable fields")
    end
  end

  def lease_update_changeset(operation, _updates),
    do: operation |> change() |> add_error(:base, "is invalid")

  defp normalize_oid(changeset, field) do
    update_change(changeset, field, fn
      oid when is_binary(oid) -> String.downcase(oid)
      oid -> oid
    end)
  end

  defp validate_oid(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and Regex.match?(@oid_regex, value),
        do: [],
        else: [{field, "is invalid"}]
    end)
  end

  defp validate_target_ref(changeset) do
    validate_change(changeset, :target_ref, fn :target_ref, ref ->
      if canonical_full_ref?(ref), do: [], else: [target_ref: "is not a canonical full ref"]
    end)
  end

  defp validate_initial_lifecycle(changeset) do
    kind = get_field(changeset, :kind)
    state = get_field(changeset, :state)
    oid = get_field(changeset, :result_blob_oid)
    reason = get_field(changeset, :failure_reason)
    content? = kind in [:content_create, :content_update]

    changeset
    |> validate_initial_result(content?, state, oid, reason)
    |> validate_initial_failure(state, reason)
  end

  defp validate_initial_result(changeset, true, state, oid, reason) do
    oid_required? =
      state in [:object_written, :ref_advanced, :bookkeeping_complete] or
        (state == :failed and reason == "ref_not_advanced")

    oid_forbidden? =
      state == :prepared or (state == :failed and reason == "effect_not_started")

    cond do
      oid_required? and not valid_oid?(oid) ->
        add_error(changeset, :result_blob_oid, "is required for this lifecycle state")

      oid_forbidden? and oid != nil ->
        add_error(changeset, :result_blob_oid, "is not valid for this lifecycle state")

      true ->
        changeset
    end
  end

  defp validate_initial_result(changeset, false, _state, nil, _reason), do: changeset

  defp validate_initial_result(changeset, false, _state, _oid, _reason),
    do: add_error(changeset, :result_blob_oid, "is not valid for this operation kind")

  defp validate_initial_failure(changeset, :failed, reason)
       when reason in ["effect_not_started", "ref_not_advanced"],
       do: changeset

  defp validate_initial_failure(changeset, :failed, _reason),
    do: add_error(changeset, :failure_reason, "is invalid for terminal failure")

  defp validate_initial_failure(changeset, state, reason)
       when state in [:prepared, :object_written, :ref_advanced] and
              reason in [nil, "unexpected_ref"],
       do: changeset

  defp validate_initial_failure(changeset, _state, nil), do: changeset

  defp validate_initial_failure(changeset, _state, _reason),
    do: add_error(changeset, :failure_reason, "is invalid for this lifecycle state")

  defp reject_explicit_nil(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, nil} -> add_error(changeset, field, "cannot be cleared")
      _ -> changeset
    end
  end

  defp validate_lease_transition(changeset) do
    case fetch_change(changeset, :state) do
      {:ok, target} ->
        source = changeset.data.state

        changeset =
          if target in Map.get(@transitions, source, []),
            do: changeset,
            else: add_error(changeset, :state, "is not a valid lease transition")

        if target == :failed do
          validate_required(changeset, [:failure_reason])
        else
          changeset
        end

      :error ->
        changeset
    end
  end

  defp validate_result_blob_update(changeset, operation) do
    if get_change(changeset, :result_blob_oid) != nil do
      cond do
        operation.kind not in [:content_create, :content_update] ->
          add_error(changeset, :result_blob_oid, "is not valid for this operation kind")

        operation.result_blob_oid != nil ->
          add_error(changeset, :result_blob_oid, "is already recorded")

        operation.state != :prepared or
            get_change(changeset, :state) not in [nil, :object_written] ->
          add_error(changeset, :result_blob_oid, "is not valid in this transition")

        true ->
          changeset
      end
    else
      changeset
    end
  end

  defp validate_failure_reason_transition(changeset, operation) do
    case fetch_change(changeset, :failure_reason) do
      {:ok, reason} ->
        valid? =
          operation.failure_reason == nil and
            case reason do
              "effect_not_started" ->
                operation.state == :prepared and get_change(changeset, :state) == :failed

              "ref_not_advanced" ->
                operation.state == :object_written and get_change(changeset, :state) == :failed

              "unexpected_ref" ->
                operation.state in [:prepared, :object_written, :ref_advanced] and
                  get_change(changeset, :state) == nil

              _ ->
                false
            end

        if valid?, do: changeset, else: add_error(changeset, :failure_reason, "is invalid here")

      :error ->
        changeset
    end
  end

  defp validate_effective_transition_values(changeset, operation) do
    case get_change(changeset, :state) do
      :object_written when operation.kind in [:content_create, :content_update] ->
        if valid_oid?(get_field(changeset, :result_blob_oid)) do
          changeset
        else
          add_error(changeset, :result_blob_oid, "is required for object_written")
        end

      :failed ->
        expected_reason =
          case operation.state do
            :prepared -> "effect_not_started"
            :object_written -> "ref_not_advanced"
            _ -> nil
          end

        if expected_reason != nil and get_field(changeset, :failure_reason) == expected_reason do
          changeset
        else
          add_error(changeset, :failure_reason, "is invalid for terminal failure")
        end

      _state ->
        changeset
    end
  end

  defp valid_oid?(oid), do: is_binary(oid) and Regex.match?(@oid_regex, oid)

  defp exact_fields?(updates, allowed) do
    keys = Keyword.keys(updates)
    keys != [] and length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in allowed))
  end

  defp request_ref_constraint do
    ~r/^git_write_operations_(?:request_ref|request_id_kind_target_ref|\(request_id_kind_target_ref\))(?: \(\d+\))?_index$/
  end

  defp canonical_full_ref?(ref) when is_binary(ref) do
    components = String.split(ref, "/")

    byte_size(ref) <= @max_target_ref_bytes and String.starts_with?(ref, "refs/") and
      byte_size(ref) > byte_size("refs/") and
      not String.ends_with?(ref, "/") and
      not String.ends_with?(ref, ".") and
      not String.ends_with?(ref, ".lock") and
      not String.contains?(ref, ["//", "..", "@{", "\\"]) and
      not String.match?(ref, ~r/[\x00-\x20\x7f~^:?*\[]/) and
      Enum.all?(components, &(&1 not in ["", ".", ".."] and not String.starts_with?(&1, ".")))
  end

  defp canonical_full_ref?(_ref), do: false
end
