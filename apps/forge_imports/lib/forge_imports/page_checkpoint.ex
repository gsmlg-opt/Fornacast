defmodule ForgeImports.PageCheckpoint do
  use Ecto.Schema

  import Ecto.Changeset

  @derive {Inspect, except: [:page_key, :etag, :cursor_metadata]}
  schema "github_import_page_checkpoints" do
    field :repository_item_id, :integer
    field :resource_kind, :string
    field :page_key, :string
    field :etag, :string
    field :observed_at, :utc_datetime
    field :item_count, :integer, default: 0
    field :cursor_metadata, :map, default: %{}
    field :committed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def create_changeset(checkpoint, attrs) when is_map(attrs) do
    checkpoint
    |> cast(attrs, [
      :repository_item_id,
      :resource_kind,
      :page_key,
      :etag,
      :observed_at,
      :item_count,
      :cursor_metadata,
      :committed_at
    ])
    |> validate_required([
      :repository_item_id,
      :resource_kind,
      :page_key,
      :item_count,
      :cursor_metadata,
      :committed_at
    ])
    |> validate_number(:repository_item_id, greater_than: 0)
    |> validate_number(:item_count, greater_than_or_equal_to: 0)
    |> validate_safe_string(:resource_kind, 120)
    |> validate_classified_string(:page_key, 512)
    |> validate_classified_string(:etag, 512)
    |> validate_cursor_metadata()
    |> foreign_key_constraint(:repository_item_id)
    |> unique_constraint([:repository_item_id, :resource_kind, :page_key],
      name:
        ~r/^github_import_(?:checkpoints_item_resource_page|page_checkpoints_\(repository_item_id_resource_kind_page_key\)(?: \(\d+\))?)_index$/,
      error_key: :page_key
    )
    |> check_constraint(:item_count, name: :github_import_checkpoints_item_count_check)
  end

  def create_changeset(checkpoint, _attrs),
    do: checkpoint |> change() |> add_error(:base, "is invalid")

  defp validate_cursor_metadata(changeset) do
    validate_change(changeset, :cursor_metadata, fn :cursor_metadata, value ->
      cond do
        not is_map(value) ->
          [cursor_metadata: "must be a map"]

        map_size(value) > 8 ->
          [cursor_metadata: "has too many entries"]

        Enum.any?(Map.keys(value), &(to_string(&1) not in ~w(cursor next_url))) ->
          [cursor_metadata: "contains unsupported keys"]

        Enum.any?(value, fn {key, cursor_value} ->
          not safe_cursor_value?(key, cursor_value)
        end) ->
          [cursor_metadata: "contains unsafe values"]

        byte_size(:erlang.term_to_binary(value)) > 4_096 ->
          [cursor_metadata: "is too large"]

        true ->
          []
      end
    end)
  end

  defp validate_safe_string(changeset, field, max) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not is_binary(value) -> [{field, "is invalid"}]
        String.trim(value) == "" -> [{field, "can't be blank"}]
        :binary.match(value, <<0>>) != :nomatch -> [{field, "contains a NUL byte"}]
        String.length(value) > max -> [{field, "should be at most #{max} character(s)"}]
        true -> []
      end
    end)
  end

  defp validate_classified_string(changeset, field, max) do
    validate_change(changeset, field, fn ^field, value ->
      if ForgeImports.SafeValue.safe_string?(value, max,
           required?: true,
           classified?: true
         ),
         do: [],
         else: [{field, "contains unsafe provenance"}]
    end)
  end

  defp safe_cursor_value?(_key, nil), do: true

  defp safe_cursor_value?(key, value)
       when (is_atom(key) or is_binary(key)) and is_binary(value),
       do: ForgeImports.SafeValue.safe_string?(value, 2_048, classified?: true)

  defp safe_cursor_value?(_key, _value), do: false
end
