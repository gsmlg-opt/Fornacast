defmodule Fornacast.Audit do
  @moduledoc """
  Minimal audit-event writer for first-release repository operations.
  """

  alias Fornacast.{AuditEvent, Repo}

  def record(actor, action, target_type, target_id, metadata \\ %{}, opts \\ []) do
    attrs = %{
      actor_user_id: actor_id(actor),
      action: action,
      target_type: target_type,
      target_id: to_string(target_id),
      metadata: metadata || %{},
      ip_address: opts[:ip_address],
      user_agent: opts[:user_agent]
    }

    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil
end
