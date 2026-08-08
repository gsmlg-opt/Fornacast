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
    |> validate_number(:lock_version, greater_than_or_equal_to: 0)
    |> unique_constraint([:request_id, :kind, :target_ref],
      name: :git_write_operations_request_ref_index
    )
  end

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

  defp canonical_full_ref?(ref) when is_binary(ref) do
    components = String.split(ref, "/")

    String.starts_with?(ref, "refs/") and
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
