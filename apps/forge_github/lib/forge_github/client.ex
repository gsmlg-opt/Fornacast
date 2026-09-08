defmodule ForgeGitHub.Client do
  @moduledoc "A fixed-host, bounded client for GitHub REST resources."

  alias ForgeGitHub.{
    Error,
    HostPolicy,
    Organization,
    Pagination,
    Repository,
    RepositoryReference,
    RequestGate,
    Transport,
    User
  }

  @api_base "https://api.github.com"
  @accept "application/vnd.github+json"
  @api_version "2026-03-10"
  @user_agent "Fornacast/0.2.0"
  @request_timeout 20_000
  @request_gate_acquire_timeout 2_000
  @max_body_bytes 2_000_000
  @allowed_methods [:get, :post, :patch, :put, :delete]
  @max_pages 100
  @max_json_depth 16
  @max_json_nodes 50_000
  @max_json_collection 512
  @max_json_string_bytes 16_384
  @max_issue_metadata_string_bytes 262_144
  # GitHub asks clients to pause on rate limits; cap a durable pause at 24 hours so a
  # malformed or hostile header cannot strand an import indefinitely.
  @retry_fallback_seconds 60
  @max_retry_delay_seconds 24 * 60 * 60
  @allow_test_plug Mix.env() == :test

  @type method :: :get | :post | :patch | :put | :delete

  @doc """
  Performs one bounded request against the fixed GitHub API origin.

  The result contains decoded, complexity-bounded JSON, or `nil` for a successful
  response with no body. A request body may be supplied as bounded JSON through
  the `:json` option.
  """
  @spec request(String.t(), method(), String.t(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def request(pat, method, path, opts \\ []) do
    with_request_gate(pat, opts, [:json], fn ->
      with true <- method in @allowed_methods,
           {:ok, body} <- encode_request_body(opts),
           {:ok, response} <- perform_request(path, pat, opts, method, body),
           {:ok, value} <- successful_response(response, opts) do
        {:ok, value}
      else
        {:error, %Error{} = error} -> {:error, error}
        _invalid -> error(:invalid_request)
      end
    end)
  end

  @doc false
  @spec issue_metadata_request(String.t(), method(), String.t(), 200 | 201 | 204, keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def issue_metadata_request(token, method, path, expected_status, opts) do
    metadata_request(token, method, path, expected_status, opts, &issue_metadata_request_kind/2)
  end

  @doc false
  def pull_metadata_request(token, method, path, expected_status, opts) do
    metadata_request(token, method, path, expected_status, opts, &pull_metadata_request_kind/2)
  end

  defp metadata_request(token, method, path, expected_status, opts, classify) do
    with {:ok, request_kind} <- classify.(method, path),
         true <- valid_issue_metadata_status?(request_kind, expected_status),
         true <- installation_gate?(opts) do
      with_request_gate(token, opts, [:json], fn ->
        with {:ok, body} <- encode_request_body(opts, :issue_metadata),
             {:ok, response} <- perform_request(path, token, opts, method, body),
             {:ok, value} <-
               successful_response(
                 response,
                 opts,
                 expected_status,
                 :issue_metadata
               ) do
          {:ok, value}
        else
          {:error, %Error{} = error} -> {:error, error}
        end
      end)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @doc false
  @spec issue_metadata_page(String.t(), String.t(), keyword()) ::
          {:ok, %{json: term(), next_url: String.t() | nil}} | {:error, Error.t()}
  def issue_metadata_page(token, path, opts) do
    metadata_page(token, path, opts, &issue_metadata_request_kind/2)
  end

  @doc false
  def pull_metadata_page(token, path, opts) do
    metadata_page(token, path, opts, &pull_metadata_request_kind/2)
  end

  defp metadata_page(token, path, opts, classify) do
    with {:ok, :page} <- classify.(:get, path),
         true <- installation_gate?(opts),
         {:ok, %URI{path: allowed_path}} <- URI.new(path) do
      with_request_gate(token, opts, fn ->
        with {:ok, response} <- perform_request(path, token, opts, :get, nil),
             {:ok, json} <-
               successful_response(response, opts, 200, :issue_metadata),
             {:ok, next_url} <- Pagination.next_url(response, [allowed_path]) do
          {:ok, %{json: json, next_url: next_url}}
        else
          {:error, %Error{} = error} -> {:error, error}
          {:error, :invalid_pagination} -> error(:invalid_pagination)
        end
      end)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @doc false
  def pull_graphql_request(token, json, opts) when is_map(json) do
    if installation_gate?(opts) do
      opts = Keyword.put(opts, :json, json)

      with_request_gate(
        token,
        opts,
        [:json, :deadline_monotonic_ms],
        fn -> validate_graphql_deadline(opts) end,
        fn ->
          with {:ok, body} <- encode_request_body(opts),
               {:ok, response} <- perform_request("/graphql", token, opts, :post, body) do
            successful_response(response, opts, 200, :generic)
          end
        end
      )
    else
      error(:invalid_request)
    end
  end

  def pull_graphql_request(_, _, _), do: error(:invalid_request)

  @spec authenticated_user(String.t(), keyword()) :: {:ok, User.t()} | {:error, Error.t()}
  def authenticated_user(pat, opts \\ []) do
    with_request_gate(pat, opts, fn ->
      fetch_one("#{@api_base}/user", pat, opts, &User.from_json/1)
    end)
  end

  @spec repository(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Repository.t()} | {:error, Error.t()}
  def repository(pat, owner, repository, opts \\ []) do
    with true <- RepositoryReference.valid_owner?(owner),
         true <- RepositoryReference.valid_repository?(repository) do
      with_request_gate(pat, opts, fn ->
        fetch_one(
          "#{@api_base}/repos/#{owner}/#{repository}",
          pat,
          opts,
          &Repository.from_json/1
        )
      end)
    else
      _invalid_component -> error(:invalid_request)
    end
  end

  @spec organization(String.t(), String.t(), keyword()) ::
          {:ok, Organization.t()} | {:error, Error.t()}
  def organization(pat, login, opts \\ []) do
    if RepositoryReference.valid_owner?(login) do
      with_request_gate(pat, opts, fn ->
        fetch_one("#{@api_base}/orgs/#{login}", pat, opts, &Organization.from_json/1)
      end)
    else
      error(:invalid_request)
    end
  end

  @spec organization_repositories(String.t(), String.t(), keyword()) ::
          {:ok, [Repository.t()]} | {:error, Error.t()}
  def organization_repositories(pat, login, opts \\ []) do
    if RepositoryReference.valid_owner?(login) do
      with_request_gate(pat, opts, fn ->
        with {:ok, %Organization{id: organization_id}} <-
               fetch_one(
                 "#{@api_base}/orgs/#{login}",
                 pat,
                 opts,
                 &Organization.from_json/1
               ) do
          paginate_repositories(
            "#{@api_base}/orgs/#{login}/repos?per_page=100&type=all",
            pat,
            opts,
            ["/orgs/#{login}/repos", "/organizations/#{organization_id}/repos"],
            1,
            []
          )
        end
      end)
    else
      error(:invalid_request)
    end
  end

  @doc """
  Fetches one bounded page of repositories visible to a GitHub App installation.

  The cursor is a provider-owned page number rather than an arbitrary URL. This
  keeps durable resume data small and prevents a persisted cursor from changing
  the fixed GitHub origin or endpoint.
  """
  @spec installation_repositories_page(String.t(), nil | pos_integer(), keyword()) ::
          {:ok, %{repositories: [Repository.t()], next_cursor: pos_integer() | nil}}
          | {:error, Error.t()}
  def installation_repositories_page(token, cursor \\ nil, opts \\ [])

  def installation_repositories_page(token, cursor, opts)
      when (is_nil(cursor) or (is_integer(cursor) and cursor in 1..@max_pages)) and
             is_list(opts) do
    page = cursor || 1

    with_request_gate(token, opts, fn ->
      url = "#{@api_base}/installation/repositories?per_page=100&page=#{page}"

      with {:ok, response} <- perform_request(url, token, opts, :get, nil),
           {:ok, json} <- successful_json(response, opts),
           {:ok, repositories} <- installation_repositories_from_json(json),
           {:ok, next_url} <- Pagination.next_url(response, ["/installation/repositories"]),
           {:ok, next_cursor} <- installation_next_cursor(next_url, page) do
        {:ok, %{repositories: repositories, next_cursor: next_cursor}}
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, :invalid_response} -> error(:invalid_response)
        {:error, :invalid_pagination} -> error(:invalid_pagination)
        {:error, :pagination_limit} -> error(:pagination_limit)
      end
    end)
  end

  def installation_repositories_page(_token, _cursor, _opts), do: error(:invalid_request)

  @spec repository_labels(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def repository_labels(pat, owner, repository, opts \\ []) do
    with {:ok, paths} <- repository_paths(owner, repository) do
      with_request_gate(pat, opts, fn ->
        paginate_json_list(
          "#{@api_base}#{paths.labels}?per_page=100",
          pat,
          opts,
          [paths.labels],
          1,
          []
        )
      end)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec repository_issues(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def repository_issues(pat, owner, repository, opts \\ []) do
    with {:ok, paths} <- repository_paths(owner, repository) do
      with_request_gate(pat, opts, fn ->
        paginate_json_list(
          "#{@api_base}#{paths.issues}?state=all&per_page=100",
          pat,
          opts,
          [paths.issues],
          1,
          [],
          if(installation_gate?(opts), do: :issue_metadata, else: :generic)
        )
      end)
    else
      _invalid -> error(:invalid_request)
    end
  end

  @spec issue_comments(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def issue_comments(pat, owner, repository, issue_number, opts \\ [])

  def issue_comments(pat, owner, repository, issue_number, opts)
      when is_integer(issue_number) and issue_number > 0 do
    with {:ok, paths} <- repository_paths(owner, repository),
         true <- issue_number <= 999_999 do
      with_request_gate(pat, opts, fn ->
        paginate_json_list(
          "#{@api_base}#{paths.comments}/#{issue_number}/comments?per_page=100",
          pat,
          opts,
          ["#{paths.comments}/#{issue_number}/comments"],
          1,
          [],
          if(installation_gate?(opts), do: :issue_metadata, else: :generic)
        )
      end)
    else
      _invalid -> error(:invalid_request)
    end
  end

  def issue_comments(_pat, _owner, _repository, _issue_number, _opts),
    do: error(:invalid_request)

  @spec repository_issue(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def repository_issue(pat, owner, repository, number, opts \\ [])

  def repository_issue(pat, owner, repository, number, opts)
      when is_integer(number) and number > 0 and number <= 999_999 do
    with {:ok, paths} <- repository_paths(owner, repository) do
      with_request_gate(pat, opts, fn ->
        fetch_one(
          "#{@api_base}#{paths.issues}/#{number}",
          pat,
          opts,
          &json_object/1,
          if(installation_gate?(opts), do: :issue_metadata, else: :generic)
        )
      end)
    else
      _ -> error(:invalid_request)
    end
  end

  def repository_issue(_, _, _, _, _), do: error(:invalid_request)

  @spec pull_request(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def pull_request(pat, owner, repository, pull_number, opts \\ [])

  def pull_request(pat, owner, repository, pull_number, opts)
      when is_integer(pull_number) and pull_number > 0 do
    with {:ok, paths} <- repository_paths(owner, repository),
         true <- pull_number <= 999_999 do
      with_request_gate(pat, opts, fn ->
        fetch_one(
          "#{@api_base}#{paths.pulls}/#{pull_number}",
          pat,
          opts,
          &json_object/1,
          if(installation_gate?(opts), do: :issue_metadata, else: :generic)
        )
      end)
    else
      _invalid -> error(:invalid_request)
    end
  end

  def pull_request(_pat, _owner, _repository, _pull_number, _opts),
    do: error(:invalid_request)

  defp repository_paths(owner, repository) do
    with true <- RepositoryReference.valid_owner?(owner),
         true <- RepositoryReference.valid_repository?(repository) do
      base = "/repos/#{owner}/#{repository}"

      {:ok,
       %{
         labels: "#{base}/labels",
         issues: "#{base}/issues",
         comments: "#{base}/issues",
         pulls: "#{base}/pulls"
       }}
    else
      _invalid -> :error
    end
  end

  defp pull_metadata_request_kind(method, path)
       when method in [:get, :post, :patch] and is_binary(path) do
    with {:ok,
          %URI{scheme: nil, host: nil, userinfo: nil, fragment: nil, path: parsed, query: query}} <-
           URI.new(path),
         ["repos", owner, repository, "pulls" | resource] <- String.split(parsed, "/", trim: true),
         true <-
           RepositoryReference.valid_owner?(owner) and
             RepositoryReference.valid_repository?(repository) do
      case {method, resource, query} do
        {:get, [], query} when is_binary(query) ->
          {:ok, :page}

        {:post, [], nil} ->
          {:ok, :create}

        {method, [number], nil} when method in [:get, :patch] ->
          with :ok <- validate_positive_id(number),
               do: {:ok, if(method == :get, do: :read, else: :update)}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp pull_metadata_request_kind(_, _), do: :error

  defp issue_metadata_request_kind(method, path)
       when method in [:get, :post, :patch, :delete] and is_binary(path) do
    with {:ok,
          %URI{
            scheme: nil,
            host: nil,
            userinfo: nil,
            fragment: nil,
            path: path,
            query: query
          }} <- URI.new(path),
         ["repos", owner, repository, "issues" | resource] <-
           String.split(path, "/", trim: true),
         true <- RepositoryReference.valid_owner?(owner),
         true <- RepositoryReference.valid_repository?(repository) do
      issue_metadata_resource_kind(method, resource, query)
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  defp issue_metadata_request_kind(_method, _path), do: :error

  defp issue_metadata_resource_kind(:get, [], query) when is_binary(query), do: {:ok, :page}
  defp issue_metadata_resource_kind(:post, [], nil), do: {:ok, :create}

  defp issue_metadata_resource_kind(:get, ["comments"], query) when is_binary(query),
    do: {:ok, :page}

  defp issue_metadata_resource_kind(method, ["comments", id], nil)
       when method in [:get, :patch, :delete] do
    with :ok <- validate_positive_id(id) do
      {:ok,
       case method do
         :get -> :read
         :patch -> :update
         :delete -> :delete
       end}
    end
  end

  defp issue_metadata_resource_kind(:post, [issue_number, "comments"], nil) do
    with :ok <- validate_positive_id(issue_number), do: {:ok, :create}
  end

  defp issue_metadata_resource_kind(method, [issue_number], nil)
       when method in [:get, :patch] do
    with :ok <- validate_positive_id(issue_number) do
      {:ok, if(method == :get, do: :read, else: :update)}
    end
  end

  defp issue_metadata_resource_kind(_method, _resource, _query), do: :error

  defp validate_positive_id(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {id, ""} when id in 1..9_223_372_036_854_775_807 -> :ok
      _invalid -> :error
    end
  end

  defp validate_positive_id(_value), do: :error

  defp valid_issue_metadata_status?(:create, 201), do: true
  defp valid_issue_metadata_status?(kind, 200) when kind in [:read, :update], do: true
  defp valid_issue_metadata_status?(:delete, 204), do: true
  defp valid_issue_metadata_status?(_kind, _status), do: false

  defp installation_gate?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and
      match?(
        {:ok, {:github_installation, id}}
        when is_integer(id) and id in 1..9_223_372_036_854_775_807,
        Keyword.fetch(opts, :gate_key)
      )
  end

  defp installation_gate?(_opts), do: false

  defp with_request_gate(pat, opts, fun) do
    with_request_gate(pat, opts, [], fun)
  end

  defp with_request_gate(pat, opts, extra_allowed, fun) do
    with_request_gate(pat, opts, extra_allowed, fn -> :ok end, fun)
  end

  defp with_request_gate(pat, opts, extra_allowed, pre_gate, fun) do
    with :ok <- validate_pat(pat),
         :ok <- validate_options(opts, extra_allowed),
         {:ok, gate_key} <- fetch_gate_key(opts),
         :ok <- pre_gate.() do
      case RequestGate.run(gate_key, fun) do
        {:error, :invalid_gate_key} -> error(:invalid_request)
        {:error, :busy} -> error(:request_gate_busy)
        result -> result
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> error(:invalid_request)
    end
  end

  defp validate_graphql_deadline(opts) do
    case Keyword.fetch(opts, :deadline_monotonic_ms) do
      :error ->
        :ok

      {:ok, deadline} when is_integer(deadline) ->
        if deadline - monotonic_ms() >= @request_gate_acquire_timeout,
          do: :ok,
          else: error(:timeout)

      _invalid ->
        :error
    end
  end

  defp fetch_gate_key(opts) do
    case Keyword.fetch(opts, :gate_key) do
      {:ok, gate_key} -> {:ok, gate_key}
      :error -> :error
    end
  end

  defp validate_pat(pat) when is_binary(pat) do
    if byte_size(pat) in 1..16_384 and String.valid?(pat) and
         :binary.match(pat, <<0>>) == :nomatch,
       do: :ok,
       else: :error
  end

  defp validate_pat(_pat), do: :error

  if @allow_test_plug do
    defp validate_options(opts, extra_allowed) when is_list(opts) and is_list(extra_allowed) do
      if Keyword.keyword?(opts) do
        allowed =
          [:gate_key, :plug, :resolver, :now, :transport_api, :request_timeout] ++ extra_allowed

        test_adapter? = Keyword.has_key?(opts, :plug) or Keyword.has_key?(opts, :transport_api)

        injected? =
          Enum.any?(
            [:resolver, :now, :transport_api, :request_timeout],
            &Keyword.has_key?(opts, &1)
          )

        keys = Keyword.keys(opts)

        cond do
          keys -- allowed != [] -> :error
          length(keys) != length(Enum.uniq(keys)) -> :error
          injected? and not test_adapter? -> :error
          not valid_test_injections?(opts) -> :error
          true -> :ok
        end
      else
        :error
      end
    end
  else
    defp validate_options(opts, extra_allowed) when is_list(opts) and is_list(extra_allowed) do
      if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:gate_key | extra_allowed] == [],
        do: :ok,
        else: :error
    end
  end

  defp validate_options(_opts, _extra_allowed), do: :error

  if @allow_test_plug do
    defp valid_test_injections?(opts) do
      (not Keyword.has_key?(opts, :resolver) or is_function(opts[:resolver], 1)) and
        (not Keyword.has_key?(opts, :now) or is_function(opts[:now], 0)) and
        (not Keyword.has_key?(opts, :transport_api) or is_atom(opts[:transport_api])) and
        (not Keyword.has_key?(opts, :request_timeout) or
           (is_integer(opts[:request_timeout]) and opts[:request_timeout] in 1..@request_timeout))
    end
  end

  defp fetch_one(url, pat, opts, decoder, json_profile \\ :generic) do
    with {:ok, response} <- perform_request(url, pat, opts, :get, nil),
         {:ok, json} <- successful_json(response, opts, json_profile),
         {:ok, value} <- decoder.(json) do
      {:ok, value}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :invalid_response} -> error(:invalid_response)
    end
  end

  defp paginate_repositories(_url, _pat, _opts, _allowed_paths, page, _pages)
       when page > @max_pages,
       do: error(:pagination_limit)

  defp paginate_repositories(url, pat, opts, allowed_paths, page, pages) do
    with {:ok, response} <- perform_request(url, pat, opts, :get, nil),
         {:ok, json} <- successful_json(response, opts),
         {:ok, repositories} <- repositories_from_json(json),
         {:ok, next_url} <- Pagination.next_url(response, allowed_paths) do
      case next_url do
        nil ->
          {:ok, [repositories | pages] |> Enum.reverse() |> List.flatten()}

        _url when page == @max_pages ->
          error(:pagination_limit)

        next_url ->
          paginate_repositories(
            next_url,
            pat,
            opts,
            allowed_paths,
            page + 1,
            [repositories | pages]
          )
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :invalid_response} -> error(:invalid_response)
      {:error, :invalid_pagination} -> error(:invalid_pagination)
    end
  end

  defp paginate_json_list(url, pat, opts, allowed_paths, page, pages, json_profile \\ :generic)

  defp paginate_json_list(_url, _pat, _opts, _allowed_paths, page, _pages, _json_profile)
       when page > @max_pages,
       do: error(:pagination_limit)

  defp paginate_json_list(url, pat, opts, allowed_paths, page, pages, json_profile) do
    with {:ok, response} <- perform_request(url, pat, opts, :get, nil),
         {:ok, json} <- successful_response(response, opts, 200, json_profile),
         {:ok, items} <- json_list(json),
         {:ok, next_url} <- Pagination.next_url(response, allowed_paths) do
      case next_url do
        nil ->
          {:ok, [items | pages] |> Enum.reverse() |> List.flatten()}

        _url when page == @max_pages ->
          error(:pagination_limit)

        next_url ->
          paginate_json_list(
            next_url,
            pat,
            opts,
            allowed_paths,
            page + 1,
            [items | pages],
            json_profile
          )
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :invalid_response} -> error(:invalid_response)
      {:error, :invalid_pagination} -> error(:invalid_pagination)
    end
  end

  defp repositories_from_json(values) when is_list(values) and length(values) <= 100 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, repositories} ->
      case Repository.from_json(value) do
        {:ok, repository} -> {:cont, {:ok, [repository | repositories]}}
        {:error, :invalid_response} -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, repositories} -> {:ok, Enum.reverse(repositories)}
      error -> error
    end
  end

  defp repositories_from_json(_values), do: {:error, :invalid_response}

  defp installation_repositories_from_json(%{
         "total_count" => total_count,
         "repositories" => repositories
       })
       when is_integer(total_count) and total_count in 0..10_000 do
    with {:ok, repositories} <- repositories_from_json(repositories),
         true <- Enum.all?(repositories, &(is_binary(&1.node_id) and &1.node_id != "")) do
      {:ok, repositories}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp installation_repositories_from_json(_json), do: {:error, :invalid_response}

  defp installation_next_cursor(nil, _page), do: {:ok, nil}

  defp installation_next_cursor(_next_url, @max_pages), do: {:error, :pagination_limit}

  defp installation_next_cursor(next_url, page) when is_binary(next_url) do
    with {:ok, %URI{path: "/installation/repositories", query: query}} <- URI.new(next_url),
         true <- is_binary(query),
         pairs <- Enum.to_list(URI.query_decoder(query)),
         true <- length(pairs) == 2 and length(pairs) == length(Enum.uniq_by(pairs, &elem(&1, 0))),
         %{"page" => encoded_page, "per_page" => "100"} <- Map.new(pairs),
         {next_page, ""} <- Integer.parse(encoded_page),
         true <- next_page == page + 1 and next_page in 2..@max_pages do
      {:ok, next_page}
    else
      _invalid -> {:error, :invalid_pagination}
    end
  rescue
    _exception -> {:error, :invalid_pagination}
  end

  defp json_list(values) when is_list(values) and length(values) <= 100 do
    if Enum.all?(values, &is_map/1), do: {:ok, values}, else: {:error, :invalid_response}
  end

  defp json_list(_values), do: {:error, :invalid_response}

  defp json_object(value) when is_map(value), do: {:ok, value}
  defp json_object(_value), do: {:error, :invalid_response}

  defp perform_request(url, pat, opts, method, body) do
    started = System.monotonic_time()
    request_deadline = monotonic_ms() + Keyword.get(opts, :request_timeout, @request_timeout)
    deadline = min(request_deadline, Keyword.get(opts, :deadline_monotonic_ms, request_deadline))

    result =
      with :ok <- validate_request_url(url),
           {:ok, addresses} <- resolve_addresses(opts, deadline) do
        request =
          Req.new(
            method: method,
            base_url: @api_base,
            adapter: Transport,
            headers: [
              {"accept", @accept},
              {"accept-encoding", "identity"},
              {"authorization", "Bearer " <> pat},
              {"user-agent", @user_agent},
              {"x-github-api-version", @api_version}
            ],
            redirect: false,
            retry: false,
            compressed: false,
            raw: true,
            decode_body: false,
            body: body
          )
          |> maybe_put_content_type(body)
          |> Req.Request.put_private(:forge_github_addresses, addresses)
          |> maybe_put_transport_api(opts)

        request_options = [url: url]

        request_options =
          case Keyword.fetch(opts, :plug) do
            {:ok, plug} -> Keyword.put(request_options, :plug, plug)
            :error -> request_options
          end

        case remaining_timeout(deadline) do
          {:ok, transport_timeout} ->
            request
            |> Req.Request.put_private(:forge_github_transport_timeout, transport_timeout)
            |> safe_req_request(request_options)

          {:error, :timeout} ->
            error(:timeout)
        end
      else
        {:error, :unsafe_host} -> error(:unsafe_host)
        {:error, :host_unavailable} -> error(:host_unavailable)
        {:error, :timeout} -> error(:timeout)
        _invalid -> error(:invalid_request)
      end

    emit_request_telemetry(result, System.monotonic_time() - started, opts)
    result
  end

  defp emit_request_telemetry({:ok, %Req.Response{status: status}}, duration, _opts)
       when status in 200..299 do
    emit_telemetry([:request, :stop], %{duration: duration}, %{outcome: :ok})
  end

  defp emit_request_telemetry({:ok, %Req.Response{} = response}, duration, opts) do
    {:error, %Error{kind: kind}} = classify_response(response, opts)

    emit_telemetry([:request, :stop], %{duration: duration}, %{
      outcome: :error,
      error: kind
    })

    maybe_emit_rate_limit_pause(%{error: kind})
  end

  defp emit_request_telemetry({:error, %Error{kind: kind}}, duration, _opts) do
    emit_telemetry([:request, :stop], %{duration: duration}, %{
      outcome: :error,
      error: kind
    })

    maybe_emit_rate_limit_pause(%{error: kind})
  end

  defp maybe_emit_rate_limit_pause(%{error: kind})
       when kind in [:primary_rate_limit, :secondary_rate_limit] do
    classification = if kind == :primary_rate_limit, do: :primary, else: :secondary

    emit_telemetry([:rate_limit, :pause], %{count: 1}, %{
      classification: classification,
      error: kind
    })
  end

  defp maybe_emit_rate_limit_pause(_metadata), do: :ok

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute([:fornacast, :github] ++ event, measurements, metadata)
  end

  defp maybe_put_content_type(request, nil), do: request

  defp maybe_put_content_type(request, _body) do
    Req.Request.put_header(request, "content-type", "application/json")
  end

  defp maybe_put_transport_api(request, opts) do
    case Keyword.fetch(opts, :transport_api) do
      {:ok, api} when is_atom(api) ->
        Req.Request.put_private(request, :forge_github_transport_api, api)

      _missing_or_invalid ->
        request
    end
  end

  defp resolve_addresses(opts, deadline) do
    case Keyword.fetch(opts, :resolver) do
      {:ok, resolver} -> HostPolicy.resolve_public(resolver: resolver, deadline: deadline)
      :error -> HostPolicy.resolve_public(deadline: deadline)
    end
  end

  defp remaining_timeout(deadline) do
    case deadline - monotonic_ms() do
      remaining when remaining > 0 -> {:ok, min(remaining, @request_timeout)}
      _expired -> {:error, :timeout}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp safe_req_request(request, request_options) do
    case Req.request(request, request_options) do
      {:ok, response} -> validate_wire_response(response)
      {:error, %Transport.Error{kind: :response_too_large}} -> error(:response_too_large)
      {:error, %Transport.Error{kind: :timeout}} -> error(:timeout)
      {:error, %Transport.Error{}} -> error(:transport)
      {:error, _exception} -> error(:transport)
    end
  rescue
    _exception -> error(:transport)
  catch
    _kind, _reason -> error(:transport)
  end

  defp validate_request_url(url) do
    case URI.new(url) do
      {:ok,
       %URI{
         scheme: nil,
         host: nil,
         userinfo: nil,
         fragment: nil,
         path: "/" <> _rest = path
       }} ->
        if String.starts_with?(path, "//"), do: :error, else: :ok

      {:ok, %URI{} = uri} ->
        if String.downcase(uri.scheme || "") == "https" and
             String.downcase(uri.host || "") == "api.github.com" and
             is_nil(uri.userinfo) and uri.port in [nil, 443] and is_nil(uri.fragment),
           do: :ok,
           else: :error

      _invalid ->
        :error
    end
  end

  defp validate_wire_response(%Req.Response{body: body} = response) when is_binary(body) do
    cond do
      byte_size(body) > @max_body_bytes ->
        error(:response_too_large)

      oversized_content_length?(response) ->
        error(:response_too_large)

      not identity_encoding?(response) ->
        error(:invalid_response)

      true ->
        {:ok, response}
    end
  end

  defp validate_wire_response(_response), do: error(:invalid_response)

  defp oversized_content_length?(response) do
    case Req.Response.get_header(response, "content-length") do
      [value] ->
        match?(
          {:ok, length} when length > @max_body_bytes,
          parse_decimal(value, 10, 9_999_999_999)
        )

      _other ->
        false
    end
  end

  defp identity_encoding?(response) do
    case Req.Response.get_header(response, "content-encoding") do
      [] -> true
      [value] -> String.downcase(String.trim(value)) == "identity"
      _multiple -> false
    end
  end

  defp encode_request_body(opts), do: encode_request_body(opts, :generic)

  defp encode_request_body(opts, json_profile) do
    case Keyword.fetch(opts, :json) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        with {:ok, _nodes} <- validate_json(value, 0, 0, json_profile),
             {:ok, body} <- encode_json(value) do
          if byte_size(body) <= @max_body_bytes,
            do: {:ok, body},
            else: error(:request_too_large)
        else
          _invalid -> error(:invalid_request)
        end
    end
  end

  defp encode_json(value) do
    {:ok, JSON.encode!(value)}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp successful_response(%Req.Response{status: status, body: ""}, _opts)
       when status in 200..299,
       do: {:ok, nil}

  defp successful_response(%Req.Response{status: status, body: body}, _opts)
       when status in 200..299 and is_binary(body),
       do: decode_json(body)

  defp successful_response(%Req.Response{} = response, opts),
    do: classify_response(response, opts)

  defp successful_response(
         %Req.Response{status: expected_status, body: ""},
         _opts,
         expected_status,
         _json_profile
       ),
       do: {:ok, nil}

  defp successful_response(
         %Req.Response{status: expected_status, body: body},
         _opts,
         expected_status,
         json_profile
       )
       when is_binary(body),
       do: decode_json(body, json_profile)

  defp successful_response(
         %Req.Response{status: status},
         _opts,
         expected_status,
         _json_profile
       )
       when status in 200..299 and status != expected_status,
       do: error(:unexpected_status)

  defp successful_response(%Req.Response{} = response, opts, _expected_status, _json_profile),
    do: classify_response(response, opts)

  defp successful_json(response, opts, json_profile \\ :generic)

  defp successful_json(%Req.Response{status: 200, body: body}, _opts, json_profile),
    do: decode_json(body, json_profile)

  defp successful_json(%Req.Response{} = response, opts, _json_profile),
    do: classify_response(response, opts)

  defp decode_json(body), do: decode_json(body, :generic)

  defp decode_json(body, json_profile) do
    with {:ok, value} <- JSON.decode(body),
         {:ok, _nodes} <- validate_json(value, 0, 0, json_profile) do
      {:ok, value}
    else
      {:error, {_reason, _offset}} -> error(:invalid_json)
      {:error, {_reason, _offset, _value}} -> error(:invalid_json)
      {:error, :invalid_json} -> error(:invalid_response)
    end
  end

  defp validate_json(_value, depth, _nodes, _json_profile) when depth > @max_json_depth,
    do: {:error, :invalid_json}

  defp validate_json(_value, _depth, nodes, _json_profile) when nodes >= @max_json_nodes,
    do: {:error, :invalid_json}

  defp validate_json(value, _depth, nodes, json_profile) when is_binary(value) do
    if byte_size(value) <= json_string_limit(json_profile),
      do: {:ok, nodes + 1},
      else: {:error, :invalid_json}
  end

  defp validate_json(value, _depth, nodes, _json_profile)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, nodes + 1}

  defp validate_json(values, depth, nodes, json_profile)
       when is_list(values) and length(values) <= @max_json_collection do
    item_profile = if json_profile == :issue_metadata, do: :issue_metadata, else: :generic

    Enum.reduce_while(values, {:ok, nodes + 1}, fn value, {:ok, count} ->
      case validate_json(value, depth + 1, count, item_profile) do
        {:ok, count} -> {:cont, {:ok, count}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_json(values, depth, nodes, json_profile)
       when is_map(values) and map_size(values) <= @max_json_collection do
    Enum.reduce_while(values, {:ok, nodes + 1}, fn {key, value}, {:ok, count} ->
      with true <- is_binary(key) and byte_size(key) <= 128,
           {:ok, count} <-
             validate_json(value, depth + 1, count, json_value_profile(json_profile, key)) do
        {:cont, {:ok, count}}
      else
        _invalid -> {:halt, {:error, :invalid_json}}
      end
    end)
  end

  defp validate_json(_value, _depth, _nodes, _json_profile), do: {:error, :invalid_json}

  defp json_value_profile(:issue_metadata, "body"), do: :issue_body
  defp json_value_profile(_json_profile, _key), do: :generic

  defp json_string_limit(:issue_body), do: @max_issue_metadata_string_bytes
  defp json_string_limit(_json_profile), do: @max_json_string_bytes

  defp classify_response(%Req.Response{status: 401}, _opts), do: error(:invalid_credential)

  defp classify_response(%Req.Response{status: status} = response, opts)
       when status in [403, 429] do
    cond do
      rate_limit_remaining_zero?(response) ->
        error(:primary_rate_limit, primary_retry_at(response, opts))

      status == 429 or header(response, "retry-after") != nil or
          secondary_message?(response.body) ->
        error(:secondary_rate_limit, secondary_retry_at(response, opts))

      true ->
        error(:forbidden)
    end
  end

  defp classify_response(%Req.Response{status: 404}, _opts), do: error(:not_found)

  defp classify_response(%Req.Response{status: status}, _opts) when status in 500..599,
    do: error(:upstream_unavailable)

  defp classify_response(_response, _opts), do: error(:unexpected_status)

  defp primary_retry_at(response, opts) do
    current = now(opts)

    with value when is_binary(value) <- header(response, "x-ratelimit-reset"),
         {:ok, unix} <- parse_decimal(value, 12, 253_402_300_799),
         {:ok, datetime} <- DateTime.from_unix(unix) do
      bounded_retry_at(datetime, current)
    else
      _invalid -> fallback_retry_at(current)
    end
  end

  defp secondary_retry_at(response, opts) do
    current = now(opts)

    case parse_retry_after(header(response, "retry-after"), current) do
      {:ok, datetime} -> bounded_retry_at(datetime, current)
      :error -> fallback_retry_at(current)
    end
  end

  defp parse_retry_after(nil, _now), do: :error

  defp parse_retry_after(value, now) do
    case parse_decimal(value, 6, 604_800) do
      {:ok, seconds} ->
        {:ok, DateTime.add(now, seconds)}

      :error ->
        parse_retry_after_date(value, now)
    end
  end

  defp parse_retry_after_date(value, _now) when byte_size(value) <= 128 do
    with true <- String.valid?(value),
         {:ok, {{year, month, day}, {hour, minute, second}}} <- request_date(value),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      _invalid -> :error
    end
  end

  defp parse_retry_after_date(_value, _now), do: :error

  defp request_date(value) do
    {:ok, :httpd_util.convert_request_date(String.to_charlist(value))}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp parse_decimal(value, max_digits, max_value)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max_digits do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 and integer <= max_value -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp parse_decimal(_value, _max_digits, _max_value), do: :error

  defp rate_limit_remaining_zero?(response) do
    match?({:ok, 0}, parse_decimal(header(response, "x-ratelimit-remaining"), 12, 999_999_999))
  end

  defp bounded_retry_at(candidate, current) do
    maximum = DateTime.add(current, @max_retry_delay_seconds)

    cond do
      DateTime.compare(candidate, current) in [:lt, :eq] -> fallback_retry_at(current)
      DateTime.after?(candidate, maximum) -> maximum
      true -> DateTime.truncate(candidate, :second)
    end
  end

  defp fallback_retry_at(current), do: DateTime.add(current, @retry_fallback_seconds)

  defp now(opts) do
    case Keyword.get(opts, :now, &DateTime.utc_now/0).() do
      %DateTime{} = datetime -> DateTime.truncate(datetime, :second)
      _invalid -> DateTime.utc_now(:second)
    end
  end

  defp secondary_message?(body) when is_binary(body) do
    sample = binary_part(body, 0, min(byte_size(body), 512))

    if String.valid?(sample),
      do: sample |> String.downcase() |> String.contains?("secondary rate limit"),
      else: false
  end

  defp secondary_message?(_body), do: false

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value] -> value
      _other -> nil
    end
  end

  defp error(kind, retry_at \\ nil), do: {:error, Error.new(kind, retry_at)}
end
