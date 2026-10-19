defmodule FornacastAPI.GitDataContractTest do
  use ExUnit.Case, async: false
  alias FornacastAPI.{RequestValidator, Serializer}
  @versions ["2022-11-28", "2026-03-10"]
  @oid "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    previous = Application.fetch_env!(:fornacast, :base_url)
    previous_api = Application.fetch_env(:fornacast_api, :base_url)
    Application.put_env(:fornacast, :base_url, "https://forge.test")
    Application.put_env(:fornacast_api, :base_url, "https://forge.test")

    on_exit(fn ->
      Application.put_env(:fornacast, :base_url, previous)

      case previous_api do
        {:ok, value} -> Application.put_env(:fornacast_api, :base_url, value)
        :error -> Application.delete_env(:fornacast_api, :base_url)
      end
    end)
  end

  test "all ten ordered routes recognize slash-bearing resources" do
    for {method, path, action} <- [
          {"GET", "/branches", :branches},
          {"GET", "/branches/feature/api", :branch},
          {"GET", "/git/ref/heads/feature/api", :ref},
          {"POST", "/git/refs", :create_ref},
          {"PATCH", "/git/refs/heads/feature/api", :update_ref},
          {"GET", "/commits", :commits},
          {"GET", "/commits/feature/api", :commit},
          {"GET", "/contents/docs/guide.txt", :content},
          {"PUT", "/contents/docs/guide.txt", :put_content},
          {"DELETE", "/contents/docs/guide.txt", :delete_content}
        ] do
      assert %{plug: FornacastAPI.GitDataController, plug_opts: ^action} =
               Phoenix.Router.route_info(
                 FornacastAPI.Router,
                 method,
                 "/api/v3/repos/acme/widget" <> path,
                 "forge.test"
               )
    end
  end

  test "both contracts accept the approved fields and reject force or malformed signatures" do
    for version <- @versions do
      assert {:ok, _} =
               RequestValidator.validate(version, :git_create_ref, %{
                 "ref" => "refs/heads/topic",
                 "sha" => @oid
               })

      assert {:ok, _} =
               RequestValidator.validate(version, :git_update_ref, %{
                 "sha" => @oid,
                 "force" => false
               })

      assert {:error, {:validation, _}} =
               RequestValidator.validate(version, :git_update_ref, %{
                 "sha" => @oid,
                 "force" => true
               })

      valid = %{
        "message" => "Create guide",
        "content" => "aGkK",
        "author" => %{
          "name" => "A",
          "email" => "a@example.test",
          "date" => "2026-07-21T00:00:00Z"
        }
      }

      assert {:ok, _} = RequestValidator.validate(version, :content_put, valid)

      for author <- [
            %{"name" => "A"},
            %{"name" => "A\n", "email" => "a@example.test"},
            %{"name" => "A", "email" => "a@example.test", "extra" => true},
            %{"name" => "A", "email" => "a@example.test", "date" => "tomorrow"}
          ] do
        assert {:error, {:validation, _}} =
                 RequestValidator.validate(version, :content_put, %{valid | "author" => author})
      end

      assert {:error, {:validation, _}} =
               RequestValidator.validate(version, :content_delete, %{"message" => "Delete"})
    end
  end

  test "literal branch, ref and file fixtures match serializers and pinned response schemas" do
    entry = %GitCore.ContentEntry{
      type: "file",
      name: "guide.txt",
      path: "docs/guide.txt",
      oid: @oid,
      size: 3,
      mode: "100644",
      content: "hi\n"
    }

    for version <- @versions do
      document =
        Path.expand("../priv/openapi/ghes-3.21-#{version}.json", __DIR__)
        |> File.read!()
        |> JSON.decode!()
        |> OpenApiSpex.OpenApi.Decode.decode()

      for {name, resource, value, path} <- [
            {"branch-list", :branch_short, %{name: "feature/api", oid: @oid},
             "/repos/{owner}/{repo}/branches"},
            {"ref", :git_ref, %{ref: "refs/heads/feature/api", oid: @oid, kind: "commit"},
             "/repos/{owner}/{repo}/git/ref/{ref}"},
            {"file", :content_file, entry, "/repos/{owner}/{repo}/contents/{path}"}
          ] do
        literal =
          Path.join([__DIR__, "fixtures", version, "git-data", name <> ".json"])
          |> File.read!()
          |> JSON.decode!()

        rendered =
          Serializer.render(version, resource, value,
            owner: "acme",
            repo: "widget",
            ref: "feature/api"
          )

        actual = if name == "branch-list", do: [rendered], else: rendered
        assert JSON.decode!(JSON.encode!(actual)) == literal

        schema =
          document.paths
          |> Map.fetch!(path)
          |> Map.fetch!(:get)
          |> Map.fetch!(:responses)
          |> Map.fetch!("200")
          |> Map.fetch!(:content)
          |> Map.fetch!("application/json")
          |> Map.fetch!(:schema)

        assert {:ok, _} = OpenApiSpex.cast_value(literal, schema, document)
      end
    end
  end
end
