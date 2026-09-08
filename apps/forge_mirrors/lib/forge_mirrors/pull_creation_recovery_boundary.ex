defmodule ForgeMirrors.PullCreationRecoveryBoundary do
  @moduledoc "Marker-preserving recovery progress and fresh effect eligibility; never a POST grant."
  alias ForgeMirrors.{MirrorOperation, PullOutboundCreation}
  alias Fornacast.Repo
  @key "pull_creation_recovery"
  @initial %{"page" => 1, "candidate" => nil, "complete" => false}

  def context(%MirrorOperation{} = operation, lock_fun) do
    Repo.transaction(fn ->
      with {:ok, persisted, scope, intent} <- recover(operation, lock_fun),
           {:ok, current} <- PullOutboundCreation.active_recovery(persisted, scope, intent),
           checkpoint = Map.get(persisted.checkpoint, @key, @initial),
           true <- valid?(checkpoint),
           {:ok, _, _} <- lock_fun.(operation) do
        scope
        |> Map.merge(current)
        |> Map.merge(%{
          phase: :recovery,
          intent: intent,
          marker: persisted.external_effect_marker,
          recovery_checkpoint: checkpoint
        })
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_recovery_checkpoint)
      end
    end)
  end

  def context(_, _), do: {:error, :invalid_argument}

  def checkpoint(
        %MirrorOperation{} = operation,
        expected,
        next,
        %DateTime{} = retry_at,
        %DateTime{} = now,
        lock_fun,
        save_fun
      ) do
    if utc?(now) and utc?(retry_at) and DateTime.compare(retry_at, now) != :lt and
         advances?(expected, next) do
      Repo.transaction(fn ->
        with {:ok, persisted, _, _} <- recover(operation, lock_fun),
             true <- Map.get(persisted.checkpoint, @key, @initial) == expected,
             checkpoint = Map.put(persisted.checkpoint, @key, next),
             {:ok, persisted, _} <- lock_fun.(operation),
             {:ok, saved} <- save_fun.(persisted, checkpoint, retry_at, now) do
          saved
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_recovery_checkpoint)
        end
      end)
    else
      {:error, :invalid_recovery_checkpoint}
    end
  end

  def checkpoint(_, _, _, _, _, _, _), do: {:error, :invalid_argument}

  defp recover(operation, lock_fun) do
    with {:ok, persisted, scope} <- lock_fun.(operation),
         true <- persisted.state == :effect_pending,
         {:ok, intent} <-
           PullOutboundCreation.lock_recovery(persisted, scope, persisted.external_effect_marker) do
      {:ok, persisted, scope, intent}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_transition}
    end
  end

  defp advances?(previous, next) do
    valid?(previous) and valid?(next) and
      (previous == next or
         (not previous["complete"] and
            (is_nil(previous["candidate"]) or previous["candidate"] == next["candidate"]) and
            ((next["complete"] and next["page"] == previous["page"]) or
               (not next["complete"] and next["page"] == previous["page"] + 1))))
  end

  defp valid?(%{"page" => page, "candidate" => candidate, "complete" => complete} = value),
    do:
      map_size(value) == 3 and is_integer(page) and page in 1..1_000_000 and is_boolean(complete) and
        candidate?(candidate)

  defp valid?(_), do: false
  defp candidate?(nil), do: true

  defp candidate?(
         %{"github_object_id" => id, "github_node_id" => node, "github_number" => number} = value
       ),
       do:
         map_size(value) == 3 and positive?(id) and positive?(number) and is_binary(node) and
           byte_size(node) in 1..255 and String.valid?(node) and String.trim(node) == node and
           not String.contains?(node, <<0>>)

  defp candidate?(_), do: false
  defp positive?(id), do: is_integer(id) and id in 1..9_223_372_036_854_775_807
  defp utc?(date), do: date.utc_offset == 0 and date.std_offset == 0
end
