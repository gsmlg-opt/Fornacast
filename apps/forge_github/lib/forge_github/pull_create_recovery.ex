defmodule ForgeGitHub.PullCreateRecovery do
  @moduledoc """
  Bounded observation-only recovery of an ambiguous pull creation.

  One provider page is consumed per checkpoint. A positive UUID match is only a
  candidate for authenticated paired GETs, never authorization or a final mapping.
  An empty completed scan is ambiguous: page drift or removal of the marker can
  hide a successful POST. No state in this module authorizes another create.
  """
  alias ForgeMirrors.CorrelationMarker

  @max_page 1_000_000
  @max_id 9_223_372_036_854_775_807

  def initial, do: %{"page" => 1, "candidate" => nil, "complete" => false}

  def decision(checkpoint) do
    if valid_checkpoint?(checkpoint) do
      case checkpoint do
        %{"complete" => false, "page" => page} -> {:scan, page}
        %{"candidate" => nil} -> {:error, :ambiguous_external_effect}
        %{"candidate" => candidate} -> {:found, candidate}
      end
    else
      {:error, :invalid_recovery_checkpoint}
    end
  end

  def advance(checkpoint, %{pulls: rows, next_cursor: next} = page, uuid)
      when is_list(rows) and length(rows) <= 100 and map_size(page) == 2 do
    with true <- valid_checkpoint?(checkpoint) and checkpoint["complete"] == false,
         {:ok, ^uuid} <- Ecto.UUID.cast(uuid),
         true <- is_nil(next) or (next == checkpoint["page"] + 1 and next <= @max_page),
         true <- Enum.all?(rows, &valid_row?/1),
         {:ok, candidate} <- candidates(rows, checkpoint["candidate"], uuid) do
      {:ok,
       %{
         "page" => next || checkpoint["page"],
         "candidate" => candidate,
         "complete" => is_nil(next)
       }}
    else
      {:error, :ambiguous_external_effect} = error -> error
      _ -> {:error, :invalid_recovery_page}
    end
  end

  def advance(_, _, _), do: {:error, :invalid_recovery_page}

  defp candidates(rows, previous, uuid) do
    matches =
      rows
      |> Enum.filter(&CorrelationMarker.matches?(&1["body"], uuid))
      |> Enum.map(&identity/1)
      |> then(fn values -> if previous, do: [previous | values], else: values end)
      |> Enum.uniq()

    case matches do
      [] -> {:ok, nil}
      [candidate] -> {:ok, candidate}
      _ -> {:error, :ambiguous_external_effect}
    end
  end

  defp valid_checkpoint?(
         %{"page" => page, "candidate" => candidate, "complete" => complete} = checkpoint
       ) do
    map_size(checkpoint) == 3 and is_integer(page) and page in 1..@max_page and
      is_boolean(complete) and (is_nil(candidate) or valid_identity?(candidate))
  end

  defp valid_checkpoint?(_), do: false

  defp valid_row?(row) when is_map(row) do
    valid_identity?(identity(row)) and
      (is_nil(row["body"]) or
         (is_binary(row["body"]) and
            byte_size(row["body"]) <= 262_144 and String.valid?(row["body"])))
  end

  defp valid_row?(_), do: false

  defp identity(row),
    do: %{
      "github_object_id" => row["id"],
      "github_node_id" => row["node_id"],
      "github_number" => row["number"]
    }

  defp valid_identity?(
         %{"github_object_id" => id, "github_node_id" => node, "github_number" => number} =
           identity
       ) do
    map_size(identity) == 3 and positive?(id) and positive?(number) and
      is_binary(node) and byte_size(node) in 1..255 and String.valid?(node) and
      String.trim(node) == node and not String.contains?(node, <<0>>)
  end

  defp valid_identity?(_), do: false
  defp positive?(id), do: is_integer(id) and id in 1..@max_id
end
