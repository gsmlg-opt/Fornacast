defmodule ForgeGitHub.RefObservation do
  @moduledoc """
  Reads one current GitHub branch tip from an authenticated immutable repository.

  The repository identity is checked before and after the reference read so a
  rename, transfer, or path replacement cannot silently bind the observation to
  a different repository.
  """

  alias ForgeGitHub.{Client, Error, Repository, RepositoryReference}

  @oid ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @spec observe(
          String.t(),
          String.t(),
          String.t(),
          %{github_object_id: pos_integer(), github_node_id: String.t()},
          String.t(),
          keyword()
        ) ::
          {:ok,
           %{
             repository: %{github_object_id: pos_integer(), github_node_id: String.t()},
             ref_name: String.t(),
             oid: String.t()
           }}
          | {:error, Error.t()}
  def observe(token, owner, repository, expected_repository, full_ref, opts) do
    with :ok <- validate_request(owner, repository, expected_repository, full_ref, opts) do
      do_observe(token, owner, repository, expected_repository, full_ref, opts)
    else
      _invalid -> error(:invalid_request)
    end
  end

  defp do_observe(token, owner, repository, expected_repository, full_ref, opts) do
    with {:ok, before} <- Client.repository(token, owner, repository, opts),
         :ok <- authenticate_repository(before, owner, repository, expected_repository),
         {:ok, response} <-
           Client.request(token, :get, ref_path(owner, repository, full_ref), opts),
         {:ok, oid} <- decode_ref(response, full_ref),
         {:ok, after_read} <- Client.repository(token, owner, repository, opts),
         :ok <- authenticate_repository(after_read, owner, repository, expected_repository),
         true <- same_repository?(before, after_read) do
      {:ok,
       %{
         repository: expected_repository,
         ref_name: full_ref,
         oid: oid
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> error(:invalid_response)
    end
  end

  defp validate_request(owner, repository, expected_repository, full_ref, opts) do
    with true <- RepositoryReference.valid_owner?(owner),
         true <- RepositoryReference.valid_repository?(repository),
         true <- valid_repository_identity?(expected_repository),
         true <- valid_branch_ref?(full_ref),
         true <- valid_options?(opts) do
      :ok
    end
  end

  defp valid_repository_identity?(
         %{
           github_object_id: id,
           github_node_id: node_id
         } = identity
       )
       when map_size(identity) == 2 do
    is_integer(id) and id in 1..9_223_372_036_854_775_807 and identity_text?(node_id)
  end

  defp valid_repository_identity?(_identity), do: false

  defp valid_branch_ref?("refs/heads/" <> _suffix = full_ref) do
    match?({:ok, _tracking_ref}, GitCore.tracking_ref_name("provider-observation", full_ref))
  end

  defp valid_branch_ref?(_full_ref), do: false

  defp valid_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and not Keyword.has_key?(opts, :json) and
      match?(
        {:github_installation, id}
        when is_integer(id) and id in 1..9_223_372_036_854_775_807,
        Keyword.get(opts, :gate_key)
      )
  end

  defp valid_options?(_opts), do: false

  defp authenticate_repository(
         %Repository{} = observed,
         owner,
         repository,
         %{github_object_id: expected_id, github_node_id: expected_node_id}
       ) do
    requested_full_name = String.downcase("#{owner}/#{repository}")

    if observed.id == expected_id and observed.node_id == expected_node_id and
         String.downcase(observed.owner_login) == String.downcase(owner) and
         String.downcase(observed.name) == String.downcase(repository) and
         String.downcase(observed.full_name) == requested_full_name,
       do: :ok,
       else: :error
  end

  defp same_repository?(%Repository{} = before, %Repository{} = after_read) do
    {before.id, before.node_id, before.full_name} ==
      {after_read.id, after_read.node_id, after_read.full_name}
  end

  defp decode_ref(
         %{
           "ref" => full_ref,
           "node_id" => node_id,
           "object" => %{"type" => "commit", "sha" => oid}
         },
         full_ref
       ) do
    if identity_text?(node_id) and valid_oid?(oid), do: {:ok, oid}, else: :error
  end

  defp decode_ref(_response, _full_ref), do: :error

  defp ref_path(owner, repository, "refs/" <> relative_ref) do
    encoded_ref =
      relative_ref
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn character -> URI.char_unreserved?(character) end))

    "/repos/#{owner}/#{repository}/git/ref/#{encoded_ref}"
  end

  defp valid_oid?(oid) when is_binary(oid), do: Regex.match?(@oid, oid)
  defp valid_oid?(_oid), do: false

  defp identity_text?(value) when is_binary(value) and byte_size(value) in 1..512 do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp identity_text?(_value), do: false

  defp error(kind), do: {:error, Error.new(kind)}
end
