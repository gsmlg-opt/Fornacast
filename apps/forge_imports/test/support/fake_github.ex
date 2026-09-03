defmodule ForgeImports.TestSupport.FakeGitHub do
  @moduledoc false

  @fixtures Path.expand("../fixtures/github", __DIR__)

  @type repo_config :: %{
          required(:name) => String.t(),
          optional(:id) => pos_integer(),
          optional(:full_name) => String.t(),
          optional(:owner) => String.t(),
          optional(:default_branch) => String.t(),
          optional(:visibility) => String.t(),
          optional(:description) => String.t(),
          optional(:labels) => list(),
          optional(:issues) => list(),
          optional(:comments) => map(),
          optional(:pulls) => list()
        }

  @type config :: %{
          optional(:login) => String.t(),
          optional(:user_id) => pos_integer(),
          optional(:organization) => map(),
          optional(:repos) => [repo_config()],
          optional(:rate_limit?) => boolean(),
          optional(:retry_at) => DateTime.t()
        }

  @spec stub_name() :: atom()
  def stub_name, do: :"fake_github_#{System.unique_integer([:positive])}"

  @spec start!(config()) :: atom()
  def start!(config) when is_map(config) do
    stub = stub_name()
    parent = self()

    Req.Test.stub(stub, fn conn ->
      send(parent, {:fake_github_request, conn.method, conn.request_path})
      dispatch(conn, config)
    end)

    stub
  end

  @spec client_opts(atom(), keyword()) :: keyword()
  def client_opts(stub, opts \\ []) when is_atom(stub) and is_list(opts) do
    gate_key = Keyword.get(opts, :gate_key, {:fake_github, stub})

    [
      plug: {Req.Test, stub},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end,
      gate_key: gate_key
    ]
  end

  @spec fixture!(String.t()) :: term()
  def fixture!(filename) do
    @fixtures
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
  end

  @spec user_json(config()) :: map()
  def user_json(config) do
    %{
      "id" => Map.get(config, :user_id, 9_000_000_001),
      "login" => Map.get(config, :login, "octocat"),
      "name" => "The Octocat",
      "avatar_url" => "https://avatars.githubusercontent.com/u/9",
      "html_url" => "https://github.com/octocat"
    }
  end

  @spec organization_json(map()) :: map()
  def organization_json(attrs) do
    %{
      "id" => Map.get(attrs, "id", 99),
      "login" => Map.fetch!(attrs, "login"),
      "name" => Map.get(attrs, "name", Map.fetch!(attrs, "login")),
      "description" => Map.get(attrs, "description", "Imported organization")
    }
  end

  @spec repository_json(repo_config()) :: map()
  def repository_json(repo) do
    owner = Map.get(repo, :owner, "acme")
    name = Map.fetch!(repo, :name)

    %{
      "id" => Map.get(repo, :id, 12_000 + :erlang.phash2(name, 1_000_000)),
      "node_id" => "R_#{name}",
      "name" => name,
      "full_name" => Map.get(repo, :full_name, "#{owner}/#{name}"),
      "private" => Map.get(repo, :visibility, "private") == "private",
      "visibility" => Map.get(repo, :visibility, "private"),
      "default_branch" => Map.get(repo, :default_branch, "main"),
      "description" => Map.get(repo, :description, "Imported repository"),
      "has_issues" => true,
      "allow_merge_commit" => true,
      "fork" => false,
      "archived" => false,
      "owner" => %{
        "id" => 1,
        "login" => owner,
        "avatar_url" => "https://avatars.githubusercontent.com/u/1",
        "html_url" => "https://github.com/#{owner}"
      }
    }
  end

  defp dispatch(conn, config) do
    cond do
      config[:rate_limit?] ->
        retry_at = Map.get(config, :retry_at, DateTime.utc_now(:second))

        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header(
          "x-ratelimit-reset",
          Integer.to_string(DateTime.to_unix(retry_at))
        )
        |> Plug.Conn.send_resp(403, "rate limit")

      conn.request_path == "/user" ->
        Req.Test.json(conn, user_json(config))

      String.starts_with?(conn.request_path, "/orgs/") and
          not String.ends_with?(conn.request_path, "/repos") ->
        org = organization_path(conn.request_path)
        org_config = Map.get(config, :organization, %{"login" => org})
        Req.Test.json(conn, organization_json(org_config))

      String.starts_with?(conn.request_path, "/orgs/") and
          String.ends_with?(conn.request_path, "/repos") ->
        repos = Enum.map(Map.get(config, :repos, []), &repository_json/1)
        Req.Test.json(conn, repos)

      repo = repository_path(conn.request_path) ->
        respond_repository_metadata(conn, repo, config)

      true ->
        Plug.Conn.send_resp(conn, 404, "{}")
    end
  end

  defp respond_repository_metadata(conn, {owner, name}, config) do
    repo = find_repo!(config, owner, name)

    cond do
      String.contains?(conn.request_path, "/labels") ->
        Req.Test.json(conn, Map.get(repo, :labels, fixture!("labels_page.json")))

      String.ends_with?(conn.request_path, "/issues") and
          not String.contains?(conn.request_path, "/issues/") ->
        Req.Test.json(conn, Map.get(repo, :issues, []))

      String.contains?(conn.request_path, "/issues/") and
          String.ends_with?(conn.request_path, "/comments") ->
        number = conn.request_path |> String.split("/") |> Enum.at(5) |> String.to_integer()
        comments = Map.get(repo, :comments, %{})
        Req.Test.json(conn, Map.get(comments, number, []))

      String.contains?(conn.request_path, "/pulls/") ->
        number = conn.request_path |> String.split("/") |> List.last() |> String.to_integer()
        pulls = Map.get(repo, :pulls, [])

        case Enum.find(pulls, &(&1["number"] == number)) do
          nil -> Plug.Conn.send_resp(conn, 404, "{}")
          payload -> Req.Test.json(conn, payload)
        end

      true ->
        Req.Test.json(conn, repository_json(repo))
    end
  end

  defp find_repo!(config, owner, name) do
    Enum.find_value(Map.get(config, :repos, []), fn repo ->
      repo_owner = Map.get(repo, :owner, "acme")
      repo_name = Map.get(repo, :name)

      if repo_owner == owner and repo_name == name, do: repo
    end) || raise "missing fake repository #{owner}/#{name}"
  end

  defp organization_path("/orgs/" <> rest) do
    rest
    |> String.split("/", parts: 2)
    |> hd()
  end

  defp organization_path(_), do: nil

  defp repository_path("/repos/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [owner, repo_and_more] ->
        name = repo_and_more |> String.split("/") |> hd()
        {owner, name}

      _ ->
        nil
    end
  end

  defp repository_path(_), do: nil
end
