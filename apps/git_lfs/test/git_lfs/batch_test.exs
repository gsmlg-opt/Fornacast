defmodule GitLFS.BatchTest do
  use ExUnit.Case, async: false

  alias GitLFS.{Principal, TransferToken}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    username = "lfs-batch-#{System.unique_integer([:positive])}"

    assert {:ok, actor} =
             ForgeAccounts.create_user(%{
               username: username,
               email: "#{username}@example.test",
               password: "correct horse battery staple"
             })

    assert {:ok, repository} =
             ForgeRepos.create_repository(actor, %{name: "Batch", slug: "batch"})

    %{actor: actor, repository: repository, principal: Principal.ssh(actor)}
  end

  test "upload batch returns scoped Basic upload and verify actions", context do
    oid = String.duplicate("a", 64)
    now = ~U[2026-09-05 00:00:00Z]

    request = %{
      "operation" => "upload",
      "transfers" => ["basic"],
      "hash_algo" => "sha256",
      "objects" => [%{"oid" => oid, "size" => 42}]
    }

    assert {:ok, response} =
             GitLFS.batch(
               context.repository,
               context.principal,
               request,
               "https://forge.example.test",
               now: now
             )

    assert response["transfer"] == "basic"
    assert response["hash_algo"] == "sha256"
    assert [%{"oid" => ^oid, "size" => 42, "actions" => actions}] = response["objects"]

    assert %{"href" => upload_href, "header" => %{"Authorization" => "Bearer " <> upload}} =
             actions["upload"]

    assert upload_href ==
             "https://forge.example.test/#{context.actor.username}/batch.git/info/lfs/objects/#{oid}"

    assert %{"href" => verify_href, "header" => %{"Authorization" => "Bearer " <> verify}} =
             actions["verify"]

    assert verify_href == upload_href <> "/verify"

    assert {:ok, _principal, _repository} =
             TransferToken.verify(upload, :object, :upload, oid, now: now, object_size: 42)

    assert {:ok, _principal, _repository} =
             TransferToken.verify(verify, :object, :verify, oid, now: now, object_size: 42)

    assert {:error, :invalid_credentials} =
             TransferToken.verify(upload, :object, :verify, oid, now: now, object_size: 42)
  end

  test "download exposes only objects mapped to this repository", context do
    payload = "downloadable"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)
    publish!(context.repository, oid, payload)

    missing_oid = String.duplicate("b", 64)

    request = %{
      "operation" => "download",
      "objects" => [
        %{"oid" => oid, "size" => byte_size(payload)},
        %{"oid" => missing_oid, "size" => 7}
      ]
    }

    assert {:ok, %{"transfer" => "basic", "objects" => [available, missing]}} =
             GitLFS.batch(
               context.repository,
               context.principal,
               request,
               "https://forge.example.test"
             )

    assert available["oid"] == oid
    assert available["authenticated"]
    assert %{"download" => %{"href" => href, "header" => header}} = available["actions"]
    assert href =~ "/#{context.actor.username}/batch.git/info/lfs/objects/#{oid}"
    assert %{"Authorization" => "Bearer " <> _token} = header

    assert missing == %{
             "oid" => missing_oid,
             "size" => 7,
             "error" => %{"code" => 404, "message" => "Object does not exist"}
           }
  end

  test "download batch checks storage availability without rehashing ready bytes", context do
    payload = "downloadable"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)
    publish!(context.repository, oid, payload)

    File.write!(blob_path(oid), String.duplicate("x", byte_size(payload)))
    assert {:error, :integrity_mismatch} = ForgeBlobs.verify(oid)

    request = %{
      "operation" => "download",
      "objects" => [%{"oid" => oid, "size" => byte_size(payload)}]
    }

    assert {:ok, %{"objects" => [%{"actions" => %{"download" => _action}}]}} =
             GitLFS.batch(
               context.repository,
               context.principal,
               request,
               "https://forge.example.test"
             )
  end

  test "download batch reports mapped bytes missing from storage", context do
    payload = "missing bytes"
    oid = digest(payload)
    publish!(context.repository, oid, payload)
    assert :ok = ForgeBlobs.delete(oid)

    request = %{
      "operation" => "download",
      "objects" => [%{"oid" => oid, "size" => byte_size(payload)}]
    }

    assert {:ok, %{"objects" => [%{"error" => %{"code" => 404}}]}} =
             GitLFS.batch(
               context.repository,
               context.principal,
               request,
               "https://forge.example.test"
             )
  end

  test "globally present bytes still require repository proof before attachment", context do
    payload = "globally shared"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)
    publish!(context.repository, oid, payload)

    assert {:ok, second} =
             ForgeRepos.create_repository(context.actor, %{name: "Second", slug: "second"})

    request = %{
      "operation" => "upload",
      "objects" => [%{"oid" => oid, "size" => byte_size(payload)}]
    }

    assert {:ok, %{"objects" => [%{"actions" => actions}]}} =
             GitLFS.batch(second, context.principal, request, "https://forge.example.test")

    assert %{"upload" => %{}, "verify" => %{}} = actions
    assert {:error, :not_found} = GitLFS.verify_object(second, oid, byte_size(payload))
  end

  test "rejects unsupported transfers, algorithms, operations, malformed objects, and oversized batches",
       context do
    valid = %{
      "operation" => "download",
      "objects" => [%{"oid" => String.duplicate("a", 64), "size" => 1}]
    }

    invalid = [
      {Map.put(valid, "operation", "delete"), :invalid_request},
      {Map.put(valid, "hash_algo", "sha512"), :unsupported_hash_algorithm},
      {Map.put(valid, "transfers", ["tus"]), :unsupported_transfer},
      {Map.put(valid, "objects", []), :invalid_request},
      {Map.put(valid, "objects", [hd(valid["objects"]), hd(valid["objects"])]), :invalid_request},
      {Map.put(valid, "objects", List.duplicate(hd(valid["objects"]), 101)), :too_many_objects},
      {Map.put(valid, "objects", [%{"oid" => "bad", "size" => 1}]), :invalid_request},
      {Map.put(valid, "objects", [%{"oid" => String.duplicate("a", 64), "size" => -1}]),
       :invalid_request}
    ]

    for {request, reason} <- invalid do
      assert {:error, ^reason} =
               GitLFS.batch(
                 context.repository,
                 context.principal,
                 request,
                 "https://forge.example.test"
               )
    end
  end

  defp publish!(repository, oid, payload) do
    assert {:ok, reservation} = GitLFS.reserve_upload(repository, oid, byte_size(payload))

    reader = fn
      [chunk | rest], _options -> {:more, chunk, rest}
      [], _options -> {:done, []}
    end

    assert {:ok, staged, []} = GitLFS.stage_upload(reservation, reader, [payload])
    assert {:ok, _object} = GitLFS.commit_upload(staged)
  end

  defp digest(payload), do: :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

  defp blob_path(oid) do
    <<prefix::binary-size(2), rest::binary>> = oid
    Path.join([ForgeBlobs.Config.load!().blob_root, "objects", "sha256", prefix, rest])
  end
end
