defmodule FornacastAPI.Plugs.EndpointTelemetry do
  @behaviour Plug

  import Plug.Conn, only: [register_before_send: 2]

  @impl true
  def init(opts), do: Plug.Telemetry.init(opts)

  @impl true
  def call(conn, {start_event, stop_event, opts}) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      start_event,
      %{system_time: System.system_time()},
      sanitized_metadata(conn, opts)
    )

    register_before_send(conn, fn conn ->
      duration = System.monotonic_time() - start_time
      :telemetry.execute(stop_event, %{duration: duration}, sanitized_metadata(conn, opts))
      conn
    end)
  end

  defp sanitized_metadata(conn, opts) do
    sanitized_conn =
      Map.update!(conn, :req_headers, fn headers ->
        Enum.reject(headers, fn {name, _value} -> String.downcase(name) == "authorization" end)
      end)

    %{conn: sanitized_conn, options: opts}
  end
end
