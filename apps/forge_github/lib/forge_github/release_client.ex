defmodule ForgeGitHub.ReleaseClient do
  @moduledoc """
  Installation-gated, bounded GitHub release metadata client.

  Release asset binaries and provider content URLs are outside the synchronization
  boundary. Responses retain only canonical metadata plus a bounded `asset_count`
  so bootstrap can report ignored assets without retaining their contents.
  """

  alias ForgeGitHub.{Client, Error, RepositoryReference}

  @max_id 9_223_372_036_854_775_807
  @max_page 2_147_483_647
  @max_body_codepoints 65_536
  @max_body_bytes 262_144
  @max_name_codepoints 255
  @max_name_bytes 1_020
  @max_node_id_bytes 512
  @max_login_codepoints 105
  @max_login_bytes 420
  @max_assets 512
  @login ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?(?:\[bot\])?$/

  @create_fields ~w(tag_name target_commitish name body draft prerelease)
  @update_fields @create_fields
  @canonical_fields ~w(id node_id tag_name name body draft prerelease target_commitish published_at created_at updated_at author asset_count unsupported_fields)
  @unsupported_release_fields ~w(assets_url body_html body_text discussion_url html_url make_latest mentions_count reactions tarball_url upload_url zipball_url)

  @spec list_releases_page(String.t(), String.t(), String.t(), nil | pos_integer(), keyword()) ::
          {:ok, %{releases: [map()], next_cursor: nil | pos_integer()}}
          | {:error, Error.t()}
  def list_releases_page(token, owner, repository, cursor, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         {:ok, page} <- normalize_cursor(cursor),
         true <- valid_options?(opts),
         {:ok, %{json: json, next_url: next_url}} <-
           Client.release_metadata_page(token, "#{base}?page=#{page}&per_page=100", opts),
         {:ok, releases} <- releases_from_json(json, owner, repository, token),
         {:ok, next_cursor} <- next_cursor(next_url, base, page) do
      {:ok, %{releases: releases, next_cursor: next_cursor}}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> error(:invalid_request)
    end
  end

  @spec get_release(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_release(token, owner, repository, release_id, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(release_id),
         true <- valid_options?(opts) do
      token
      |> Client.release_metadata_request(:get, "#{base}/#{release_id}", 200, opts)
      |> decode_release(owner, repository, token, release_id, nil)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @doc "Reads the provider's unique release identity for an exact encoded tag."
  @spec get_release_by_tag(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_release_by_tag(token, owner, repository, tag_name, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_tag_name(tag_name),
         true <- valid_options?(opts) do
      encoded_tag = URI.encode(tag_name, &URI.char_unreserved?/1)

      token
      |> Client.release_metadata_request(:get, "#{base}/tags/#{encoded_tag}", 200, opts)
      |> decode_release(owner, repository, token, nil, tag_name)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec create_release(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_release(token, owner, repository, attrs, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         {:ok, payload} <- normalize_create(attrs),
         {:ok, opts} <- request_options(opts, payload) do
      token
      |> Client.release_metadata_request(:post, base, 201, opts)
      |> decode_release(owner, repository, token, nil, payload["tag_name"])
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec update_release(String.t(), String.t(), String.t(), pos_integer(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update_release(token, owner, repository, release_id, attrs, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(release_id),
         {:ok, payload} <- normalize_update(attrs),
         {:ok, opts} <- request_options(opts, payload) do
      token
      |> Client.release_metadata_request(:patch, "#{base}/#{release_id}", 200, opts)
      |> decode_release(owner, repository, token, release_id, nil)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec delete_release(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          :ok | {:error, Error.t()}
  def delete_release(token, owner, repository, release_id, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(release_id),
         true <- valid_options?(opts),
         {:ok, nil} <-
           Client.release_metadata_request(
             token,
             :delete,
             "#{base}/#{release_id}",
             204,
             opts
           ) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      {:ok, _unexpected_body} -> error(:invalid_response)
      _invalid -> error(:invalid_request)
    end
  end

  defp repository_base(owner, repository) do
    if RepositoryReference.valid_owner?(owner) and
         RepositoryReference.valid_repository?(repository),
       do: {:ok, "/repos/#{owner}/#{repository}/releases"},
       else: :error
  end

  defp normalize_cursor(nil), do: {:ok, 1}

  defp normalize_cursor(cursor) when is_integer(cursor) and cursor in 1..@max_page,
    do: {:ok, cursor}

  defp normalize_cursor(_cursor), do: :error

  defp valid_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and not Keyword.has_key?(opts, :json) and
      case Keyword.get(opts, :gate_key) do
        {kind, id}
        when kind in [:github_installation, :one_time_run] and is_integer(id) and
               id in 1..@max_id ->
          true

        _invalid ->
          false
      end
  end

  defp valid_options?(_opts), do: false

  defp request_options(opts, payload) do
    if valid_options?(opts), do: {:ok, Keyword.put(opts, :json, payload)}, else: :error
  end

  defp normalize_create(attrs) do
    with {:ok, payload} <- normalize_attrs(attrs, @create_fields),
         true <- Map.has_key?(payload, "tag_name"),
         true <- Map.has_key?(payload, "target_commitish"),
         :ok <- validate_payload(payload) do
      {:ok, payload}
    else
      _invalid -> :error
    end
  end

  defp normalize_update(attrs) do
    with {:ok, payload} <- normalize_attrs(attrs, @update_fields),
         true <- map_size(payload) > 0,
         :ok <- validate_payload(payload) do
      {:ok, payload}
    else
      _invalid -> :error
    end
  end

  defp normalize_attrs(attrs, allowed)
       when is_map(attrs) and map_size(attrs) <= length(allowed) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key, allowed),
           false <- Map.has_key?(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp normalize_attrs(_attrs, _allowed), do: :error

  defp normalize_key(key, allowed) when is_atom(key) do
    normalized = Atom.to_string(key)
    if normalized in allowed, do: {:ok, normalized}, else: :error
  end

  defp normalize_key(key, allowed) when is_binary(key) do
    if key in allowed, do: {:ok, key}, else: :error
  end

  defp normalize_key(_key, _allowed), do: :error

  defp validate_payload(payload) do
    validations = [
      optional(payload, "tag_name", &validate_tag_name/1),
      optional(payload, "target_commitish", &validate_required_name/1),
      optional(payload, "name", &validate_optional_name/1),
      optional(payload, "body", &validate_body/1),
      optional(payload, "draft", &validate_boolean/1),
      optional(payload, "prerelease", &validate_boolean/1)
    ]

    if Enum.all?(validations, &(&1 == :ok)), do: :ok, else: :error
  end

  defp optional(payload, key, validator) do
    case Map.fetch(payload, key) do
      {:ok, value} -> validator.(value)
      :error -> :ok
    end
  end

  defp releases_from_json(releases, owner, repository, token)
       when is_list(releases) and length(releases) <= 100 do
    with {:ok, releases} <- decode_list(releases, owner, repository, token),
         true <- unique?(releases, "id"),
         true <- unique?(releases, "node_id"),
         true <- unique?(releases, "tag_name") do
      {:ok, releases}
    else
      _invalid -> error(:invalid_response)
    end
  end

  defp releases_from_json(_releases, _owner, _repository, _token),
    do: error(:invalid_response)

  defp decode_list(releases, owner, repository, token) do
    Enum.reduce_while(releases, {:ok, []}, fn release, {:ok, decoded} ->
      case release_from_json(release, owner, repository, token, nil, nil) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | decoded]}}
        {:error, :invalid_response} -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp unique?(values, key), do: length(values) == length(Enum.uniq_by(values, & &1[key]))

  defp decode_release(result, owner, repository, token, expected_id, expected_tag) do
    case result do
      {:ok, json} ->
        case release_from_json(json, owner, repository, token, expected_id, expected_tag) do
          {:ok, release} -> {:ok, release}
          {:error, :invalid_response} -> error(:invalid_response)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp release_from_json(
         %{
           "id" => id,
           "node_id" => node_id,
           "url" => url,
           "tag_name" => tag_name,
           "name" => name,
           "body" => body,
           "draft" => draft,
           "prerelease" => prerelease,
           "target_commitish" => target_commitish,
           "published_at" => published_at,
           "created_at" => created_at,
           "updated_at" => updated_at,
           "author" => author,
           "assets" => assets
         } = release,
         owner,
         repository,
         token,
         expected_id,
         expected_tag
       ) do
    with :ok <- validate_id(id),
         true <- is_nil(expected_id) or id == expected_id,
         true <- is_nil(expected_tag) or tag_name == expected_tag,
         true <- valid_node_id?(node_id),
         true <- release_url_matches?(url, owner, repository, id),
         :ok <- validate_tag_name(tag_name),
         :ok <- validate_optional_name(name),
         :ok <- validate_body(body),
         :ok <- validate_boolean(draft),
         :ok <- validate_boolean(prerelease),
         :ok <- validate_required_name(target_commitish),
         true <- valid_publication_state?(draft, published_at),
         true <- valid_timestamp?(created_at),
         true <- valid_timestamp?(updated_at),
         :ok <-
           validate_retained_strings(
             [
               node_id,
               tag_name,
               name,
               body,
               target_commitish,
               published_at,
               created_at,
               updated_at
             ],
             token
           ),
         {:ok, author} <- canonical_author(author, token),
         {:ok, asset_count} <- asset_count(assets) do
      canonical =
        release
        |> Map.take(@canonical_fields)
        |> Map.put("author", author)
        |> Map.put("asset_count", asset_count)
        |> Map.put("unsupported_fields", unsupported_release_fields(release))

      {:ok, canonical}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp release_from_json(
         _release,
         _owner,
         _repository,
         _token,
         _expected_id,
         _expected_tag
       ),
       do: {:error, :invalid_response}

  defp canonical_author(%{"id" => id, "node_id" => node_id, "login" => login}, token) do
    canonical = %{"id" => id, "node_id" => node_id, "login" => login}

    if validate_id(id) == :ok and valid_node_id?(node_id) and valid_login?(login) and
         ForgeAccounts.GitHubProfileSafety.validate(%{description: node_id}, token) == :ok and
         ForgeAccounts.GitHubProfileSafety.validate(%{description: login}, token) == :ok,
       do: {:ok, canonical},
       else: :error
  end

  defp canonical_author(_author, _token), do: :error

  defp asset_count(assets) when is_list(assets) and length(assets) <= @max_assets do
    if Enum.all?(assets, &is_map/1), do: {:ok, length(assets)}, else: :error
  end

  defp asset_count(_assets), do: :error

  defp unsupported_release_fields(release) do
    release
    |> Map.keys()
    |> Enum.filter(&(&1 in @unsupported_release_fields))
    |> Enum.sort()
  end

  defp next_cursor(nil, _base, _page), do: {:ok, nil}
  defp next_cursor(_next_url, _base, @max_page), do: error(:pagination_limit)

  defp next_cursor(next_url, base, page) when is_binary(next_url) do
    with {:ok, %URI{path: ^base, query: query}} <- URI.new(next_url),
         true <- is_binary(query),
         pairs <- Enum.to_list(URI.query_decoder(query)),
         true <- length(pairs) == 2,
         true <- length(pairs) == length(Enum.uniq_by(pairs, &elem(&1, 0))),
         %{"page" => encoded_page, "per_page" => "100"} <- Map.new(pairs),
         {next_page, ""} <- Integer.parse(encoded_page),
         true <- encoded_page == Integer.to_string(next_page),
         true <- next_page == page + 1 and next_page in 2..@max_page do
      {:ok, next_page}
    else
      _invalid -> error(:invalid_pagination)
    end
  rescue
    _exception -> error(:invalid_pagination)
  end

  defp next_cursor(_next_url, _base, _page), do: error(:invalid_pagination)

  defp release_url_matches?(url, owner, repository, id)
       when is_binary(url) and byte_size(url) <= 2_048 do
    with {:ok,
          %URI{
            scheme: scheme,
            host: host,
            port: port,
            userinfo: nil,
            query: nil,
            fragment: nil,
            path: path
          }} <- URI.new(url),
         true <- String.downcase(scheme || "") == "https",
         true <- String.downcase(host || "") == "api.github.com",
         true <- port in [nil, 443],
         false <- String.contains?(path, "//"),
         ["repos", response_owner, response_repository, "releases", encoded_id] <-
           String.split(path, "/", trim: true),
         true <- String.downcase(response_owner) == String.downcase(owner),
         true <- String.downcase(response_repository) == String.downcase(repository),
         {^id, ""} <- Integer.parse(encoded_id),
         true <- encoded_id == Integer.to_string(id) do
      true
    else
      _invalid -> false
    end
  rescue
    _exception -> false
  end

  defp release_url_matches?(_url, _owner, _repository, _id), do: false

  defp validate_id(id) when is_integer(id) and id in 1..@max_id, do: :ok
  defp validate_id(_id), do: :error

  defp validate_tag_name(value) do
    if valid_name?(value) and not String.starts_with?(value, "refs/") and
         match?({:ok, _}, GitCore.tracking_ref_name("release-validation", "refs/tags/#{value}")),
       do: :ok,
       else: :error
  end

  defp validate_required_name(value) do
    if valid_name?(value), do: :ok, else: :error
  end

  defp validate_optional_name(nil), do: :ok
  defp validate_optional_name(value), do: if(valid_name?(value, true), do: :ok, else: :error)

  defp valid_name?(value, allow_empty? \\ false) do
    valid_text?(value, @max_name_bytes) and (allow_empty? or value != "") and
      codepoints_at_most?(value, @max_name_codepoints)
  end

  defp validate_body(nil), do: :ok

  defp validate_body(value) do
    if valid_text?(value, @max_body_bytes) and codepoints_at_most?(value, @max_body_codepoints),
      do: :ok,
      else: :error
  end

  defp validate_boolean(value) when is_boolean(value), do: :ok
  defp validate_boolean(_value), do: :error

  defp valid_node_id?(value),
    do: valid_text?(value, @max_node_id_bytes) and value != "" and value == String.trim(value)

  defp valid_login?(value) do
    valid_text?(value, @max_login_bytes) and value != "" and
      codepoints_at_most?(value, @max_login_codepoints) and Regex.match?(@login, value)
  end

  defp valid_publication_state?(true, nil), do: true
  defp valid_publication_state?(false, published_at), do: valid_timestamp?(published_at)
  defp valid_publication_state?(_draft, _published_at), do: false

  defp valid_timestamp?(value) when is_binary(value) and byte_size(value) <= 64 do
    match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false

  defp validate_retained_strings(values, token) when is_list(values) and is_binary(token) do
    if Enum.all?(values, &safe_provider_string?(&1, token)), do: :ok, else: :error
  end

  defp safe_provider_string?(nil, _token), do: true

  defp safe_provider_string?(value, token) when is_binary(value) do
    chunks = safety_chunks(value)
    windows = chunks ++ Enum.zip_with(chunks, Enum.drop(chunks, 1), &(&1 <> &2))

    Enum.all?(windows, fn window ->
      ForgeAccounts.GitHubProfileSafety.validate(%{description: window}, token) == :ok
    end)
  end

  defp safe_provider_string?(_value, _token), do: false

  defp safety_chunks(value) do
    {chunks, current} =
      Enum.reduce(String.codepoints(value), {[], ""}, fn codepoint, {chunks, current} ->
        if byte_size(current) + byte_size(codepoint) <= 1_024 do
          {chunks, current <> codepoint}
        else
          {[current | chunks], codepoint}
        end
      end)

    case {chunks, current} do
      {[], ""} -> [""]
      {chunks, current} -> Enum.reverse([current | chunks])
    end
  end

  defp valid_text?(value, max_bytes) when is_binary(value) and byte_size(value) <= max_bytes do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp valid_text?(_value, _max_bytes), do: false

  defp codepoints_at_most?(value, limit), do: codepoints_at_most?(value, limit, 0)
  defp codepoints_at_most?("", _limit, _count), do: true
  defp codepoints_at_most?(_value, limit, count) when count >= limit, do: false

  defp codepoints_at_most?(value, limit, count) do
    case String.next_codepoint(value) do
      {_codepoint, rest} -> codepoints_at_most?(rest, limit, count + 1)
      nil -> true
    end
  end

  defp error(kind), do: {:error, Error.new(kind)}
end
