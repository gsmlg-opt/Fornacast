defmodule ForgeMirrors.PullCreationIntent do
  @moduledoc "Immutable desired snapshots for one outbound pull creation attempt."
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(operation_id repository_mirror_id repository_id pull_id issue_id local_version creation_uuid payload payload_fingerprint)a
  schema "mirror_pull_creation_intents" do
    field :operation_id, :integer
    field :repository_mirror_id, :integer
    field :repository_id, :integer
    field :pull_id, :integer
    field :issue_id, :integer
    field :local_version, :integer
    field :creation_uuid, Ecto.UUID
    field :payload, :map
    field :payload_fingerprint, :string
    timestamps(type: :utc_datetime)
  end

  def create_changeset(intent, attrs) do
    changeset =
      intent
      |> cast(attrs, @fields)
      |> validate_required(@fields)
      |> validate_number(:local_version, greater_than: 0)
      |> validate_format(:payload_fingerprint, ~r/\A[0-9a-f]{64}\z/)
      |> validate_change(:payload, fn :payload, value ->
        if is_map(value) and byte_size(JSON.encode!(value)) <= 2_000_000,
          do: [],
          else: [payload: "must be an object of at most 2000000 encoded bytes"]
      end)
      |> unique_constraint(:operation_id)
      |> unique_constraint([:repository_mirror_id, :pull_id])
      |> unique_constraint(:creation_uuid)
      |> check_constraint(:payload, name: :mirror_pull_creation_intents_payload_check)
      |> check_constraint(:local_version, name: :mirror_pull_creation_intents_version_check)

    if intent.__meta__.state == :loaded and map_size(changeset.changes) > 0,
      do: add_error(changeset, :payload, "creation intent is immutable"),
      else: changeset
  end
end
