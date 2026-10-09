defmodule ForgeImports.PatRepositorySyncTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeImports.PatRepositorySync
  alias ForgeMirrors.PatSettings
  alias ForgeRepos.Repository
  alias Fornacast.Repo
  alias GitCore.Remote.{ObservedRef, SyncRequest}

  @moduletag :tmp_dir
  @pat "github_pat_repository_sync_test"

  setup %{tmp_dir: tmp_dir} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    n = System.unique_integer([:positive, :monotonic])

    owner =
      Repo.insert!(%User{
        username: "patrepo#{n}",
        email: "patrepo#{n}@test.local",
        password_hash: "unused",
        kind: :user,
        role: :user,
        state: :active
      })

    {:ok, organization} =
      ForgeAccounts.create_organization(owner, %{username: "patrepo-org#{n}"})

    {:ok, account} =
      ForgeAccounts.save_github_account(
        owner,
        %{github_user_id: n, login: "owner#{n}", avatar_url: nil, profile_url: nil},
        @pat,
        %{}
      )

    {:ok, config} =
      PatSettings.save(
        owner,
        organization.id,
        %{
          "owner_user_id" => to_string(owner.id),
          "github_identity_id" => to_string(account.identity_id),
          "github_organization" => "source-org",
          "enabled" => "true",
          "lock_version" => "1"
        },
        %{}
      )

    {:ok, repository} =
      ForgeRepos.create_repository(organization, %{name: "demo", slug: "demo"})

    path = ForgeRepos.absolute_storage_path(repository)
    on_exit(fn -> File.rm_rf!(path) end)
    source = Path.join(tmp_dir, "source")
    File.mkdir_p!(source)
    git!(source, ["init", "--initial-branch=main"])
    initial = commit!(source, "initial", "README.md", "initial\n")
    copy_objects!(source, path)
    git!(path, ["update-ref", "refs/heads/main", initial])

    %{
      owner: owner,
      organization: organization,
      config: config,
      repository: repository,
      path: path,
      source: source,
      initial: initial,
      credential_id:
        Repo.get_by!(ForgeAccounts.GitHubCredential,
          github_identity_id: account.identity_id,
          local_user_id: owner.id
        ).id
    }
  end

  test "updates branches and tags using PAT without a GitHub App installation", c do
    installation_count = Repo.aggregate(ForgeMirrors.GitHubAppInstallation, :count)
    target = commit!(c.source, "upstream update", "README.md", "updated\n")
    git!(c.source, ["branch", "feature"])
    git!(c.source, ["tag", "v1"])

    assert :ok = sync(c)
    assert {:ok, ^target} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert {:ok, ^target} = GitCore.exact_ref(c.path, "refs/heads/feature")
    assert {:ok, ^target} = GitCore.exact_ref(c.path, "refs/tags/v1")

    assert {:ok, %GitCore.Blob{data: "updated\n"} = blob} =
             GitCore.read_blob(c.path, target, "README.md")

    GitCore.release_blob(blob)

    assert %Repository{write_version: 3, last_pushed_at: %DateTime{}} =
             Repo.get!(Repository, c.repository.id)

    assert Repo.aggregate(ForgeMirrors.GitHubAppInstallation, :count) == installation_count

    assert :ok = sync(c)
    assert %Repository{write_version: 3} = Repo.get!(Repository, c.repository.id)
  end

  test "synchronizes lightweight and annotated tags with tree and blob targets", c do
    tree = git!(c.source, ["rev-parse", "HEAD^{tree}"])
    blob = git!(c.source, ["rev-parse", "HEAD:README.md"])
    git!(c.source, ["tag", "tree", tree])
    git!(c.source, ["tag", "blob", blob])
    git!(c.source, ["tag", "-a", "annotated-tree", tree, "-m", "tree tag"])
    git!(c.source, ["tag", "-a", "annotated-blob", blob, "-m", "blob tag"])
    assert :ok = sync(c)

    for tag <- ["tree", "blob", "annotated-tree", "annotated-blob"] do
      expected = git!(c.source, ["rev-parse", "refs/tags/" <> tag])
      assert {:ok, ^expected} = GitCore.exact_ref(c.path, "refs/tags/" <> tag)
    end
  end

  test "preserves local commits on diverging branch histories", c do
    local = commit!(c.source, "local work", "local.txt", "keep local\n")
    copy_objects!(c.source, c.path)
    git!(c.path, ["update-ref", "refs/heads/main", local])
    git!(c.source, ["reset", "--hard", c.initial])
    _remote = commit!(c.source, "different remote work", "remote.txt", "remote\n")

    assert {:error, :git_divergence} = sync(c)
    assert {:ok, ^local} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert %Repository{write_version: 0} = Repo.get!(Repository, c.repository.id)
  end

  test "recovers bookkeeping after Git refs advance and the SQL completion fails", c do
    target = commit!(c.source, "upstream update", "README.md", "updated\n")

    result =
      ForgeRepos.GitWriteRecovery.with_test_complete_multi_hook(
        fn multi, _operation ->
          Ecto.Multi.run(multi, :injected_bookkeeping_failure, fn _, _ ->
            {:error, :unavailable}
          end)
        end,
        fn ->
          ForgeRepos.with_test_mark_pushed_after_update_hook(
            fn -> raise "injected SQL bookkeeping failure" end,
            fn -> sync(c) end
          )
        end
      )

    assert {:error, :unavailable} = result
    assert {:ok, ^target} = GitCore.exact_ref(c.path, "refs/heads/main")

    assert %Repository{write_version: 0, last_pushed_at: nil} =
             Repo.get!(Repository, c.repository.id)

    assert :ok = sync(c)

    assert %Repository{write_version: 1, last_pushed_at: %DateTime{}} =
             Repo.get!(Repository, c.repository.id)

    assert :ok = sync(c)
    assert %Repository{write_version: 1} = Repo.get!(Repository, c.repository.id)
  end

  test "retains local branches when they are ahead of GitHub", c do
    local = commit!(c.source, "local work", "local.txt", "keep local\n")
    copy_objects!(c.source, c.path)
    git!(c.path, ["update-ref", "refs/heads/main", local])
    git!(c.source, ["reset", "--hard", c.initial])

    assert {:error, :git_divergence} = sync(c)
    assert {:ok, ^local} = GitCore.exact_ref(c.path, "refs/heads/main")
  end

  test "does not retarget tags or delete refs absent from GitHub", c do
    initial = c.initial
    git!(c.path, ["update-ref", "refs/tags/v1", initial])
    git!(c.path, ["update-ref", "refs/heads/local-only", initial])
    _target = commit!(c.source, "upstream update", "README.md", "updated\n")
    git!(c.source, ["tag", "v1"])

    assert {:error, :tag_retarget} = sync(c)
    assert {:ok, ^initial} = GitCore.exact_ref(c.path, "refs/tags/v1")
    assert {:ok, ^initial} = GitCore.exact_ref(c.path, "refs/heads/local-only")
  end

  test "checks owner authorization and repository generation again after fetching", c do
    _target = commit!(c.source, "upstream update", "README.md", "updated\n")
    fetch = fetch(c)

    altered_fetch = fn request, token, namespace ->
      result = fetch.(request, token, namespace)

      Repo.update_all(from(r in Repository, where: r.id == ^c.repository.id),
        inc: [generation: 1]
      )

      result
    end

    assert {:error, :stale_repository} = sync(c, fetch_refs: altered_fetch)
    initial = c.initial
    assert {:ok, ^initial} = GitCore.exact_ref(c.path, "refs/heads/main")
  end

  test "blocks Git ref publication when an LFS object exists only in history and is missing", c do
    oid = :crypto.hash(:sha256, "historical object") |> Base.encode16(case: :lower)
    pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:#{oid}\nsize 17\n"
    commit!(c.source, "historical LFS pointer", "old.bin", pointer)
    git!(c.source, ["rm", "old.bin"])
    git!(c.source, ["commit", "-m", "remove pointer from tip"])
    initial = c.initial
    parent = self()

    options = [
      callbacks: %{
        batch: fn token, "source-org", "demo", :download, objects, opts ->
          assert token == @pat
          assert opts[:gate_key] == {:saved_credential, c.credential_id}
          assert [%{oid: ^oid, size: 17}] = Enum.map(objects, &Map.take(&1, [:oid, :size]))
          assert {:ok, ^initial} = GitCore.exact_ref(c.path, "refs/heads/main")
          send(parent, :historical_lfs_requested)
          {:error, ForgeGitHub.Error.new(:object_missing)}
        end
      }
    ]

    assert {:error, :object_missing} = sync(c, lfs_transfer_options: options)
    assert_received :historical_lfs_requested
    assert {:ok, ^initial} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert %Repository{write_version: 0} = Repo.get!(Repository, c.repository.id)
  end

  test "checks cancellation before publishing fetched Git refs", c do
    _target = commit!(c.source, "upstream update", "README.md", "updated\n")
    fetch = fetch(c)

    options = [
      fetch_refs: fn request, token, namespace ->
        result = fetch.(request, token, namespace)
        Process.put(:cancel_pat_repository_sync, true)
        result
      end,
      authorize: fn ->
        if Process.get(:cancel_pat_repository_sync), do: {:error, :cancelled}, else: :ok
      end
    ]

    assert {:error, :cancelled} = sync(c, options)
    initial = c.initial
    assert {:ok, ^initial} = GitCore.exact_ref(c.path, "refs/heads/main")
  end

  @tag :immutable_repository_identity
  test "rejects a different GitHub repository that occupies the discovered full name", c do
    initial = c.initial

    assert {:error, :source_changed} =
             PatRepositorySync.sync(c.owner, c.config, c.repository, "source-org/demo",
               github_repository_id: 42,
               lookup_repository: fn _token, "source-org", "demo", _opts ->
                 {:ok, %{id: 43, owner_login: "source-org"}}
               end,
               fetch_refs: fn _, _, _ -> flunk("replacement repository must not be fetched") end
             )

    assert {:ok, ^initial} = GitCore.exact_ref(c.path, "refs/heads/main")
  end

  test "checks immutable GitHub identity again after the Git transfer", c do
    _target = commit!(c.source, "upstream update", "README.md", "updated\n")
    initial = c.initial
    fetch = fetch(c)

    assert {:error, :source_changed} =
             sync(c,
               lookup_repository: fn _token, "source-org", "demo", _opts ->
                 id = if Process.get(:pat_sync_fetched), do: 43, else: 42
                 {:ok, %{id: id, owner_login: "source-org"}}
               end,
               fetch_refs: fn request, token, namespace ->
                 result = fetch.(request, token, namespace)
                 Process.put(:pat_sync_fetched, true)
                 result
               end
             )

    assert {:ok, ^initial} = GitCore.exact_ref(c.path, "refs/heads/main")
  end

  test "downloads historical LFS bytes before fast-forwarding the public ref", c do
    payload = "historical PAT LFS object #{c.config.id}"
    oid = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

    pointer =
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{oid}\nsize #{byte_size(payload)}\n"

    commit!(c.source, "historical LFS pointer", "old.bin", pointer)
    git!(c.source, ["rm", "old.bin"])
    git!(c.source, ["commit", "-m", "remove pointer from tip"])
    target = git!(c.source, ["rev-parse", "HEAD"])
    initial = c.initial
    parent = self()
    on_exit(fn -> ForgeBlobs.delete(oid) end)

    options = [
      callbacks: %{
        batch: fn token, "source-org", "demo", :download, objects, opts ->
          assert token == @pat
          assert opts[:gate_key] == {:saved_credential, c.credential_id}
          assert [%{oid: ^oid}] = Enum.map(objects, &Map.take(&1, [:oid]))

          {:ok,
           Enum.map(objects, fn object ->
             %ForgeGitHub.LFS.Object{
               oid: object.oid,
               size: object.size,
               authenticated: false,
               actions: %{
                 download: %ForgeGitHub.LFS.Action{
                   operation: :download,
                   url: "https://github.com/source-org/demo/info/lfs/objects/#{oid}",
                   headers: []
                 }
               }
             }
           end)}
        end,
        consume_download: fn _action, _object, consumer, _opts ->
          assert {:ok, ^initial} = GitCore.exact_ref(c.path, "refs/heads/main")

          reader = fn
            [data], _ -> {:ok, data, []}
            [], _ -> {:eof, []}
          end

          {:ok, staged, []} = consumer.(reader, [payload])
          send(parent, :historical_lfs_downloaded)
          {:ok, staged}
        end
      }
    ]

    assert :ok = sync(c, lfs_transfer_options: options)
    assert_received :historical_lfs_downloaded
    assert {:ok, ^target} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert :ok = GitLFS.verify_object(c.repository, oid, byte_size(payload))

    assert {:ok, source, _metadata} =
             GitLFS.open_object(c.repository, oid, byte_size(payload), :all)

    assert {:ok, ^payload, source} = GitLFS.read(source, byte_size(payload))
    GitLFS.close(source)
  end

  defp sync(c, options \\ []) do
    PatRepositorySync.sync(
      c.owner,
      c.config,
      c.repository,
      "source-org/demo",
      Keyword.merge(
        [
          github_repository_id: 42,
          lookup_repository: fn _token, "source-org", "demo", _opts ->
            {:ok, %{id: 42, owner_login: "source-org"}}
          end,
          fetch_refs: fetch(c)
        ],
        options
      )
    )
  end

  defp fetch(c) do
    fn %SyncRequest{} = request, token, namespace ->
      assert token == @pat
      assert request.owner == "source-org"
      assert request.repository == "demo"
      assert request.repository_path == c.path
      assert request.credential_login =~ "owner"
      assert namespace == "pat-sync-#{c.config.id}"
      copy_objects!(c.source, c.path)
      git!(c.path, ["fetch", "--no-tags", c.source, "+refs/tags/*:refs/pat-test-tags/*"])

      refs =
        git!(c.source, [
          "for-each-ref",
          "--format=%(refname) %(objectname)",
          "refs/heads",
          "refs/tags"
        ])

      {:ok,
       for line <- String.split(refs, "\n", trim: true) do
         [ref, oid] = String.split(line, " ")
         {:ok, tracking} = GitCore.tracking_ref_name(namespace, ref)
         git!(c.path, ["update-ref", tracking, oid])
         %ObservedRef{ref: ref, oid: oid}
       end}
    end
  end

  defp copy_objects!(source, destination) do
    git!(destination, ["fetch", "--no-tags", source, "HEAD"])
  end

  defp commit!(source, message, filename, contents) do
    File.write!(Path.join(source, filename), contents)
    git!(source, ["add", "."])
    git!(source, ["commit", "-m", message])
    git!(source, ["rev-parse", "HEAD"])
  end

  defp git!(directory, args) do
    {output, status} =
      System.cmd("git", args,
        cd: directory,
        stderr_to_stdout: true,
        env: [
          {"GIT_AUTHOR_NAME", "PAT sync test"},
          {"GIT_AUTHOR_EMAIL", "pat-sync@example.test"},
          {"GIT_COMMITTER_NAME", "PAT sync test"},
          {"GIT_COMMITTER_EMAIL", "pat-sync@example.test"}
        ]
      )

    assert status == 0, output
    String.trim(output)
  end
end
