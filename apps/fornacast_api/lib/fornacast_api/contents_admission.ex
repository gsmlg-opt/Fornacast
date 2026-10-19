defmodule FornacastAPI.ContentsAdmission do
  import Plug.Conn
  alias FornacastAPI.Error

  def reservation_bytes("PUT", nil), do: GitCore.Limits.get(:contents_reservation_bytes)

  def reservation_bytes("PUT", bytes),
    do:
      min(
        bytes + min(div(bytes * 3 + 3, 4), GitCore.Limits.get(:blob_bytes)),
        GitCore.Limits.get(:contents_reservation_bytes)
      )

  def reservation_bytes("DELETE", nil), do: GitCore.Limits.get(:contents_json_bytes)
  def reservation_bytes("DELETE", bytes), do: bytes

  def admit(conn, [_repository]) do
    bytes =
      case get_req_header(conn, "content-length") do
        [value] ->
          case Integer.parse(value) do
            {bytes, ""} -> bytes
            _ -> nil
          end

        _ ->
          nil
      end

    case GitCore.BodyMemoryLimiter.acquire(reservation_bytes(conn.method, bytes)) do
      {:ok, lease} ->
        {:ok, assign(conn, :contents_reservation, lease), lease}

      {:error, _} ->
        {:error, Error.from_domain(:unavailable, "https://docs.github.com/rest/repos/contents"),
         conn}
    end
  end

  def release(lease), do: GitCore.BodyMemoryLimiter.release(lease)
end
