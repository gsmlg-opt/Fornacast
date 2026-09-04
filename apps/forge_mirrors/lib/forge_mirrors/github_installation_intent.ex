defmodule ForgeMirrors.GitHubInstallationIntent do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @states [:pending, :callback_received, :completed, :cancelled, :expired]
  @setup_actions [:install, :update]

  schema "github_installation_intents" do
    field :organization_mirror_id, :integer
    field :organization_id, :integer
    field :actor_user_id, :integer
    field :state_digest, :binary, redact: true
    field :github_installation_id, :integer
    field :setup_action, Ecto.Enum, values: @setup_actions
    field :state, Ecto.Enum, values: @states, default: :pending
    field :expires_at, :utc_datetime
    field :callback_received_at, :utc_datetime
    field :confirmed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  def create_changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :organization_mirror_id,
      :organization_id,
      :actor_user_id,
      :state_digest,
      :expires_at
    ])
    |> put_change(:state, :pending)
    |> validate_required([
      :organization_mirror_id,
      :organization_id,
      :actor_user_id,
      :state_digest,
      :state,
      :expires_at
    ])
    |> validate_length(:state_digest, is: 32, count: :bytes)
    |> validate_number(:organization_mirror_id, greater_than: 0)
    |> validate_number(:organization_id, greater_than: 0)
    |> validate_number(:actor_user_id, greater_than: 0)
    |> unique_constraint(:state_digest)
  end

  def callback_changeset(intent, installation_id, setup_action, now)
      when is_integer(installation_id) and setup_action in @setup_actions and
             is_struct(now, DateTime) do
    intent
    |> change(
      github_installation_id: installation_id,
      setup_action: setup_action,
      state: :callback_received,
      callback_received_at: DateTime.truncate(now, :second)
    )
    |> validate_number(:github_installation_id, greater_than: 0)
  end

  def callback_changeset(intent, _installation_id, _setup_action, _now),
    do: intent |> change() |> add_error(:base, "is invalid")

  def complete_changeset(intent, now) when is_struct(now, DateTime) do
    intent
    |> change(state: :completed, confirmed_at: DateTime.truncate(now, :second))
    |> validate_required([:github_installation_id, :setup_action, :callback_received_at])
  end

  def terminate_changeset(intent, state) when state in [:cancelled, :expired],
    do: change(intent, state: state)
end
