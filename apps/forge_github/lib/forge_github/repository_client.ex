defmodule ForgeGitHub.RepositoryClient do
  @moduledoc "Installation-gated, bounded GitHub repository creation and metadata updates."

  alias ForgeGitHub.{Client, Error, Repository, RepositoryReference}

  @max_installation_id 9_223_372_036_854_775_807
  @fields ~w(name description visibility default_branch archived)
  @create_fields ~w(name description visibility)

  @spec create_organization_repository(String.t(), String.t(), map(), keyword()) ::
          {:ok, Repository.t()} | {:error, Error.t()}
  def create_organization_repository(token, owner, attrs, opts) do
    with true <- RepositoryReference.valid_owner?(owner),
         {:ok, payload} <- normalize_create_attrs(attrs),
         true <- valid_options?(opts),
         {:ok, json} <-
           Client.repository_metadata_request(
             token,
             :post,
             "/orgs/#{owner}/repos",
             201,
             Keyword.put(opts, :json, payload)
           ),
         {:ok, %Repository{} = created} <- decode_repository(json),
         :ok <- validate_created_identity(created, owner, payload["name"]) do
      {:ok, created}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :identity_mismatch} -> error(:invalid_response)
      _invalid -> error(:invalid_request)
    end
  end

  defp validate_created_identity(created, owner, name) do
    if created.owner_login == owner and created.name == name and
         created.full_name == "#{owner}/#{name}",
       do: :ok,
       else: {:error, :identity_mismatch}
  end

  @spec update_repository(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, Repository.t()} | {:error, Error.t()}
  def update_repository(token, owner, repository, attrs, opts) do
    with true <- RepositoryReference.valid_owner?(owner),
         true <- RepositoryReference.valid_repository?(repository),
         {:ok, payload} <- normalize_attrs(attrs),
         true <- valid_options?(opts),
         {:ok, json} <-
           Client.repository_metadata_request(
             token,
             :patch,
             "/repos/#{owner}/#{repository}",
             200,
             Keyword.put(opts, :json, payload)
           ),
         {:ok, %Repository{} = updated} <- decode_repository(json) do
      {:ok, updated}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> error(:invalid_request)
    end
  end

  defp normalize_create_attrs(attrs) when is_map(attrs) and map_size(attrs) in 2..3 do
    with {:ok, payload} <- normalize_attrs(attrs),
         true <- Enum.all?(Map.keys(payload), &(&1 in @create_fields)),
         true <- Map.has_key?(payload, "name") and Map.has_key?(payload, "visibility") do
      {:ok,
       if(is_nil(payload["description"]), do: Map.delete(payload, "description"), else: payload)}
    else
      _invalid -> :error
    end
  end

  defp normalize_create_attrs(_attrs), do: :error

  defp normalize_attrs(attrs) when is_map(attrs) and map_size(attrs) in 1..5 do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, payload} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(payload, key),
           :ok <- validate_field(key, value) do
        {:cont, {:ok, Map.put(payload, key, normalize_value(key, value))}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp normalize_attrs(_attrs), do: :error

  defp normalize_key(key) when is_atom(key) do
    key = Atom.to_string(key)
    if key in @fields, do: {:ok, key}, else: :error
  end

  defp normalize_key(key) when is_binary(key) do
    if key in @fields, do: {:ok, key}, else: :error
  end

  defp normalize_key(_key), do: :error

  defp validate_field("name", value) when is_binary(value) do
    if RepositoryReference.valid_repository?(value), do: :ok, else: :error
  end

  defp validate_field("description", nil), do: :ok

  defp validate_field("description", value)
       when is_binary(value) and byte_size(value) <= 1_000 do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch, do: :ok, else: :error
  end

  defp validate_field("description", _value), do: :error

  defp validate_field("visibility", value) when value in [:public, :private, "public", "private"],
    do: :ok

  defp validate_field("default_branch", value), do: validate_text(value, 255)
  defp validate_field("archived", value) when is_boolean(value), do: :ok
  defp validate_field(_key, _value), do: :error

  defp validate_text(value, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum do
    if String.valid?(value) and value == String.trim(value) and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: :error
  end

  defp validate_text(_value, _maximum), do: :error

  defp normalize_value("visibility", value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(_key, value), do: value

  defp valid_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and not Keyword.has_key?(opts, :json) and
      match?(
        {:ok, {:github_installation, id}}
        when is_integer(id) and id in 1..@max_installation_id,
        Keyword.fetch(opts, :gate_key)
      )
  end

  defp valid_options?(_opts), do: false

  defp decode_repository(json) do
    case Repository.from_json(json) do
      {:ok, %Repository{} = repository} -> {:ok, repository}
      _invalid -> error(:invalid_response)
    end
  end

  defp error(kind), do: {:error, Error.new(kind)}
end
