defmodule GitTransport.Command do
  @moduledoc """
  Parser for the restricted Git SSH exec command surface.
  """

  @commands %{
    "git-upload-pack" => :upload_pack,
    "git-receive-pack" => :receive_pack
  }

  defstruct [:operation, :path, :owner, :repository]

  def parse(command) when is_binary(command) do
    with {:ok, command_name, raw_path} <- split_command(command),
         {:ok, operation} <- supported_command(command_name),
         {:ok, owner, repository} <-
           raw_path |> normalize_ssh_path() |> ForgeRepos.parse_git_path() do
      {:ok,
       %__MODULE__{
         operation: operation,
         path: owner <> "/" <> repository <> ".git",
         owner: owner,
         repository: repository
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(_), do: {:error, :invalid_command}

  defp split_command(command) do
    command = String.trim(command)

    cond do
      command == "" -> {:error, :invalid_command}
      String.contains?(command, "\0") -> {:error, :invalid_command}
      true -> split_supported_command(command)
    end
  end

  defp split_supported_command(command) do
    @commands
    |> Map.keys()
    |> Enum.find_value(fn command_name ->
      prefix = command_name <> " "

      if String.starts_with?(command, prefix) do
        raw_path =
          command
          |> String.replace_prefix(prefix, "")
          |> String.trim()

        {:ok, command_name, raw_path}
      end
    end)
    |> case do
      nil -> {:error, :unsupported_command}
      {:ok, command_name, raw_path} -> parse_path_argument(command_name, raw_path)
    end
  end

  defp parse_path_argument(_command_name, ""), do: {:error, :missing_path}

  defp parse_path_argument(command_name, "'" <> rest) do
    case String.split(rest, "'", parts: 2) do
      [path, ""] when path != "" -> validate_path_argument(command_name, path)
      _ -> {:error, :invalid_command}
    end
  end

  defp parse_path_argument(command_name, "\"" <> rest) do
    case String.split(rest, "\"", parts: 2) do
      [path, ""] when path != "" -> validate_path_argument(command_name, path)
      _ -> {:error, :invalid_command}
    end
  end

  defp parse_path_argument(command_name, raw_path) do
    validate_path_argument(command_name, raw_path)
  end

  defp validate_path_argument(command_name, raw_path) do
    if String.match?(raw_path, ~r/[\s'";&|`$()<>]/) do
      {:error, :invalid_command}
    else
      {:ok, command_name, raw_path}
    end
  end

  defp normalize_ssh_path("/" <> path), do: path
  defp normalize_ssh_path(path), do: path

  defp supported_command(command_name) do
    case Map.fetch(@commands, command_name) do
      {:ok, operation} -> {:ok, operation}
      :error -> {:error, :unsupported_command}
    end
  end
end
