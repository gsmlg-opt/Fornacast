defmodule FornacastAPI.Plugs.GitHubWebhookRequest do
  @moduledoc """
  Validates GitHub webhook transport metadata and verifies the exact request bytes.

  The request is deliberately outside the public API authentication pipeline. Its
  sole credential is the GitHub App webhook signature.
  """

  @behaviour Plug

  import Plug.Conn

  alias ForgeGitHub.{AppConfig, Webhook}
  alias FornacastAPI.Response

  @read_chunk_bytes 64_000
  @read_timeout 5_000
  @max_signed_bigint 9_223_372_036_854_775_807
  @event_pattern ~r/\A[a-z0-9_]+\z/

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    with {:ok, config} <- AppConfig.fetch(),
         :ok <- validate_content_type(conn),
         {:ok, user_agent} <- one_header(conn, "user-agent"),
         :ok <- validate_user_agent(user_agent),
         {:ok, delivery_guid} <- one_header(conn, "x-github-delivery"),
         :ok <- validate_delivery_guid(delivery_guid),
         {:ok, event} <- one_header(conn, "x-github-event"),
         :ok <- validate_event(event),
         {:ok, hook_header} <- one_header(conn, "x-github-hook-id"),
         {:ok, hook_id} <- parse_positive_integer(hook_header),
         {:ok, signature} <- signature_header(conn),
         :ok <- validate_content_length(conn, config.webhook_max_bytes),
         {:ok, raw_body, conn} <- read_raw_body(conn, config.webhook_max_bytes),
         {:ok, secret} <- AppConfig.read_webhook_secret(config),
         :ok <- Webhook.verify_signature(secret, raw_body, signature, config.webhook_max_bytes),
         {:ok, routing} <- Webhook.decode_payload(raw_body, config.webhook_max_bytes),
         {:ok, classification} <- classify_routing(event, routing) do
      assign(conn, :github_webhook, %{
        delivery_guid: delivery_guid,
        hook_id: hook_id,
        event: event,
        raw_body: raw_body,
        classification: classification,
        action: routing.action,
        installation_id: routing.installation_id,
        github_repository_id: routing.repository_id
      })
    else
      {:error, reason, error_conn} ->
        reject_read_error(error_conn, reason)

      {:error, :unsupported_media_type} ->
        reject(conn, 415, "Unsupported Media Type")

      {:error, :body_too_large} ->
        reject(conn, 413, "Payload Too Large")

      {:error, :request_timeout} ->
        reject(conn, 408, "Request Timeout")

      {:error, :invalid_signature} ->
        reject(conn, 401, "Unauthorized")

      {:error, :invalid_webhook_secret} ->
        reject(conn, 503, "Service Unavailable")

      {:error, reason} when reason in [:disabled, :invalid_configuration] ->
        reject(conn, 503, "Service Unavailable")

      {:error, _safe_reason} ->
        reject(conn, 400, "Bad Request")
    end
  rescue
    _exception -> reject(conn, 503, "Service Unavailable")
  catch
    _kind, _reason -> reject(conn, 503, "Service Unavailable")
  end

  defp validate_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        if String.downcase(String.trim(value)) == "application/json",
          do: :ok,
          else: {:error, :unsupported_media_type}

      _missing_or_multiple ->
        {:error, :unsupported_media_type}
    end
  end

  defp one_header(conn, name) do
    case get_req_header(conn, name) do
      [value] when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _missing_or_multiple -> {:error, :invalid_header}
    end
  end

  defp signature_header(conn) do
    case one_header(conn, "x-hub-signature-256") do
      {:ok, signature} -> {:ok, signature}
      {:error, _reason} -> {:error, :invalid_signature}
    end
  end

  defp validate_user_agent("GitHub-Hookshot/" <> suffix) when byte_size(suffix) in 1..255,
    do: :ok

  defp validate_user_agent(_user_agent), do: {:error, :invalid_user_agent}

  defp validate_delivery_guid(value) when byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> :ok
      _invalid -> {:error, :invalid_delivery_guid}
    end
  end

  defp validate_delivery_guid(_value), do: {:error, :invalid_delivery_guid}

  defp validate_event(event) when byte_size(event) in 1..64 do
    if Regex.match?(@event_pattern, event), do: :ok, else: {:error, :invalid_event}
  end

  defp validate_event(_event), do: {:error, :invalid_event}

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..@max_signed_bigint -> {:ok, integer}
      _invalid -> {:error, :invalid_integer}
    end
  end

  defp validate_content_length(conn, maximum_bytes) do
    case get_req_header(conn, "content-length") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(String.trim(value)) do
          {length, ""} when length >= 0 and length <= maximum_bytes -> :ok
          {length, ""} when length > maximum_bytes -> {:error, :body_too_large}
          _invalid -> {:error, :invalid_content_length}
        end

      _multiple ->
        {:error, :invalid_content_length}
    end
  end

  defp read_raw_body(conn, maximum_bytes) do
    total_timeout_ms =
      Application.get_env(:fornacast_api, :github_webhook_body_total_timeout_ms, @read_timeout)

    if is_integer(total_timeout_ms) and total_timeout_ms in 1..30_000 do
      read_raw_body(
        conn,
        maximum_bytes,
        total_timeout_ms,
        System.monotonic_time(:millisecond),
        [],
        0
      )
    else
      {:error, :invalid_configuration}
    end
  end

  defp read_raw_body(conn, maximum_bytes, total_timeout_ms, started_at, chunks, byte_count) do
    remaining_time = remaining_time(total_timeout_ms, started_at)

    if remaining_time <= 0 do
      {:error, :request_timeout, conn}
    else
      remaining_bytes = maximum_bytes - byte_count

      options = [
        length: max(remaining_bytes + 1, 1),
        read_length: max(min(remaining_bytes + 1, @read_chunk_bytes), 1),
        read_timeout: min(@read_timeout, remaining_time)
      ]

      case Plug.Conn.read_body(conn, options) do
        {:ok, chunk, conn} ->
          finish_body(
            conn,
            chunk,
            maximum_bytes,
            total_timeout_ms,
            started_at,
            chunks,
            byte_count
          )

        {:more, chunk, conn} ->
          continue_body(
            conn,
            chunk,
            maximum_bytes,
            total_timeout_ms,
            started_at,
            chunks,
            byte_count
          )

        {:error, :timeout} ->
          {:error, :request_timeout, conn}

        {:error, _reason} ->
          {:error, :invalid_body, conn}
      end
    end
  end

  defp finish_body(
         conn,
         chunk,
         maximum_bytes,
         total_timeout_ms,
         started_at,
         chunks,
         byte_count
       ) do
    cond do
      byte_count + byte_size(chunk) > maximum_bytes ->
        {:error, :body_too_large, conn}

      remaining_time(total_timeout_ms, started_at) <= 0 ->
        {:error, :request_timeout, conn}

      true ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}
    end
  end

  defp continue_body(
         conn,
         chunk,
         maximum_bytes,
         total_timeout_ms,
         started_at,
         chunks,
         byte_count
       ) do
    new_byte_count = byte_count + byte_size(chunk)

    cond do
      new_byte_count > maximum_bytes ->
        {:error, :body_too_large, conn}

      remaining_time(total_timeout_ms, started_at) <= 0 ->
        {:error, :request_timeout, conn}

      true ->
        read_raw_body(
          conn,
          maximum_bytes,
          total_timeout_ms,
          started_at,
          [chunk | chunks],
          new_byte_count
        )
    end
  end

  defp remaining_time(total_timeout_ms, started_at),
    do: total_timeout_ms - (System.monotonic_time(:millisecond) - started_at)

  defp classify_routing(event, routing) do
    classification = Webhook.classify(event, routing.action)

    if classification == :ignored or is_integer(routing.installation_id),
      do: {:ok, classification},
      else: {:error, :invalid_installation_id}
  end

  defp reject_read_error(conn, :body_too_large), do: reject(conn, 413, "Payload Too Large")
  defp reject_read_error(conn, :request_timeout), do: reject(conn, 408, "Request Timeout")
  defp reject_read_error(conn, _safe_reason), do: reject(conn, 400, "Bad Request")

  defp reject(conn, status, message) do
    conn
    |> Response.json(status, %{message: message})
    |> halt()
  end
end
