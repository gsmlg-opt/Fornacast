defmodule ForgeGitHub.LFSSyncPersistenceTest do
  use ExUnit.Case, async: false

  alias Fornacast.Repo
  alias ForgeGitHub.{Error, LFSSync}
  alias ForgeMirrors.MirrorOperation
  alias GitLFS.{LFSObject, PointerScanner}

  @moduletag :tmp_dir

  test "101-object scan replay checks page one again after publication", %{tmp_dir: path} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    assert {:ok, owner} =
             ForgeAccounts.create_user(%{
               username: "lfs-replay-#{suffix}",
               email: "lfs-replay-#{suffix}@example.test",
               password: "correct horse battery staple"
             })

    assert {:ok, repository} =
             ForgeRepos.create_repository(owner, %{
               name: "Replay",
               slug: "replay"
             })

    git!(path, ["init"])

    oids =
      for number <- 1..101 do
        oid = :crypto.hash(:sha256, "object-#{number}") |> Base.encode16(case: :lower)

        File.write!(
          Path.join(path, "#{number}.lfs"),
          "version https://git-lfs.github.com/spec/v1\noid sha256:#{oid}\nsize 1\n"
        )

        %LFSObject{}
        |> LFSObject.ready_changeset(%{
          oid_sha256: oid,
          size: 1,
          storage_key: oid,
          verified_at: DateTime.utc_now(:second)
        })
        |> Repo.insert!()

        oid
      end

    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "101 pointers"])
    git!(path, ["branch", "-M", "main"])
    target = git!(path, ["rev-parse", "HEAD"])
    bare_path = Path.join(path, "mirror.git")
    git!(path, ["clone", "--bare", path, bare_path])

    sync = %{
      github_installation_id: 44,
      ref_kind: :branch,
      ref_name: "refs/heads/main",
      remote_owner: "acme",
      remote_repository: "project",
      repository_generation: repository.generation,
      repository_id: repository.id,
      repository_path: bare_path
    }

    operation = %MirrorOperation{id: 700, attempt_count: 1, state: :processing, checkpoint: %{}}
    parent = self()

    options = [
      transfer_page: fn _repository, scan, _direction, _token, _owner, _remote, cursor, _opts ->
        assert {:ok, page} = PointerScanner.list_requirements(scan, after_oid: cursor, limit: 100)
        send(parent, {:page, cursor, length(page.objects)})

        if Enum.any?(page.objects, &(&1.oid == Process.get(:corrupt_oid))) do
          {:error, Error.new(:integrity_mismatch)}
        else
          {:ok, page.next_cursor}
        end
      end
    ]

    assert {:ok, before_effect} = drain(operation, sync, target, options, 500)
    assert_received {:page, nil, 100}
    assert_received {:page, cursor, 1}
    assert is_binary(cursor)
    assert before_effect.checkpoint["requirement_cursor"] == cursor

    Process.put(:corrupt_oid, Enum.min(oids))
    recovered = %{before_effect | state: :effect_pending, attempt_count: 2}

    assert {:error, %Error{kind: :integrity_mismatch}} =
             drain(recovered, sync, target, options, 500)

    assert_received {:page, nil, 100}
  end

  defp drain(operation, sync, target, options, remaining) when remaining > 0 do
    case LFSSync.ensure(operation, sync, :inbound, target, "token", %{}, options) do
      :ok ->
        {:ok, operation}

      {:incomplete, checkpoint} ->
        drain(%{operation | checkpoint: checkpoint}, sync, target, options, remaining - 1)

      error ->
        error
    end
  end

  defp drain(_operation, _sync, _target, _options, 0), do: flunk("scan did not terminate")

  defp git!(path, args) do
    {output, status} =
      System.cmd("git", args,
        cd: path,
        stderr_to_stdout: true,
        env: [
          {"GIT_AUTHOR_NAME", "Test"},
          {"GIT_AUTHOR_EMAIL", "test@example.test"},
          {"GIT_COMMITTER_NAME", "Test"},
          {"GIT_COMMITTER_EMAIL", "test@example.test"}
        ]
      )

    assert status == 0, output
    String.trim(output)
  end
end
