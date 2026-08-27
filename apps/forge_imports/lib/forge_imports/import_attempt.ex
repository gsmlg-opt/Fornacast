defmodule ForgeImports.ImportAttempt do
  use Ecto.Schema

  import Ecto.Changeset

  alias ForgeRepos.Repository
  alias Fornacast.Storage

  @states [:running, :completed, :failed, :canceled, :destination_changed]
  @terminal_states [:completed, :failed, :canceled, :destination_changed]

  @derive {Inspect, except: [:decision, :failure_kind]}
  schema "github_import_attempts" do
    field :repository_item_id, :integer
    field :attempt_number, :integer
    field :state, Ecto.Enum, values: @states
    field :decision, :map, default: %{}
    field :started_at, :utc_datetime
    field :terminal_at, :utc_datetime
    field :failure_kind, :string

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  def create_changeset(%__MODULE__{id: nil} = attempt, attrs) when is_map(attrs) do
    attempt
    |> cast(attrs, [
      :repository_item_id,
      :attempt_number,
      :state,
      :decision,
      :started_at,
      :terminal_at,
      :failure_kind
    ])
    |> update_change(:decision, &normalize_decision/1)
    |> validate_required([:repository_item_id, :attempt_number, :state, :decision, :started_at])
    |> validate_number(:repository_item_id, greater_than: 0)
    |> validate_number(:attempt_number, greater_than: 0)
    |> validate_inclusion(:state, @states)
    |> validate_failure_kind()
    |> validate_decision()
    |> validate_terminal_fields()
    |> foreign_key_constraint(:repository_item_id)
    |> unique_constraint([:repository_item_id, :attempt_number],
      name:
        ~r/^github_import_attempts_(?:item_number|\(repository_item_id_attempt_number\)(?: \(\d+\))?)_index$/,
      error_key: :attempt_number
    )
    |> check_constraint(:state, name: :github_import_attempts_state_check)
    |> check_constraint(:terminal_at, name: :github_import_attempts_terminal_at_check)
  end

  def create_changeset(attempt, _attrs), do: attempt |> change() |> add_error(:base, "is invalid")

  def transition_changeset(attempt, target, attrs \\ %{})

  def transition_changeset(%__MODULE__{state: :running} = attempt, target, attrs)
      when target in @terminal_states and is_map(attrs) do
    attempt
    |> cast(attrs, [:terminal_at, :failure_kind])
    |> put_change(:state, target)
    |> put_change(
      :terminal_at,
      get_field(attempt |> cast(attrs, [:terminal_at]), :terminal_at) || DateTime.utc_now(:second)
    )
    |> validate_failure_kind()
    |> validate_terminal_fields()
  end

  def transition_changeset(attempt, _target, _attrs),
    do: attempt |> change() |> add_error(:state, "is not an allowed transition")

  defp validate_terminal_fields(changeset) do
    state = get_field(changeset, :state)
    terminal_at = get_field(changeset, :terminal_at)

    cond do
      state in @terminal_states and is_nil(terminal_at) ->
        add_error(changeset, :terminal_at, "is required for a terminal attempt")

      state == :running and not is_nil(terminal_at) ->
        add_error(changeset, :terminal_at, "must be absent while running")

      true ->
        changeset
    end
  end

  defp validate_decision(changeset) do
    validate_change(changeset, :decision, fn :decision, decision ->
      cond do
        not is_map(decision) -> [decision: "must be a map"]
        map_size(decision) > 32 -> [decision: "has too many entries"]
        byte_size(:erlang.term_to_binary(decision)) > 16_384 -> [decision: "is too large"]
        not valid_decision?(decision) -> [decision: "is not an approved immutable decision"]
        true -> []
      end
    end)
  end

  defp validate_failure_kind(changeset) do
    validate_change(changeset, :failure_kind, fn :failure_kind, value ->
      if ForgeImports.SafeValue.safe_string?(value, 120, classified?: true),
        do: [],
        else: [failure_kind: "contains unsafe classification"]
    end)
  end

  defp normalize_decision(decision) when is_map(decision) do
    Map.new(decision, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, normalize_decision_value(key, value)}
    end)
  end

  defp normalize_decision(decision), do: decision

  defp normalize_decision_value(key, %DateTime{} = value)
       when key in ["replacement_updated_at", "replacement_last_pushed_at"],
       do: DateTime.to_iso8601(value)

  defp normalize_decision_value(key, %NaiveDateTime{} = value)
       when key in ["replacement_updated_at", "replacement_last_pushed_at"],
       do: NaiveDateTime.to_iso8601(value)

  defp normalize_decision_value(_key, value), do: value

  defp valid_decision?(%{"action" => "skip"} = decision),
    do: exact_keys?(decision, ~w(action))

  defp valid_decision?(%{"action" => "create", "slug" => slug} = decision),
    do: exact_keys?(decision, ~w(action slug)) and valid_slug?(slug)

  defp valid_decision?(%{"action" => "rename", "slug" => slug} = decision),
    do: exact_keys?(decision, ~w(action slug)) and valid_slug?(slug)

  defp valid_decision?(
         %{
           "action" => "replace",
           "slug" => slug,
           "replacement_repository_id" => repository_id,
           "replacement_owner_id" => owner_id,
           "replacement_storage_path" => storage_path,
           "replacement_generation" => generation,
           "replacement_write_version" => write_version,
           "replacement_updated_at" => updated_at,
           "replacement_last_pushed_at" => last_pushed_at
         } = decision
       ) do
    exact_keys?(decision, [
      "action",
      "slug",
      "replacement_repository_id",
      "replacement_owner_id",
      "replacement_storage_path",
      "replacement_generation",
      "replacement_write_version",
      "replacement_updated_at",
      "replacement_last_pushed_at"
    ]) and valid_slug?(slug) and positive_id?(repository_id) and positive_id?(owner_id) and
      positive_id?(generation) and nonnegative_integer?(write_version) and
      valid_storage_path?(storage_path) and
      valid_timestamp?(updated_at) and valid_optional_timestamp?(last_pushed_at)
  end

  defp valid_decision?(_decision), do: false

  defp exact_keys?(decision, expected),
    do: Map.keys(decision) |> Enum.sort() == Enum.sort(expected)

  defp valid_slug?(slug) do
    ForgeImports.SafeValue.github_source_text?(slug, 63, required?: true) and
      Repository.canonical_slug?(slug)
  end

  defp positive_id?(value), do: is_integer(value) and value > 0
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0

  defp valid_storage_path?(value) do
    ForgeImports.SafeValue.safe_string?(value, 1_024, required?: true) and
      ForgeImports.SafeValue.github_secret_free?(value) and
      Storage.validate_relative_storage_path(value) == :ok
  end

  defp valid_optional_timestamp?(nil), do: true
  defp valid_optional_timestamp?(value), do: valid_timestamp?(value)

  defp valid_timestamp?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) or
      match?({:ok, _naive}, NaiveDateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false
end
