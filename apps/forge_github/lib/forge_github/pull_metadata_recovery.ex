defmodule ForgeGitHub.PullMetadataRecovery do
  @moduledoc """
  Pure durable recovery evidence for mapped pull relationship effects.

  The complete payload belongs in a separately persisted, immutable 2 MB
  intent. An operation effect marker must reference that intent by identity and
  hash; this payload is not safe to embed in the marker's 64 KiB JSON column.
  """

  @issue_fields ~w(title body state state_reason label_github_ids assignee_github_ids)
  @set_fields ~w(label_github_ids assignee_github_ids)
  @payload_fields ~w(v expected_local_issue expected_remote_issue target_issue)
  @max_relationships 512
  @max_payload_bytes 2_000_000
  @max_id 9_223_372_036_854_775_807

  @type payload :: %{required(String.t()) => term()}

  @type classification :: %{
          status: :applied | :not_applied,
          expected_local_issue: map(),
          current_local_issue: map(),
          expected_remote_issue: map(),
          target_issue: map()
        }

  @spec build(map(), map(), map()) :: {:ok, payload()} | {:error, :invalid_projection}
  def build(expected_local_issue, expected_remote_issue, target_issue) do
    payload = %{
      "v" => 1,
      "expected_local_issue" => expected_local_issue,
      "expected_remote_issue" => expected_remote_issue,
      "target_issue" => target_issue
    }

    if valid_payload?(payload), do: {:ok, payload}, else: {:error, :invalid_projection}
  end

  @spec classify(map(), map(), map()) ::
          {:ok, classification()}
          | {:conflict, :ambiguous_external_effect}
          | {:error, :invalid_projection}
  def classify(payload, current_local_issue, fresh_remote_issue) do
    if valid_payload?(payload) and valid_issue?(current_local_issue) and
         valid_issue?(fresh_remote_issue) do
      result = %{
        expected_local_issue: payload["expected_local_issue"],
        current_local_issue: current_local_issue,
        expected_remote_issue: payload["expected_remote_issue"],
        target_issue: payload["target_issue"]
      }

      cond do
        fresh_remote_issue == payload["expected_remote_issue"] ->
          {:ok, Map.put(result, :status, :not_applied)}

        fresh_remote_issue == payload["target_issue"] ->
          {:ok, Map.put(result, :status, :applied)}

        true ->
          {:conflict, :ambiguous_external_effect}
      end
    else
      {:error, :invalid_projection}
    end
  end

  defp valid_payload?(payload) when is_map(payload) do
    Enum.sort(Map.keys(payload)) == Enum.sort(@payload_fields) and payload["v"] == 1 and
      valid_issue?(payload["expected_local_issue"]) and
      valid_issue?(payload["expected_remote_issue"]) and
      valid_issue?(payload["target_issue"]) and
      payload["expected_remote_issue"] != payload["target_issue"] and
      encoded_size(payload) <= @max_payload_bytes
  end

  defp valid_payload?(_payload), do: false

  defp valid_issue?(snapshot) when is_map(snapshot) do
    Enum.sort(Map.keys(snapshot)) == Enum.sort(@issue_fields) and
      valid_text?(snapshot["title"], 1_024) and snapshot["title"] != "" and
      codepoints_at_most?(snapshot["title"], 256) and valid_body?(snapshot["body"]) and
      snapshot["state"] in ["open", "closed"] and
      valid_state_reason?(snapshot["state"], snapshot["state_reason"]) and
      Enum.all?(@set_fields, &valid_identity_set?(snapshot[&1]))
  end

  defp valid_issue?(_snapshot), do: false

  defp valid_body?(nil), do: true

  defp valid_body?(body),
    do: valid_text?(body, 262_144) and codepoints_at_most?(body, 65_536)

  defp valid_state_reason?("open", reason), do: reason in [nil, "reopened"]
  defp valid_state_reason?("closed", reason), do: reason in [nil, "completed", "not_planned"]
  defp valid_state_reason?(_state, _reason), do: false

  defp valid_identity_set?(ids) when is_list(ids) do
    length(Enum.take(ids, @max_relationships + 1)) <= @max_relationships and
      ids == Enum.sort(Enum.uniq(ids)) and Enum.all?(ids, &valid_id?/1)
  end

  defp valid_identity_set?(_ids), do: false
  defp valid_id?(id), do: is_integer(id) and id > 0 and id <= @max_id

  defp valid_text?(value, max_bytes),
    do:
      is_binary(value) and byte_size(value) <= max_bytes and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp codepoints_at_most?(value, max),
    do: length(Enum.take(String.codepoints(value), max + 1)) <= max

  defp encoded_size(value), do: value |> JSON.encode!() |> byte_size()
end
