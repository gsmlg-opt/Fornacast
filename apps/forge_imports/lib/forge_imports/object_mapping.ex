defmodule ForgeImports.ObjectMapping do
  use Ecto.Schema

  import Ecto.Changeset

  @max_id 9_223_372_036_854_775_807

  @derive {Inspect, except: [:source_url]}
  schema "github_import_object_mappings" do
    field :repository_item_id, :integer
    field :hidden_repository_id, :integer
    field :github_repository_id, :integer
    field :object_kind, :string
    field :github_object_id, :integer
    field :local_resource_type, :string
    field :local_resource_id, :integer
    field :source_url, :string

    timestamps(type: :utc_datetime)
  end

  def create_changeset(mapping, attrs) when is_map(attrs) do
    mapping
    |> cast(attrs, [
      :repository_item_id,
      :hidden_repository_id,
      :github_repository_id,
      :object_kind,
      :github_object_id,
      :local_resource_type,
      :local_resource_id,
      :source_url
    ])
    |> validate_required([
      :repository_item_id,
      :hidden_repository_id,
      :github_repository_id,
      :object_kind,
      :github_object_id,
      :local_resource_type,
      :local_resource_id
    ])
    |> validate_positive_id(:repository_item_id)
    |> validate_positive_id(:hidden_repository_id)
    |> validate_positive_id(:github_repository_id)
    |> validate_positive_id(:github_object_id)
    |> validate_positive_id(:local_resource_id)
    |> validate_safe_string(:object_kind, 120)
    |> validate_safe_string(:local_resource_type, 255)
    |> validate_classified_string(:source_url, 2_048)
    |> foreign_key_constraint(:repository_item_id)
    |> foreign_key_constraint(:hidden_repository_id)
    |> unique_constraint(
      [:hidden_repository_id, :github_repository_id, :object_kind, :github_object_id],
      name:
        ~r/^github_import_(?:mappings_source_object|object_mappings_\(hidden_repository_id_github_repository_id_object_kind_github_object_id\)(?: \(\d+\))?)_index$/,
      error_key: :github_object_id
    )
    |> check_constraint(:github_repository_id,
      name: :github_import_mappings_repository_id_positive_check
    )
    |> check_constraint(:github_object_id,
      name: :github_import_mappings_object_id_positive_check
    )
  end

  def create_changeset(mapping, _attrs), do: mapping |> change() |> add_error(:base, "is invalid")

  defp validate_positive_id(changeset, field) do
    validate_number(changeset, field, greater_than: 0, less_than_or_equal_to: @max_id)
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
end
