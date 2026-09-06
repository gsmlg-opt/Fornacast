defmodule GitLFS.PointerScanner.Scan do
  use Ecto.Schema

  import Ecto.Changeset

  @states [:scanning, :complete, :prepared, :published]

  @type t :: %__MODULE__{}

  schema "lfs_pointer_scans" do
    field(:repository_id, :integer)
    field(:repository_generation, :integer)
    field(:scan_key, :string)
    field(:baseline_fingerprint, :string)
    field(:state, Ecto.Enum, values: @states, default: :scanning)
    field(:batch_limit, :integer)
    field(:completed_at, :utc_datetime)
    field(:published_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def creation_changeset(scan, attrs) do
    scan
    |> cast(attrs, [
      :repository_id,
      :repository_generation,
      :scan_key,
      :baseline_fingerprint,
      :batch_limit
    ])
    |> put_change(:state, :scanning)
    |> put_change(:completed_at, nil)
    |> put_change(:published_at, nil)
    |> validate_required([
      :repository_id,
      :repository_generation,
      :scan_key,
      :baseline_fingerprint,
      :state,
      :batch_limit
    ])
    |> validate_number(:repository_id, greater_than: 0)
    |> validate_number(:repository_generation, greater_than: 0)
    |> validate_length(:scan_key, min: 1, max: 255, count: :bytes)
    |> validate_length(:baseline_fingerprint, is: 64)
    |> validate_format(:baseline_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:batch_limit, greater_than_or_equal_to: 1, less_than_or_equal_to: 200)
    |> unique_constraint([:repository_id, :scan_key])
    |> foreign_key_constraint(:repository_id)
  end

  @doc false
  def completion_changeset(scan, completed_at) do
    scan
    |> change(state: :complete, completed_at: completed_at)
    |> validate_required([:state, :completed_at])
  end

  @doc false
  def publication_changeset(scan, published_at, state \\ :published) do
    scan
    |> change(state: state, published_at: published_at)
    |> validate_required([:state, :completed_at, :published_at])
  end
end
