defmodule GitTransport.HostKey do
  @moduledoc """
  Ensures the SSH daemon has a private host key in its configured system dir.
  """

  @rsa_host_key "ssh_host_rsa_key"

  def ensure_system_dir!(system_dir) when is_binary(system_dir) do
    File.mkdir_p!(system_dir)
    File.chmod!(system_dir, 0o700)

    path = Path.join(system_dir, @rsa_host_key)

    unless File.exists?(path) do
      write_rsa_host_key!(path)
    end

    File.chmod!(path, 0o600)
    path
  end

  defp write_rsa_host_key!(path) do
    private_key = :public_key.generate_key({:rsa, 3072, 65_537})

    pem =
      :RSAPrivateKey
      |> :public_key.pem_entry_encode(private_key)
      |> List.wrap()
      |> :public_key.pem_encode()

    case File.write(path, pem, [:write, :exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write", path: path
    end
  end
end
