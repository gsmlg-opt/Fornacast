defmodule GitTransport.PktLine do
  @moduledoc false

  @flush "0000"

  def encode(payload) when is_binary(payload) do
    length =
      payload
      |> byte_size()
      |> Kernel.+(4)
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")

    length <> payload
  end

  def flush, do: @flush
end
