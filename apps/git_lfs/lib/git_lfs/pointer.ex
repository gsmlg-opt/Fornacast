defmodule GitLFS.Pointer do
  @moduledoc """
  Strict parser for canonical Git LFS v1 pointer files.
  """

  @version "version https://git-lfs.github.com/spec/v1"
  @maximum_pointer_bytes 1_024
  @maximum_size 9_223_372_036_854_775_807
  @oid_regex ~r/\Aoid sha256:([0-9a-f]{64})\z/
  @extension_regex ~r/\A(ext-(?:0|[1-9][0-9]*)-[A-Za-z0-9][A-Za-z0-9.-]*) ([^\r\n]+)\z/
  @size_regex ~r/\Asize (0|[1-9][0-9]*)\z/

  @enforce_keys [:oid, :size]
  defstruct [:oid, :size, extensions: []]

  @type t :: %__MODULE__{
          oid: String.t(),
          size: non_neg_integer(),
          extensions: [{String.t(), String.t()}]
        }

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_pointer}
  def parse(pointer)
      when is_binary(pointer) and byte_size(pointer) <= @maximum_pointer_bytes do
    with true <- String.valid?(pointer),
         false <- :binary.match(pointer, "\r") != :nomatch,
         true <- String.ends_with?(pointer, "\n"),
         [@version | remaining] <- String.split(pointer, "\n", trim: false),
         {extension_lines, [oid_line, size_line, ""]} <-
           Enum.split_while(remaining, &String.starts_with?(&1, "ext-")),
         {:ok, extensions} <- parse_extensions(extension_lines),
         [_, oid] <- Regex.run(@oid_regex, oid_line),
         [_, encoded_size] <- Regex.run(@size_regex, size_line),
         {size, ""} <- Integer.parse(encoded_size),
         true <- size <= @maximum_size do
      {:ok, %__MODULE__{oid: oid, size: size, extensions: extensions}}
    else
      _invalid -> {:error, :invalid_pointer}
    end
  end

  def parse(_pointer), do: {:error, :invalid_pointer}

  defp parse_extensions(lines) do
    with extensions when is_list(extensions) <- Enum.map(lines, &parse_extension/1),
         false <- Enum.any?(extensions, &is_nil/1),
         names = Enum.map(extensions, &elem(&1, 0)),
         true <- names == Enum.sort(names),
         true <- length(names) == length(Enum.uniq(names)) do
      {:ok, extensions}
    else
      _invalid -> {:error, :invalid_pointer}
    end
  end

  defp parse_extension(line) do
    case Regex.run(@extension_regex, line) do
      [_, name, value] -> {name, value}
      _invalid -> nil
    end
  end
end
