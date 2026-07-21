defmodule FornacastAPI.Plugs.RateLimit do
  import Plug.Conn

  alias FornacastAPI.{Error, Response}
  alias FornacastAPI.RateLimit, as: Counter
  alias FornacastAPI.RateLimit.Bucket

  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/using-the-rest-api/rate-limits-for-the-rest-api"

  def init(opts), do: opts

  def call(conn, _opts) do
    identity = identity(conn)

    if conn.method == "GET" and conn.request_path == "/api/v3/rate_limit" do
      assign_bucket(conn, identity, Counter.peek(identity))
    else
      case Counter.consume(identity) do
        {:ok, bucket} ->
          assign_bucket(conn, identity, bucket)

        {:error, bucket} ->
          conn
          |> assign_bucket(identity, bucket)
          |> Response.error(rate_limit_error())
          |> halt()
      end
    end
  end

  def ensure_bucket(%Plug.Conn{assigns: %{rate_limit_bucket: %Bucket{}}} = conn), do: conn

  def ensure_bucket(conn) do
    identity = {:ip, Map.fetch!(conn.assigns, :effective_client_ip)}

    case Counter.consume(identity) do
      {:ok, bucket} ->
        assign_bucket(conn, identity, bucket)

      {:error, bucket} ->
        conn
        |> assign_bucket(identity, bucket)
        |> put_exceeded_response()
    end
  end

  def put_headers(%Plug.Conn{assigns: %{rate_limit_bucket: %Bucket{} = bucket}} = conn) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(bucket.limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(bucket.remaining))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(bucket.reset))
    |> put_resp_header("x-ratelimit-used", Integer.to_string(bucket.used))
    |> put_resp_header("x-ratelimit-resource", bucket.resource)
  end

  def identity(%Plug.Conn{assigns: %{api_auth: %{api_key: %{id: id}}}})
      when is_integer(id) and id > 0,
      do: {:token, id}

  def identity(conn), do: {:ip, Map.fetch!(conn.assigns, :effective_client_ip)}

  defp assign_bucket(conn, identity, bucket) do
    conn
    |> assign(:rate_limit_identity, identity)
    |> assign(:rate_limit_bucket, bucket)
  end

  defp put_exceeded_response(conn) do
    body = %{
      message: "API rate limit exceeded",
      documentation_url: @documentation_url
    }

    conn
    |> put_resp_content_type("application/json")
    |> resp(429, JSON.encode_to_iodata!(body))
  end

  defp rate_limit_error do
    Error.new(429, "API rate limit exceeded", @documentation_url)
  end
end
