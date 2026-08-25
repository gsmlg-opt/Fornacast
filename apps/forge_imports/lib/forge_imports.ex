defmodule ForgeImports do
  @moduledoc "GitHub import discovery and durable orchestration."

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, User}
  alias ForgeAccounts.GitHubCredentialVault.Envelope

  alias ForgeImports.{
    ImportRun,
    OneTimeCredential,
    Persistence,
    RepositoryItem,
    RunView
  }

  alias Fornacast.Repo

  def provider, do: :github

  def create_run(%User{} = actor, attrs) when is_map(attrs) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           :ok <- validate_predecessor_run(active_actor, attrs),
           :ok <- validate_credential_binding(active_actor, attrs) do
        %ImportRun{}
        |> ImportRun.creation_changeset(active_actor.id, attrs)
        |> Repo.insert()
      end
    end)
  end

  def create_run(_actor, _attrs), do: {:error, :forbidden}

  def get_run(%User{id: actor_id}, id) when is_integer(id) and id > 0 do
    case Repo.one(from run in ImportRun, where: run.id == ^id and run.actor_user_id == ^actor_id) do
      %ImportRun{} = run -> {:ok, run}
      nil -> {:error, :not_found}
    end
  end

  def get_run(_actor, _id), do: {:error, :not_found}

  def get_run_view(%User{} = actor, id) do
    with {:ok, run} <- get_run(actor, id),
         {:ok, items} <- repository_items(actor, run) do
      {:ok, RunView.from_run(run, items)}
    end
  end

  def get_run_view(_actor, _id), do: {:error, :not_found}

  def create_repository_item(%User{} = actor, %ImportRun{} = expected_run, attrs)
      when is_map(attrs) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, current_run} <- scoped_run(active_actor, expected_run, lock?: true),
           :ok <- available_for_discovery(current_run, expected_run),
           :ok <- validate_predecessor_item(active_actor, current_run, attrs) do
        Persistence.create_repository_item(current_run, attrs)
      end
    end)
  end

  def create_repository_item(_actor, _run, _attrs), do: {:error, :not_found}

  def repository_items(%User{} = actor, %ImportRun{} = expected_run) do
    with {:ok, active_actor} <- active_actor(actor),
         {:ok, run} <- scoped_run(active_actor, expected_run) do
      items =
        RepositoryItem
        |> where([item], item.import_run_id == ^run.id)
        |> order_by([item], asc: item.id)
        |> Repo.all()

      {:ok, items}
    else
      _ -> {:error, :not_found}
    end
  end

  def repository_items(_actor, _run), do: {:error, :not_found}

  def select_repository_item(
        %User{} = actor,
        %ImportRun{} = expected_run,
        %RepositoryItem{} = expected_item,
        selected
      )
      when is_boolean(selected) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, _current_run} <- scoped_run(active_actor, expected_run),
           {:ok, _current_item} <- scoped_item(expected_run, expected_item) do
        Persistence.select_repository_item(expected_run, expected_item, selected)
      end
    end)
  end

  def select_repository_item(_actor, _run, _item, _selected), do: {:error, :not_found}

  def transition_run(actor, run, target, attrs \\ %{})

  def transition_run(%User{} = actor, %ImportRun{} = expected_run, target, attrs)
      when is_atom(target) and is_map(attrs) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, current_run} <- scoped_run(active_actor, expected_run) do
        changeset = run_transition_changeset(expected_run, current_run, target, attrs)
        persist_changeset(expected_run, [expected_run.state], changeset, :invalid_transition)
      end
    end)
  end

  def transition_run(_actor, _run, _target, _attrs), do: {:error, :not_found}

  def transition_repository_item(actor, run, item, target, attrs \\ %{})

  def transition_repository_item(
        %User{} = actor,
        %ImportRun{} = expected_run,
        %RepositoryItem{} = expected_item,
        target,
        attrs
      )
      when is_atom(target) and is_map(attrs) do
    mutate_item(actor, expected_run, expected_item, fn ->
      changeset = RepositoryItem.transition_changeset(expected_item, target, attrs)
      persist_changeset(expected_item, [expected_item.state], changeset, :invalid_transition)
    end)
  end

  def transition_repository_item(_actor, _run, _item, _target, _attrs),
    do: {:error, :not_found}

  def attach_one_time_credential(
        actor,
        run,
        envelope,
        keyring \\ Fornacast.Config.github_credential_keyring()
      )

  def attach_one_time_credential(
        %User{} = actor,
        %ImportRun{} = expected_run,
        %Envelope{} = envelope,
        keyring
      ) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, current_run} <- scoped_run(active_actor, expected_run),
           :ok <- OneTimeCredential.verify_envelope(current_run, envelope, keyring) do
        changeset = OneTimeCredential.attach_changeset(expected_run, envelope)

        persist_changeset(
          expected_run,
          [expected_run.state],
          changeset,
          :credential_service_unavailable
        )
      end
    end)
  end

  def attach_one_time_credential(_actor, _run, _envelope, _keyring), do: {:error, :not_found}

  defp mutate_item(actor, expected_run, expected_item, callback) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, current_run} <- scoped_run(active_actor, expected_run),
           {:ok, _current_item} <- scoped_item(current_run, expected_item) do
        callback.()
      end
    end)
  end

  defp persist_changeset(row, allowed_states, %Ecto.Changeset{valid?: true} = changeset, _error) do
    Persistence.update_without_lease(row, allowed_states, changeset)
  end

  defp persist_changeset(_row, _allowed_states, %Ecto.Changeset{}, error), do: {:error, error}

  defp active_actor(actor, opts \\ [])

  defp active_actor(%User{id: actor_id}, opts) when is_integer(actor_id) and actor_id > 0 do
    query =
      from user in User,
        where: user.id == ^actor_id and user.kind == :user and user.state == :active

    case query |> maybe_lock(Keyword.get(opts, :lock?, false)) |> Repo.one() do
      %User{} = active_actor -> {:ok, active_actor}
      nil -> {:error, :forbidden}
    end
  end

  defp active_actor(_actor, _opts), do: {:error, :forbidden}

  defp scoped_run(%User{id: actor_id}, %ImportRun{id: run_id}, opts \\ []) do
    query =
      from run in ImportRun,
        where: run.id == ^run_id and run.actor_user_id == ^actor_id

    case query |> maybe_lock(Keyword.get(opts, :lock?, false)) |> Repo.one() do
      %ImportRun{} = run -> {:ok, run}
      nil -> {:error, :not_found}
    end
  end

  defp scoped_item(%ImportRun{id: run_id}, %RepositoryItem{id: item_id}) do
    case Repo.one(
           from item in RepositoryItem,
             where: item.id == ^item_id and item.import_run_id == ^run_id
         ) do
      %RepositoryItem{} = item -> {:ok, item}
      nil -> {:error, :not_found}
    end
  end

  defp available_for_discovery(current, expected) do
    now = DateTime.utc_now(:second)

    cond do
      current.lock_version != expected.lock_version -> {:error, :stale}
      current.state != :discovering -> {:error, :stale}
      active_lease?(current, now) -> {:error, :busy}
      true -> :ok
    end
  end

  defp active_lease?(%{lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp active_lease?(_row, _now), do: false

  defp run_transition_changeset(
         %ImportRun{state: :discovering} = expected_run,
         %ImportRun{id: run_id},
         :awaiting_resolution,
         attrs
       ) do
    count =
      RepositoryItem
      |> where([item], item.import_run_id == ^run_id and item.selected == true)
      |> Repo.aggregate(:count, :id)

    ImportRun.snapshot_selection_changeset(expected_run, count, attrs)
  end

  defp run_transition_changeset(expected_run, _current_run, target, attrs),
    do: ImportRun.transition_changeset(expected_run, target, attrs)

  defp validate_credential_binding(%User{} = actor, attrs) do
    case credential_source(attrs) do
      :saved -> validate_saved_credential(actor, attrs)
      :one_time -> validate_one_time_identity(attrs)
      _unknown -> :ok
    end
  end

  defp validate_predecessor_run(%User{id: actor_id}, attrs) do
    case optional_positive_id(attrs, :predecessor_run_id) do
      :absent ->
        :ok

      {:ok, predecessor_id} ->
        case Repo.get(ImportRun, predecessor_id) do
          %ImportRun{actor_user_id: ^actor_id, state: state}
          when state in [:failed, :canceled, :completed_with_warnings] ->
            :ok

          %ImportRun{actor_user_id: ^actor_id} ->
            {:error, :invalid_predecessor}

          _foreign_or_missing ->
            {:error, :not_found}
        end

      :error ->
        {:error, :invalid_predecessor}
    end
  end

  defp validate_predecessor_item(%User{id: actor_id}, %ImportRun{} = run, attrs) do
    case optional_positive_id(attrs, :predecessor_item_id) do
      :absent ->
        :ok

      {:ok, predecessor_item_id} ->
        predecessor =
          Repo.one(
            from item in RepositoryItem,
              join: predecessor_run in ImportRun,
              on: predecessor_run.id == item.import_run_id,
              where:
                item.id == ^predecessor_item_id and predecessor_run.actor_user_id == ^actor_id,
              select: item
          )

        case predecessor do
          nil ->
            {:error, :not_found}

          %RepositoryItem{} = item when item.import_run_id == run.predecessor_run_id ->
            if retryable_unpublished_predecessor?(item),
              do: :ok,
              else: {:error, :invalid_predecessor}

          %RepositoryItem{} ->
            {:error, :invalid_predecessor}
        end

      :error ->
        {:error, :invalid_predecessor}
    end
  end

  defp retryable_unpublished_predecessor?(%RepositoryItem{
         state: state,
         publication_evidence: evidence
       })
       when state in [:failed, :canceled] and is_map(evidence) do
    map_size(evidence) == 0
  end

  defp retryable_unpublished_predecessor?(_item), do: false

  defp validate_saved_credential(%User{id: actor_id}, attrs) do
    with {:ok, credential_id} <- positive_id(attrs, :github_credential_id),
         {:ok, identity_id} <- positive_id(attrs, :github_identity_id),
         %GitHubCredential{} <-
           Repo.one(
             from credential in GitHubCredential,
               join: identity in GitHubIdentity,
               on: identity.id == credential.github_identity_id,
               where:
                 credential.id == ^credential_id and credential.status == :valid and
                   credential.local_user_id == ^actor_id and identity.id == ^identity_id and
                   identity.local_user_id == ^actor_id and identity.kind == :user and
                   identity.github_user_id > 0
           ) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp validate_one_time_identity(attrs) do
    with {:ok, identity_id} <- positive_id(attrs, :github_identity_id),
         %GitHubIdentity{} <-
           Repo.one(
             from identity in GitHubIdentity,
               where:
                 identity.id == ^identity_id and identity.kind == :user and
                   identity.github_user_id > 0
           ) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp credential_source(attrs) do
    case Map.get(attrs, :credential_source) || Map.get(attrs, "credential_source") do
      :saved -> :saved
      "saved" -> :saved
      :one_time -> :one_time
      "one_time" -> :one_time
      value -> value
    end
  end

  defp positive_id(attrs, field) do
    value = Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

    case Ecto.Type.cast(:integer, value) do
      {:ok, id} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp optional_positive_id(attrs, field) do
    value = Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

    if is_nil(value), do: :absent, else: positive_id(attrs, field)
  end

  defp maybe_lock(query, true) do
    if postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end

  defp maybe_lock(query, false), do: query

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp transact(callback) do
    transaction = fn ->
      Repo.transaction(fn ->
        case callback.() do
          {:ok, _value} = ok -> ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end
end
