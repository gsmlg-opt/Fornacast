defmodule ForgeMirrors.CorrelationMarker do
  @moduledoc """
  Source-format marker for recovering ambiguous outbound issue/comment creates.

  The worker must persist a random correlation UUID before sending a create and
  reuse it on recovery. Markers are hints, not authorization or identity proof:
  recovery must scan the entire relevant provider collection and conflict when
  more than one immutable object identity matches. This module performs no I/O.

  Only a terminal marker matching the expected persisted UUID is stripped, so
  ordinary user HTML comments and unrelated correlation markers remain intact.
  """

  @max_body_characters 65_536

  def append(body, correlation_id) when is_binary(body) or is_nil(body) do
    with {:ok, suffix} <- suffix(correlation_id) do
      body = body || ""
      encoded = if String.ends_with?(body, suffix), do: body, else: body <> suffix

      if byte_size(encoded) <= @max_body_characters * 4 and
           within_character_limit?(encoded, @max_body_characters),
         do: {:ok, encoded},
         else: {:error, :body_too_long}
    end
  end

  def append(_body, _correlation_id), do: {:error, :invalid_body}

  def matches?(body, correlation_id) when is_binary(body) do
    case suffix(correlation_id) do
      {:ok, suffix} -> String.ends_with?(body, suffix)
      {:error, _} -> false
    end
  end

  def matches?(_body, _correlation_id), do: false

  def strip(body, correlation_id) do
    if matches?(body, correlation_id) do
      {:ok, suffix} = suffix(correlation_id)
      binary_part(body, 0, byte_size(body) - byte_size(suffix))
    else
      body
    end
  end

  defp suffix(correlation_id) when is_binary(correlation_id) do
    case Ecto.UUID.cast(correlation_id) do
      {:ok, ^correlation_id} -> {:ok, "\n\n<!-- fornacast:sync:v1:#{correlation_id} -->"}
      _invalid -> {:error, :invalid_correlation_id}
    end
  end

  defp suffix(_correlation_id), do: {:error, :invalid_correlation_id}

  defp within_character_limit?("", _remaining), do: true

  defp within_character_limit?(<<_character::utf8, rest::binary>>, remaining)
       when remaining > 0,
       do: within_character_limit?(rest, remaining - 1)

  defp within_character_limit?(_body, _remaining), do: false
end
