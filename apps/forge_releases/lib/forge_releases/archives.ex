defmodule ForgeReleases.Archives do
  @moduledoc "Authorized, bounded source archives generated from local Git objects."

  @max_bytes 2_147_483_648
  @timeout_ms 30_000

  def prepare(actor, owner, repo, release_id, format) when format in ["tar", "zip"] do
    with {:ok, release} <- ForgeReleases.get(actor, owner, repo, release_id),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read) do
      deadline = System.monotonic_time(:millisecond) + @timeout_ms

      ForgeRepos.with_repository_read(repository, deadline, fn handle ->
        path = ForgeRepos.repository_read_path(handle)

        with {:ok, oid} <- commit_oid(path, "refs/tags/#{release.tag_name}") do
          generate(path, oid, repository.slug, release.tag_name, format)
        end
      end)
    end
  end

  def prepare(_actor, _owner, _repo, _release_id, _format), do: {:error, :not_found}

  def cleanup(%{path: path}), do: File.rm(path)

  @doc false
  def commit_oid(path, ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    with {:ok, output} <-
           git_output(
             path,
             ["rev-parse", "--verify", "--end-of-options", ref <> "^{commit}"],
             128
           ),
         oid <- String.trim(output),
         true <- Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, oid) do
      {:ok, oid}
    else
      _ -> {:error, :not_found}
    end
  end

  def commit_oid(_path, _ref), do: {:error, :not_found}

  @doc false
  def git_output(path, args, max_bytes) do
    run_git(path, args, fn chunk, acc -> {:ok, [chunk | acc]} end, [], max_bytes)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp generate(repository_path, oid, slug, tag, format) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    output_path = Path.join(System.tmp_dir!(), "fornacast-archive-#{nonce}")
    filename = "#{slug}-#{safe_filename(tag)}.#{format}"

    with {:ok, file} <- File.open(output_path, [:write, :binary, :exclusive]) do
      File.chmod(output_path, 0o600)

      try do
        case run_git(
               repository_path,
               ["archive", "--format=#{format}", "--prefix=#{slug}/", oid],
               fn chunk, size ->
                 case IO.binwrite(file, chunk) do
                   :ok -> {:ok, size + byte_size(chunk)}
                   _ -> {:error, {:unavailable, :archive}}
                 end
               end,
               0,
               Application.get_env(:forge_releases, :archive_max_bytes, @max_bytes)
             ) do
          {:ok, size} ->
            {:ok,
             %{
               path: output_path,
               size: size,
               filename: filename,
               content_type: if(format == "zip", do: "application/zip", else: "application/x-tar")
             }}

          error ->
            File.rm(output_path)
            error
        end
      after
        File.close(file)
      end
    else
      _ -> {:error, {:unavailable, :archive}}
    end
  end

  defp run_git(path, args, consumer, state, max_bytes) do
    case System.find_executable("git") do
      nil ->
        {:error, {:unavailable, :git}}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args: ["--git-dir=#{path}" | args],
            env: [{~c"GIT_CONFIG_GLOBAL", ~c"/dev/null"}, {~c"GIT_CONFIG_NOSYSTEM", ~c"1"}]
          ])

        deadline = System.monotonic_time(:millisecond) + @timeout_ms

        try do
          receive_output(port, consumer, state, 0, max_bytes, deadline)
        after
          if Port.info(port), do: Port.close(port)
        end
    end
  rescue
    ArgumentError -> {:error, {:unavailable, :git}}
  end

  defp receive_output(port, consumer, state, bytes, max_bytes, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, {:unavailable, :archive_timeout}}
    else
      receive do
        {^port, {:data, chunk}} ->
          if bytes + byte_size(chunk) <= max_bytes do
            case consumer.(chunk, state) do
              {:ok, state} ->
                receive_output(
                  port,
                  consumer,
                  state,
                  bytes + byte_size(chunk),
                  max_bytes,
                  deadline
                )

              error ->
                error
            end
          else
            {:error, :entity_too_large}
          end

        {^port, {:exit_status, 0}} ->
          {:ok, state}

        {^port, {:exit_status, _status}} ->
          {:error, :not_found}
      after
        remaining -> {:error, {:unavailable, :archive_timeout}}
      end
    end
  end

  defp safe_filename(value), do: String.replace(value, ~r/[^A-Za-z0-9._-]/, "-")
end
