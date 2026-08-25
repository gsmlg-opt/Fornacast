defmodule ForgeImports.ReportEntry do
  use Ecto.Schema

  import Ecto.Changeset

  @scopes [:run, :repository, :object]
  @outcomes [:imported, :skipped, :warning, :failed, :canceled, :not_selected]
  @metadata_keys MapSet.new(~w(
                   code field phase state count github_id category expected actual visibility
                 ))
  @max_id 9_223_372_036_854_775_807

  @derive {Inspect,
           except: [:idempotency_key, :object_kind, :classification, :summary, :metadata]}
  schema "github_import_report_entries" do
    field :import_run_id, :integer
    field :repository_item_id, :integer
    field :idempotency_key, :string
    field :scope, Ecto.Enum, values: @scopes
    field :object_kind, :string
    field :source_object_id, :integer
    field :outcome, Ecto.Enum, values: @outcomes
    field :classification, :string
    field :summary, :string
    field :metadata, :map, default: %{}
    field :source_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def create_changeset(entry, attrs) when is_map(attrs) do
    entry
    |> cast(attrs, [
      :import_run_id,
      :repository_item_id,
      :idempotency_key,
      :scope,
      :object_kind,
      :source_object_id,
      :outcome,
      :classification,
      :summary,
      :metadata,
      :source_count
    ])
    |> validate_required([
      :import_run_id,
      :idempotency_key,
      :scope,
      :outcome,
      :classification,
      :summary,
      :metadata,
      :source_count
    ])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_positive_id(:import_run_id)
    |> validate_positive_id(:repository_item_id)
    |> validate_positive_id(:source_object_id)
    |> validate_number(:source_count, greater_than_or_equal_to: 0)
    |> validate_classified_string(:idempotency_key, 255)
    |> validate_optional_classified_string(:object_kind, 120)
    |> validate_classified_string(:classification, 120)
    |> validate_classified_string(:summary, 500)
    |> validate_scope_shape()
    |> validate_metadata()
    |> foreign_key_constraint(:import_run_id)
    |> foreign_key_constraint(:repository_item_id,
      name: :github_import_reports_item_run_fkey
    )
    |> unique_constraint([:import_run_id, :idempotency_key],
      name:
        ~r/^github_import_(?:reports_run_idempotency|report_entries_\(import_run_id_idempotency_key\)(?: \(\d+\))?)_index$/,
      error_key: :idempotency_key
    )
    |> check_constraint(:scope, name: :github_import_reports_scope_check)
    |> check_constraint(:outcome, name: :github_import_reports_outcome_check)
  end

  def create_changeset(entry, _attrs), do: entry |> change() |> add_error(:base, "is invalid")

  defp validate_scope_shape(changeset) do
    scope = get_field(changeset, :scope)
    item_id = get_field(changeset, :repository_item_id)
    object_kind = get_field(changeset, :object_kind)
    object_id = get_field(changeset, :source_object_id)

    cond do
      scope == :run and (not is_nil(item_id) or not is_nil(object_kind) or not is_nil(object_id)) ->
        add_error(changeset, :scope, "run entries cannot identify a repository or object")

      scope == :repository and
          (is_nil(item_id) or not is_nil(object_kind) or not is_nil(object_id)) ->
        add_error(
          changeset,
          :scope,
          "repository entries require only a repository item"
        )

      scope == :object and (is_nil(item_id) or is_nil(object_kind) or is_nil(object_id)) ->
        add_error(changeset, :scope, "object entry is incomplete")

      true ->
        changeset
    end
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      cond do
        not is_map(metadata) ->
          [metadata: "must be a map"]

        map_size(metadata) > MapSet.size(@metadata_keys) ->
          [metadata: "has too many entries"]

        byte_size(:erlang.term_to_binary(metadata)) > 8_192 ->
          [metadata: "is too large"]

        Enum.any?(metadata, fn {key, _value} -> not allowed_metadata_key?(key) end) ->
          [metadata: "contains unsupported keys"]

        Enum.any?(metadata, fn {_key, value} ->
          not ForgeImports.SafeValue.report_value?(value)
        end) ->
          [metadata: "contains unsafe values"]

        true ->
          []
      end
    end)
  end

  defp allowed_metadata_key?(key) when is_atom(key) or is_binary(key),
    do: MapSet.member?(@metadata_keys, to_string(key))

  defp allowed_metadata_key?(_key), do: false

  defp validate_positive_id(changeset, field) do
    validate_number(changeset, field, greater_than: 0, less_than_or_equal_to: @max_id)
  end

  defp validate_classified_string(changeset, field, max) do
    validate_change(changeset, field, fn ^field, value ->
      if ForgeImports.SafeValue.safe_string?(value, max,
           required?: true,
           classified?: true
         ),
         do: [],
         else: [{field, "contains unsafe detail"}]
    end)
  end

  defp validate_optional_classified_string(changeset, field, max) do
    validate_change(changeset, field, fn ^field, value ->
      if ForgeImports.SafeValue.safe_string?(value, max,
           required?: true,
           classified?: true
         ),
         do: [],
         else: [{field, "contains unsafe detail"}]
    end)
  end
end
