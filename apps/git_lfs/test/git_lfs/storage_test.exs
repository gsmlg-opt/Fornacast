defmodule GitLFS.StorageTest do
  use ExUnit.Case, async: false

  alias GitLFS.{LFSObject, RepositoryObject, StagedUpload, UploadReservation}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    assert {:ok, owner} =
             ForgeAccounts.create_user(%{
               username: "lfs-#{System.unique_integer([:positive])}",
               email: "lfs-#{System.unique_integer([:positive])}@example.test",
               password: "correct horse battery staple"
             })

    assert {:ok, repository} =
             ForgeRepos.create_repository(owner, %{
               name: "LFS repository",
               slug: "lfs-repository"
             })

    %{owner: owner, repository: repository}
  end

  test "stages, commits, verifies, and range-reads a SHA-256 object", %{repository: repository} do
    payload = "large binary payload"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)

    assert {:ok, %UploadReservation{} = reservation} =
             GitLFS.reserve_upload(repository, oid, byte_size(payload))

    assert inspect(reservation) == "#GitLFS.UploadReservation<redacted>"

    assert {:ok, %StagedUpload{} = staged, %{chunks: []}} =
             GitLFS.stage_upload(
               reservation,
               &chunk_reader/2,
               %{chunks: ["large ", "binary ", "payload"]}
             )

    assert inspect(staged) == "#GitLFS.StagedUpload<redacted>"
    assert {:ok, %LFSObject{oid_sha256: ^oid, state: :ready}} = GitLFS.commit_upload(staged)
    assert :ok = GitLFS.verify_object(repository, oid, byte_size(payload))

    assert {:ok, source, %{size: 6, total_size: 20, offset: 6}} =
             GitLFS.open_object(repository, oid, byte_size(payload), {6, 6})

    assert {:ok, "binary", source} = GitLFS.read(source, 32)
    assert :eof = GitLFS.read(source, 1)
    assert :ok = GitLFS.close(source)
  end

  test "size and SHA-256 mismatches never publish an object and the reservation can retry", %{
    repository: repository
  } do
    payload = "expected"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)

    assert {:ok, reservation} = GitLFS.reserve_upload(repository, oid, byte_size(payload))

    assert {:error, :size_mismatch, %{chunks: []}} =
             GitLFS.stage_upload(reservation, &chunk_reader/2, %{chunks: ["short"]})

    assert {:error, :not_found} =
             GitLFS.open_object(repository, oid, byte_size(payload), :all)

    wrong = "xxxxxxxx"
    assert byte_size(wrong) == byte_size(payload)

    assert {:error, :sha256_mismatch, %{chunks: []}} =
             GitLFS.stage_upload(reservation, &chunk_reader/2, %{chunks: [wrong]})

    assert {:ok, staged, _state} =
             GitLFS.stage_upload(reservation, &chunk_reader/2, %{chunks: [payload]})

    assert {:ok, %LFSObject{state: :ready}} = GitLFS.commit_upload(staged)
  end

  test "a fully staged upload is recoverable after the coordinator is interrupted", %{
    repository: repository
  } do
    payload = "recoverable payload"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)

    assert {:ok, reservation} = GitLFS.reserve_upload(repository, oid, byte_size(payload))

    assert {:ok, _abandoned_staged, _state} =
             GitLFS.stage_upload(reservation, &chunk_reader/2, %{chunks: [payload]})

    assert {:ok, %StagedUpload{} = recovered} = GitLFS.recover_upload(reservation)
    assert {:ok, %LFSObject{state: :ready}} = GitLFS.commit_upload(recovered)
    assert :ok = GitLFS.verify_object(repository, oid, byte_size(payload))
  end

  test "a staged upload can be cleaned before retrying", %{repository: repository} do
    payload = "abandoned payload"
    oid = digest(payload)

    assert {:ok, reservation} = GitLFS.reserve_upload(repository, oid, byte_size(payload))

    assert {:ok, %StagedUpload{}, _state} =
             GitLFS.stage_upload(reservation, &chunk_reader/2, %{chunks: [payload]})

    assert :ok = GitLFS.cleanup_upload(reservation)
    assert {:error, :not_found} = GitLFS.recover_upload(reservation)
  end

  test "upload locks serialize one repository generation and OID", %{repository: repository} do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    oid = digest("serialized upload")
    parent = self()

    first =
      Task.async(fn ->
        GitLFS.with_upload_lock(repository, oid, fn ->
          send(parent, :first_entered)

          receive do
            :release -> :first_complete
          end
        end)
      end)

    assert_receive :first_entered

    second =
      Task.async(fn ->
        send(parent, :second_attempted)

        GitLFS.with_upload_lock(repository, oid, fn ->
          send(parent, :second_entered)
          :second_complete
        end)
      end)

    assert_receive :second_attempted
    refute_receive :second_entered, 50
    send(first.pid, :release)
    assert Task.await(first) == :first_complete
    assert_receive :second_entered, 1_000
    assert Task.await(second) == :second_complete
  end

  test "global bytes dedupe only after the second repository proves possession", %{
    owner: owner,
    repository: first_repository
  } do
    payload = "shared lfs object"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)

    assert {:ok, second_repository} =
             ForgeRepos.create_repository(owner, %{name: "Second", slug: "second"})

    assert {:ok, reservation} =
             GitLFS.reserve_upload(first_repository, oid, byte_size(payload))

    assert {:ok, staged, _state} =
             GitLFS.stage_upload(reservation, &chunk_reader/2, %{chunks: [payload]})

    assert {:ok, _object} = GitLFS.commit_upload(staged)

    assert {:error, :not_found} =
             GitLFS.open_object(second_repository, oid, byte_size(payload), :all)

    assert {:ok, second_reservation} =
             GitLFS.reserve_upload(second_repository, oid, byte_size(payload))

    assert {:error, :not_found} =
             GitLFS.open_object(second_repository, oid, byte_size(payload), :all)

    assert Repo.aggregate(RepositoryObject, :count) == 1

    assert {:ok, second_staged, _state} =
             GitLFS.stage_upload(second_reservation, &chunk_reader/2, %{chunks: [payload]})

    assert {:ok, _object} = GitLFS.commit_upload(second_staged)

    assert :ok = GitLFS.verify_object(second_repository, oid, byte_size(payload))
    assert Repo.aggregate(LFSObject, :count) == 1
    assert Repo.aggregate(RepositoryObject, :count) == 2
  end

  test "neutral CAS bytes are not adopted without an LFS upload", %{repository: repository} do
    payload = "neutral CAS payload"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)
    staging_key = "neutral-#{System.unique_integer([:positive])}"

    assert {:ok, staged_ref, %{sha256_digest: ^oid}, []} =
             ForgeBlobs.stage_from_reader(staging_key, &list_reader/2, [payload],
               max_size: byte_size(payload),
               read_options: [length: 1_024, read_length: 1_024, read_timeout: 1_000]
             )

    assert {:ok, %{storage_key: ^oid}} = ForgeBlobs.commit(staged_ref)
    assert is_nil(Repo.get(LFSObject, oid))

    assert {:ok, %UploadReservation{}} =
             GitLFS.reserve_upload(repository, oid, byte_size(payload))

    assert {:error, :not_found} = GitLFS.object_metadata(repository, oid)
  end

  test "deleting one repository never removes bytes shared by another repository", %{
    owner: owner,
    repository: first_repository
  } do
    payload = "retained shared object"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)

    assert {:ok, second_repository} =
             ForgeRepos.create_repository(owner, %{name: "Retained", slug: "retained"})

    assert {:ok, reservation} =
             GitLFS.reserve_upload(first_repository, oid, byte_size(payload))

    assert {:ok, staged, _state} =
             GitLFS.stage_upload(reservation, &chunk_reader/2, %{chunks: [payload]})

    assert {:ok, _object} = GitLFS.commit_upload(staged)

    assert {:ok, second_reservation} =
             GitLFS.reserve_upload(second_repository, oid, byte_size(payload))

    assert {:ok, second_staged, _state} =
             GitLFS.stage_upload(second_reservation, &chunk_reader/2, %{chunks: [payload]})

    assert {:ok, _object} = GitLFS.commit_upload(second_staged)

    assert %ForgeRepos.Repository{} = Repo.delete!(first_repository)
    assert Repo.aggregate(LFSObject, :count) == 1
    assert Repo.aggregate(RepositoryObject, :count) == 1
    assert :ok = ForgeBlobs.verify(oid)
    assert :ok = GitLFS.verify_object(second_repository, oid, byte_size(payload))
  end

  defp chunk_reader(%{chunks: [chunk | rest]} = state, _options),
    do: {:more, chunk, %{state | chunks: rest}}

  defp chunk_reader(%{chunks: []} = state, _options), do: {:done, state}

  defp list_reader([chunk | rest], _options), do: {:more, chunk, rest}
  defp list_reader([], _options), do: {:done, []}

  defp digest(payload), do: :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
end
