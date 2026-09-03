defmodule ForgeImports.GitHub.Client do
  @moduledoc "A fixed-host, bounded client for the GitHub REST resources used by imports."

  alias ForgeImports.GitHub.{
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

  alias ForgeImports.Telemetry

  @api_base "https://api.github.com"
  @accept "application/vnd.github+json"
  @api_version "2026-03-10"
  @user_agent "Fornacast/0.2.0"
  @request_timeout 20_000
  @max_body_bytes 2_000_000
  @max_pages 100
  @max_json_depth 16
  @max_json_nodes 50_000
  @max_json_collection 512
  @max_json_string_bytes 16_384
  # GitHub asks clients to pause on rate limits; cap a durable pause at 24 hours so a
  # malformed or hostile header cannot strand an import indefinitely.
  @retry_fallback_seconds 60
  @max_retry_delay_seconds 24 * 60 * 60
  @allow_test_plug Mix.env() == :test

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
          []
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
          []
        )
      end)
    else
      _invalid -> error(:invalid_request)
    end
  end

  def issue_comments(_pat, _owner, _repository, _issue_number, _opts),
    do: error(:invalid_request)

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
          &json_object/1
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

  defp with_request_gate(pat, opts, fun) do
    with :ok <- validate_pat(pat),
         :ok <- validate_options(opts),
         {:ok, gate_key} <- fetch_gate_key(opts) do
      case RequestGate.run(gate_key, fun) do
        {:error, :invalid_gate_key} -> error(:invalid_request)
        {:error, :busy} -> error(:request_gate_busy)
        result -> result
      end
    else
      _invalid -> error(:invalid_request)
    end
  end

  defp fetch_gate_key(opts) do
    case Keyword.fetch(opts, :gate_key) do
      {:ok, gate_key} -> {:ok, gate_key}
      :error -> :error
    end
  end

  defp validate_pat(pat) when is_binary(pat) do
    if byte_size(pat) in 1..1_024 and String.valid?(pat) and
         :binary.match(pat, <<0>>) == :nomatch,
       do: :ok,
       else: :error
  end

  defp validate_pat(_pat), do: :error

  if @allow_test_plug do
    defp validate_options(opts) when is_list(opts) do
      allowed = [:gate_key, :plug, :resolver, :now, :transport_api, :request_timeout]
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
    end
  else
    defp validate_options(opts) when is_list(opts) do
      if Keyword.keys(opts) -- [:gate_key] == [], do: :ok, else: :error
    end
  end

  defp validate_options(_opts), do: :error

  if @allow_test_plug do
    defp valid_test_injections?(opts) do
      (not Keyword.has_key?(opts, :resolver) or is_function(opts[:resolver], 1)) and
        (not Keyword.has_key?(opts, :now) or is_function(opts[:now], 0)) and
        (not Keyword.has_key?(opts, :transport_api) or is_atom(opts[:transport_api])) and
        (not Keyword.has_key?(opts, :request_timeout) or
           (is_integer(opts[:request_timeout]) and opts[:request_timeout] in 1..@request_timeout))
    end
  end

  defp fetch_one(url, pat, opts, decoder) do
    with {:ok, response} <- request(url, pat, opts),
         {:ok, json} <- successful_json(response, opts),
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
    with {:ok, response} <- request(url, pat, opts),
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

  defp paginate_json_list(_url, _pat, _opts, _allowed_paths, page, _pages)
       when page > @max_pages,
       do: error(:pagination_limit)

  defp paginate_json_list(url, pat, opts, allowed_paths, page, pages) do
    with {:ok, response} <- request(url, pat, opts),
         {:ok, json} <- successful_json(response, opts),
         {:ok, items} <- json_list(json),
         {:ok, next_url} <- Pagination.next_url(response, allowed_paths) do
      case next_url do
        nil ->
          {:ok, [items | pages] |> Enum.reverse() |> List.flatten()}

        _url when page == @max_pages ->
          error(:pagination_limit)

        next_url ->
          paginate_json_list(next_url, pat, opts, allowed_paths, page + 1, [items | pages])
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

  defp json_list(values) when is_list(values) and length(values) <= 100 do
    if Enum.all?(values, &is_map/1), do: {:ok, values}, else: {:error, :invalid_response}
  end

  defp json_list(_values), do: {:error, :invalid_response}

  defp json_object(value) when is_map(value), do: {:ok, value}
  defp json_object(_value), do: {:error, :invalid_response}

  defp request(url, pat, opts) do
    started = System.monotonic_time()
    deadline = monotonic_ms() + Keyword.get(opts, :request_timeout, @request_timeout)

    result =
      with :ok <- validate_request_url(url),
           {:ok, addresses} <- resolve_addresses(opts, deadline) do
        request =
          Req.new(
            method: :get,
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
            decode_body: false
          )
          |> Req.Request.put_private(:forge_imports_github_addresses, addresses)
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
            |> Req.Request.put_private(:forge_imports_transport_timeout, transport_timeout)
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
    Telemetry.execute([:github, :request, :stop], %{duration: duration}, %{outcome: :ok})
  end

  defp emit_request_telemetry({:ok, %Req.Response{} = response}, duration, opts) do
    {:error, %Error{kind: kind}} = classify_response(response, opts)

    Telemetry.execute([:github, :request, :stop], %{duration: duration}, %{
      outcome: :error,
      error: kind
    })

    maybe_emit_rate_limit_pause(%{error: kind})
  end

  defp emit_request_telemetry({:error, %Error{kind: kind}}, duration, _opts) do
    Telemetry.execute([:github, :request, :stop], %{duration: duration}, %{
      outcome: :error,
      error: kind
    })

    maybe_emit_rate_limit_pause(%{error: kind})
  end

  defp maybe_emit_rate_limit_pause(%{error: kind})
       when kind in [:primary_rate_limit, :secondary_rate_limit] do
    classification = if kind == :primary_rate_limit, do: :primary, else: :secondary

    Telemetry.execute([:rate_limit, :pause], %{count: 1}, %{
      classification: classification,
      error: kind
    })
  end

  defp maybe_emit_rate_limit_pause(_metadata), do: :ok

  defp maybe_put_transport_api(request, opts) do
    case Keyword.fetch(opts, :transport_api) do
      {:ok, api} when is_atom(api) ->
        Req.Request.put_private(request, :forge_imports_transport_api, api)

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

  defp successful_json(%Req.Response{status: 200, body: body}, _opts), do: decode_json(body)

  defp successful_json(%Req.Response{} = response, opts),
    do: classify_response(response, opts)

  defp decode_json(body) do
    with {:ok, value} <- JSON.decode(body),
         {:ok, _nodes} <- validate_json(value, 0, 0) do
      {:ok, value}
    else
      {:error, {_reason, _offset}} -> error(:invalid_json)
      {:error, {_reason, _offset, _value}} -> error(:invalid_json)
      {:error, :invalid_json} -> error(:invalid_response)
    end
  end

  defp validate_json(_value, depth, _nodes) when depth > @max_json_depth,
    do: {:error, :invalid_json}

  defp validate_json(_value, _depth, nodes) when nodes >= @max_json_nodes,
    do: {:error, :invalid_json}

  defp validate_json(value, _depth, nodes)
       when is_binary(value) and byte_size(value) <= @max_json_string_bytes,
       do: {:ok, nodes + 1}

  defp validate_json(value, _depth, nodes)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, nodes + 1}

  defp validate_json(values, depth, nodes)
       when is_list(values) and length(values) <= @max_json_collection do
    Enum.reduce_while(values, {:ok, nodes + 1}, fn value, {:ok, count} ->
      case validate_json(value, depth + 1, count) do
        {:ok, count} -> {:cont, {:ok, count}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_json(values, depth, nodes)
       when is_map(values) and map_size(values) <= @max_json_collection do
    Enum.reduce_while(values, {:ok, nodes + 1}, fn {key, value}, {:ok, count} ->
      with true <- is_binary(key) and byte_size(key) <= 128,
           {:ok, count} <- validate_json(value, depth + 1, count) do
        {:cont, {:ok, count}}
      else
        _invalid -> {:halt, {:error, :invalid_json}}
      end
    end)
  end

  defp validate_json(_value, _depth, _nodes), do: {:error, :invalid_json}

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
