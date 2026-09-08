defmodule ForgeGitHub.RefObservationTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, RefObservation}

  setup {Req.Test, :verify_on_exit!}

  test "observes one exact branch commit from an authenticated immutable repository" do
    stub = stub_name()
    parent = self()

    Req.Test.expect(stub, 3, fn conn ->
      send(parent, {:request, conn.request_path})

      case conn.request_path do
        "/repos/acme/base" ->
          Req.Test.json(conn, repository_json())

        "/repos/acme/base/git/ref/heads/feature/topic" ->
          Req.Test.json(conn, reference_json("refs/heads/feature/topic"))
      end
    end)

    assert {:ok,
            %{
              repository: %{github_object_id: 1_001, github_node_id: "R_base"},
              ref_name: "refs/heads/feature/topic",
              oid: "1111111111111111111111111111111111111111"
            }} =
             RefObservation.observe(
               "installation_token",
               "acme",
               "base",
               %{github_object_id: 1_001, github_node_id: "R_base"},
               "refs/heads/feature/topic",
               client_opts(stub)
             )

    assert_received {:request, "/repos/acme/base"}
    assert_received {:request, "/repos/acme/base/git/ref/heads/feature/topic"}
    assert_received {:request, "/repos/acme/base"}
  end

  test "rejects a repository path replacement between the reference and final identity read" do
    stub = stub_name()
    counter = :counters.new(1, [:atomics])

    Req.Test.expect(stub, 3, fn conn ->
      :counters.add(counter, 1, 1)

      case {conn.request_path, :counters.get(counter, 1)} do
        {"/repos/acme/base", 1} ->
          Req.Test.json(conn, repository_json())

        {"/repos/acme/base/git/ref/heads/main", 2} ->
          Req.Test.json(conn, reference_json("refs/heads/main"))

        {"/repos/acme/base", 3} ->
          Req.Test.json(
            conn,
            repository_json(%{"id" => 2_002, "node_id" => "R_replacement"})
          )
      end
    end)

    assert {:error, %Error{kind: :invalid_response}} =
             RefObservation.observe(
               "installation_token",
               "acme",
               "base",
               %{github_object_id: 1_001, github_node_id: "R_base"},
               "refs/heads/main",
               client_opts(stub)
             )
  end

  test "encodes branch components without allowing the ref to alter the endpoint" do
    stub = stub_name()
    full_ref = "refs/heads/feature%name"

    Req.Test.expect(stub, 3, fn conn ->
      case conn.request_path do
        "/repos/acme/base" ->
          Req.Test.json(conn, repository_json())

        "/repos/acme/base/git/ref/heads/feature%25name" ->
          Req.Test.json(conn, reference_json(full_ref))
      end
    end)

    assert {:ok, %{ref_name: ^full_ref}} =
             RefObservation.observe(
               "installation_token",
               "acme",
               "base",
               %{github_object_id: 1_001, github_node_id: "R_base"},
               full_ref,
               client_opts(stub)
             )
  end

  test "rejects a different ref, a non-commit target, and malformed object IDs" do
    responses = [
      reference_json("refs/heads/other"),
      reference_json("refs/heads/main", %{
        "object" => %{
          "type" => "tag",
          "sha" => "1111111111111111111111111111111111111111"
        }
      }),
      reference_json("refs/heads/main", %{
        "object" => %{"type" => "commit", "sha" => String.duplicate("A", 40)}
      })
    ]

    for response <- responses do
      stub = stub_name()

      Req.Test.expect(stub, 2, fn conn ->
        case conn.request_path do
          "/repos/acme/base" -> Req.Test.json(conn, repository_json())
          "/repos/acme/base/git/ref/heads/main" -> Req.Test.json(conn, response)
        end
      end)

      assert {:error, %Error{kind: :invalid_response}} =
               RefObservation.observe(
                 "installation_token",
                 "acme",
                 "base",
                 %{github_object_id: 1_001, github_node_id: "R_base"},
                 "refs/heads/main",
                 client_opts(stub)
               )
    end
  end

  test "invalid repository identities, refs, and gates fail before HTTP" do
    stub = stub_name()
    Req.Test.stub(stub, fn _conn -> flunk("invalid observation reached HTTP") end)
    expected = %{github_object_id: 1_001, github_node_id: "R_base"}

    cases = [
      {"", "base", expected, "refs/heads/main", client_opts(stub)},
      {"acme", "..", expected, "refs/heads/main", client_opts(stub)},
      {"acme", "base", %{expected | github_object_id: 0}, "refs/heads/main", client_opts(stub)},
      {"acme", "base", Map.put(expected, :extra, true), "refs/heads/main", client_opts(stub)},
      {"acme", "base", expected, "refs/tags/v1", client_opts(stub)},
      {"acme", "base", expected, "refs/heads/../main", client_opts(stub)},
      {"acme", "base", expected, "refs/heads/main", []}
    ]

    for {owner, repository, identity, ref_name, opts} <- cases do
      assert {:error, %Error{kind: :invalid_request}} =
               RefObservation.observe(
                 "installation_token",
                 owner,
                 repository,
                 identity,
                 ref_name,
                 opts
               )
    end
  end

  defp repository_json(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 1_001,
        "node_id" => "R_base",
        "owner" => %{"id" => 12, "login" => "acme"},
        "name" => "base",
        "full_name" => "acme/base",
        "description" => nil,
        "visibility" => "private",
        "default_branch" => "main",
        "has_issues" => true,
        "allow_merge_commit" => true,
        "fork" => false,
        "archived" => false,
        "html_url" => "https://github.com/acme/base",
        "updated_at" => "2026-09-08T00:00:00Z",
        "pushed_at" => "2026-09-08T00:00:00Z"
      },
      overrides
    )
  end

  defp reference_json(ref_name, overrides \\ %{}) do
    oid = "1111111111111111111111111111111111111111"

    Map.merge(
      %{
        "ref" => ref_name,
        "node_id" => "REF_feature",
        "url" => "https://api.github.com/repos/acme/base/git/refs/heads/feature/topic",
        "object" => %{
          "type" => "commit",
          "sha" => oid,
          "url" => "https://api.github.com/repos/acme/base/git/commits/#{oid}"
        }
      },
      overrides
    )
  end

  defp client_opts(stub),
    do: [
      plug: {Req.Test, stub},
      gate_key: {:github_installation, System.unique_integer([:positive])},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]

  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}
end
