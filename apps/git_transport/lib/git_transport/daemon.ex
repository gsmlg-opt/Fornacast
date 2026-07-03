defmodule GitTransport.Daemon do
  @moduledoc """
  Owns the Erlang/OTP SSH daemon listener.
  """

  use GenServer

  require Logger

  defstruct [:daemon_ref, :bind_ip, :port, :system_dir]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def info(server \\ __MODULE__) do
    GenServer.call(server, :info)
  end

  def port(server \\ __MODULE__) do
    GenServer.call(server, :port)
  end

  @impl true
  def init(opts) do
    system_dir = Keyword.get(opts, :system_dir, Fornacast.Config.ssh_system_dir())
    port = Keyword.get(opts, :port, Fornacast.Config.ssh_port())
    bind_ip = Keyword.get(opts, :bind_ip, Fornacast.Config.ssh_bind_ip())

    with {:ok, parsed_bind_ip} <- parse_bind_ip(bind_ip),
         {:ok, daemon_ref} <- start_daemon(parsed_bind_ip, port, system_dir, opts),
         {:ok, info} <- daemon_info(daemon_ref),
         {:port, actual_port} <- List.keyfind(info, :port, 0) do
      Logger.info("SSH daemon started on #{format_bind_ip(parsed_bind_ip)}:#{actual_port}")

      {:ok,
       %__MODULE__{
         daemon_ref: daemon_ref,
         bind_ip: parsed_bind_ip,
         port: actual_port,
         system_dir: system_dir
       }}
    else
      {:error, reason} -> {:stop, reason}
      nil -> {:stop, :missing_ssh_port}
    end
  end

  @impl true
  def handle_call(:info, _from, %__MODULE__{daemon_ref: daemon_ref} = state) do
    {:reply, daemon_info(daemon_ref), state}
  end

  def handle_call(:port, _from, %__MODULE__{port: port} = state) do
    {:reply, port, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{daemon_ref: daemon_ref}) when not is_nil(daemon_ref) do
    :ssh.stop_daemon(daemon_ref)
  end

  def terminate(_reason, _state), do: :ok

  def daemon_options(system_dir, extra_options \\ []) when is_binary(system_dir) do
    [
      system_dir: String.to_charlist(system_dir),
      key_cb: {GitTransport.KeyCallback, []},
      auth_methods: ~c"publickey",
      shell: :disabled,
      exec: :disabled,
      ssh_cli: {GitTransport.Channel, []},
      subsystems: [],
      tcpip_tunnel_in: false,
      tcpip_tunnel_out: false,
      max_initial_idle_time: 30_000,
      idle_time: 300_000,
      max_sessions: 25,
      parallel_login: true
    ]
    |> Keyword.merge(extra_options)
  end

  defp start_daemon(bind_ip, port, system_dir, opts) do
    _host_key_path = GitTransport.HostKey.ensure_system_dir!(system_dir)
    extra_options = Keyword.get(opts, :daemon_options, [])

    :ssh.daemon(bind_ip, port, daemon_options(system_dir, extra_options))
  end

  defp daemon_info(daemon_ref) do
    case :ssh.daemon_info(daemon_ref) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_bind_ip(:loopback), do: {:ok, :loopback}
  defp parse_bind_ip(:any), do: {:ok, :any}
  defp parse_bind_ip(ip) when is_tuple(ip), do: {:ok, ip}

  defp parse_bind_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:invalid_ssh_bind_ip, reason}}
    end
  end

  defp format_bind_ip(:loopback), do: "loopback"
  defp format_bind_ip(:any), do: "any"

  defp format_bind_ip(ip) when is_tuple(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  end
end
