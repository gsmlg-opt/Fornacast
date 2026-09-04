defmodule ForgeGitHub.Webhook do
  @moduledoc "Bounded GitHub webhook signature verification and event classification."

  @max_secret_bytes 4_096
  @max_payload_bytes 1_048_576

  @installation_actions ~w(created deleted suspend unsuspend new_permissions_accepted)
  @installation_repository_actions ~w(added removed)
  @repository_actions ~w(archived created deleted edited privatized publicized renamed transferred unarchived)
  @issue_actions ~w(assigned closed deleted demilestoned edited labeled locked milestoned opened pinned reopened transferred unassigned unlabeled unlocked unpinned)
  @issue_comment_actions ~w(created deleted edited)
  @pull_request_actions ~w(assigned auto_merge_disabled auto_merge_enabled closed converted_to_draft demilestoned dequeued edited enqueued labeled locked milestoned opened ready_for_review reopened review_request_removed review_requested synchronize unassigned unlabeled unlocked)
  @release_actions ~w(created deleted edited prereleased published released unpublished)

  @max_json_depth 16
  @max_json_nodes 50_000
  @max_json_collection 512
  @max_json_string_bytes 16_384

  @type classification :: :processable | :pending_unsupported | :ignored

  @spec verify_signature(String.t(), binary(), String.t(), pos_integer()) ::
          :ok
          | {:error,
             :invalid_secret
             | :invalid_body
             | :invalid_body_limit
             | :body_too_large
             | :invalid_signature}
  def verify_signature(secret, payload, signature, maximum_bytes)

  def verify_signature(secret, payload, signature, maximum_bytes)
      when is_binary(secret) and is_binary(payload) and is_binary(signature) and
             is_integer(maximum_bytes) and maximum_bytes in 1..@max_payload_bytes do
    with :ok <- validate_secret(secret),
         :ok <- validate_body(payload, maximum_bytes),
         {:ok, supplied_digest} <- decode_signature(signature),
         expected_digest <- :crypto.mac(:hmac, :sha256, secret, payload),
         true <- secure_compare(expected_digest, supplied_digest) do
      :ok
    else
      false -> {:error, :invalid_signature}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :invalid_signature}
  catch
    _kind, _reason -> {:error, :invalid_signature}
  end

  def verify_signature(_secret, payload, _signature, maximum_bytes) do
    cond do
      not is_integer(maximum_bytes) or maximum_bytes not in 1..@max_payload_bytes ->
        {:error, :invalid_body_limit}

      not is_binary(payload) ->
        {:error, :invalid_body}

      true ->
        {:error, :invalid_signature}
    end
  end

  @doc false
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  def secure_compare(_left, _right), do: false

  @spec decode_payload(binary(), pos_integer()) ::
          {:ok,
           %{
             action: String.t() | nil,
             installation_id: pos_integer() | nil,
             repository_id: pos_integer() | nil
           }}
          | {:error,
             :invalid_body
             | :invalid_body_limit
             | :body_too_large
             | :invalid_utf8
             | :nul_byte
             | :invalid_json
             | :json_too_complex
             | :invalid_payload
             | :invalid_installation_id
             | :invalid_repository_id
             | :invalid_action}
  def decode_payload(raw_body, maximum_bytes)

  def decode_payload(raw_body, maximum_bytes)
      when is_binary(raw_body) and is_integer(maximum_bytes) and
             maximum_bytes in 1..@max_payload_bytes do
    with :ok <- validate_decoded_body(raw_body, maximum_bytes),
         {:ok, payload} <- decode_json(raw_body),
         true <- is_map(payload),
         {:ok, _nodes} <- validate_json(payload, 0, 0),
         {:ok, installation_id} <- installation_id(payload),
         {:ok, repository_id} <- repository_id(payload),
         {:ok, action} <- action(payload) do
      {:ok, %{action: action, installation_id: installation_id, repository_id: repository_id}}
    else
      false -> {:error, :invalid_payload}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :invalid_json}
  catch
    _kind, _reason -> {:error, :invalid_json}
  end

  def decode_payload(_raw_body, maximum_bytes)
      when not is_integer(maximum_bytes) or maximum_bytes not in 1..@max_payload_bytes,
      do: {:error, :invalid_body_limit}

  def decode_payload(_raw_body, _maximum_bytes), do: {:error, :invalid_body}

  @spec classify(String.t(), String.t() | nil) :: classification()
  def classify("installation", action) when action in @installation_actions, do: :processable

  def classify("installation_repositories", action)
      when action in @installation_repository_actions,
      do: :processable

  def classify("repository", action) when action in @repository_actions,
    do: :processable

  def classify(event, nil) when event in ["push", "create", "delete"],
    do: :pending_unsupported

  def classify("issues", action) when action in @issue_actions,
    do: :pending_unsupported

  def classify("issue_comment", action) when action in @issue_comment_actions,
    do: :pending_unsupported

  def classify("pull_request", action) when action in @pull_request_actions,
    do: :pending_unsupported

  def classify("release", action) when action in @release_actions,
    do: :pending_unsupported

  def classify(_event, _action), do: :ignored

  defp validate_secret(secret) do
    if byte_size(secret) in 1..@max_secret_bytes and String.valid?(secret) and
         :binary.match(secret, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, :invalid_secret}
  end

  defp validate_body(payload, maximum_bytes) do
    cond do
      byte_size(payload) == 0 -> {:error, :invalid_body}
      byte_size(payload) > maximum_bytes -> {:error, :body_too_large}
      true -> :ok
    end
  end

  defp validate_decoded_body(raw_body, maximum_bytes) do
    cond do
      byte_size(raw_body) == 0 -> {:error, :invalid_body}
      byte_size(raw_body) > maximum_bytes -> {:error, :body_too_large}
      not String.valid?(raw_body) -> {:error, :invalid_utf8}
      :binary.match(raw_body, <<0>>) != :nomatch -> {:error, :nul_byte}
      true -> :ok
    end
  end

  defp decode_json(raw_body) do
    case JSON.decode(raw_body) do
      {:ok, value} -> {:ok, value}
      _invalid -> {:error, :invalid_json}
    end
  end

  defp installation_id(payload) do
    case Map.fetch(payload, "installation") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:error, :invalid_installation_id}

      {:ok, %{"id" => id}} when is_integer(id) ->
        if valid_id?(id), do: {:ok, id}, else: {:error, :invalid_installation_id}

      _invalid ->
        {:error, :invalid_installation_id}
    end
  end

  defp repository_id(payload) do
    case Map.fetch(payload, "repository") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{"id" => id}} when is_integer(id) ->
        if valid_id?(id), do: {:ok, id}, else: {:error, :invalid_repository_id}

      _invalid ->
        {:error, :invalid_repository_id}
    end
  end

  defp action(payload) do
    case Map.fetch(payload, "action") do
      :error -> {:ok, nil}
      {:ok, action} when is_binary(action) and byte_size(action) in 1..100 -> {:ok, action}
      _invalid -> {:error, :invalid_action}
    end
  end

  defp valid_id?(id), do: id in 1..9_223_372_036_854_775_807

  defp validate_json(_value, depth, _nodes) when depth > @max_json_depth,
    do: {:error, :json_too_complex}

  defp validate_json(_value, _depth, nodes) when nodes >= @max_json_nodes,
    do: {:error, :json_too_complex}

  defp validate_json(value, _depth, nodes) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      :binary.match(value, <<0>>) != :nomatch -> {:error, :nul_byte}
      byte_size(value) > @max_json_string_bytes -> {:error, :json_too_complex}
      true -> {:ok, nodes + 1}
    end
  end

  defp validate_json(value, _depth, nodes)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, nodes + 1}

  defp validate_json(values, depth, nodes)
       when is_list(values) and length(values) <= @max_json_collection do
    Enum.reduce_while(values, {:ok, nodes + 1}, fn value, {:ok, count} ->
      case validate_json(value, depth + 1, count) do
        {:ok, count} -> {:cont, {:ok, count}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_json(values, depth, nodes)
       when is_map(values) and map_size(values) <= @max_json_collection do
    Enum.reduce_while(values, {:ok, nodes + 1}, fn {key, value}, {:ok, count} ->
      cond do
        not is_binary(key) or not String.valid?(key) ->
          {:halt, {:error, :json_too_complex}}

        :binary.match(key, <<0>>) != :nomatch ->
          {:halt, {:error, :nul_byte}}

        byte_size(key) > 128 ->
          {:halt, {:error, :json_too_complex}}

        true ->
          case validate_json(value, depth + 1, count) do
            {:ok, count} -> {:cont, {:ok, count}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp validate_json(_value, _depth, _nodes), do: {:error, :json_too_complex}

  defp decode_signature("sha256=" <> digest) when byte_size(digest) == 64 do
    case Base.decode16(digest, case: :lower) do
      {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded}
      _invalid -> {:error, :invalid_signature}
    end
  end

  defp decode_signature(_signature), do: {:error, :invalid_signature}
end
