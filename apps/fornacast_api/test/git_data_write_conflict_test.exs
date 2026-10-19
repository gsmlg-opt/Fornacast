defmodule FornacastAPI.GitDataWriteConflictTest do
  use FornacastAPI.ConnCase, async: false
  import Ecto.Query
  alias ForgeRepos.GitWriteOperation
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(dir, "repos"))
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous) end)
  end

  test "definitive CAS conflict terminally releases its operation and permits the next writer" do
    actor = user("cas-conflict-owner")
    {_key, secret} = pat(actor, ["repo"])

    {:ok, repository} =
      ForgeRepos.create_api_repository(actor, actor, %{"name" => "demo", "auto_init" => true}, %{
        request_id: "initialize"
      })

    path = ForgeRepos.absolute_storage_path(repository)
    {:ok, initial} = GitCore.exact_ref(path, "refs/heads/main")

    signature = %GitCore.Signature{
      name: actor.username,
      email: actor.email,
      seconds: 1_700_000_000,
      offset_minutes: 0
    }

    {:ok, external} =
      GitCore.plan_content_change(path, %{
        action: :create,
        ref: "refs/heads/main",
        path: "external.txt",
        expected_ref_oid: initial,
        expected_blob_oid: nil,
        content: "external\n",
        message: "External writer",
        author: signature,
        committer: signature
      })

    {:ok, external_oid} = GitCore.write_content_change(path, external)
    base = "/api/v3/repos/#{actor.username}/demo/contents/"

    response =
      ForgeRepos.GitWrites.with_test_before_publish_hook(
        fn ->
          assert {:ok, ^external_oid} =
                   GitCore.compare_and_swap_ref(
                     path,
                     "refs/heads/main",
                     initial,
                     external_oid,
                     :fast_forward,
                     []
                   )

          :ok
        end,
        fn -> put_content(base <> "ours.txt", secret) end
      )

    assert response.status == 409

    assert %GitWriteOperation{} =
             failed =
             Repo.one(
               from op in GitWriteOperation,
                 where: op.repository_id == ^repository.id and op.state == :failed
             )

    assert failed.failure_reason == "cas_conflict"
    assert failed.lease_owner == nil
    assert failed.lease_expires_at == nil
    assert {:ok, ^external_oid} = GitCore.exact_ref(path, "refs/heads/main")
    assert put_content(base <> "next.txt", secret).status == 201

    refute Repo.exists?(
             from op in GitWriteOperation,
               where:
                 op.repository_id == ^repository.id and
                   op.state not in [:bookkeeping_complete, :failed]
           )
  end

  test "expected-absent publication collisions fail definitively while retaining API422" do
    actor = user("cas-create-owner")
    {_key, secret} = pat(actor, ["repo"])

    {:ok, repository} =
      ForgeRepos.create_api_repository(actor, actor, %{"name" => "demo", "auto_init" => true}, %{
        request_id: "initialize"
      })

    path = ForgeRepos.absolute_storage_path(repository)
    {:ok, initial} = GitCore.exact_ref(path, "refs/heads/main")
    url = "/api/v3/repos/#{actor.username}/demo/git/refs"

    create = fn name ->
      build_conn()
      |> put_req_header("user-agent", "git-data-conflict/1.0")
      |> put_req_header("authorization", "Bearer " <> secret)
      |> put_req_header("content-type", "application/json")
      |> dispatch(@endpoint, :post, url, JSON.encode!(%{"ref" => name, "sha" => initial}))
    end

    response =
      ForgeRepos.GitWrites.with_test_before_publish_hook(
        fn ->
          assert {:ok, ^initial} =
                   GitCore.compare_and_swap_ref(
                     path,
                     "refs/heads/race",
                     nil,
                     initial,
                     :fast_forward,
                     []
                   )

          :ok
        end,
        fn -> create.("refs/heads/race") end
      )

    assert response.status == 422

    assert %GitWriteOperation{
             failure_reason: "cas_conflict",
             lease_owner: nil,
             lease_expires_at: nil
           } =
             Repo.one(
               from op in GitWriteOperation,
                 where: op.repository_id == ^repository.id and op.state == :failed
             )

    assert {:ok, ^initial} = GitCore.exact_ref(path, "refs/heads/race")
    assert create.("refs/heads/next").status == 201
  end

  test "definitive publication failure reasons are valid only from object-written state" do
    for reason <- ["cas_conflict", "non_fast_forward"] do
      written = %GitWriteOperation{
        state: :object_written,
        kind: :content_create,
        result_blob_oid: String.duplicate("a", 40)
      }

      assert GitWriteOperation.lease_update_changeset(written,
               state: :failed,
               failure_reason: reason
             ).valid?

      for state <- [:prepared, :ref_advanced, :bookkeeping_complete] do
        refute GitWriteOperation.lease_update_changeset(%{written | state: state},
                 state: :failed,
                 failure_reason: reason
               ).valid?
      end
    end
  end

  defp put_content(path, secret) do
    build_conn()
    |> put_req_header("user-agent", "git-data-conflict/1.0")
    |> put_req_header("authorization", "Bearer " <> secret)
    |> put_req_header("content-type", "application/json")
    |> dispatch(
      @endpoint,
      :put,
      path,
      JSON.encode!(%{"message" => "Create", "content" => "b3Vycwo="})
    )
  end
end
