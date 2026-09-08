defmodule ForgeGitHub.RelationshipClientTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, RelationshipClient}

  setup {Req.Test, :verify_on_exit!}

  test "resolves two independent 512 node sets in one fixed query with current names" do
    labels = Enum.map(1..512, &label_input/1)
    users = Enum.map(1..512, &user_input/1)
    stub = stub_name()

    Req.Test.expect(stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/graphql"
      assert {:ok, encoded, conn} = Plug.Conn.read_body(conn)
      request = JSON.decode!(encoded)

      assert request["variables"] == %{
               "labels" => Enum.map(labels, & &1.github_node_id),
               "assignees" => Enum.map(users, & &1.github_node_id)
             }

      assert request["query"] =~ "labels: nodes(ids: $labels)"
      assert request["query"] =~ "assignees: nodes(ids: $assignees)"

      Req.Test.json(
        conn,
        response(
          Enum.reverse(Enum.map(1..512, &label_node/1)),
          Enum.reverse(Enum.map(1..512, &user_node/1))
        )
      )
    end)

    client_opts =
      Keyword.put(
        opts(stub),
        :deadline_monotonic_ms,
        System.monotonic_time(:millisecond) + 20_000
      )

    assert {:ok, result} =
             RelationshipClient.resolve("token", repository(), labels, users, client_opts)

    assert length(result.labels) == 512
    assert length(result.assignees) == 512
    assert hd(result.labels) == %{github_object_id: 1, github_node_id: "L_1", name: "renamed-1"}
    assert hd(result.assignees) == %{github_user_id: 1, github_node_id: "U_1", login: "renamed-1"}
  end

  test "accepts a bot and empty relationship sets" do
    assert {:ok, %{labels: [], assignees: []}} =
             RelationshipClient.resolve("token", repository(), [], [], opts(stub_name()))

    stub = stub_name()

    Req.Test.expect(
      stub,
      &Req.Test.json(
        &1,
        response([], [%{"__typename" => "Bot", "id" => "U_1", "login" => "renovate[bot]"}])
      )
    )

    assert {:ok, %{labels: [], assignees: [%{login: "renovate[bot]"}]}} =
             RelationshipClient.resolve("token", repository(), [], [user_input(1)], opts(stub))
  end

  test "rejects echoed credentials in names and logins without narrowing Unicode labels" do
    for {field, value} <- [
          {:label, "opaquecredential"},
          {:label, "prefix opaquecredential suffix"},
          {:label, "ghs_othersecret"},
          {:user, "opaquecredential"}
        ] do
      stub = stub_name()
      label = if field == :label, do: Map.put(label_node(1), "name", value), else: label_node(1)
      user = if field == :user, do: Map.put(user_node(1), "login", value), else: user_node(1)
      Req.Test.expect(stub, &Req.Test.json(&1, response([label], [user])))

      assert {:error, %Error{kind: :invalid_response}} =
               RelationshipClient.resolve(
                 "opaquecredential",
                 repository(),
                 [label_input(1)],
                 [user_input(1)],
                 opts(stub)
               )
    end

    stub = stub_name()
    name = String.duplicate("界", 255)

    Req.Test.expect(
      stub,
      &Req.Test.json(&1, response([Map.put(label_node(1), "name", name)], []))
    )

    assert {:ok, %{labels: [%{name: ^name}]}} =
             RelationshipClient.resolve(
               "opaquecredential",
               repository(),
               [label_input(1)],
               [],
               opts(stub)
             )
  end

  test "rejects credential-shaped or echoed node identities before transport" do
    for node <- ["opaquecredential", "prefixopaquecredentialsuffix", "ghs_othersecret"] do
      assert {:error, %Error{kind: :invalid_request}} =
               RelationshipClient.resolve(
                 "opaquecredential",
                 repository(),
                 [%{github_object_id: 1, github_node_id: node}],
                 [],
                 opts(stub_name())
               )

      assert {:error, %Error{kind: :invalid_request}} =
               RelationshipClient.resolve(
                 "opaquecredential",
                 %{github_object_id: 77, github_node_id: node},
                 [],
                 [],
                 opts(stub_name())
               )
    end
  end

  test "rejects partial GraphQL data, null, wrong types and non-exact identity sets" do
    good = response([label_node(1)], [user_node(1)])

    invalid = [
      Map.put(good, "errors", [%{"message" => "partial"}]),
      response([nil], [user_node(1)]),
      response([], [user_node(1)]),
      response([label_node(1), label_node(1)], [user_node(1)]),
      response([label_node(2)], [user_node(1)]),
      response([Map.put(label_node(1), "__typename", "User")], [user_node(1)]),
      response([put_in(label_node(1), ["repository", "id"], "OTHER")], [user_node(1)]),
      response([label_node(1)], [Map.put(user_node(1), "__typename", "Organization")]),
      response([label_node(1)], [Map.put(user_node(1), "login", "bad/login")]),
      response([Map.put(label_node(1), "name", "")], [user_node(1)]),
      %{"data" => nil}
    ]

    for body <- invalid do
      stub = stub_name()
      Req.Test.expect(stub, &Req.Test.json(&1, body))

      assert {:error, %Error{kind: :invalid_response}} =
               RelationshipClient.resolve(
                 "token",
                 repository(),
                 [label_input(1)],
                 [user_input(1)],
                 opts(stub)
               )
    end
  end

  test "rejects malformed identities and oversized or duplicate inputs before transport" do
    for {repo, labels, users} <- [
          {repository(), Enum.map(1..513, &label_input/1), []},
          {repository(), [], Enum.map(1..513, &user_input/1)},
          {repository(), [label_input(1), label_input(1)], []},
          {repository(), [label_input(1), %{github_object_id: 2, github_node_id: "L_1"}], []},
          {repository(), [label_input(1)], [%{github_user_id: 1, github_node_id: "L_1"}]},
          {repository(), [%{github_object_id: 0, github_node_id: "L_1"}], []},
          {repository(), [%{github_object_id: 9_223_372_036_854_775_808, github_node_id: "L_1"}],
           []},
          {repository(), [Map.put(label_input(1), :name, "untrusted")], []},
          {repository(), [%{github_object_id: 1, github_node_id: " L_1"}], []},
          {%{github_object_id: 1, github_node_id: nil}, [], []},
          {repository(), nil, []}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               RelationshipClient.resolve("token", repo, labels, users, opts(stub_name()))
    end
  end

  test "requires installation gate and forwards an expired absolute deadline without transport" do
    assert {:error, %Error{kind: :invalid_request}} =
             RelationshipClient.resolve("token", repository(), [], [], [])

    assert {:error, %Error{kind: :invalid_request}} =
             RelationshipClient.resolve(
               "token",
               repository(),
               [],
               [],
               Keyword.put(opts(stub_name()), :json, %{"query" => "injected"})
             )

    assert {:error, %Error{kind: :invalid_request}} =
             RelationshipClient.resolve(
               "token",
               repository(),
               [],
               [],
               Keyword.put(opts(stub_name()), :deadline_monotonic_ms, "invalid")
             )

    assert {:error, %Error{kind: :timeout}} =
             RelationshipClient.resolve(
               "token",
               repository(),
               [],
               [],
               Keyword.put(
                 opts(stub_name()),
                 :deadline_monotonic_ms,
                 System.monotonic_time(:millisecond) - 1
               )
             )
  end

  defp repository, do: %{github_object_id: 77, github_node_id: "R_77"}
  defp label_input(id), do: %{github_object_id: id, github_node_id: "L_#{id}"}
  defp user_input(id), do: %{github_user_id: id, github_node_id: "U_#{id}"}

  defp label_node(id),
    do: %{
      "__typename" => "Label",
      "id" => "L_#{id}",
      "name" => "renamed-#{id}",
      "repository" => %{"id" => "R_77"}
    }

  defp user_node(id), do: %{"__typename" => "User", "id" => "U_#{id}", "login" => "renamed-#{id}"}
  defp response(labels, users), do: %{"data" => %{"labels" => labels, "assignees" => users}}
  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}

  defp opts(stub),
    do: [
      plug: {Req.Test, stub},
      gate_key: {:github_installation, System.unique_integer([:positive])},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]
end
