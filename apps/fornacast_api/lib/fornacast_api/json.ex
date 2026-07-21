defmodule FornacastAPI.JSON do
  defmodule DuplicateKeyError do
    defexception [:key]

    def message(_exception), do: "duplicate JSON object key"
  end

  def decode_object(binary) when is_binary(binary) do
    decoders = [
      object_start: fn _old_acc -> {[], MapSet.new()} end,
      object_push: fn key, value, {pairs, keys} ->
        if MapSet.member?(keys, key) do
          raise DuplicateKeyError, key: key
        else
          {[{key, value} | pairs], MapSet.put(keys, key)}
        end
      end,
      object_finish: fn {pairs, _keys}, old_acc -> {Map.new(pairs), old_acc} end
    ]

    try do
      case JSON.decode(binary, nil, decoders) do
        {value, nil, rest} when rest in ["", <<>>] and is_map(value) -> {:ok, value}
        {_value, nil, _rest} -> {:error, :malformed_json}
        {:error, _reason} -> {:error, :malformed_json}
      end
    rescue
      DuplicateKeyError -> {:error, :duplicate_key}
    end
  end
end
