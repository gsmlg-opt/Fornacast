defmodule ForgeGitHub.PullClient do
  @moduledoc """
  Bounded GitHub pull-request metadata client.

  Each REST listing fetches exactly one page. GitHub does not expose an
  updated-since filter for pull-request listings, so callers retain the page
  cursor only for the duration of one full sweep.

  Creating a draft is supported by REST. Changing the draft state of an
  existing pull request is an explicit GraphQL effect so a synchronization
  worker can recover it independently from other metadata changes.

  Create responses are structurally validated, but a synchronization
  coordinator must still match their head/base repository, ref, and SHA tuple
  against its durable effect marker before confirming the external effect.
  """

  alias ForgeGitHub.{Client, Error, RepositoryReference}

  @max_id 9_223_372_036_854_775_807
  @max_page 2_147_483_647
  @max_body_codepoints 65_536
  @max_body_bytes 262_144
  @max_title_codepoints 256
  @max_title_bytes 1_024
  @max_ref_codepoints 1_024
  @max_ref_bytes 4_096
  @max_node_id_bytes 512
  @max_full_name_bytes 256
  @login ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?(?:\[bot\])?$/
  @oid ~r/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/

  @create_fields ~w(title body head head_repo base draft maintainer_can_modify)
  @update_fields ~w(title body state base maintainer_can_modify)

  @convert_to_draft """
  mutation ConvertPullRequestToDraft($input: ConvertPullRequestToDraftInput!) {
    convertPullRequestToDraft(input: $input) {
      pullRequest { id isDraft }
    }
  }
  """

  @mark_ready """
  mutation MarkPullRequestReadyForReview($input: MarkPullRequestReadyForReviewInput!) {
    markPullRequestReadyForReview(input: $input) {
      pullRequest { id isDraft }
    }
  }
  """

  @spec create_pull(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_pull(token, owner, repository, attrs, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         {:ok, payload} <- normalize_create(attrs),
         {:ok, opts} <- request_options(opts, payload) do
      token
      |> Client.pull_metadata_request(:post, "#{base}/pulls", 201, opts)
      |> decode_pull(owner, repository, :detail, nil)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec get_pull(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_pull(token, owner, repository, pull_number, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(pull_number),
         true <- valid_options?(opts) do
      token
      |> Client.pull_metadata_request(:get, "#{base}/pulls/#{pull_number}", 200, opts)
      |> decode_pull(owner, repository, :detail, pull_number)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec update_pull(String.t(), String.t(), String.t(), pos_integer(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update_pull(token, owner, repository, pull_number, attrs, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(pull_number),
         {:ok, payload} <- normalize_update(attrs),
         {:ok, opts} <- request_options(opts, payload) do
      token
      |> Client.pull_metadata_request(
        :patch,
        "#{base}/pulls/#{pull_number}",
        200,
        opts
      )
      |> decode_pull(owner, repository, :detail, pull_number)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec set_draft(String.t(), String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def set_draft(token, pull_node_id, desired, opts) do
    with true <- valid_node_id?(pull_node_id),
         true <- is_boolean(desired),
         true <- valid_options?(opts) do
      execute_draft_mutation(token, pull_node_id, desired, opts)
    else
      _invalid -> error(:invalid_request)
    end
  end

  defp execute_draft_mutation(token, pull_node_id, desired, opts) do
    {query, field} = draft_mutation(desired)

    payload = %{
      "query" => query,
      "variables" => %{"input" => %{"pullRequestId" => pull_node_id}}
    }

    with {:ok, response} <- Client.pull_graphql_request(token, payload, opts),
         {:ok, pull} <- draft_response(response, field, pull_node_id, desired) do
      {:ok, pull}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> error(:invalid_response)
    end
  end

  @spec list_pulls_page(
          String.t(),
          String.t(),
          String.t(),
          nil | pos_integer(),
          keyword()
        ) ::
          {:ok, %{pulls: [map()], next_cursor: nil | pos_integer()}} | {:error, Error.t()}
  def list_pulls_page(token, owner, repository, cursor, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         {:ok, page} <- normalize_cursor(cursor),
         true <- valid_options?(opts) do
      query = list_query(page)
      path = "#{base}/pulls?#{URI.encode_query(query)}"

      with {:ok, %{json: json, next_url: next_url}} <-
             Client.pull_metadata_page(token, path, opts),
           {:ok, pulls} <- pulls_from_json(json, owner, repository),
           {:ok, next_cursor} <- next_cursor(next_url, "#{base}/pulls", query, page) do
        {:ok, %{pulls: pulls, next_cursor: next_cursor}}
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, :invalid_response} -> error(:invalid_response)
        {:error, :invalid_pagination} -> error(:invalid_pagination)
        {:error, :pagination_limit} -> error(:pagination_limit)
      end
    else
      _invalid -> error(:invalid_request)
    end
  end

  defp repository_base(owner, repository) do
    if RepositoryReference.valid_owner?(owner) and
         RepositoryReference.valid_repository?(repository),
       do: {:ok, "/repos/#{owner}/#{repository}"},
       else: :error
  end

  defp request_options(opts, payload) do
    if valid_options?(opts),
      do: {:ok, Keyword.put(opts, :json, payload)},
      else: :error
  end

  defp valid_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and not Keyword.has_key?(opts, :json)
  end

  defp valid_options?(_opts), do: false

  defp normalize_create(attrs) do
    with {:ok, payload} <- normalize_attrs(attrs, @create_fields),
         true <- Enum.all?(~w(title head base), &Map.has_key?(payload, &1)),
         :ok <- validate_create_payload(payload) do
      {:ok, payload}
    else
      _invalid -> :error
    end
  end

  defp normalize_update(attrs) do
    with {:ok, payload} <- normalize_attrs(attrs, @update_fields),
         true <- map_size(payload) > 0,
         :ok <- validate_update_payload(payload) do
      {:ok, payload}
    else
      _invalid -> :error
    end
  end

  defp normalize_attrs(attrs, allowed)
       when is_map(attrs) and map_size(attrs) <= length(allowed) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key, allowed),
           false <- Map.has_key?(normalized, key),
           {:ok, value} <- normalize_value(key, value) do
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

  defp normalize_value("state", state) when state in [:open, :closed],
    do: {:ok, Atom.to_string(state)}

  defp normalize_value("state", state) when state in ["open", "closed"], do: {:ok, state}
  defp normalize_value(_key, value), do: {:ok, value}

  defp validate_create_payload(payload) do
    validations = [
      validate_title(payload["title"]),
      validate_ref(payload["head"]),
      validate_ref(payload["base"]),
      optional(payload, "body", &validate_optional_body/1),
      optional(payload, "head_repo", &validate_repository_name/1),
      optional(payload, "draft", &validate_boolean/1),
      optional(payload, "maintainer_can_modify", &validate_boolean/1)
    ]

    if Enum.all?(validations, &(&1 == :ok)), do: :ok, else: :error
  end

  defp validate_update_payload(payload) do
    validations = [
      optional(payload, "title", &validate_title/1),
      optional(payload, "body", &validate_optional_body/1),
      optional(payload, "state", &validate_state/1),
      optional(payload, "base", &validate_ref/1),
      optional(payload, "maintainer_can_modify", &validate_boolean/1)
    ]

    if Enum.all?(validations, &(&1 == :ok)), do: :ok, else: :error
  end

  defp optional(payload, key, validator) do
    case Map.fetch(payload, key) do
      {:ok, value} -> validator.(value)
      :error -> :ok
    end
  end

  defp validate_title(value) do
    if valid_text?(value, @max_title_bytes) and value != "" and
         codepoints_at_most?(value, @max_title_codepoints),
       do: :ok,
       else: :error
  end

  defp validate_optional_body(nil), do: :ok

  defp validate_optional_body(value) do
    if valid_text?(value, @max_body_bytes) and
         codepoints_at_most?(value, @max_body_codepoints),
       do: :ok,
       else: :error
  end

  defp validate_ref(value) do
    if valid_text?(value, @max_ref_bytes) and value != "" and
         codepoints_at_most?(value, @max_ref_codepoints) and not control_character?(value),
       do: :ok,
       else: :error
  end

  defp validate_repository_name(value) do
    if RepositoryReference.valid_repository?(value), do: :ok, else: :error
  end

  defp validate_state(value) when value in ["open", "closed"], do: :ok
  defp validate_state(_value), do: :error
  defp validate_boolean(value) when is_boolean(value), do: :ok
  defp validate_boolean(_value), do: :error

  defp draft_mutation(true), do: {@convert_to_draft, "convertPullRequestToDraft"}
  defp draft_mutation(false), do: {@mark_ready, "markPullRequestReadyForReview"}

  defp draft_response(%{"data" => data} = response, field, node_id, desired)
       when is_map(data) do
    case Map.get(data, field) do
      %{"pullRequest" => %{"id" => ^node_id, "isDraft" => ^desired} = pull}
      when map_size(pull) <= 16 ->
        if Map.get(response, "errors", []) == [], do: {:ok, pull}, else: :error

      _invalid ->
        :error
    end
  end

  defp draft_response(_response, _field, _node_id, _desired), do: :error

  defp pulls_from_json(values, owner, repository)
       when is_list(values) and length(values) <= 100 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, pulls} ->
      case pull_from_json(value, owner, repository, :list, nil) do
        {:ok, pull} -> {:cont, {:ok, [pull | pulls]}}
        {:error, :invalid_response} -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, pulls} -> {:ok, Enum.reverse(pulls)}
      error -> error
    end
  end

  defp pulls_from_json(_values, _owner, _repository), do: {:error, :invalid_response}

  defp pull_from_json(
         %{
           "id" => id,
           "node_id" => node_id,
           "number" => number,
           "title" => title,
           "body" => body,
           "state" => state,
           "draft" => draft,
           "user" => user,
           "created_at" => created_at,
           "updated_at" => updated_at,
           "closed_at" => closed_at,
           "merged_at" => merged_at,
           "merge_commit_sha" => merge_commit_sha,
           "head" => head,
           "base" => base
         } = pull,
         owner,
         repository,
         mode,
         expected_number
       ) do
    with :ok <- validate_id(id),
         :ok <- validate_id(number),
         true <- is_nil(expected_number) or number == expected_number,
         true <- valid_node_id?(node_id),
         :ok <- validate_title(title),
         :ok <- validate_optional_body(body),
         :ok <- validate_state(state),
         true <- is_boolean(draft),
         :ok <- validate_response_author(user),
         true <- valid_timestamp?(created_at),
         true <- valid_timestamp?(updated_at),
         true <- valid_optional_timestamp?(closed_at),
         true <- valid_optional_timestamp?(merged_at),
         true <- valid_optional_oid?(merge_commit_sha),
         :ok <- validate_head_side(head),
         :ok <- validate_side(base),
         :ok <- validate_repository_pair(head, base),
         :ok <- validate_base_repository(base, owner, repository),
         :ok <- validate_detail(pull, mode) do
      {:ok, normalize_detail(pull, mode)}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp pull_from_json(_pull, _owner, _repository, _mode, _expected_number),
    do: {:error, :invalid_response}

  defp validate_head_side(%{"ref" => ref, "sha" => sha, "repo" => nil}) do
    with :ok <- validate_ref(ref), true <- valid_oid?(sha) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_head_side(side), do: validate_side(side)

  defp validate_side(%{"ref" => ref, "sha" => sha, "repo" => repository}) do
    with :ok <- validate_ref(ref),
         true <- valid_oid?(sha),
         :ok <- validate_repository_identity(repository) do
      :ok
    else
      _invalid -> :error
    end
  end

  defp validate_side(_side), do: :error

  defp validate_repository_identity(%{
         "id" => id,
         "node_id" => node_id,
         "full_name" => full_name
       }) do
    with :ok <- validate_id(id),
         true <- valid_node_id?(node_id),
         {:ok, _owner, _repository} <- split_full_name(full_name) do
      :ok
    else
      _invalid -> :error
    end
  end

  defp validate_repository_identity(_repository), do: :error

  defp validate_repository_pair(%{"repo" => nil}, %{"repo" => base}) when is_map(base), do: :ok

  defp validate_repository_pair(%{"repo" => head}, %{"repo" => base}) do
    coordinates = [
      {head["id"], base["id"]},
      {head["node_id"], base["node_id"]},
      {normalize_full_name(head["full_name"]), normalize_full_name(base["full_name"])}
    ]

    if Enum.any?(coordinates, fn {left, right} -> left == right end) and
         not Enum.all?(coordinates, fn {left, right} -> left == right end),
       do: :error,
       else: :ok
  end

  defp validate_repository_pair(_head, _base), do: :error

  defp normalize_full_name(value) when is_binary(value), do: String.downcase(value)
  defp normalize_full_name(value), do: value

  defp validate_base_repository(%{"repo" => %{"full_name" => full_name}}, owner, repository) do
    with {:ok, response_owner, response_repository} <- split_full_name(full_name),
         true <- String.downcase(response_owner) == String.downcase(owner),
         true <- String.downcase(response_repository) == String.downcase(repository) do
      :ok
    else
      _invalid -> :error
    end
  end

  defp validate_base_repository(_base, _owner, _repository), do: :error

  defp split_full_name(full_name)
       when is_binary(full_name) and byte_size(full_name) <= @max_full_name_bytes do
    case String.split(full_name, "/", parts: 3) do
      [owner, repository]
      when owner != "" and repository != "" ->
        if RepositoryReference.valid_owner?(owner) and
             RepositoryReference.valid_repository?(repository),
           do: {:ok, owner, repository},
           else: :error

      _invalid ->
        :error
    end
  end

  defp split_full_name(_full_name), do: :error

  defp validate_detail(_pull, :list), do: :ok

  defp validate_detail(
         %{
           "merged" => merged,
           "mergeable" => mergeable,
           "mergeable_state" => mergeable_state
         } = pull,
         :detail
       ) do
    rebaseable = Map.get(pull, "rebaseable")

    if is_boolean(merged) and optional_boolean?(mergeable) and optional_boolean?(rebaseable) and
         valid_text?(mergeable_state, 128) and mergeable_state != "",
       do: :ok,
       else: :error
  end

  defp validate_detail(_pull, :detail), do: :error

  defp normalize_detail(pull, :detail), do: Map.put_new(pull, "rebaseable", nil)
  defp normalize_detail(pull, :list), do: pull

  defp validate_response_author(nil), do: :ok

  defp validate_response_author(%{"id" => id, "node_id" => node_id, "login" => login}) do
    if validate_id(id) == :ok and valid_node_id?(node_id) and valid_login?(login),
      do: :ok,
      else: :error
  end

  defp validate_response_author(_user), do: :error

  defp valid_login?(value) do
    valid_text?(value, 420) and value != "" and codepoints_at_most?(value, 105) and
      Regex.match?(@login, value)
  end

  defp valid_node_id?(value), do: valid_text?(value, @max_node_id_bytes) and value != ""

  defp valid_timestamp?(value) when is_binary(value) and byte_size(value) <= 64 do
    match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false
  defp valid_optional_timestamp?(nil), do: true
  defp valid_optional_timestamp?(value), do: valid_timestamp?(value)
  defp valid_optional_oid?(nil), do: true
  defp valid_optional_oid?(value), do: valid_oid?(value)
  defp valid_oid?(value) when is_binary(value), do: Regex.match?(@oid, value)
  defp valid_oid?(_value), do: false
  defp optional_boolean?(value), do: is_nil(value) or is_boolean(value)

  defp validate_id(id) when is_integer(id) and id in 1..@max_id, do: :ok
  defp validate_id(_id), do: :error

  defp normalize_cursor(nil), do: {:ok, 1}

  defp normalize_cursor(cursor) when is_integer(cursor) and cursor in 1..@max_page,
    do: {:ok, cursor}

  defp normalize_cursor(_cursor), do: :error

  defp list_query(page) do
    %{
      "direction" => "asc",
      "page" => Integer.to_string(page),
      "per_page" => "100",
      "sort" => "updated",
      "state" => "all"
    }
  end

  defp next_cursor(nil, _allowed_path, _query, _page), do: {:ok, nil}

  defp next_cursor(_next_url, _allowed_path, _query, @max_page),
    do: {:error, :pagination_limit}

  defp next_cursor(next_url, allowed_path, query, page) when is_binary(next_url) do
    with {:ok, %URI{path: ^allowed_path, query: encoded_query}} <- URI.new(next_url),
         true <- is_binary(encoded_query),
         {:ok, pairs} <- query_pairs(encoded_query),
         {encoded_page, link_query} <- Map.pop(pairs, "page"),
         true <- link_query == Map.delete(query, "page"),
         {next_page, ""} <- Integer.parse(encoded_page),
         true <- next_page == page + 1 and next_page in 2..@max_page do
      {:ok, next_page}
    else
      _invalid -> {:error, :invalid_pagination}
    end
  rescue
    _exception -> {:error, :invalid_pagination}
  end

  defp query_pairs(encoded_query) do
    pairs = Enum.to_list(URI.query_decoder(encoded_query))

    if pairs != [] and length(pairs) == length(Enum.uniq_by(pairs, &elem(&1, 0))),
      do: {:ok, Map.new(pairs)},
      else: :error
  rescue
    _exception -> :error
  end

  defp decode_pull({:ok, json}, owner, repository, mode, expected_number) do
    case pull_from_json(json, owner, repository, mode, expected_number) do
      {:ok, pull} -> {:ok, pull}
      {:error, :invalid_response} -> error(:invalid_response)
    end
  end

  defp decode_pull(
         {:error, %Error{} = error},
         _owner,
         _repository,
         _mode,
         _expected_number
       ),
       do: {:error, error}

  defp valid_text?(value, max_bytes) when is_binary(value) and byte_size(value) <= max_bytes do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp valid_text?(_value, _max_bytes), do: false

  defp control_character?(value), do: Regex.match?(~r/[\x00-\x1F\x7F]/u, value)

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
