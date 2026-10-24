defmodule GitCore.PublicRemoteTest do
  use ExUnit.Case, async: false

  alias GitCore.Remote
  alias GitCore.Remote.{Error, Request, SyncRequest}

  @moduletag :tmp_dir

  test "anonymous mirror and subsequent fetch transfer real Git bytes without credential helpers",
       %{tmp_dir: tmp_dir} do
    git = System.find_executable("git")
    bash = System.find_executable("bash")
    source = Path.join(tmp_dir, "source")
    destination = Path.join(tmp_dir, "clone.git")
    log = Path.join(tmp_dir, "arguments")
    git!(["init", "--initial-branch=main", source])
    git!(["-C", source, "config", "user.name", "Fixture"])
    git!(["-C", source, "config", "user.email", "fixture@example.test"])
    File.write!(Path.join(source, "README.md"), "first bytes\n")
    git!(["-C", source, "add", "README.md"])
    git!(["-C", source, "commit", "-m", "first"])
    first = git!(["-C", source, "rev-parse", "HEAD"])
    adapter = Path.join(tmp_dir, "git-adapter")

    File.write!(adapter, """
    #!#{bash}
    set -euo pipefail
    [[ "$HOME" == /dev/null ]]
    [[ "$XDG_CONFIG_HOME" == /dev/null ]]
    [[ "$GIT_CONFIG_GLOBAL" == /dev/null ]]
    [[ "$GIT_CONFIG_NOSYSTEM" == 1 ]]
    [[ "$GIT_TERMINAL_PROMPT" == 0 ]]
    [[ "$GIT_ASKPASS" == /bin/false ]]
    [[ "${GIT_CONFIG_COUNT-unset}" == unset ]]
    printf '%s\\n' "$@" >> #{shell_quote(log)}
    translated=()
    for argument in "$@"; do
      case "$argument" in
        https://github.com/acme/widgets.git) translated+=(#{shell_quote(source)}) ;;
        protocol.file.allow=never) translated+=(protocol.file.allow=always) ;;
        *) translated+=("$argument") ;;
      esac
    done
    export GIT_ALLOW_PROTOCOL=https:file
    exec #{shell_quote(git)} "${translated[@]}"
    """)

    File.chmod!(adapter, 0o700)

    request =
      struct!(Request,
        provider: :github,
        owner: "acme",
        repository: "widgets",
        credential_login: nil,
        authentication: :anonymous,
        destination: destination,
        default_branch: "main"
      )

    opts = [
      git: adapter,
      credential_root: Path.join(tmp_dir, "credentials"),
      resolver: fn
        "github.com", :a -> [{140, 82, 121, 3}]
        "github.com", :aaaa -> []
      end
    ]

    assert {:ok, %Remote.Result{}} = Remote.mirror(request, :public, opts)
    assert git!(["--git-dir", destination, "show", "main:README.md"]) == "first bytes"
    assert {:ok, ^first} = GitCore.exact_ref(destination, "refs/heads/main")

    File.write!(Path.join(source, "README.md"), "second bytes\n")
    git!(["-C", source, "commit", "-am", "second"])
    second = git!(["-C", source, "rev-parse", "HEAD"])

    sync =
      struct!(SyncRequest,
        provider: :github,
        owner: "acme",
        repository: "widgets",
        credential_login: nil,
        authentication: :anonymous,
        repository_path: destination
      )

    assert {:ok, [%Remote.ObservedRef{ref: "refs/heads/main", oid: ^second}]} =
             Remote.fetch_observed_refs(sync, :public, "public-check", opts)

    assert {:ok, ^first} = GitCore.exact_ref(destination, "refs/heads/main")
    assert git!(["--git-dir", destination, "show", second <> ":README.md"]) == "second bytes"

    arguments = File.read!(log)
    assert arguments =~ "credential.helper=\n"
    refute arguments =~ "credential.helper=cache"
    refute arguments =~ "credential-cache"
    refute arguments =~ "authorization"
    refute File.exists?(opts[:credential_root])
  end

  test "anonymous requests reject credential mixing and remote writes", %{tmp_dir: tmp_dir} do
    base = [
      provider: :github,
      owner: "acme",
      repository: "widgets",
      credential_login: nil,
      authentication: :anonymous,
      destination: Path.join(tmp_dir, "clone.git"),
      default_branch: "main"
    ]

    request = struct!(Request, base)
    assert {:error, %Error{kind: :invalid_credential}} = Remote.mirror(request, "token")

    assert {:error, %Error{kind: :invalid_credential}} =
             Remote.mirror(%{request | credential_login: "octocat"}, :public)

    assert {:error, %Error{kind: :invalid_credential}} =
             Remote.mirror(
               %{request | authentication: :token, credential_login: "octocat"},
               :public
             )

    sync =
      struct!(SyncRequest,
        provider: :github,
        owner: "acme",
        repository: "widgets",
        credential_login: nil,
        authentication: :anonymous,
        repository_path: tmp_dir
      )

    assert {:error, %Error{kind: :invalid_credential}} =
             Remote.delete_ref(sync, :public, "refs/heads/main", String.duplicate("a", 40))

    assert {:error, %Error{kind: :invalid_credential}} = Remote.push_refs(sync, :public, [])
  end

  defp git!(args) do
    case System.cmd(System.find_executable("git"), args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git exited #{status}: #{output}")
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
