defmodule ForgeImports.Waits do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, User}
  alias ForgeImports.GitHub.{Client, Error}
  alias ForgeImports.GitHub.User, as: GitHubUser
  alias ForgeImports.{ImportRun, OneTimeCredential, Persistence, RepositoryItem, Telemetry}
  alias Fornacast.Repo

  @terminal_run_states [:completed, :completed_with_warnings, :canceled, :failed]
  @pausable_item_states [
    :queued,
    :awaiting_resolution,
    :staging_git,
    :git_staged,
    :staging_metadata,
    :ready_to_publish,
    :publishing
  ]

  @spec rate_limited(RepositoryItem.t(), DateTime.t(), :primary | :secondary) ::
          {:ok, RepositoryItem.t()} | {:error, atom()}
  def rate_limited(%RepositoryItem{} = item, %DateTime{} = retry_at, classification)
      when classification in [:primary, :secondary] do
    now = DateTime.utc_now(:second)
    retry_at = DateTime.truncate(retry_at, :second)

    changeset =
      RepositoryItem.lease_update_changeset(item,
        wait_reason: rate_limit_reason(classification),
        next_attempt_at: retry_at
      )

    case Persistence.update_without_lease(item, [item.state], changeset, now) do
      {:ok, waiting} = result ->
        Telemetry.execute([:rate_limit, :pause], %{count: 1}, %{
          run_id: waiting.import_run_id,
          item_id: waiting.id,
          phase: waiting.state,
          classification: classification
        })

        result

      other ->
        other
    end
  end

  @spec awaiting_credential(ImportRun.t(), RepositoryItem.t() | nil, atom(), keyword()) ::
          {:ok, {ImportRun.t(), RepositoryItem.t() | nil}} | {:error, atom()}
  def awaiting_credential(%ImportRun{} = run, item, resume_state, opts \\ [])
      when is_atom(resume_state) and is_list(opts) do
    wait_reason = Keyword.get(opts, :wait_reason, "credential_unavailable")
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))

    transaction = fn ->
      Repo.transaction(fn ->
        with %ImportRun{} = locked_run <- locked_run(run.id),
             {:ok, paused_run} <- pause_run(locked_run, wait_reason, now),
             {:ok, paused_item} <- maybe_pause_item(item, resume_state, wait_reason, now) do
          {paused_run, paused_item}
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec pause_for_missing_saved_credential(ImportRun.t(), RepositoryItem.t(), keyword()) ::
          {:ok, {ImportRun.t(), RepositoryItem.t()}} | {:error, atom()}
  def pause_for_missing_saved_credential(%ImportRun{} = run, %RepositoryItem{} = item, opts \\ []) do
    if missing_saved_credential?(run) do
      resume_state = item.state
      awaiting_credential(run, item, resume_state, opts)
    else
      {:error, :stale}
    end
  end

  @spec resume_with_credential(User.t(), ImportRun.t(), map(), map(), keyword()) ::
          {:ok, ImportRun.t()} | {:error, atom()}
  def resume_with_credential(actor, run, credential_source, request_metadata, opts \\ [])

  def resume_with_credential(
        %User{} = actor,
        %ImportRun{} = expected_run,
        credential_source,
        request_metadata,
        opts
      )
      when is_map(credential_source) and is_map(request_metadata) and is_list(opts) do
    transaction = fn ->
      Repo.transaction(fn ->
        with {:ok, active_actor} <- active_actor(actor, lock?: true),
             %ImportRun{} = run <- scoped_run(active_actor, expected_run, lock?: true),
             true <- run.state == :awaiting_credential,
             {:ok, safe_metadata} <- safe_request_metadata(request_metadata),
             {:ok, prepared_run} <-
               attach_credential(active_actor, run, credential_source, safe_metadata, opts),
             {:ok, resumed_run} <- resume_run(prepared_run, safe_metadata),
             :ok <- resume_items(resumed_run) do
          kick_reconciler()
          resumed_run
        else
          false -> Repo.rollback(:invalid_transition)
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  def resume_with_credential(_actor, _run, _credential_source, _request_metadata, _opts),
    do: {:error, :not_found}

  @doc false
  @spec missing_saved_credential?(ImportRun.t()) :: boolean()
  def missing_saved_credential?(%ImportRun{credential_source: :saved, state: state} = run)
      when state not in @terminal_run_states do
    case run.github_credential_id do
      nil ->
        true

      credential_id ->
        not valid_saved_credential?(credential_id, run.actor_user_id, run.github_identity_id)
    end
  end

  def missing_saved_credential?(_run), do: false

  defp pause_run(%ImportRun{state: :running} = run, wait_reason, now) do
    changeset =
      ImportRun.transition_changeset(run, :awaiting_credential, %{
        wait_reason: wait_reason,
        next_attempt_at: nil
      })

    Persistence.update_without_lease(run, [:running], changeset, now)
  end

  defp pause_run(%ImportRun{state: :awaiting_credential} = run, wait_reason, now) do
    changeset =
      ImportRun.lease_update_changeset(run,
        wait_reason: wait_reason,
        next_attempt_at: nil,
        lease_owner: nil,
        lease_expires_at: nil
      )

    Persistence.update_without_lease(run, [:awaiting_credential], changeset, now)
  end

  defp pause_run(%ImportRun{state: state} = run, wait_reason, now)
       when state in [:ready, :awaiting_resolution] do
    changeset =
      ImportRun.transition_changeset(run, :awaiting_credential, %{
        wait_reason: wait_reason,
        next_attempt_at: nil
      })

    Persistence.update_without_lease(run, [state], changeset, now)
  end

  defp pause_run(_run, _wait_reason, _now), do: {:error, :invalid_transition}

  defp maybe_pause_item(nil, _resume_state, _wait_reason, _now), do: {:ok, nil}

  defp maybe_pause_item(%RepositoryItem{} = item, resume_state, wait_reason, now) do
    with %RepositoryItem{} = locked_item <- locked_item(item.id) do
      if locked_item.state != resume_state do
        {:error, :stale}
      else
        pause_item(locked_item, wait_reason, now)
      end
    else
      nil -> {:error, :not_found}
    end
  end

  defp pause_item(%RepositoryItem{state: :awaiting_credential} = item, wait_reason, now) do
    changeset =
      RepositoryItem.lease_update_changeset(item,
        wait_reason: wait_reason,
        next_attempt_at: nil,
        lease_owner: nil,
        lease_expires_at: nil
      )

    Persistence.update_without_lease(item, [:awaiting_credential], changeset, now)
  end

  defp pause_item(%RepositoryItem{} = item, wait_reason, now)
       when item.state in @pausable_item_states do
    changeset =
      RepositoryItem.transition_changeset(item, :awaiting_credential, %{
        wait_reason: wait_reason,
        next_attempt_at: nil
      })

    Persistence.update_without_lease(item, [item.state], changeset, now)
  end

  defp pause_item(_item, _wait_reason, _now), do: {:error, :invalid_transition}

  defp resume_run(%ImportRun{resume_state: resume_state} = run, _request_metadata)
       when resume_state in [:awaiting_resolution, :ready, :running] do
    changeset = ImportRun.transition_changeset(run, resume_state, %{})

    Persistence.update_without_lease(run, [:awaiting_credential], changeset)
  end

  defp resume_run(_run, _request_metadata), do: {:error, :invalid_transition}

  defp resume_items(%ImportRun{id: run_id}) do
    now = DateTime.utc_now(:second)

    items =
      Repo.all(
        from item in RepositoryItem,
          where:
            item.import_run_id == ^run_id and item.state == :awaiting_credential and
              not is_nil(item.resume_state)
      )

    Enum.reduce_while(items, :ok, fn item, :ok ->
      target = item.resume_state

      changeset = RepositoryItem.transition_changeset(item, target, %{})

      case Persistence.update_without_lease(item, [:awaiting_credential], changeset, now) do
        {:ok, _updated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp attach_credential(
         actor,
         %ImportRun{} = run,
         %{credential_source: :saved} = source,
         _request_metadata,
         _opts
       ) do
    with {:ok, credential_id} <- positive_id(source, :github_credential_id),
         {:ok, identity_id} <- positive_id(source, :github_identity_id),
         :ok <- validate_saved_credential(actor, run, credential_id, identity_id) do
      if run.github_credential_id == credential_id do
        {:ok, run}
      else
        changeset =
          ImportRun.persistence_changeset(run, %{
            github_credential_id: credential_id,
            github_identity_id: identity_id,
            credential_source: :saved
          })

        Persistence.update_without_lease(run, [:awaiting_credential], changeset)
      end
    end
  end

  defp attach_credential(
         actor,
         run,
         %{credential_source: :one_time, pat: pat} = _source,
         _request_metadata,
         opts
       )
       when is_binary(pat) do
    with {:ok, client, client_opts} <- client_options(opts),
         {:ok, user} <- authenticated_user(client, pat, client_opts, run, opts),
         :ok <- exact_identity(run, user),
         {:ok, envelope} <-
           ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
             run.id,
             actor.id,
             user.id,
             pat,
             Keyword.get(opts, :keyring, Fornacast.Config.github_credential_keyring())
           ),
         changeset <- OneTimeCredential.attach_changeset(run, envelope),
         {:ok, updated} <-
           Persistence.update_without_lease(run, [:awaiting_credential], changeset) do
      {:ok, updated}
    else
      {:error, :invalid_response} -> {:error, :identity_mismatch}
      error -> error
    end
  end

  defp attach_credential(_actor, _run, _source, _request_metadata, _opts),
    do: {:error, :invalid_transition}

  defp validate_saved_credential(
         %User{id: actor_id},
         %ImportRun{} = run,
         credential_id,
         identity_id
       ) do
    case Repo.one(
           from credential in GitHubCredential,
             join: identity in GitHubIdentity,
             on: identity.id == credential.github_identity_id,
             where:
               credential.id == ^credential_id and credential.status == :valid and
                 credential.local_user_id == ^actor_id and identity.id == ^identity_id and
                 identity.local_user_id == ^actor_id and identity.id == ^run.github_identity_id and
                 identity.github_user_id > 0
         ) do
      %GitHubCredential{} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authenticated_user(client, pat, client_opts, run, opts) do
    client_opts =
      client_opts
      |> Keyword.put(:test_pid, Keyword.get(opts, :test_pid, self()))
      |> Keyword.put(:response, Keyword.fetch!(opts, :response))
      |> Keyword.put(:gate_key, {:one_time_run, run.id})

    case client.authenticated_user(pat, client_opts) do
      {:ok, %GitHubUser{} = user} -> {:ok, user}
      {:error, %Error{kind: :invalid_credential}} -> {:error, :invalid_credential}
      {:error, %Error{kind: :identity_mismatch}} -> {:error, :identity_mismatch}
      {:error, %Error{}} -> {:error, :invalid_response}
      _ -> {:error, :invalid_response}
    end
  end

  defp exact_identity(%ImportRun{} = run, %GitHubUser{id: github_user_id}) do
    case Repo.get(GitHubIdentity, run.github_identity_id) do
      %GitHubIdentity{github_user_id: ^github_user_id} -> :ok
      _ -> {:error, :identity_mismatch}
    end
  end

  defp client_options(opts) do
    client = Keyword.get(opts, :client, Client)

    if is_atom(client) and Code.ensure_loaded?(client) and
         function_exported?(client, :authenticated_user, 2),
       do: {:ok, client, Keyword.get(opts, :client_options, [])},
       else: {:error, :invalid_response}
  end

  defp safe_request_metadata(request_metadata) do
    case ForgeAccounts.validate_github_request_metadata(request_metadata) do
      {:ok, safe} -> {:ok, safe}
      {:error, _} = error -> error
    end
  end

  defp active_actor(%User{id: actor_id}, opts) do
    query =
      from user in User,
        where: user.id == ^actor_id and user.kind == :user and user.state == :active

    case query |> maybe_lock(Keyword.get(opts, :lock?, false)) |> Repo.one() do
      %User{} = active -> {:ok, active}
      nil -> {:error, :forbidden}
    end
  end

  defp scoped_run(%User{id: actor_id}, %ImportRun{id: run_id}, opts) do
    query =
      from run in ImportRun,
        where: run.id == ^run_id and run.actor_user_id == ^actor_id

    query |> maybe_lock(Keyword.get(opts, :lock?, false)) |> Repo.one()
  end

  defp locked_run(run_id) do
    ImportRun
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp locked_item(item_id) do
    RepositoryItem
    |> where([item], item.id == ^item_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp maybe_lock(query, true), do: lock(query, "FOR UPDATE")
  defp maybe_lock(query, _), do: query

  defp positive_id(attrs, field) do
    value = Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

    case Ecto.Type.cast(:integer, value) do
      {:ok, id} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_transition}
    end
  end

  defp rate_limit_reason(:primary), do: "rate_limit"
  defp rate_limit_reason(:secondary), do: "rate_limit"

  defp valid_saved_credential?(credential_id, actor_user_id, identity_id) do
    Repo.exists?(
      from credential in GitHubCredential,
        where:
          credential.id == ^credential_id and credential.status == :valid and
            credential.local_user_id == ^actor_user_id and
            credential.github_identity_id == ^identity_id
    )
  end

  defp kick_reconciler do
    if Process.whereis(ForgeImports.Reconciler), do: ForgeImports.Reconciler.kick(), else: :ok
  end
end
