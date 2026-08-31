defmodule FornacastWeb.RequestMetadata do
  @moduledoc """
  Extracts the bounded, non-sensitive request metadata accepted by domain operations.
  """

  import Plug.Conn, only: [get_req_header: 2, get_resp_header: 2]

  @max_request_id_bytes 255
  @external_request_id_bytes 20..200
  @max_user_agent_bytes 512

  def from_conn(%Plug.Conn{} = conn) do
    %{
      request_id: request_id(conn),
      ip_address: normalize_ip(conn.remote_ip),
      user_agent: conn |> get_req_header("user-agent") |> List.first() |> bound_user_agent()
    }
  end

  @spec external_request_id(Plug.Conn.t()) :: String.t() | nil
  def external_request_id(%Plug.Conn{} = conn) do
    case get_req_header(conn, "x-request-id") do
      [value | _rest] when byte_size(value) in @external_request_id_bytes ->
        if String.valid?(value), do: value, else: nil

      _missing_or_invalid ->
        nil
    end
  end

  defp request_id(conn) do
    value =
      conn.assigns[:request_id] || List.first(get_resp_header(conn, "x-request-id")) ||
        "unassigned"

    bound_request_id(value)
  end

  defp bound_request_id(value) when is_binary(value), do: bound_utf8(value, @max_request_id_bytes)
  defp bound_request_id(_value), do: "unassigned"

  defp normalize_ip(address) do
    address
    |> :inet.ntoa()
    |> IO.iodata_to_binary()
  end

  defp bound_user_agent(nil), do: nil

  defp bound_user_agent(value) when is_binary(value) do
    bound_utf8(value, @max_user_agent_bytes)
  end

  defp bound_utf8(value, max_bytes) do
    value
    |> binary_part(0, min(byte_size(value), max_bytes))
    |> valid_utf8_prefix()
  end

  defp valid_utf8_prefix(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end
end
