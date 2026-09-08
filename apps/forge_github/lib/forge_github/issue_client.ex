defmodule ForgeGitHub.IssueClient do
  @moduledoc """
  Bounded GitHub issue and issue-comment synchronization client.

  Every request is serialized by an installation-scoped request gate. Updated
  resource listings return one page and a small integer cursor; callers retain
  the immutable `since` value until the cursor is exhausted.

  Fornacast accepts issue and comment bodies of at most 65,536 Unicode
  codepoints and 262,144 UTF-8 bytes. This is a local compatibility policy based
  on GitHub's observed validation behavior; the REST parameter documentation
  does not publish a body `maxLength` contract.
  """

  alias ForgeGitHub.{Client, Error, RepositoryReference}

  @max_id 9_223_372_036_854_775_807
  @max_page 2_147_483_647
  @max_body_codepoints 65_536
  @max_body_bytes 262_144
  @max_title_codepoints 256
  @max_title_bytes 1_024
  @max_set_items 100
  @max_name_codepoints 255
  @max_name_bytes 1_020
  @max_login_codepoints 105
  @max_login_bytes 420
  @max_node_id_bytes 512
  @login ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?(?:\[bot\])?$/

  @issue_create_fields ~w(title body labels assignees)
  @issue_update_fields ~w(title body state state_reason labels assignees)
  @comment_fields ~w(body)
  @response_state_reasons [nil, "completed", "not_planned", "duplicate", "reopened"]

  @spec create_issue(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_issue(token, owner, repository, attrs, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         {:ok, payload} <- normalize_issue_create(attrs),
         {:ok, opts} <- request_options(opts, payload) do
      token
      |> Client.issue_metadata_request(:post, "#{base}/issues", 201, opts)
      |> decode_resource(&issue_from_json/1)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec get_issue(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_issue(token, owner, repository, issue_number, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(issue_number),
         true <- valid_options?(opts) do
      token
      |> Client.issue_metadata_request(:get, "#{base}/issues/#{issue_number}", 200, opts)
      |> decode_resource(&issue_from_json/1)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @doc """
  Fetches the canonical issue record that backs a pull request.

  GitHub gives issues and pull requests distinct object identities. This
  endpoint therefore requires the issue response's pull-request signpost and
  never treats a pull object ID as an issue object ID.
  """
  @spec get_pull_issue(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_pull_issue(token, owner, repository, issue_number, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(issue_number),
         true <- valid_options?(opts) do
      token
      |> Client.issue_metadata_request(:get, "#{base}/issues/#{issue_number}", 200, opts)
      |> decode_resource(&pull_issue_from_json(&1, owner, repository, issue_number))
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec update_issue(String.t(), String.t(), String.t(), pos_integer(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update_issue(token, owner, repository, issue_number, attrs, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(issue_number),
         {:ok, payload} <- normalize_issue_update(attrs),
         {:ok, opts} <- request_options(opts, payload) do
      token
      |> Client.issue_metadata_request(
        :patch,
        "#{base}/issues/#{issue_number}",
        200,
        opts
      )
      |> decode_resource(&issue_from_json/1)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @doc """
  Updates the canonical issue record backing an existing pull request.

  The response must retain the exact pull-request signpost so the caller never
  acknowledges an ordinary issue or a pull from another repository.
  """
  @spec update_pull_issue(
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          map(),
          keyword()
        ) :: {:ok, map()} | {:error, Error.t()}
  def update_pull_issue(token, owner, repository, issue_number, attrs, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(issue_number),
         {:ok, payload} <- normalize_issue_update(attrs),
         {:ok, opts} <- request_options(opts, payload) do
      token
      |> Client.issue_metadata_request(
        :patch,
        "#{base}/issues/#{issue_number}",
        200,
        opts
      )
      |> decode_resource(&pull_issue_from_json(&1, owner, repository, issue_number))
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec create_comment(
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          map(),
          keyword()
        ) :: {:ok, map()} | {:error, Error.t()}
  def create_comment(token, owner, repository, issue_number, attrs, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(issue_number),
         {:ok, payload} <- normalize_comment(attrs),
         {:ok, opts} <- request_options(opts, payload) do
      result =
        Client.issue_metadata_request(
          token,
          :post,
          "#{base}/issues/#{issue_number}/comments",
          201,
          opts
        )

      decode_resource(result, &comment_from_json(&1, owner, repository, issue_number))
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec get_comment(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_comment(token, owner, repository, comment_id, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(comment_id),
         true <- valid_options?(opts) do
      result =
        Client.issue_metadata_request(
          token,
          :get,
          "#{base}/issues/comments/#{comment_id}",
          200,
          opts
        )

      decode_resource(result, &comment_from_json(&1, owner, repository, nil))
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec update_comment(String.t(), String.t(), String.t(), pos_integer(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update_comment(token, owner, repository, comment_id, attrs, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(comment_id),
         {:ok, payload} <- normalize_comment(attrs),
         {:ok, opts} <- request_options(opts, payload) do
      result =
        Client.issue_metadata_request(
          token,
          :patch,
          "#{base}/issues/comments/#{comment_id}",
          200,
          opts
        )

      decode_resource(result, &comment_from_json(&1, owner, repository, nil))
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec delete_comment(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          :ok | {:error, Error.t()}
  def delete_comment(token, owner, repository, comment_id, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         :ok <- validate_id(comment_id),
         true <- valid_options?(opts),
         {:ok, nil} <-
           Client.issue_metadata_request(
             token,
             :delete,
             "#{base}/issues/comments/#{comment_id}",
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

  @spec list_updated_issues_page(
          String.t(),
          String.t(),
          String.t(),
          DateTime.t(),
          nil | pos_integer(),
          keyword()
        ) ::
          {:ok, %{issues: [map()], next_cursor: nil | pos_integer()}}
          | {:error, Error.t()}
  def list_updated_issues_page(token, owner, repository, since, cursor, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         {:ok, since} <- normalize_since(since),
         {:ok, page} <- normalize_cursor(cursor),
         true <- valid_options?(opts) do
      query =
        updated_query(since, page)
        |> Map.put("state", "all")

      path = "#{base}/issues?#{URI.encode_query(query)}"

      with {:ok, %{json: json, next_url: next_url}} <-
             Client.issue_metadata_page(token, path, opts),
           {:ok, issues} <- issues_from_json(json),
           {:ok, next_cursor} <- next_cursor(next_url, "#{base}/issues", query, page) do
        {:ok, %{issues: issues, next_cursor: next_cursor}}
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

  @spec list_updated_comments_page(
          String.t(),
          String.t(),
          String.t(),
          DateTime.t(),
          nil | pos_integer(),
          keyword()
        ) ::
          {:ok, %{comments: [map()], next_cursor: nil | pos_integer()}}
          | {:error, Error.t()}
  def list_updated_comments_page(token, owner, repository, since, cursor, opts) do
    with {:ok, base} <- repository_base(owner, repository),
         {:ok, since} <- normalize_since(since),
         {:ok, page} <- normalize_cursor(cursor),
         true <- valid_options?(opts) do
      query = updated_query(since, page)
      path = "#{base}/issues/comments?#{URI.encode_query(query)}"

      with {:ok, %{json: json, next_url: next_url}} <-
             Client.issue_metadata_page(token, path, opts),
           {:ok, comments} <- comments_from_json(json, owner, repository),
           {:ok, next_cursor} <- next_cursor(next_url, "#{base}/issues/comments", query, page) do
        {:ok, %{comments: comments, next_cursor: next_cursor}}
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

  defp normalize_issue_create(attrs) do
    with {:ok, payload} <- normalize_attrs(attrs, @issue_create_fields),
         true <- Map.has_key?(payload, "title"),
         :ok <- validate_issue_payload(payload, :create) do
      {:ok, payload}
    else
      _invalid -> :error
    end
  end

  defp normalize_issue_update(attrs) do
    with {:ok, payload} <- normalize_attrs(attrs, @issue_update_fields),
         true <- map_size(payload) > 0,
         :ok <- validate_issue_payload(payload, :update),
         :ok <- validate_state_reason_change(payload) do
      {:ok, payload}
    else
      _invalid -> :error
    end
  end

  defp normalize_comment(attrs) do
    with {:ok, %{"body" => body} = payload} <- normalize_attrs(attrs, @comment_fields),
         :ok <- validate_body(body, false) do
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
           {:ok, value} <- normalize_attr_value(key, value) do
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

  defp normalize_attr_value("state", state) when state in [:open, :closed],
    do: {:ok, Atom.to_string(state)}

  defp normalize_attr_value("state", state) when state in ["open", "closed"], do: {:ok, state}

  defp normalize_attr_value("state_reason", reason)
       when reason in [:completed, :not_planned, :reopened],
       do: {:ok, Atom.to_string(reason)}

  defp normalize_attr_value("state_reason", reason)
       when reason in [nil, "completed", "not_planned", "reopened"],
       do: {:ok, reason}

  defp normalize_attr_value(_key, value), do: {:ok, value}

  defp validate_issue_payload(payload, mode) do
    validations = [
      optional(payload, "title", &validate_title/1),
      optional(payload, "body", &validate_optional_body/1),
      optional(payload, "labels", &validate_labels/1),
      optional(payload, "assignees", &validate_assignees/1)
    ]

    validations =
      if mode == :update do
        [
          optional(payload, "state", &validate_state/1),
          optional(payload, "state_reason", &validate_state_reason/1)
          | validations
        ]
      else
        validations
      end

    if Enum.all?(validations, &(&1 == :ok)), do: :ok, else: :error
  end

  defp optional(payload, key, validator) do
    case Map.fetch(payload, key) do
      {:ok, value} -> validator.(value)
      :error -> :ok
    end
  end

  defp validate_state_reason_change(%{"state_reason" => reason, "state" => state}) do
    case {state, reason} do
      {"open", reason} when reason in [nil, "reopened"] -> :ok
      {"closed", reason} when reason in [nil, "completed", "not_planned"] -> :ok
      _invalid -> :error
    end
  end

  defp validate_state_reason_change(payload) do
    if Map.has_key?(payload, "state_reason"), do: :error, else: :ok
  end

  defp validate_title(value) do
    if valid_text?(value, @max_title_bytes) and value != "" and
         codepoints_at_most?(value, @max_title_codepoints),
       do: :ok,
       else: :error
  end

  defp validate_optional_body(nil), do: :ok
  defp validate_optional_body(body), do: validate_body(body, true)

  defp validate_body(value, allow_empty?) do
    if valid_text?(value, @max_body_bytes) and (allow_empty? or value != "") and
         codepoints_at_most?(value, @max_body_codepoints),
       do: :ok,
       else: :error
  end

  defp validate_state(state) when state in ["open", "closed"], do: :ok
  defp validate_state(_state), do: :error

  defp validate_state_reason(reason) when reason in [nil, "completed", "not_planned", "reopened"],
    do: :ok

  defp validate_state_reason(_reason), do: :error

  defp validate_labels(labels), do: validate_name_set(labels, &valid_label?/1)

  defp validate_assignees(assignees),
    do: validate_name_set(assignees, &valid_login?/1)

  defp validate_name_set(values, validator)
       when is_list(values) and length(values) <= @max_set_items do
    if length(values) == length(Enum.uniq(values)) and Enum.all?(values, validator),
      do: :ok,
      else: :error
  end

  defp validate_name_set(_values, _validator), do: :error

  defp valid_label?(value) do
    valid_text?(value, @max_name_bytes) and value != "" and
      codepoints_at_most?(value, @max_name_codepoints)
  end

  defp valid_login?(value) do
    valid_text?(value, @max_login_bytes) and value != "" and
      codepoints_at_most?(value, @max_login_codepoints) and Regex.match?(@login, value)
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

  defp validate_id(id) when is_integer(id) and id in 1..@max_id, do: :ok
  defp validate_id(_id), do: :error

  defp normalize_since(%DateTime{utc_offset: utc_offset, std_offset: std_offset} = since)
       when utc_offset + std_offset == 0 do
    {:ok, since |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
  rescue
    _exception -> :error
  end

  defp normalize_since(_since), do: :error

  defp normalize_cursor(nil), do: {:ok, 1}

  defp normalize_cursor(cursor) when is_integer(cursor) and cursor in 1..@max_page,
    do: {:ok, cursor}

  defp normalize_cursor(_cursor), do: :error

  defp updated_query(since, page) do
    %{
      "direction" => "asc",
      "page" => Integer.to_string(page),
      "per_page" => "100",
      "since" => since,
      "sort" => "updated"
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

  defp issues_from_json(values) when is_list(values) and length(values) <= 100 do
    values
    |> Enum.reject(&(is_map(&1) and Map.has_key?(&1, "pull_request")))
    |> decode_list(&issue_from_json/1)
  end

  defp issues_from_json(_values), do: {:error, :invalid_response}

  defp comments_from_json(values, owner, repository)
       when is_list(values) and length(values) <= 100 do
    decode_list(values, &comment_from_json(&1, owner, repository, nil))
  end

  defp comments_from_json(_values, _owner, _repository), do: {:error, :invalid_response}

  defp decode_list(values, decoder) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case decoder.(value) do
        {:ok, resource} -> {:cont, {:ok, [resource | decoded]}}
        {:error, :invalid_response} -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp issue_from_json(
         %{
           "id" => id,
           "node_id" => node_id,
           "number" => number,
           "title" => title,
           "body" => body,
           "state" => state,
           "state_reason" => state_reason,
           "labels" => labels,
           "assignees" => assignees,
           "user" => user,
           "created_at" => created_at,
           "updated_at" => updated_at
         } = issue
       ) do
    with false <- Map.has_key?(issue, "pull_request"),
         :ok <- validate_id(id),
         :ok <- validate_id(number),
         true <- valid_node_id?(node_id),
         :ok <- validate_title(title),
         :ok <- validate_optional_body(body),
         :ok <- validate_state(state),
         true <- state_reason in @response_state_reasons,
         :ok <- validate_response_labels(labels),
         :ok <- validate_response_users(assignees),
         :ok <- validate_response_author(user),
         true <- valid_timestamp?(created_at),
         true <- valid_timestamp?(updated_at),
         true <- valid_optional_timestamp?(Map.get(issue, "closed_at")) do
      {:ok, issue}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp issue_from_json(_issue), do: {:error, :invalid_response}

  defp pull_issue_from_json(
         %{
           "number" => expected_number,
           "pull_request" => %{"url" => pull_url}
         } = issue,
         owner,
         repository,
         expected_number
       ) do
    if pull_url_matches?(pull_url, owner, repository, expected_number) do
      issue
      |> Map.delete("pull_request")
      |> issue_from_json()
    else
      {:error, :invalid_response}
    end
  end

  defp pull_issue_from_json(_issue, _owner, _repository, _expected_number),
    do: {:error, :invalid_response}

  defp pull_url_matches?(pull_url, owner, repository, expected_number)
       when is_binary(pull_url) and byte_size(pull_url) <= 2_048 do
    with {:ok,
          %URI{
            scheme: scheme,
            host: host,
            port: port,
            userinfo: nil,
            query: nil,
            fragment: nil,
            path: path
          }} <- URI.new(pull_url),
         true <- String.downcase(scheme || "") == "https",
         true <- String.downcase(host || "") == "api.github.com",
         true <- port in [nil, 443],
         ["repos", response_owner, response_repository, "pulls", encoded_number] <-
           String.split(path, "/", trim: true),
         true <- String.downcase(response_owner) == String.downcase(owner),
         true <- String.downcase(response_repository) == String.downcase(repository),
         {^expected_number, ""} <- Integer.parse(encoded_number) do
      true
    else
      _invalid -> false
    end
  rescue
    _exception -> false
  end

  defp pull_url_matches?(_pull_url, _owner, _repository, _expected_number), do: false

  defp comment_from_json(
         %{
           "id" => id,
           "node_id" => node_id,
           "body" => body,
           "user" => user,
           "issue_url" => issue_url,
           "created_at" => created_at,
           "updated_at" => updated_at
         } = comment,
         owner,
         repository,
         expected_issue_number
       ) do
    with :ok <- validate_id(id),
         true <- valid_node_id?(node_id),
         :ok <- validate_body(body, false),
         :ok <- validate_response_author(user),
         {:ok, issue_number} <- issue_number_from_url(issue_url, owner, repository),
         true <- is_nil(expected_issue_number) or issue_number == expected_issue_number,
         true <- valid_timestamp?(created_at),
         true <- valid_timestamp?(updated_at) do
      {:ok, Map.put(comment, "issue_number", issue_number)}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp comment_from_json(_comment, _owner, _repository, _expected_issue_number),
    do: {:error, :invalid_response}

  defp validate_response_labels(labels)
       when is_list(labels) and length(labels) <= @max_set_items do
    if Enum.all?(labels, fn
         %{"id" => id, "node_id" => node_id, "name" => name} ->
           validate_id(id) == :ok and valid_node_id?(node_id) and valid_label?(name)

         _invalid ->
           false
       end),
       do: :ok,
       else: :error
  end

  defp validate_response_labels(_labels), do: :error

  defp validate_response_users(users) when is_list(users) and length(users) <= @max_set_items do
    if Enum.all?(users, &(validate_response_user(&1) == :ok)), do: :ok, else: :error
  end

  defp validate_response_users(_users), do: :error

  defp validate_response_user(%{"id" => id, "node_id" => node_id, "login" => login}) do
    if validate_id(id) == :ok and valid_node_id?(node_id) and valid_login?(login),
      do: :ok,
      else: :error
  end

  defp validate_response_user(_user), do: :error

  defp validate_response_author(nil), do: :ok
  defp validate_response_author(user), do: validate_response_user(user)

  defp valid_node_id?(value), do: valid_text?(value, @max_node_id_bytes) and value != ""

  defp valid_timestamp?(value) when is_binary(value) and byte_size(value) <= 64 do
    match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false

  defp valid_optional_timestamp?(nil), do: true
  defp valid_optional_timestamp?(value), do: valid_timestamp?(value)

  defp issue_number_from_url(issue_url, owner, repository)
       when is_binary(issue_url) and byte_size(issue_url) <= 2_048 do
    with {:ok,
          %URI{
            scheme: scheme,
            host: host,
            port: port,
            userinfo: nil,
            query: nil,
            fragment: nil,
            path: path
          }} <- URI.new(issue_url),
         true <- String.downcase(scheme || "") == "https",
         true <- String.downcase(host || "") == "api.github.com",
         true <- port in [nil, 443],
         ["repos", response_owner, response_repository, "issues", encoded_number] <-
           String.split(path, "/", trim: true),
         true <- String.downcase(response_owner) == String.downcase(owner),
         true <- String.downcase(response_repository) == String.downcase(repository),
         {issue_number, ""} <- Integer.parse(encoded_number),
         :ok <- validate_id(issue_number) do
      {:ok, issue_number}
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  defp issue_number_from_url(_issue_url, _owner, _repository), do: :error

  defp decode_resource({:ok, json}, decoder) do
    case decoder.(json) do
      {:ok, resource} -> {:ok, resource}
      {:error, :invalid_response} -> error(:invalid_response)
    end
  end

  defp decode_resource({:error, %Error{} = error}, _decoder), do: {:error, error}

  defp error(kind), do: {:error, Error.new(kind)}
end
