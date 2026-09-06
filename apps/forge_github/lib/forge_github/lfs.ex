defmodule ForgeGitHub.LFS do
  @moduledoc "GitHub Git LFS Batch and Basic transfer client."

  alias ForgeGitHub.{Error, RepositoryReference, RequestGate}
  alias ForgeGitHub.LFS.{Action, Object, Transport}

  @lfs_media_type "application/vnd.git-lfs+json"
  @user_agent "Fornacast/0.2.2"
  @maximum_batch_objects 100
  @maximum_metadata_bytes 2_000_000
  @maximum_action_response_bytes 65_536
  @maximum_object_size 9_223_372_036_854_775_807
  @expiry_skew_seconds 5
  @retry_fallback_seconds 60
  @maximum_retry_seconds 24 * 60 * 60
  @oid_regex ~r/\A[0-9a-f]{64}\z/
  @allow_test_options Mix.env() == :test

  @type object_spec :: %{required(:oid) => String.t(), required(:size) => non_neg_integer()}
  @type reader_state :: term()
  @type writer_state :: term()
  @type reader ::
          (pos_integer(), reader_state() ->
             {:ok, binary(), reader_state()}
             | {:eof, reader_state()}
             | {:error, term(), reader_state()})
  @type writer ::
          (binary(), writer_state() ->
             {:ok, writer_state()} | {:error, term(), writer_state()})

  @doc "Requests validated Basic transfer actions from GitHub's trusted repository endpoint."
  @spec batch(String.t(), String.t(), String.t(), :download | :upload, [object_spec()], keyword()) ::
          {:ok, [Object.t()]} | {:error, Error.t()}
  def batch(token, owner, repository, operation, objects, opts \\ []) do
    with :ok <- validate_token(token),
         true <- RepositoryReference.valid_owner?(owner),
         true <- RepositoryReference.valid_repository?(repository),
         {:ok, objects} <- validate_objects(objects),
         true <- operation in [:download, :upload],
         :ok <- validate_options(opts, [:ref]),
         {:ok, gate_key} <- Keyword.fetch(opts, :gate_key) do
      case RequestGate.run(gate_key, fn ->
             request_batch(token, owner, repository, operation, objects, opts)
           end) do
        {:error, :invalid_gate_key} -> error(:invalid_request)
        {:error, :busy} -> error(:request_gate_busy)
        result -> result
      end
    else
      _invalid -> error(:invalid_request)
    end
  end

  @doc "Streams one Basic download while checking its exact size and SHA-256 digest."
  @spec download(Action.t(), object_spec(), writer(), writer_state(), keyword()) ::
          {:ok, writer_state()} | {:error, Error.t(), writer_state()}
  def download(action, object, writer, state, opts \\ [])

  def download(%Action{operation: :download} = action, object, writer, state, opts)
      when is_function(writer, 2) do
    with {:ok, object} <- validate_object(object),
         :ok <- validate_options(opts, []),
         :ok <- ensure_fresh(action, opts),
         {url, headers} <- Action.request(action),
         {:ok, response, {state, hash}} <-
           transport_request(
             :get,
             url,
             headers,
             {:download, writer, {state, :crypto.hash_init(:sha256)}, object.size},
             opts
           ) do
      finish_download(response, action, hash, object.oid, state, opts)
    else
      {:error, %Error{} = error, latest_state} ->
        {:error, error, writer_state(latest_state, state)}

      {:error, %Error{} = error} ->
        {:error, error, state}

      _invalid ->
        {:error, Error.new(:invalid_request), state}
    end
  end

  def download(_action, _object, _writer, state, _opts),
    do: {:error, Error.new(:invalid_request), state}

  @doc "Runs a consumer with a bounded state-first reader suitable for `GitLFS.stage_upload/3`."
  @spec consume_download(Action.t(), object_spec(), function(), keyword()) ::
          {:ok, term()} | {:error, Error.t()} | {:error, Error.t(), term()}
  def consume_download(action, object, consumer, opts \\ [])

  def consume_download(%Action{operation: :download} = action, object, consumer, opts)
      when is_function(consumer, 2) do
    with {:ok, object} <- validate_object(object),
         :ok <- validate_options(opts, []),
         :ok <- ensure_fresh(action, opts),
         {url, headers} <- Action.request(action),
         {:ok, response, consumer_result} <-
           transport_request(
             :get,
             url,
             headers,
             {:consume_download, consumer, object.size, object.oid},
             opts
           ) do
      finish_consumed_download(response, action, consumer_result, opts)
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> error(:invalid_request)
    end
  end

  def consume_download(_action, _object, _consumer, _opts), do: error(:invalid_request)

  @doc "Streams one exact local object to a validated Basic upload action."
  @spec upload(Action.t(), object_spec(), reader(), reader_state(), keyword()) ::
          {:ok, reader_state()} | {:error, Error.t(), reader_state()}
  def upload(action, object, reader, state, opts \\ [])

  def upload(%Action{operation: :upload} = action, object, reader, state, opts)
      when is_function(reader, 2) do
    with {:ok, object} <- validate_object(object),
         :ok <- validate_options(opts, []),
         :ok <- ensure_fresh(action, opts),
         {url, headers} <- Action.request(action),
         headers <- put_default_header(headers, "content-type", "application/octet-stream"),
         {:ok, response, {state, hash}} <-
           transport_request(
             :put,
             url,
             headers,
             {:upload, hash_reader(reader), {state, :crypto.hash_init(:sha256)}, object.size},
             opts
           ) do
      finish_upload(response, action, hash, object.oid, state, opts)
    else
      {:error, %Error{} = error, latest_state} ->
        {:error, error, reader_state(latest_state, state)}

      {:error, %Error{} = error} ->
        {:error, error, state}

      _invalid ->
        {:error, Error.new(:invalid_request), state}
    end
  end

  def upload(_action, _object, _reader, state, _opts),
    do: {:error, Error.new(:invalid_request), state}

  @doc "Calls an optional Basic verify action after upload."
  @spec verify(Action.t(), object_spec(), keyword()) :: :ok | {:error, Error.t()}
  def verify(action, object, opts \\ [])

  def verify(%Action{operation: :verify} = action, object, opts) do
    with {:ok, object} <- validate_object(object),
         :ok <- validate_options(opts, []),
         :ok <- ensure_fresh(action, opts),
         {:ok, body} <- encode_json(%{"oid" => object.oid, "size" => object.size}),
         {url, headers} <- Action.request(action),
         headers <- put_default_header(headers, "accept", @lfs_media_type),
         headers <- put_default_header(headers, "content-type", @lfs_media_type),
         {:ok, response} <-
           transport_request(
             :post,
             url,
             headers,
             {:buffer, body, @maximum_action_response_bytes},
             opts
           ) do
      successful_action_response(response, action, opts)
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> error(:invalid_request)
    end
  end

  def verify(_action, _object, _opts), do: error(:invalid_request)

  defp request_batch(token, owner, repository, operation, objects, opts) do
    url = "https://github.com/#{owner}/#{repository}.git/info/lfs/objects/batch"

    payload = %{
      "operation" => Atom.to_string(operation),
      "transfers" => ["basic"],
      "hash_algo" => "sha256",
      "objects" => Enum.map(objects, &%{"oid" => &1.oid, "size" => &1.size})
    }

    with {:ok, payload} <- maybe_put_ref(payload, opts),
         {:ok, body} <- encode_json(payload),
         true <- byte_size(body) <= @maximum_metadata_bytes,
         {:ok, response} <-
           transport_request(
             :post,
             url,
             batch_headers(token),
             {:buffer, body, @maximum_metadata_bytes},
             opts
           ),
         :ok <- successful_batch_response(response, opts),
         {:ok, json} <- decode_json(response.body),
         {:ok, results} <- parse_batch_response(json, operation, objects, opts) do
      {:ok, results}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> error(:invalid_lfs_response)
    end
  end

  defp batch_headers(token) do
    [
      {"accept", @lfs_media_type},
      {"content-type", @lfs_media_type},
      {"authorization", "Basic " <> Base.encode64("x-access-token:" <> token)},
      {"user-agent", @user_agent}
    ]
  end

  defp maybe_put_ref(payload, opts) do
    case Keyword.fetch(opts, :ref) do
      :error ->
        {:ok, payload}

      {:ok, ref} when is_binary(ref) and byte_size(ref) in 1..1_024 ->
        if String.valid?(ref) and :binary.match(ref, <<0>>) == :nomatch,
          do: {:ok, Map.put(payload, "ref", %{"name" => ref})},
          else: :error

      _invalid ->
        :error
    end
  end

  defp parse_batch_response(json, operation, requested, opts) when is_map(json) do
    with true <- Map.get(json, "transfer", "basic") == "basic",
         true <- Map.get(json, "hash_algo", "sha256") == "sha256",
         values when is_list(values) <- Map.get(json, "objects"),
         true <- length(values) == length(requested),
         true <- length(values) <= @maximum_batch_objects,
         requested_by_oid <- Map.new(requested, &{&1.oid, &1}),
         {:ok, objects} <- parse_objects(values, operation, requested_by_oid, opts),
         true <- MapSet.new(Enum.map(objects, & &1.oid)) == MapSet.new(Map.keys(requested_by_oid)) do
      {:ok, objects}
    else
      _invalid -> error(:invalid_lfs_response)
    end
  end

  defp parse_batch_response(_json, _operation, _requested, _opts),
    do: error(:invalid_lfs_response)

  defp parse_objects(values, operation, requested_by_oid, opts) do
    Enum.reduce_while(values, {:ok, [], MapSet.new()}, fn value, {:ok, objects, seen} ->
      case parse_object(value, operation, requested_by_oid, opts) do
        {:ok, %Object{oid: oid} = object} ->
          if MapSet.member?(seen, oid),
            do: {:halt, error(:invalid_lfs_response)},
            else: {:cont, {:ok, [object | objects], MapSet.put(seen, oid)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, objects, _seen} -> {:ok, Enum.reverse(objects)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp parse_object(%{"oid" => oid, "size" => size} = value, operation, requested, opts) do
    with %{size: ^size} <- Map.get(requested, oid),
         authenticated when is_boolean(authenticated) <- Map.get(value, "authenticated", false),
         {:ok, actions, object_error} <- parse_result(value, operation, opts) do
      {:ok,
       %Object{
         oid: oid,
         size: size,
         authenticated: authenticated,
         actions: actions,
         error: object_error
       }}
    else
      _invalid -> error(:invalid_lfs_response)
    end
  end

  defp parse_object(_value, _operation, _requested, _opts), do: error(:invalid_lfs_response)

  defp parse_result(%{"error" => error_value} = value, _operation, _opts) do
    with false <- Map.has_key?(value, "actions"),
         {:ok, object_error} <- parse_object_error(error_value) do
      {:ok, %{}, object_error}
    else
      _invalid -> error(:invalid_lfs_response)
    end
  end

  defp parse_result(value, operation, opts) do
    case Map.get(value, "actions", %{}) do
      actions when is_map(actions) ->
        with {:ok, parsed} <- parse_actions(actions, operation, opts),
             true <- valid_action_set?(operation, parsed) do
          {:ok, parsed, nil}
        else
          _invalid -> error(:invalid_lfs_response)
        end

      _invalid ->
        error(:invalid_lfs_response)
    end
  end

  defp parse_actions(actions, operation, opts) do
    allowed =
      if operation == :download,
        do: %{"download" => :download},
        else: %{"upload" => :upload, "verify" => :verify}

    if Enum.all?(Map.keys(actions), &Map.has_key?(allowed, &1)) do
      Enum.reduce_while(actions, {:ok, %{}}, fn {name, value}, {:ok, parsed} ->
        action_operation = Map.fetch!(allowed, name)

        case parse_action(action_operation, value, opts) do
          {:ok, action} -> {:cont, {:ok, Map.put(parsed, action_operation, action)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
    else
      error(:invalid_lfs_response)
    end
  end

  defp parse_action(operation, %{"href" => href} = value, opts) do
    with headers when is_map(headers) <- Map.get(value, "header", %{}),
         {:ok, expires_at} <- action_expiry(value, opts) do
      case Action.new(operation, href, headers, expires_at) do
        {:ok, action} -> {:ok, action}
        :error -> error(:unsafe_action_url)
      end
    else
      _invalid -> error(:invalid_lfs_response)
    end
  end

  defp parse_action(_operation, _value, _opts), do: error(:invalid_lfs_response)

  defp valid_action_set?(:download, parsed), do: Map.has_key?(parsed, :download)

  defp valid_action_set?(:upload, parsed),
    do: map_size(parsed) == 0 or Map.has_key?(parsed, :upload)

  defp action_expiry(value, opts) do
    cond do
      Map.has_key?(value, "expires_in") ->
        case Map.fetch!(value, "expires_in") do
          seconds when is_integer(seconds) and seconds in -2_147_483_647..2_147_483_647 ->
            {:ok, DateTime.add(now(opts), seconds)}

          _invalid ->
            :error
        end

      Map.has_key?(value, "expires_at") ->
        case DateTime.from_iso8601(Map.fetch!(value, "expires_at")) do
          {:ok, expires_at, 0} -> {:ok, expires_at}
          _invalid -> :error
        end

      true ->
        {:ok, nil}
    end
  rescue
    _exception -> :error
  end

  defp parse_object_error(%{"code" => code, "message" => message})
       when is_integer(code) and is_binary(message) and byte_size(message) <= 16_384 do
    kind =
      case code do
        code when code in [404, 410] -> :object_missing
        401 -> :invalid_credential
        403 -> :forbidden
        code when code in 500..599 -> :upstream_unavailable
        _other -> :invalid_response
      end

    {:ok, Error.new(kind)}
  end

  defp parse_object_error(_value), do: :error

  defp successful_batch_response(%{status: 200} = response, _opts) do
    if lfs_json_response?(response), do: :ok, else: error(:invalid_lfs_response)
  end

  defp successful_batch_response(response, opts), do: classify_response(response, opts)

  defp successful_action_response(%{status: 200}, _action, _opts),
    do: :ok

  defp successful_action_response(response, action, opts) do
    if Action.expired?(action, now(opts), 0),
      do: error(:action_expired),
      else: classify_response(response, opts, :action)
  end

  defp finish_download(response, action, hash, oid, state, opts) do
    with :ok <- successful_action_response(response, action, opts),
         :ok <- verify_digest(hash, oid) do
      {:ok, state}
    else
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp finish_upload(response, action, hash, oid, state, opts) do
    with :ok <- successful_action_response(response, action, opts),
         :ok <- verify_digest(hash, oid) do
      {:ok, state}
    else
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp finish_consumed_download(response, action, {:ok, value}, opts) do
    case successful_action_response(response, action, opts) do
      :ok -> {:ok, value}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp finish_consumed_download(response, action, {:error, reason}, opts) do
    case successful_action_response(response, action, opts) do
      :ok -> {:error, Error.new(:sink), reason}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp finish_consumed_download(_response, _action, _invalid, _opts),
    do: error(:transport)

  defp classify_response(response, opts, context \\ :batch)

  defp classify_response(%{status: status}, _opts, _context) when status in 300..399,
    do: error(:unsafe_redirect)

  defp classify_response(%{status: 401}, _opts, _context), do: error(:invalid_credential)

  defp classify_response(%{status: status} = response, opts, _context)
       when status in [403, 429] do
    cond do
      header(response, "x-ratelimit-remaining") == "0" ->
        error(:primary_rate_limit, primary_retry_at(response, opts))

      status == 429 or not is_nil(header(response, "retry-after")) ->
        error(:secondary_rate_limit, secondary_retry_at(response, opts))

      true ->
        error(:forbidden)
    end
  end

  defp classify_response(%{status: 404}, _opts, :action), do: error(:object_missing)
  defp classify_response(%{status: 404}, _opts, :batch), do: error(:not_found)

  defp classify_response(%{status: status}, _opts, _context) when status in 500..599,
    do: error(:upstream_unavailable)

  defp classify_response(_response, _opts, _context), do: error(:unexpected_status)

  defp primary_retry_at(response, opts) do
    current = now(opts)

    case parse_integer(header(response, "x-ratelimit-reset"), 9_999_999_999) do
      {:ok, unix} ->
        case DateTime.from_unix(unix) do
          {:ok, candidate} -> bounded_retry_at(candidate, current)
          _invalid -> fallback_retry_at(current)
        end

      :error ->
        fallback_retry_at(current)
    end
  end

  defp secondary_retry_at(response, opts) do
    current = now(opts)

    case parse_integer(header(response, "retry-after"), @maximum_retry_seconds) do
      {:ok, seconds} -> bounded_retry_at(DateTime.add(current, seconds), current)
      :error -> fallback_retry_at(current)
    end
  end

  defp bounded_retry_at(candidate, current) do
    maximum = DateTime.add(current, @maximum_retry_seconds)

    cond do
      DateTime.compare(candidate, current) in [:lt, :eq] -> fallback_retry_at(current)
      DateTime.compare(candidate, maximum) == :gt -> maximum
      true -> candidate
    end
  end

  defp fallback_retry_at(current), do: DateTime.add(current, @retry_fallback_seconds)

  defp header(%{headers: headers}, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {header_name, value} when is_binary(header_name) and is_binary(value) ->
        if String.downcase(header_name) == name, do: value

      _invalid ->
        nil
    end)
  end

  defp header(_response, _name), do: nil

  defp lfs_json_response?(response) do
    case headers(response, "content-type") do
      [value] ->
        media_type =
          value
          |> String.split(";", parts: 2)
          |> hd()
          |> String.trim()
          |> String.downcase()

        media_type == @lfs_media_type

      _missing ->
        false
    end
  end

  defp headers(%{headers: headers}, name) when is_list(headers) do
    Enum.flat_map(headers, fn
      {header_name, value} when is_binary(header_name) and is_binary(value) ->
        if String.downcase(header_name) == name, do: [value], else: []

      _invalid ->
        []
    end)
  end

  defp headers(_response, _name), do: []

  defp parse_integer(value, maximum) when is_binary(value) and byte_size(value) <= 12 do
    case Integer.parse(value) do
      {integer, ""} when integer in 0..maximum//1 -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp parse_integer(_value, _maximum), do: :error

  defp ensure_fresh(action, opts) do
    if Action.expired?(action, now(opts), @expiry_skew_seconds),
      do: error(:action_expired),
      else: :ok
  end

  defp verify_digest(hash, oid) do
    digest = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    if Plug.Crypto.secure_compare(digest, oid), do: :ok, else: error(:integrity_mismatch)
  end

  defp hash_reader(reader) do
    fn length, {state, hash} ->
      case reader.(length, state) do
        {:ok, chunk, next_state} when is_binary(chunk) and chunk != "" ->
          {:ok, chunk, {next_state, :crypto.hash_update(hash, chunk)}}

        {:eof, next_state} ->
          {:eof, {next_state, hash}}

        {:error, _reason, next_state} ->
          {:error, :source, {next_state, hash}}

        _invalid ->
          {:error, :source, {state, hash}}
      end
    end
  end

  defp writer_state({state, _hash}, _fallback), do: state
  defp writer_state(_invalid, fallback), do: fallback
  defp reader_state({state, _hash}, _fallback), do: state
  defp reader_state(_invalid, fallback), do: fallback

  defp put_default_header(headers, name, value) do
    if List.keymember?(headers, name, 0), do: headers, else: [{name, value} | headers]
  end

  defp validate_objects(objects)
       when is_list(objects) and length(objects) in 1..@maximum_batch_objects do
    Enum.reduce_while(objects, {:ok, [], MapSet.new()}, fn object, {:ok, acc, seen} ->
      case validate_object(object) do
        {:ok, %{oid: oid} = object} ->
          if MapSet.member?(seen, oid),
            do: {:halt, :error},
            else: {:cont, {:ok, [object | acc], MapSet.put(seen, oid)}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, values, _seen} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp validate_objects(_objects), do: :error

  defp validate_object(%{oid: oid, size: size})
       when is_binary(oid) and is_integer(size) and size in 0..@maximum_object_size do
    if Regex.match?(@oid_regex, oid), do: {:ok, %{oid: oid, size: size}}, else: :error
  end

  defp validate_object(_object), do: :error

  defp validate_token(token) when is_binary(token) and byte_size(token) in 1..16_384 do
    if String.valid?(token) and :binary.match(token, <<0>>) == :nomatch, do: :ok, else: :error
  end

  defp validate_token(_token), do: :error

  if @allow_test_options do
    defp validate_options(opts, extra) when is_list(opts) and is_list(extra) do
      allowed =
        [:gate_key, :transport, :resolver, :now, :transport_api, :request_timeout, :test_pid] ++
          extra

      keys = Keyword.keys(opts)

      if Keyword.keyword?(opts) and keys -- allowed == [] and
           length(keys) == length(Enum.uniq(keys)) and valid_test_options?(opts),
         do: :ok,
         else: :error
    end

    defp validate_options(_opts, _extra), do: :error

    defp valid_test_options?(opts) do
      (not Keyword.has_key?(opts, :now) or is_function(opts[:now], 0)) and
        (not Keyword.has_key?(opts, :resolver) or is_function(opts[:resolver], 1)) and
        (not Keyword.has_key?(opts, :transport_api) or is_atom(opts[:transport_api])) and
        (not Keyword.has_key?(opts, :request_timeout) or
           (is_integer(opts[:request_timeout]) and opts[:request_timeout] in 1..20_000)) and
        (not Keyword.has_key?(opts, :transport) or valid_transport?(opts[:transport]))
    end

    defp valid_transport?({module, _state}), do: is_atom(module)
    defp valid_transport?(module), do: is_atom(module)
  else
    defp validate_options(opts, extra) when is_list(opts) and is_list(extra) do
      keys = Keyword.keys(opts)

      if Keyword.keyword?(opts) and keys -- [:gate_key | extra] == [] and
           length(keys) == length(Enum.uniq(keys)),
         do: :ok,
         else: :error
    end

    defp validate_options(_opts, _extra), do: :error
  end

  defp transport_request(method, url, headers, body, opts) do
    module =
      case Keyword.get(opts, :transport, Transport) do
        {module, _state} -> module
        module -> module
      end

    case module.request(method, url, headers, body, opts) do
      {:ok, response} ->
        {:ok, response}

      {:ok, response, state} ->
        {:ok, response, state}

      {:error, %Transport.Error{kind: kind}} ->
        error(transport_error_kind(kind))

      {:error, %Transport.Error{kind: kind}, state} ->
        {:error, Error.new(transport_error_kind(kind)), state}

      _invalid ->
        error(:transport)
    end
  rescue
    _exception -> error(:transport)
  catch
    _kind, _reason -> error(:transport)
  end

  defp transport_error_kind(kind)
       when kind in [
              :timeout,
              :host_unavailable,
              :unsafe_host,
              :source,
              :sink,
              :integrity_mismatch,
              :response_too_large
            ],
       do: kind

  defp transport_error_kind(_kind), do: :transport

  defp decode_json(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, value} -> {:ok, value}
      _invalid -> error(:invalid_lfs_response)
    end
  end

  defp decode_json(_body), do: error(:invalid_lfs_response)

  defp encode_json(value) do
    {:ok, JSON.encode!(value)}
  rescue
    _exception -> error(:invalid_request)
  end

  defp now(opts) do
    case Keyword.fetch(opts, :now) do
      {:ok, now} -> now.()
      :error -> DateTime.utc_now()
    end
  end

  defp error(kind, retry_at \\ nil), do: {:error, Error.new(kind, retry_at)}
end
