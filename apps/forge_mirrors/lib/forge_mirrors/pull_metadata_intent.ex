defmodule ForgeMirrors.PullMetadataIntent do
  @moduledoc "Immutable full metadata effect evidence referenced by compact operation markers."
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(operation_id repository_mirror_id pull_id issue_id local_version sequence payload)a
  schema "mirror_pull_metadata_intents" do
    field :operation_id, :integer
    field :repository_mirror_id, :integer
    field :pull_id, :integer
    field :issue_id, :integer
    field :local_version, :integer
    field :sequence, :integer
    field :payload, :map
    field :payload_fingerprint, :string
    timestamps(type: :utc_datetime)
  end

  # Payload semantics and leased scope are validated by the admission boundary.
  # Hash the retained payload here; never accept a caller's claimed fingerprint.
  def create_changeset(intent, attrs) do
    changeset = intent |> cast(attrs, @fields) |> validate_required(@fields)

    changeset =
      Enum.reduce(@fields -- [:payload], changeset, fn field, acc ->
        validate_number(acc, field, greater_than: 0)
      end)

    payload = get_field(changeset, :payload)

    changeset =
      if is_map(payload) and byte_size(JSON.encode!(payload)) <= 2_000_000 do
        case ForgeMirrors.resource_fingerprint(payload) do
          {:ok, fingerprint} -> put_change(changeset, :payload_fingerprint, fingerprint)
          {:error, _} -> add_error(changeset, :payload, "must be canonical JSON evidence")
        end
      else
        add_error(changeset, :payload, "must be an object of at most 2000000 encoded bytes")
      end

    changeset =
      changeset
      |> unique_constraint([:operation_id, :sequence])
      |> foreign_key_constraint(:operation_id)
      |> foreign_key_constraint(:repository_mirror_id)
      |> foreign_key_constraint(:pull_id)
      |> foreign_key_constraint(:issue_id)
      |> check_constraint(:payload, name: :mirror_pull_metadata_intents_payload_check)
      |> check_constraint(:sequence, name: :mirror_pull_metadata_intents_versions_check)

    if intent.__meta__.state == :loaded and map_size(changeset.changes) > 0,
      do: add_error(changeset, :payload, "metadata intent is immutable"),
      else: changeset
  end
end
