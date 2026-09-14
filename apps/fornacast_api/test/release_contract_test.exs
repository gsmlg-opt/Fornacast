defmodule FornacastAPI.ReleaseContractTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.User
  alias ForgeReleases.Release
  alias FornacastAPI.{RequestValidator, Serializer, URL}

  @versions ["2022-11-28", "2026-03-10"]

  setup do
    previous_base_url = Application.fetch_env!(:fornacast, :base_url)
    Application.put_env(:fornacast, :base_url, "https://forge.test")
    on_exit(fn -> Application.put_env(:fornacast, :base_url, previous_base_url) end)
  end

  test "both API versions validate the supported release mutation fields" do
    create = %{
      "tag_name" => "v1.0.0",
      "target_commitish" => "main",
      "name" => "Version 1",
      "body" => "Notes",
      "draft" => false,
      "prerelease" => true
    }

    update = Map.delete(create, "tag_name")

    for version <- @versions do
      assert {:ok, ^create} = RequestValidator.validate(version, :release_create, create)
      assert {:ok, ^update} = RequestValidator.validate(version, :release_update, update)
    end
  end

  test "release validation rejects malformed and unsupported asset behavior" do
    invalid = [
      {:release_create, %{}, "tag_name", :missing_field},
      {:release_create, %{"tag_name" => ""}, "tag_name", :invalid},
      {:release_create, %{"tag_name" => 1}, "tag_name", :invalid},
      {:release_create, %{"tag_name" => "v1", "draft" => "false"}, "draft", :invalid},
      {:release_update, %{"name" => 1}, "name", :invalid},
      {:release_update, %{"body" => 1}, "body", :invalid},
      {:release_update, %{"asset" => %{}}, "asset", :unprocessable},
      {:release_create, %{"tag_name" => "v1", "generate_release_notes" => true},
       "generate_release_notes", :unprocessable},
      {:release_create, %{"tag_name" => "v1", "make_latest" => true}, "make_latest",
       :unprocessable}
    ]

    for version <- @versions, {operation, body, field, code} <- invalid do
      assert {:error, {:validation, [%{resource: "Release", field: ^field, code: ^code}]}} =
               RequestValidator.validate(version, operation, body)
    end
  end

  test "both serializers expose GitHub release metadata while assets stay empty" do
    author = %User{
      id: 7,
      username: "alice",
      kind: :user,
      role: :user,
      state: :active
    }

    release = %Release{
      id: 11,
      repository_id: 3,
      tag_name: "v1.0.0",
      target_commitish: "main",
      name: "Version 1",
      body: "Notes",
      draft: false,
      prerelease: false,
      published_at: ~U[2026-09-05 08:00:00Z],
      inserted_at: ~U[2026-09-05 07:00:00Z],
      updated_at: ~U[2026-09-05 08:00:00Z],
      author: author
    }

    for version <- @versions do
      rendered = Serializer.render(version, :release, release, owner: "alice", repo: "demo")

      assert rendered.tag_name == "v1.0.0"
      assert rendered.target_commitish == "main"
      assert rendered.name == "Version 1"
      assert rendered.body == "Notes"
      assert rendered.draft == false
      assert rendered.prerelease == false
      assert rendered.published_at == "2026-09-05T08:00:00Z"
      assert rendered.author.login == "alice"
      assert rendered.assets == []
      assert rendered.immutable == false
      assert rendered.tarball_url == nil
      assert rendered.zipball_url == nil
      assert rendered.url == "https://forge.test/api/v3/repos/alice/demo/releases/11"
      assert rendered.html_url == "https://forge.test/alice/demo/releases/tag/v1.0.0"
    end
  end

  test "release URL helpers encode tag names and keep asset endpoints unimplemented" do
    assert URL.releases("alice", "demo") ==
             "https://forge.test/api/v3/repos/alice/demo/releases"

    assert URL.release("alice", "demo", 11) ==
             "https://forge.test/api/v3/repos/alice/demo/releases/11"

    assert URL.release_by_tag("alice", "demo", "release/v1") ==
             "https://forge.test/api/v3/repos/alice/demo/releases/tags/release%2Fv1"

    assert URL.release_web("alice", "demo", "release/v1") ==
             "https://forge.test/alice/demo/releases/tag/release%2Fv1"
  end
end
