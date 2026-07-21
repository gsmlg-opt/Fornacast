defmodule FornacastAPI.RequestBody do
  @moduledoc """
  Reads bounded JSON objects after a mutation controller has completed target
  resolution and authorization.

  Organization creation must authenticate and authorize `write:org` before
  reading. Repository creation and updates must resolve and authorize the
  visible namespace or repository and a mutation scope before reading, then
  enforce any resulting visibility scope after validation. This ordering keeps
  private targets masked before request-body consumption.
  """

  import Plug.Conn, only: [get_req_header: 2, register_before_send: 2]

  alias FornacastAPI.Error

  @type admission_mfa :: {module(), atom(), [term()]}

  @spec read_json(Plug.Conn.t(), atom(), keyword()) ::
          {:ok, map(), Plug.Conn.t()}
          | {:error, Error.t(), atom(), Plug.Conn.t()}

  @policies %{
    ordinary: %{
      maximum_bytes: 1_048_576,
      total_timeout_ms: 15_000,
      idle_timeout_ms: 15_000
    }
  }

  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/using-the-rest-api/getting-started-with-the-rest-api"

  def read_json(conn, policy_name, opts) when is_atom(policy_name) and is_list(opts) do
    policy = configured_policy(policy_name)

    case check_content_length(conn, policy.maximum_bytes) do
      :ok ->
        with {:ok, conn} <- admit(conn, Keyword.get(opts, :admission)) do
          started_at = System.monotonic_time(:millisecond)
          read_chunks(conn, policy, started_at, [], 0)
        end

      {:error, reason} ->
        error_result(conn, reason)
    end
  end

  defp configured_policy(policy_name) do
    policy = Map.fetch!(@policies, policy_name)

    case policy_name do
      :ordinary ->
        %{
          policy
          | maximum_bytes:
              Application.get_env(
                :fornacast_api,
                :ordinary_json_max_bytes,
                policy.maximum_bytes
              ),
            total_timeout_ms:
              Application.get_env(
                :fornacast_api,
                :ordinary_body_total_timeout_ms,
                policy.total_timeout_ms
              )
        }
    end
  end

  defp check_content_length(conn, maximum_bytes) do
    case get_req_header(conn, "content-length") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(String.trim(value)) do
          {length, ""} when length >= 0 and length <= maximum_bytes -> :ok
          {length, ""} when length > maximum_bytes -> {:error, :request_too_large}
          _invalid -> {:error, :malformed_json}
        end

      _multiple ->
        {:error, :malformed_json}
    end
  end

  defp admit(conn, nil), do: {:ok, conn}

  defp admit(conn, {module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    case apply(module, function, [conn, args]) do
      {:ok, conn, reservation} ->
        conn = maybe_register_release(conn, module, reservation)
        {:ok, conn}

      {:error, %Error{} = error, conn} ->
        {:error, error, admission_reason(error), conn}
    end
  end

  defp maybe_register_release(conn, module, reservation) do
    if function_exported?(module, :release, 1) do
      register_before_send(conn, fn conn ->
        apply(module, :release, [reservation])
        conn
      end)
    else
      conn
    end
  end

  defp admission_reason(%Error{status: 408}), do: :request_timeout
  defp admission_reason(%Error{}), do: :request_too_large

  defp read_chunks(conn, policy, started_at, chunks, byte_count) do
    case remaining_timeout(policy, started_at) do
      remaining_ms when remaining_ms <= 0 ->
        error_result(conn, :request_timeout)

      remaining_ms ->
        remaining_bytes = policy.maximum_bytes - byte_count
        read_length = max(min(remaining_bytes + 1, 64_000), 1)

        read_options = [
          length: max(remaining_bytes + 1, 1),
          read_length: read_length,
          read_timeout: min(policy.idle_timeout_ms, remaining_ms)
        ]

        case Plug.Conn.read_body(conn, read_options) do
          {:ok, chunk, conn} ->
            finish_chunk(conn, chunk, policy, started_at, chunks, byte_count)

          {:more, chunk, conn} ->
            continue_chunk(conn, chunk, policy, started_at, chunks, byte_count)

          {:error, :timeout} ->
            error_result(conn, :request_timeout)

          {:error, _safe_reason} ->
            error_result(conn, :malformed_json)
        end
    end
  end

  defp finish_chunk(conn, chunk, policy, started_at, chunks, byte_count) do
    new_byte_count = byte_count + byte_size(chunk)

    cond do
      new_byte_count > policy.maximum_bytes ->
        error_result(conn, :request_too_large)

      remaining_timeout(policy, started_at) <= 0 ->
        error_result(conn, :request_timeout)

      true ->
        chunks
        |> then(&IO.iodata_to_binary(Enum.reverse([chunk | &1])))
        |> FornacastAPI.JSON.decode_object()
        |> decode_result(conn)
    end
  end

  defp continue_chunk(conn, chunk, policy, started_at, chunks, byte_count) do
    new_byte_count = byte_count + byte_size(chunk)

    cond do
      new_byte_count > policy.maximum_bytes ->
        error_result(conn, :request_too_large)

      remaining_timeout(policy, started_at) <= 0 ->
        error_result(conn, :request_timeout)

      true ->
        read_chunks(conn, policy, started_at, [chunk | chunks], new_byte_count)
    end
  end

  defp remaining_timeout(policy, started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    policy.total_timeout_ms - elapsed
  end

  defp decode_result({:ok, body}, conn), do: {:ok, body, conn}
  defp decode_result({:error, reason}, conn), do: error_result(conn, reason)

  defp error_result(conn, :request_too_large) do
    error = Error.new(413, "Payload Too Large", @documentation_url)
    {:error, error, :request_too_large, conn}
  end

  defp error_result(conn, :request_timeout) do
    error = Error.new(408, "Request Timeout", @documentation_url)
    {:error, error, :request_timeout, conn}
  end

  defp error_result(conn, :duplicate_key) do
    error = Error.new(400, "Bad Request", @documentation_url)
    {:error, error, :duplicate_key, conn}
  end

  defp error_result(conn, :malformed_json) do
    error = Error.new(400, "Bad Request", @documentation_url)
    {:error, error, :malformed_json, conn}
  end
end
