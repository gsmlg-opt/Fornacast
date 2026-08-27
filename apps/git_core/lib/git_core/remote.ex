defmodule GitCore.Remote do
  @moduledoc """
  Supervised, credential-isolated Git transfer into a caller-owned staging path.
  """

  alias GitCore.Remote.{Control, CredentialCache, HostPolicy, Process}

  @allowed_options [
    :cancel?,
    :credential_root,
    :git,
    :heartbeat,
    :limiter,
    :resolver,
    :task_supervisor
  ]
  @owner_pattern ~r/\A(?=.{1,39}\z)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/
  @repository_pattern ~r/\A[A-Za-z0-9_.-]{1,100}\z/
  @max_credential_bytes 4_096
  @cleanup_slot_domain "fornacast.git-core.remote.cleanup-slot.v1\0"
  @cleanup_slot_prefix ".fornacast-cleanup-v1-"
  @zero_callbacks [cancel?: false, heartbeat: :ok]
  @safe_config_keys MapSet.new([
                      "core.bare",
                      "core.filemode",
                      "core.ignorecase",
                      "core.logallrefupdates",
                      "core.precomposeunicode",
                      "core.repositoryformatversion",
                      "core.symlinks",
                      "extensions.compatobjectformat",
                      "extensions.objectformat"
                    ])

  defmodule Request do
    @enforce_keys [
      :provider,
      :owner,
      :repository,
      :credential_login,
      :destination,
      :default_branch
    ]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Result do
    @enforce_keys [:path, :empty?, :default_branch, :refs, :bytes]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Error do
    @enforce_keys [:kind, :detail]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule CleanupPending do
    @moduledoc false
    @enforce_keys [:original_kind, :quarantine_path, :identity]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defimpl Inspect, for: Error do
    import Inspect.Algebra

    def inspect(error, opts) do
      concat(["#GitCore.Remote.Error<kind: ", to_doc(error.kind, opts), ">"])
    end
  end

  defimpl Inspect, for: CleanupPending do
    import Inspect.Algebra

    def inspect(cleanup, opts) do
      concat([
        "#GitCore.Remote.CleanupPending<original_kind: ",
        to_doc(cleanup.original_kind, opts),
        ">"
      ])
    end
  end

  @spec mirror(Request.t(), binary(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def mirror(request, pat, opts \\ []) do
    with {:ok, operation} <- prepare_operation(request, pat, opts) do
      run_owned(operation.task_supervisor, fn parent_monitor, supervisor_pid ->
        with_remote_permit(operation, fn ->
          do_mirror(operation, parent_monitor, supervisor_pid)
        end)
      end)
    end
  end

  @spec refresh(Request.t(), binary(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def refresh(request, pat, opts \\ []) do
    with {:ok, operation} <- prepare_operation(request, pat, opts) do
      run_owned(operation.task_supervisor, fn parent_monitor, supervisor_pid ->
        with_remote_permit(operation, fn ->
          do_refresh(operation, parent_monitor, supervisor_pid)
        end)
      end)
    end
  end

  @doc "Returns validated deterministic quarantine evidence without requiring a credential."
  @spec cleanup_evidence(Path.t()) ::
          {:ok, CleanupPending.t()} | {:error, Error.t()}
  def cleanup_evidence(destination) when is_binary(destination) do
    if destination?(destination) do
      parent = Path.dirname(destination)

      case File.lstat(parent) do
        {:error, :enoent} -> cleanup_not_found()
        {:ok, %File.Stat{type: :directory}} -> cleanup_evidence_in_parent(destination, parent)
        _unsafe -> remote_error(:unsafe_cleanup_state)
      end
    else
      remote_error(:invalid_destination)
    end
  rescue
    _error -> remote_error(:unsafe_cleanup_state)
  end

  def cleanup_evidence(_destination), do: remote_error(:invalid_destination)

  defp cleanup_evidence_in_parent(destination, parent) do
    quarantine = cleanup_slot(destination)

    with :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(parent),
         {:ok, parent_identity} <- directory_identity(parent) do
      case {File.lstat(destination), File.lstat(quarantine)} do
        {{:error, :enoent}, {:error, :enoent}} ->
          cleanup_not_found()

        {{:ok, _destination}, {:error, :enoent}} ->
          cleanup_not_found()

        {{:error, :enoent}, {:ok, %File.Stat{type: :directory}}} ->
          validate_cleanup_slot(destination, quarantine, parent, parent_identity)

        _ambiguous ->
          remote_error(:unsafe_cleanup_state)
      end
    else
      _unsafe -> remote_error(:unsafe_cleanup_state)
    end
  end

  defp validate_cleanup_slot(destination, quarantine, parent, parent_identity) do
    with {:ok, identity} <- private_directory_identity(quarantine),
         :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(quarantine),
         {:ok, ^parent_identity} <- directory_identity(parent),
         {:error, :enoent} <- File.lstat(destination),
         {:ok, ^identity} <- private_directory_identity(quarantine) do
      {:ok,
       %CleanupPending{
         original_kind: :previous_failure,
         quarantine_path: quarantine,
         identity: identity_projection(identity)
       }}
    else
      _changed -> remote_error(:unsafe_cleanup_state)
    end
  end

  defp cleanup_not_found, do: remote_error(:cleanup_not_found)

  defp do_mirror(operation, parent_monitor, supervisor_pid) do
    destination = operation.request.destination

    with :ok <- ensure_cleanup_slot_available(destination),
         {:ok, destination_identity} <- create_destination(destination) do
      result =
        with {:ok, host_policy} <-
               resolve_host_policy(operation, parent_monitor, supervisor_pid),
             result <-
               with_credentials(
                 operation,
                 destination_identity,
                 parent_monitor,
                 supervisor_pid,
                 fn context ->
                   with :ok <- clone_mirror(context, host_policy),
                        :ok <- sanitize_repository(context),
                        {:ok, result} <- validate_repository(context) do
                     {:ok, result}
                   end
                 end
               ) do
          result
        end

      case result do
        {:ok, %Result{}} = success ->
          case ensure_destination_identity(destination, destination_identity) do
            :ok ->
              success

            {:error, %Error{}} = error ->
              finish_mirror_error(destination, destination_identity, error)
          end

        {:error, %Error{}} = error ->
          finish_mirror_error(destination, destination_identity, error)
      end
    end
  end

  defp do_refresh(operation, parent_monitor, supervisor_pid) do
    destination = operation.request.destination

    with {:ok, destination_identity} <- validate_existing_destination(destination),
         result <-
           with_credentials(
             operation,
             destination_identity,
             parent_monitor,
             supervisor_pid,
             fn context ->
               with {:ok, _existing_result} <- validate_repository(context),
                    {:ok, host_policy} <-
                      resolve_host_policy(operation, parent_monitor, supervisor_pid),
                    :ok <- fetch_heads_and_tags(context, host_policy),
                    :ok <- sanitize_repository(context),
                    {:ok, result} <- validate_repository(context) do
                 {:ok, result}
               end
             end
           ),
         :ok <- ensure_destination_identity(destination, destination_identity) do
      result
    end
  end

  defp with_credentials(
         operation,
         destination_identity,
         parent_monitor,
         supervisor_pid,
         fun
       ) do
    credential_opts = [
      credential_root: operation.credential_root,
      credential_root_state: operation.credential_root_state,
      env: operation.env,
      absolute_deadline: operation.absolute_deadline,
      cancel?: operation.cancel?,
      heartbeat: operation.heartbeat,
      parent_monitor: parent_monitor,
      owner_exit_pid: supervisor_pid
    ]

    case CredentialCache.with_cache(
           operation.git,
           operation.request.credential_login,
           operation.pat,
           credential_opts,
           fn socket_path, daemon, operation_path ->
             context = %{
               operation: operation,
               destination_identity: destination_identity,
               socket_path: socket_path,
               daemon: daemon,
               operation_path: operation_path,
               parent_monitor: parent_monitor,
               owner_exit_pid: supervisor_pid
             }

             fun.(context)
           end
         ) do
      {:error, reason} when is_atom(reason) -> remote_error(reason)
      result -> result
    end
  end

  defp resolve_host_policy(operation, parent_monitor, owner_exit_pid) do
    context = %{
      operation: operation,
      parent_monitor: parent_monitor,
      owner_exit_pid: owner_exit_pid
    }

    case controlled_call(context, fn -> HostPolicy.resolve_github(operation.resolver) end) do
      {:ok, {:ok, %HostPolicy.Result{} = policy}} -> {:ok, policy}
      {:ok, _unsafe} -> remote_error(:host_policy)
      {:error, %Error{}} = error -> error
      {:error, _reason} -> remote_error(:host_policy)
    end
  end

  defp controlled_call(context, fun) when is_function(fun, 0) do
    with :ok <- operation_control(context) do
      caller = self()
      reply = make_ref()

      {worker, monitor} =
        :erlang.spawn_opt(
          fn -> send(caller, {reply, fun.()}) end,
          [:link, :monitor]
        )

      controlled_receive(context, worker, monitor, reply)
    end
  end

  defp controlled_receive(context, worker, monitor, reply) do
    receive do
      {^reply, result} ->
        forget_controlled_worker(worker, monitor)
        {:ok, result}

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        forget_controlled_worker(worker, monitor)
        {:error, :worker_failed}

      {:EXIT, ^worker, _reason} ->
        receive do
          {^reply, result} ->
            Elixir.Process.demonitor(monitor, [:flush])
            {:ok, result}
        after
          0 ->
            Elixir.Process.demonitor(monitor, [:flush])
            {:error, :worker_failed}
        end
    after
      control_wait_ms(context) ->
        case operation_control(context) do
          :ok ->
            controlled_receive(context, worker, monitor, reply)

          {:error, %Error{}} = error ->
            stop_controlled_worker(worker, monitor)
            error
        end
    end
  end

  defp forget_controlled_worker(worker, monitor) do
    Elixir.Process.unlink(worker)
    Elixir.Process.demonitor(monitor, [:flush])

    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp stop_controlled_worker(worker, monitor) do
    Elixir.Process.unlink(worker)
    Elixir.Process.exit(worker, :kill)
    Elixir.Process.demonitor(monitor, [:flush])

    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp control_wait_ms(context) do
    remaining = context.operation.absolute_deadline - System.monotonic_time(:millisecond)
    min(GitCore.Limits.get(:remote_poll_interval_ms), max(remaining, 0))
  end

  defp operation_control(context) do
    case raw_operation_control(context) do
      :ok -> :ok
      {:error, reason} -> remote_error(reason)
    end
  end

  defp raw_operation_control(context) do
    callback_operation_control(context)
  end

  defp callback_operation_control(context) do
    operation = context.operation
    now = System.monotonic_time(:millisecond)

    cond do
      now >= operation.absolute_deadline ->
        {:error, :timeout}

      is_integer(Elixir.Process.get(operation.control_key)) and
          now < Elixir.Process.get(operation.control_key) ->
        :ok

      true ->
        Elixir.Process.put(
          operation.control_key,
          now + GitCore.Limits.get(:remote_poll_interval_ms)
        )

        Control.check(control_options(context))
    end
  end

  defp control_options(context) do
    [
      cancel?: context.operation.cancel?,
      heartbeat: context.operation.heartbeat,
      absolute_deadline: context.operation.absolute_deadline,
      parent_monitor: context.parent_monitor,
      owner_exit_pid: context.owner_exit_pid
    ]
  end

  defp clone_mirror(context, host_policy) do
    request = context.operation.request

    argv =
      git_prefix(context, host_policy) ++
        [
          "clone",
          "--mirror",
          "--no-local",
          "--no-hardlinks",
          source_url(request),
          request.destination
        ]

    run_git(context, argv, disk_check: true)
  end

  defp fetch_heads_and_tags(context, host_policy) do
    request = context.operation.request

    argv =
      git_prefix(context, host_policy) ++
        [
          "--git-dir=#{request.destination}",
          "fetch",
          "--force",
          "--prune",
          "--no-auto-maintenance",
          "--no-write-fetch-head",
          "--no-recurse-submodules",
          source_url(request),
          "+refs/heads/*:refs/heads/*",
          "+refs/tags/*:refs/tags/*"
        ]

    run_git(context, argv, disk_check: true)
  end

  defp sanitize_repository(context) do
    path = context.operation.request.destination

    with {:ok, refs_output} <-
           run_git_output(context, local_git(context, ["for-each-ref", "--format=%(refname)"])),
         {:ok, refs} <- parse_lines(refs_output),
         true <- length(refs) <= GitCore.Limits.get(:remote_refs),
         :ok <- delete_non_publishable_refs(context, refs),
         :ok <- remove_origin(context),
         :ok <- remove_hooks(context, path) do
      :ok
    else
      false -> remote_error(:ref_limit)
      {:error, %Error{}} = error -> normalize_validation_error(error)
    end
  end

  defp delete_non_publishable_refs(context, refs) do
    unwanted =
      Enum.reject(refs, fn ref ->
        String.starts_with?(ref, "refs/heads/") or String.starts_with?(ref, "refs/tags/")
      end)

    case unwanted do
      [] ->
        :ok

      refs ->
        input = Enum.map_join(refs, "", &"delete #{&1}\n")

        run_git_with_stdin(
          context,
          local_git(context, ["update-ref", "--stdin"]),
          input
        )
    end
  end

  defp remove_origin(context) do
    with {:ok, config_output} <-
           run_git_output(
             context,
             local_git(context, ["config", "--local", "--name-only", "--list"])
           ),
         {:ok, config_keys} <- parse_lines(config_output) do
      if Enum.any?(config_keys, &String.starts_with?(&1, "remote.origin.")) do
        run_git(context, local_git(context, ["remote", "remove", "origin"]))
      else
        :ok
      end
    end
  end

  defp validate_repository(context) do
    operation = context.operation
    path = operation.request.destination

    with :ok <- ensure_destination_identity(context),
         :ok <- validate_physical_tree(context, path),
         :ok <- ensure_destination_identity(context),
         {:ok, true} <- GitCore.is_bare_repository?(path),
         :ok <- ensure_destination_identity(context),
         :ok <- reject_special_git_state(path),
         :ok <- ensure_destination_identity(context),
         :ok <- reject_hooks(path),
         :ok <- ensure_destination_identity(context),
         :ok <- fsck(context),
         {:ok, refs_output} <-
           run_git_output(context, local_git(context, ["for-each-ref", "--format=%(refname)"])),
         {:ok, refs} <- parse_lines(refs_output),
         true <- length(refs) <= GitCore.Limits.get(:remote_refs),
         true <- Enum.all?(refs, &publishable_ref?/1),
         :ok <- validate_local_config(context),
         :ok <- ensure_destination_identity(context),
         {:ok, empty?} <- GitCore.empty?(path),
         :ok <- ensure_destination_identity(context),
         :ok <- validate_default_branch(context, empty?),
         {:ok, bytes} <-
           physical_disk_usage(
             context,
             path,
             GitCore.Limits.get(:remote_repository_bytes)
           ),
         true <- bytes <= GitCore.Limits.get(:remote_repository_bytes),
         :ok <- ensure_destination_identity(context) do
      {:ok,
       %Result{
         path: path,
         empty?: empty?,
         default_branch: operation.request.default_branch,
         refs: length(refs),
         bytes: bytes
       }}
    else
      false ->
        remote_error(:source_validation)

      {:error, %Error{}} = error ->
        normalize_validation_error(error)

      {:error, reason}
      when reason in [:cancelled, :heartbeat_failed, :owner_down, :timeout] ->
        remote_error(reason)

      {:error, _reason} ->
        remote_error(:source_validation)

      _error ->
        remote_error(:source_validation)
    end
  end

  defp validate_default_branch(context, true) do
    run_git(
      context,
      local_git(context, [
        "symbolic-ref",
        "HEAD",
        "refs/heads/#{context.operation.request.default_branch}"
      ])
    )
  end

  defp validate_default_branch(context, false) do
    full_ref = "refs/heads/#{context.operation.request.default_branch}"

    with :ok <- ensure_destination_identity(context) do
      case GitCore.exact_ref(context.operation.request.destination, full_ref) do
        {:ok, oid} when is_binary(oid) ->
          with :ok <- ensure_destination_identity(context) do
            run_git(context, local_git(context, ["symbolic-ref", "HEAD", full_ref]))
          end

        _missing ->
          remote_error(:default_branch)
      end
    end
  end

  defp fsck(context) do
    run_git(context, local_git(context, ["fsck", "--full", "--strict", "--no-reflogs"]))
  end

  defp validate_local_config(context) do
    with {:ok, output} <-
           run_git_output(
             context,
             local_git(context, ["config", "--local", "--name-only", "--list"])
           ),
         {:ok, keys} <- parse_lines(output),
         true <- Enum.all?(keys, &MapSet.member?(@safe_config_keys, &1)) do
      :ok
    else
      _unsafe -> remote_error(:unsafe_config)
    end
  end

  defp run_git(context, argv, extra_opts \\ []) do
    case start_git(context, argv, extra_opts) do
      {:ok, handle} ->
        case Process.await(handle, await_options(context, extra_opts)) do
          {:ok, _output} -> ensure_destination_identity(context)
          {:error, reason} -> remote_error(reason)
        end

      {:error, %Error{}} = error ->
        error

      {:error, _reason} ->
        remote_error(:process_unavailable)
    end
  end

  defp run_git_output(context, argv) do
    case start_git(context, argv, []) do
      {:ok, handle} ->
        case Process.await(handle, await_options(context, [])) do
          {:ok, %{stdout: stdout}} ->
            case ensure_destination_identity(context) do
              :ok -> {:ok, stdout}
              {:error, %Error{}} = error -> error
            end

          {:error, reason} ->
            remote_error(reason)
        end

      {:error, %Error{}} = error ->
        error

      {:error, _reason} ->
        remote_error(:process_unavailable)
    end
  end

  defp run_git_with_stdin(context, argv, input) do
    with {:ok, handle} <- start_git(context, argv, stdin: true),
         :ok <- Process.send_stdin(handle, input),
         :ok <- Process.close_stdin(handle),
         {:ok, _output} <- Process.await(handle, await_options(context, [])),
         :ok <- ensure_destination_identity(context) do
      :ok
    else
      {:error, %Error{}} = error -> error
      {:error, reason} when is_atom(reason) -> remote_error(reason)
      _error -> remote_error(:process_unavailable)
    end
  end

  defp start_git(context, argv, opts) do
    process_opts = [
      env: context.operation.env,
      group: context.daemon && context.daemon.group_id,
      kill_target: context.daemon && context.daemon.pid,
      kill_wait_ms: GitCore.Limits.get(:remote_cleanup_wait_ms),
      kill_escalation_ms: GitCore.Limits.get(:remote_kill_escalation_ms),
      stdin: Keyword.get(opts, :stdin, false)
    ]

    with :ok <- ensure_destination_identity(context) do
      Process.start(argv, process_opts)
    end
  end

  defp await_options(context, opts) do
    destination = context.operation.request.destination

    base = [
      output_limit: GitCore.Limits.get(:remote_output_bytes),
      poll_interval: GitCore.Limits.get(:remote_poll_interval_ms),
      absolute_deadline: context.operation.absolute_deadline,
      cancel?: context.operation.cancel?,
      heartbeat: context.operation.heartbeat,
      parent_monitor: context.parent_monitor,
      owner_exit_pid: context.owner_exit_pid
    ]

    if Keyword.get(opts, :disk_check, false) do
      Keyword.merge(base,
        disk_check: fn ->
          physical_disk_usage(
            context,
            destination,
            GitCore.Limits.get(:remote_repository_bytes)
          )
        end,
        repository_limit: GitCore.Limits.get(:remote_repository_bytes)
      )
    else
      base
    end
  end

  defp git_prefix(context, host_policy) do
    [
      context.operation.git,
      "-c",
      "credential.helper=",
      "-c",
      "credential.helper=cache --socket=#{shell_quote(context.socket_path)}",
      "-c",
      "credential.interactive=false",
      "-c",
      "http.followRedirects=false",
      "-c",
      "http.curloptResolve=",
      "-c",
      "http.curloptResolve=#{host_policy.curlopt_resolve}",
      "-c",
      "http.sslVerify=true",
      "-c",
      "protocol.allow=never",
      "-c",
      "protocol.https.allow=always",
      "-c",
      "protocol.http.allow=never",
      "-c",
      "protocol.file.allow=never",
      "-c",
      "protocol.ext.allow=never",
      "-c",
      "protocol.git.allow=never",
      "-c",
      "protocol.ssh.allow=never",
      "-c",
      "fetch.recurseSubmodules=false",
      "-c",
      "submodule.recurse=false",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "transfer.fsckObjects=true",
      "-c",
      "fetch.fsckObjects=true"
    ]
  end

  defp local_git(context, arguments) do
    [
      context.operation.git,
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "protocol.allow=never",
      "--git-dir=#{context.operation.request.destination}"
      | arguments
    ]
  end

  defp prepare_operation(%Request{} = request, pat, opts) do
    with :ok <- validate_options(opts),
         :ok <- validate_request(request),
         :ok <- validate_credential(pat),
         {:ok, git} <- git_executable(Keyword.get(opts, :git)),
         {:ok, resolver} <- resolver(Keyword.get(opts, :resolver)),
         {:ok, cancel?} <- callback(opts, :cancel?),
         {:ok, heartbeat} <- callback(opts, :heartbeat),
         {:ok, {credential_root, credential_root_state}} <-
           credential_root(Keyword.get(opts, :credential_root)),
         limiter <- Keyword.get(opts, :limiter, GitCore.RemoteLimiter) do
      {:ok,
       %{
         request: request,
         pat: pat,
         git: git,
         resolver: resolver,
         cancel?: cancel?,
         heartbeat: heartbeat,
         control_key: {__MODULE__, :remote_control, make_ref()},
         credential_root: credential_root,
         credential_root_state: credential_root_state,
         limiter: limiter,
         task_supervisor: Keyword.get(opts, :task_supervisor, GitCore.RemoteTaskSupervisor),
         env: safe_environment(credential_root),
         absolute_deadline:
           System.monotonic_time(:millisecond) + GitCore.Limits.get(:remote_wall_time_ms)
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> remote_error(:invalid_request)
    end
  end

  defp prepare_operation(_request, _pat, _opts), do: remote_error(:invalid_request)

  defp validate_options(opts) do
    keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: []

    if keys != [] or opts == [] do
      if length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in @allowed_options)),
        do: :ok,
        else: remote_error(:invalid_options)
    else
      remote_error(:invalid_options)
    end
  end

  defp validate_request(request) do
    cond do
      request.provider != :github -> remote_error(:unsupported_provider)
      not Regex.match?(@owner_pattern, request.owner) -> remote_error(:invalid_request)
      not Regex.match?(@repository_pattern, request.repository) -> remote_error(:invalid_request)
      request.repository in [".", ".."] -> remote_error(:invalid_request)
      not credential_field?(request.credential_login, 255) -> remote_error(:invalid_credential)
      not default_branch?(request.default_branch) -> remote_error(:invalid_request)
      not destination?(request.destination) -> remote_error(:invalid_destination)
      true -> :ok
    end
  rescue
    _error -> remote_error(:invalid_request)
  end

  defp validate_credential(pat) do
    if credential_field?(pat, @max_credential_bytes),
      do: :ok,
      else: remote_error(:invalid_credential)
  end

  defp credential_field?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value) and
      not String.contains?(value, [<<0>>, "\r", "\n"])
  end

  defp default_branch?(branch) do
    is_binary(branch) and byte_size(branch) in 1..244 and String.valid?(branch) and
      not String.starts_with?(branch, ["/", "."]) and
      not String.ends_with?(branch, ["/", ".", ".lock"]) and
      not String.contains?(branch, [<<0>>, "//", "..", "@{", "\\", "~", "^", ":", "?", "*", "["]) and
      not String.match?(branch, ~r/[\x00-\x20\x7f]/)
  end

  defp destination?(destination) do
    is_binary(destination) and destination != "" and String.valid?(destination) and
      not String.contains?(destination, <<0>>) and Path.type(destination) == :absolute and
      destination == Path.expand(destination)
  end

  defp git_executable(nil) do
    case System.find_executable("git") do
      nil -> remote_error(:process_unavailable)
      git -> git_executable(git)
    end
  end

  defp git_executable(git) when is_binary(git) do
    case File.stat(git) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Path.type(git) == :absolute and Bitwise.band(mode, 0o111) != 0,
          do: {:ok, git},
          else: remote_error(:invalid_options)

      _error ->
        remote_error(:invalid_options)
    end
  end

  defp git_executable(_git), do: remote_error(:invalid_options)

  defp resolver(nil), do: {:ok, &HostPolicy.system_resolve/2}
  defp resolver(resolver) when is_function(resolver, 2), do: {:ok, resolver}
  defp resolver(_resolver), do: remote_error(:invalid_options)

  defp callback(opts, key) do
    default = Keyword.fetch!(@zero_callbacks, key)

    case Keyword.get(opts, key) do
      nil -> {:ok, fn -> default end}
      callback when is_function(callback, 0) -> {:ok, callback}
      _invalid -> remote_error(:invalid_options)
    end
  end

  defp credential_root(nil), do: credential_root(GitCore.Remote.CredentialReaper.root())

  defp credential_root(root) when is_binary(root) do
    with true <- Path.type(root) == :absolute and root == Path.expand(root),
         :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(Path.dirname(root)),
         {:ok, state} <- validate_optional_credential_root(root) do
      {:ok, {root, state}}
    else
      _unsafe -> remote_error(:invalid_options)
    end
  end

  defp credential_root(_root), do: remote_error(:invalid_options)

  defp validate_optional_credential_root(root) do
    case File.lstat(root) do
      {:error, :enoent} ->
        {:ok, :absent}

      {:ok, %File.Stat{type: :directory, mode: mode}}
      when Bitwise.band(mode, 0o777) == 0o700 ->
        with :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(root) do
          {:ok, :existing}
        end

      _unsafe ->
        {:error, :unsafe_credential_state}
    end
  end

  defp safe_environment(credential_root) do
    [
      {"HOME", credential_root},
      {"XDG_CONFIG_HOME", credential_root},
      {"LANG", "C.UTF-8"},
      {"LC_ALL", "C.UTF-8"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_ASKPASS", "/bin/false"},
      {"SSH_ASKPASS", "/bin/false"},
      {"GCM_INTERACTIVE", "Never"},
      {"GIT_ALLOW_PROTOCOL", "https"},
      {"GIT_PROTOCOL_FROM_USER", "0"}
    ]
  end

  defp with_remote_permit(operation, fun) do
    case GitCore.RemoteLimiter.with_permit(fun, server: operation.limiter) do
      {:error, :busy} -> remote_error(:remote_busy)
      {:error, :unavailable} -> remote_error(:remote_unavailable)
      result -> result
    end
  end

  defp run_owned(task_supervisor, fun) do
    caller = self()
    reply = make_ref()

    supervisor_pid = GenServer.whereis(task_supervisor)

    shutdown =
      GitCore.Limits.get(:remote_cleanup_wait_ms) +
        GitCore.Limits.get(:remote_kill_escalation_ms)

    with pid when is_pid(pid) <- supervisor_pid,
         {:ok, owner} <-
           Task.Supervisor.start_child(
             pid,
             fn ->
               Elixir.Process.flag(:trap_exit, true)
               parent_monitor = Elixir.Process.monitor(caller)
               result = fun.(parent_monitor, pid)
               send(caller, {reply, result})
             end,
             shutdown: shutdown
           ) do
      monitor = Elixir.Process.monitor(owner)

      receive do
        {^reply, result} ->
          Elixir.Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          receive do
            {^reply, result} -> result
          after
            0 -> remote_error(:remote_unavailable)
          end
      end
    else
      _unavailable -> remote_error(:remote_unavailable)
    end
  end

  defp create_destination(destination) do
    with :ok <-
           GitCore.Remote.CredentialReaper.safe_existing_directory_path(Path.dirname(destination)) do
      case File.mkdir(destination) do
        :ok ->
          finish_created_destination(destination)

        {:error, :eexist} ->
          remote_error(:destination_exists)

        {:error, _reason} ->
          remote_error(:invalid_destination)
      end
    else
      _error -> remote_error(:invalid_destination)
    end
  end

  defp finish_created_destination(destination) do
    with {:ok, before_chmod_identity} <- directory_identity(destination) do
      case File.chmod(destination, 0o700) do
        :ok ->
          with {:ok, private_identity} <- private_directory_identity(destination),
               true <- same_directory?(before_chmod_identity, private_identity) do
            {:ok, private_identity}
          else
            _replaced -> remote_error(:unsafe_cleanup_state)
          end

        {:error, _reason} ->
          remote_error(:unsafe_cleanup_state)
      end
    else
      _unsafe -> remote_error(:unsafe_cleanup_state)
    end
  end

  defp validate_existing_destination(destination) do
    with :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(destination),
         {:ok, identity} <- private_directory_identity(destination) do
      {:ok, identity}
    else
      _error -> remote_error(:invalid_destination)
    end
  end

  defp ensure_destination_identity(destination, expected_identity) do
    with :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(destination),
         {:ok, ^expected_identity} <- directory_identity(destination) do
      :ok
    else
      _changed -> remote_error(:unsafe_cleanup_state)
    end
  end

  defp ensure_destination_identity(context) do
    ensure_destination_identity(
      context.operation.request.destination,
      context.destination_identity
    )
  end

  defp cleanup_created_destination(destination, expected_identity) do
    case File.lstat(destination) do
      {:ok, %File.Stat{type: :directory}} ->
        quarantine_created_destination(destination, expected_identity)

      {:error, :enoent} ->
        remote_error(:unsafe_cleanup_state)

      _other ->
        remote_error(:unsafe_cleanup_state)
    end
  end

  defp quarantine_created_destination(destination, expected_identity) do
    parent = Path.dirname(destination)
    quarantine = cleanup_slot(destination)

    with {:ok, ^expected_identity} <- directory_identity(destination),
         :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(parent),
         {:ok, parent_identity} <- directory_identity(parent),
         {:error, :enoent} <- File.lstat(quarantine),
         {:ok, {:ok, {^quarantine, ^expected_identity}}} <-
           bounded_call(
             fn ->
               with {:ok, ^parent_identity} <- directory_identity(parent),
                    :ok <- ensure_destination_identity(destination, expected_identity),
                    {:error, :enoent} <- File.lstat(quarantine),
                    :ok <- File.rename(destination, quarantine),
                    {:ok, ^expected_identity} <- directory_identity(quarantine) do
                 {:ok, {quarantine, expected_identity}}
               else
                 _unsafe -> {:error, :identity_changed}
               end
             end,
             GitCore.Limits.get(:remote_cleanup_wait_ms)
           ),
         {:error, :enoent} <- File.lstat(destination),
         :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(quarantine),
         {:ok, ^expected_identity} <- private_directory_identity(quarantine) do
      {:ok, {quarantine, expected_identity}}
    else
      _unsafe -> remote_error(:unsafe_cleanup_state)
    end
  end

  defp finish_mirror_error(destination, destination_identity, error) do
    case cleanup_created_destination(destination, destination_identity) do
      {:ok, {quarantine, identity}} -> cleanup_pending(error, quarantine, identity)
      {:error, %Error{}} = cleanup_error -> cleanup_error
    end
  end

  defp ensure_cleanup_slot_available(destination) do
    parent = Path.dirname(destination)
    quarantine = cleanup_slot(destination)

    with :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(parent),
         {:ok, parent_identity} <- directory_identity(parent) do
      case File.lstat(quarantine) do
        {:error, :enoent} ->
          with {:ok, ^parent_identity} <- directory_identity(parent),
               {:error, :enoent} <- File.lstat(quarantine) do
            :ok
          else
            _unsafe -> remote_error(:unsafe_cleanup_state)
          end

        {:ok, %File.Stat{type: :directory}} ->
          with {:ok, identity} <- private_directory_identity(quarantine),
               :ok <- GitCore.Remote.CredentialReaper.safe_existing_directory_path(quarantine),
               {:ok, ^parent_identity} <- directory_identity(parent),
               {:ok, ^identity} <- private_directory_identity(quarantine) do
            cleanup_pending(:previous_failure, quarantine, identity)
          else
            _unsafe -> remote_error(:unsafe_cleanup_state)
          end

        _unsafe ->
          remote_error(:unsafe_cleanup_state)
      end
    else
      _invalid_parent -> remote_error(:invalid_destination)
    end
  end

  defp cleanup_pending({:error, %Error{kind: original_kind}}, quarantine, identity) do
    cleanup_pending(original_kind, quarantine, identity)
  end

  defp cleanup_pending(original_kind, quarantine, identity) when is_atom(original_kind) do
    {:error,
     %Error{
       kind: :cleanup_pending,
       detail: %CleanupPending{
         original_kind: original_kind,
         quarantine_path: quarantine,
         identity: identity_projection(identity)
       }
     }}
  end

  defp directory_identity(path) do
    case File.lstat(path) do
      {:ok,
       %File.Stat{
         type: :directory,
         mode: mode,
         major_device: major_device,
         minor_device: minor_device,
         inode: inode
       }} ->
        {:ok, {Bitwise.band(mode, 0o777), major_device, minor_device, inode}}

      _unsafe ->
        {:error, :unsafe_path}
    end
  end

  defp private_directory_identity(path) do
    case directory_identity(path) do
      {:ok, {0o700, _major_device, _minor_device, _inode} = identity} -> {:ok, identity}
      _unsafe -> {:error, :unsafe_path}
    end
  end

  defp same_directory?(
         {_mode_before, major_device, minor_device, inode},
         {_mode_after, major_device, minor_device, inode}
       ),
       do: true

  defp same_directory?(_before, _after), do: false

  defp identity_projection({mode, major_device, minor_device, inode}) do
    %{
      mode: mode,
      major_device: major_device,
      minor_device: minor_device,
      inode: inode
    }
  end

  defp cleanup_slot(destination) do
    digest =
      :sha256
      |> :crypto.hash(@cleanup_slot_domain <> destination)
      |> Base.url_encode64(padding: false)

    Path.join(Path.dirname(destination), @cleanup_slot_prefix <> digest)
  end

  defp bounded_call(fun, timeout) when is_function(fun, 0) and is_integer(timeout) do
    caller = self()
    reply = make_ref()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              {:ok, fun.()}
            rescue
              _error -> {:error, :cleanup_failed}
            catch
              _kind, _reason -> {:error, :cleanup_failed}
            end

          send(caller, {reply, result})
        end,
        [:link, :monitor]
      )

    receive do
      {^reply, {:ok, result}} ->
        forget_bounded_worker(worker, monitor)
        {:ok, result}

      {^reply, {:error, :cleanup_failed}} ->
        forget_bounded_worker(worker, monitor)
        {:error, :cleanup_failed}

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        forget_bounded_worker(worker, monitor)
        {:error, :cleanup_failed}

      {:EXIT, ^worker, _reason} ->
        Elixir.Process.demonitor(monitor, [:flush])
        {:error, :cleanup_failed}
    after
      timeout ->
        Elixir.Process.unlink(worker)
        Elixir.Process.exit(worker, :kill)
        Elixir.Process.demonitor(monitor, [:flush])
        {:error, :cleanup_timeout}
    end
  end

  defp forget_bounded_worker(worker, monitor) do
    Elixir.Process.unlink(worker)
    Elixir.Process.demonitor(monitor, [:flush])

    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp validate_physical_tree(context, path) do
    with :ok <- operation_control(context),
         :ok <- ensure_destination_identity(context) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          with {:ok, entries} <- File.ls(path) do
            Enum.reduce_while(entries, :ok, fn entry, :ok ->
              case validate_physical_tree(context, Path.join(path, entry)) do
                :ok -> {:cont, :ok}
                {:error, %Error{}} = error -> {:halt, error}
              end
            end)
          else
            _error -> remote_error(:source_validation)
          end

        {:ok, %File.Stat{type: :regular}} ->
          :ok

        _unsafe ->
          remote_error(:source_validation)
      end
    end
  end

  defp physical_disk_usage(context, path, limit) do
    with :ok <- raw_operation_control(context),
         :ok <- ensure_destination_identity(context) do
      case File.lstat(path) do
        {:error, :enoent} ->
          {:ok, 0}

        {:ok, %File.Stat{type: :regular, size: size}} ->
          {:ok, size}

        {:ok, %File.Stat{type: :directory}} ->
          with {:ok, entries} <- File.ls(path) do
            Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, total} ->
              case physical_disk_usage(context, Path.join(path, entry), limit - total) do
                {:ok, bytes} when total + bytes > limit ->
                  {:halt, {:ok, total + bytes}}

                {:ok, bytes} ->
                  {:cont, {:ok, total + bytes}}

                {:error, _reason} = error ->
                  {:halt, error}
              end
            end)
          end

        _unsafe ->
          {:error, :unsafe_path}
      end
    end
  end

  defp reject_special_git_state(path) do
    unsafe = [
      Path.join([path, "objects", "info", "alternates"]),
      Path.join(path, "shallow")
    ]

    if Enum.any?(unsafe, &File.exists?/1), do: remote_error(:source_validation), else: :ok
  end

  defp reject_hooks(path) do
    case File.lstat(Path.join(path, "hooks")) do
      {:error, :enoent} -> :ok
      _present -> remote_error(:source_validation)
    end
  end

  defp remove_hooks(context, path) do
    hooks = Path.join(path, "hooks")

    with :ok <- operation_control(context),
         :ok <- ensure_destination_identity(context) do
      case File.lstat(hooks) do
        {:error, :enoent} ->
          :ok

        {:ok, %File.Stat{type: :directory}} ->
          remove_owned_tree(context, hooks)

        _unsafe ->
          remote_error(:source_validation)
      end
    end
  end

  defp remove_owned_tree(context, path) do
    with :ok <- operation_control(context),
         :ok <- ensure_destination_identity(context) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          with {:ok, entries} <- File.ls(path),
               :ok <- remove_owned_entries(context, path, entries),
               :ok <- ensure_destination_identity(context),
               :ok <- File.rmdir(path) do
            :ok
          else
            {:error, %Error{}} = error -> error
            _failure -> remote_error(:source_validation)
          end

        {:ok, %File.Stat{type: :regular}} ->
          case File.rm(path) do
            :ok -> :ok
            _failure -> remote_error(:source_validation)
          end

        _unsafe ->
          remote_error(:source_validation)
      end
    end
  end

  defp remove_owned_entries(context, parent, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case remove_owned_tree(context, Path.join(parent, entry)) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp parse_lines(output) when is_binary(output) do
    if String.valid?(output) and byte_size(output) <= GitCore.Limits.get(:remote_output_bytes) do
      {:ok, output |> String.split("\n", trim: true) |> Enum.uniq()}
    else
      remote_error(:source_validation)
    end
  end

  defp publishable_ref?(ref),
    do: String.starts_with?(ref, "refs/heads/") or String.starts_with?(ref, "refs/tags/")

  defp source_url(request), do: "https://github.com/#{request.owner}/#{request.repository}.git"

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp remote_error(kind), do: {:error, %Error{kind: kind, detail: safe_detail(kind)}}

  defp normalize_validation_error({:error, %Error{kind: kind}} = error)
       when kind in [
              :cancelled,
              :default_branch,
              :disk_unavailable,
              :heartbeat_failed,
              :output_limit,
              :owner_down,
              :ref_limit,
              :repository_limit,
              :timeout,
              :unsafe_config
            ],
       do: error

  defp normalize_validation_error(_error), do: remote_error(:source_validation)

  defp safe_detail(kind)
       when kind in [
              :cancelled,
              :credential_unavailable,
              :default_branch,
              :destination_exists,
              :disk_unavailable,
              :heartbeat_failed,
              :host_policy,
              :invalid_credential,
              :invalid_destination,
              :invalid_options,
              :invalid_request,
              :output_limit,
              :process_exit,
              :process_unavailable,
              :ref_limit,
              :remote_busy,
              :remote_unavailable,
              :repository_limit,
              :source_validation,
              :timeout,
              :unsafe_config,
              :unsupported_provider
            ],
       do: Atom.to_string(kind)

  defp safe_detail(_kind), do: "remote_unavailable"
end
