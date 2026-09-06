defmodule GitTransport.Command do
  @moduledoc """
  Parser for the restricted Git SSH exec command surface.
  """

  @commands %{
    "git-upload-pack" => :upload_pack,
    "git-receive-pack" => :receive_pack
  }

  defstruct [:operation, :path, :owner, :repository, :lfs_operation]

  def parse(command) when is_binary(command) do
    with {:ok, command_name, raw_path, lfs_operation} <- split_command(command),
         {:ok, operation} <- supported_command(command_name),
         {:ok, owner, repository} <-
           raw_path |> normalize_ssh_path() |> ForgeRepos.parse_git_path() do
      {:ok,
       %__MODULE__{
         operation: operation,
         path: owner <> "/" <> repository <> ".git",
         owner: owner,
         repository: repository,
         lfs_operation: lfs_operation
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
    if String.starts_with?(command, "git-lfs-authenticate ") do
      command
      |> String.replace_prefix("git-lfs-authenticate ", "")
      |> String.trim()
      |> parse_lfs_arguments()
    else
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

  defp validate_path_argument(command_name, raw_path, lfs_operation \\ nil) do
    if String.match?(raw_path, ~r/[\s'";&|`$()<>]/) do
      {:error, :invalid_command}
    else
      {:ok, command_name, raw_path, lfs_operation}
    end
  end

  defp parse_lfs_arguments(arguments) do
    case Regex.run(
           ~r/\A(?:'([^']+)'|"([^"]+)"|([^\s'"]+))[ \t]+(download|upload)\z/,
           arguments,
           capture: :all_but_first
         ) do
      [single_quoted, double_quoted, unquoted, operation] ->
        raw_path = Enum.find([single_quoted, double_quoted, unquoted], &(&1 not in [nil, ""]))
        validate_path_argument("git-lfs-authenticate", raw_path, String.to_atom(operation))

      _invalid ->
        {:error, :invalid_command}
    end
  end

  defp normalize_ssh_path("/" <> path), do: path
  defp normalize_ssh_path(path), do: path

  defp supported_command(command_name) do
    commands = Map.put(@commands, "git-lfs-authenticate", :lfs_authenticate)

    case Map.fetch(commands, command_name) do
      {:ok, operation} -> {:ok, operation}
      :error -> {:error, :unsupported_command}
    end
  end
end
