defmodule FornacastAPI.IssueFixtureGenerator do
  @moduledoc false

  alias FornacastAPI.IssueFixtureLiterals

  @lock_name ".issue-fixtures.lock"
  @journal_name ".issue-fixtures.journal"
  @transaction_prefix ".issue-fixtures."

  def run(opts \\ []) do
    fixture_root = opts |> Keyword.get(:fixture_root, "../fixtures") |> Path.expand(__DIR__)

    openapi_root =
      opts |> Keyword.get(:openapi_root, "../../priv/openapi") |> Path.expand(__DIR__)

    after_lock = Keyword.get(opts, :after_lock, fn -> :ok end)
    rename = Keyword.get(opts, :rename, &default_rename/3)

    with {:ok, lock_path} <- acquire_lock(fixture_root) do
      try do
        cleanup_stale_lock_candidates!(fixture_root)
        cleanup_stale_journal_candidates!(fixture_root)
        recover_existing!(fixture_root)
        after_lock.()
        replace_fixtures!(fixture_root, openapi_root, rename)
      after
        release_lock(lock_path)
      end
    end
  end

  defp acquire_lock(fixture_root, attempts \\ 0)

  defp acquire_lock(_fixture_root, attempts) when attempts >= 3,
    do: {:error, :locked}

  defp acquire_lock(fixture_root, attempts) do
    lock_path = Path.join(fixture_root, @lock_name)
    candidate = lock_path <> ".#{System.pid()}"
    File.write!(candidate, System.pid())

    result =
      case File.ln(candidate, lock_path) do
        :ok ->
          {:ok, lock_path}

        {:error, :eexist} ->
          if lock_owner_alive?(lock_path) do
            {:error, :locked}
          else
            case File.rm(lock_path) do
              :ok -> acquire_lock(fixture_root, attempts + 1)
              {:error, :enoent} -> acquire_lock(fixture_root, attempts + 1)
              {:error, _reason} -> {:error, :locked}
            end
          end

        {:error, reason} ->
          raise "unable to acquire issue fixture lock: #{inspect(reason)}"
      end

    File.rm(candidate)
    result
  end

  defp lock_owner_alive?(lock_path) do
    with {:ok, owner} <- File.read(lock_path),
         true <- Regex.match?(~r/^\d+$/, owner),
         {_output, 0} <- System.cmd("kill", ["-0", owner], stderr_to_stdout: true) do
      true
    else
      _ -> false
    end
  end

  defp release_lock(lock_path) do
    case File.read(lock_path) do
      {:ok, owner} -> if owner == System.pid(), do: File.rm(lock_path), else: :ok
      _ -> :ok
    end
  end

  defp cleanup_stale_lock_candidates!(fixture_root) do
    fixture_root
    |> Path.join(@lock_name <> ".*")
    |> Path.wildcard()
    |> Enum.each(fn candidate ->
      owner = Path.basename(candidate) |> String.replace_prefix(@lock_name <> ".", "")

      if Regex.match?(~r/^\d+$/, owner) do
        case System.cmd("kill", ["-0", owner], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {_output, _status} -> File.rm(candidate)
        end
      else
        File.rm(candidate)
      end
    end)
  end

  defp cleanup_stale_journal_candidates!(fixture_root) do
    fixture_root
    |> Path.join(@journal_name <> ".*")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  defp replace_fixtures!(fixture_root, openapi_root, rename) do
    prepared = prepare_fixtures!(fixture_root, openapi_root)
    transaction_root = make_transaction_root!(fixture_root)
    write_journal!(fixture_root, transaction_root, :prepared)

    try do
      stage_fixtures!(fixture_root, transaction_root, prepared)
      write_journal!(fixture_root, transaction_root, :backing_up)

      Enum.each(prepared, fn {target, _bytes} ->
        rename!(rename, :backing_up, target, backup_path(fixture_root, transaction_root, target))
      end)

      write_journal!(fixture_root, transaction_root, :installing)

      Enum.each(prepared, fn {target, _bytes} ->
        rename!(rename, :installing, staged_path(fixture_root, transaction_root, target), target)
      end)

      write_journal!(fixture_root, transaction_root, :committed)
    rescue
      error ->
        rollback_result = recover_existing(fixture_root)

        case rollback_result do
          :ok ->
            raise RuntimeError,
                  "fixture replacement failed and was rolled back: #{Exception.message(error)}"

          {:error, reason} ->
            raise RuntimeError,
                  "fixture replacement failed; rollback remains journaled: #{inspect(reason)}; original error: #{Exception.message(error)}"
        end
    end

    cleanup_transaction!(fixture_root, transaction_root)
    :ok
  end

  defp prepare_fixtures!(fixture_root, openapi_root) do
    documents =
      Map.new(IssueFixtureLiterals.versions(), fn version ->
        document =
          Path.join(openapi_root, "ghes-3.21-#{version}.json")
          |> File.read!()
          |> JSON.decode!()
          |> OpenApiSpex.OpenApi.Decode.decode()

        {version, document}
      end)

    prepared =
      for version <- IssueFixtureLiterals.versions(),
          {filename, literal} <- IssueFixtureLiterals.files(version) do
        bytes = JSON.encode!(literal)
        ^literal = JSON.decode!(bytes)
        validate_schema!(Map.fetch!(documents, version), filename, literal)
        target = Path.join([fixture_root, version, "issues", filename])
        true = File.regular?(target)
        {target, bytes}
      end

    10 = length(prepared)
    prepared
  end

  defp validate_schema!(document, filename, literal) do
    {path, method, status} = response(filename)

    schema =
      document.paths
      |> Map.fetch!(path)
      |> Map.fetch!(method)
      |> Map.fetch!(:responses)
      |> Map.fetch!(status)
      |> Map.fetch!(:content)
      |> Map.fetch!("application/json")
      |> Map.fetch!(:schema)

    {:ok, _value} = OpenApiSpex.cast_value(literal, schema, document)
  end

  defp response("issue.json"),
    do: {"/repos/{owner}/{repo}/issues/{issue_number}", :get, "200"}

  defp response("pull-issue.json"),
    do: {"/repos/{owner}/{repo}/issues/{issue_number}", :get, "200"}

  defp response("issue-list.json"), do: {"/repos/{owner}/{repo}/issues", :get, "200"}

  defp response("issue-comment.json"),
    do: {"/repos/{owner}/{repo}/issues/{issue_number}/comments", :post, "201"}

  defp response("issue-comment-list.json"),
    do: {"/repos/{owner}/{repo}/issues/{issue_number}/comments", :get, "200"}

  defp make_transaction_root!(fixture_root) do
    template = Path.join(fixture_root, @transaction_prefix <> "XXXXXXXX")

    case System.cmd("mktemp", ["-d", template], stderr_to_stdout: true) do
      {output, 0} ->
        transaction_root = String.trim(output)
        transaction_root = validate_transaction_root!(fixture_root, transaction_root)

        unless File.dir?(transaction_root) do
          raise "mktemp did not create the issue fixture transaction directory"
        end

        transaction_root

      {output, status} ->
        raise "mktemp failed with status #{status}: #{String.trim(output)}"
    end
  end

  defp validate_transaction_root!(fixture_root, transaction_root) do
    fixture_root = Path.expand(fixture_root)
    transaction_root = Path.expand(transaction_root)

    unless Path.dirname(transaction_root) == fixture_root and
             String.starts_with?(Path.basename(transaction_root), @transaction_prefix) do
      raise "mktemp returned unsafe issue fixture transaction path"
    end

    transaction_root
  end

  defp stage_fixtures!(fixture_root, transaction_root, prepared) do
    Enum.each(prepared, fn {target, bytes} ->
      staged = staged_path(fixture_root, transaction_root, target)
      File.mkdir_p!(Path.dirname(staged))
      File.write!(staged, bytes)
      ^bytes = File.read!(staged)

      backup = backup_path(fixture_root, transaction_root, target)
      File.mkdir_p!(Path.dirname(backup))
    end)
  end

  defp rename!(rename, phase, source, target) do
    case rename.(phase, source, target) do
      :ok -> :ok
      {:error, reason} -> raise "#{phase} rename failed: #{inspect(reason)}"
    end
  end

  defp default_rename(_phase, source, target), do: File.rename(source, target)

  defp staged_path(fixture_root, transaction_root, target),
    do: Path.join([transaction_root, "staged", Path.relative_to(target, fixture_root)])

  defp backup_path(fixture_root, transaction_root, target),
    do: Path.join([transaction_root, "backup", Path.relative_to(target, fixture_root)])

  defp write_journal!(fixture_root, transaction_root, phase) do
    journal_path = Path.join(fixture_root, @journal_name)
    temporary = journal_path <> ".#{System.pid()}"

    bytes =
      JSON.encode!(%{
        "phase" => Atom.to_string(phase),
        "transaction_root" => transaction_root
      })

    File.write!(temporary, bytes)
    File.rename!(temporary, journal_path)
  end

  defp recover_existing!(fixture_root) do
    case recover_existing(fixture_root) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "unable to recover prior issue fixture transaction: #{inspect(reason)}"
    end
  end

  defp recover_existing(fixture_root) do
    journal_path = Path.join(fixture_root, @journal_name)

    case File.read(journal_path) do
      {:ok, bytes} -> recover_journal(fixture_root, journal_path, bytes)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp recover_journal(fixture_root, journal_path, bytes) do
    %{"phase" => phase, "transaction_root" => transaction_root} = JSON.decode!(bytes)
    transaction_root = validate_transaction_root!(fixture_root, transaction_root)

    case phase do
      "prepared" ->
        :ok

      "backing_up" ->
        restore_backups!(fixture_root, transaction_root, false)

      "installing" ->
        unless File.dir?(transaction_root), do: raise("transaction backup directory is missing")
        restore_backups!(fixture_root, transaction_root, true)

      "committed" ->
        :ok
    end

    cleanup_transaction!(fixture_root, transaction_root, journal_path)
    :ok
  end

  defp restore_backups!(fixture_root, transaction_root, remove_installed?) do
    Enum.each(target_paths(fixture_root), fn target ->
      backup = backup_path(fixture_root, transaction_root, target)

      if File.regular?(backup) do
        if remove_installed? and File.exists?(target), do: File.rm!(target)
        File.rename!(backup, target)
      end
    end)

    unless Enum.all?(target_paths(fixture_root), &File.regular?/1) do
      raise "rollback could not restore every issue fixture"
    end
  end

  defp cleanup_transaction!(fixture_root, transaction_root, journal_path \\ nil) do
    transaction_root = validate_transaction_root!(fixture_root, transaction_root)
    journal_path = journal_path || Path.join(fixture_root, @journal_name)
    File.rm_rf!(transaction_root)
    File.rm(journal_path)
  end

  defp target_paths(fixture_root) do
    for version <- IssueFixtureLiterals.versions(),
        filename <- Map.keys(IssueFixtureLiterals.files(version)) do
      Path.join([fixture_root, version, "issues", filename])
    end
  end
end
