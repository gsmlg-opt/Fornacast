defmodule ForgeImports.OrganizationSync.Bootstrap do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{Organization, User}
  alias ForgeGitHub.{AppAuthentication, AppConfig, AppInstallation}
  alias ForgeImports.{ImportRun, RepositoryItem}
  alias ForgeMirrors.{GitHubAppInstallation, OrganizationMirror, RepositoryMirror}
  alias Fornacast.Repo

  @selection "current_policy"

  def start(actor, organization, attrs, request_metadata, opts \\ [])

  def start(
        %User{} = actor,
        %Organization{} = organization,
        attrs,
        request_metadata,
        opts
      )
      when is_map(attrs) and is_map(request_metadata) and is_list(opts) do
    now = DateTime.utc_now()

    with :ok <- validate_attrs(attrs),
         {:ok, safe_metadata} <-
           ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, _authorized_view} <- ForgeMirrors.organization_settings(actor, organization.id),
         {:ok, %OrganizationMirror{} = mirror} <-
           ForgeMirrors.get_organization_mirror_for_organization(organization.id, "github"),
         :ok <- validate_installation(mirror),
         {:ok, _installation} <- refresh_installation(mirror, now, opts),
         {:ok, settings} <- ForgeMirrors.organization_settings(actor, organization.id),
         :ok <- validate_bootstrap_actions(settings),
         {:ok, result} <- create_and_bind(actor, organization, mirror, safe_metadata) do
      ForgeImports.Reconciler.kick()
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :bootstrap_unavailable}
    end
  rescue
    _exception -> {:error, :bootstrap_unavailable}
  end

  def start(_actor, _organization, _attrs, _request_metadata, _opts),
    do: {:error, :forbidden}

  @doc false
  def runnable?(run_id) when is_integer(run_id) and run_id > 0 do
    mirrors =
      Repo.all(
        from mirror in OrganizationMirror,
          where: mirror.bootstrap_import_run_id == ^run_id and mirror.provider == "github",
          order_by: [desc: mirror.id],
          limit: 2
      )

    case mirrors do
      [] -> :ok
      [%OrganizationMirror{state: state}] when state in [:bootstrapping, :catching_up] -> :ok
      [%OrganizationMirror{state: :paused}] -> {:error, :paused}
      [%OrganizationMirror{state: :revoked}] -> {:error, :revoked}
      _invalid -> {:error, :bootstrap_unavailable}
    end
  rescue
    _exception -> {:error, :bootstrap_unavailable}
  end

  def runnable?(_run_id), do: {:error, :bootstrap_unavailable}

  @doc false
  def finish(%ImportRun{} = run, %DateTime{} = now) do
    Repo.transaction(fn ->
      case finish_in_transaction(run, now) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :bootstrap_unavailable}
  end

  @doc false
  def finish_in_transaction(%ImportRun{} = run, %DateTime{} = now) do
    case lock_bootstrap_mirror(run.id) do
      nil ->
        :ok

      %OrganizationMirror{} = mirror ->
        with :ok <- validate_handoffs(run, mirror),
             {:ok, %OrganizationMirror{} = finalized} <- finalize_mirror(mirror, run.state, now) do
          replay_bound_metadata(finalized, run.state, now)
          :ok
        end
    end
  end

  defp replay_bound_metadata(%OrganizationMirror{state: state} = mirror, run_state, now)
       when state in [:catching_up, :degraded] and
              run_state in [:completed, :completed_with_warnings] do
    Repo.update_all(
      from(delivery in ForgeMirrors.MirrorWebhookDelivery,
        join: binding in RepositoryMirror,
        on:
          binding.organization_mirror_id == ^mirror.id and
            binding.github_repository_id == delivery.github_repository_id,
        where:
          delivery.installation_id == ^mirror.github_installation_id and
            (is_nil(delivery.organization_mirror_id) or
               delivery.organization_mirror_id == ^mirror.id) and
            delivery.state == :pending_unsupported and
            delivery.event in ["issues", "issue_comment", "pull_request"] and
            not is_nil(binding.repository_id)
      ),
      set: [
        organization_mirror_id: mirror.id,
        state: :pending,
        next_attempt_at: now,
        failure_class: nil,
        updated_at: now
      ]
    )

    :ok
  end

  defp replay_bound_metadata(_mirror, _run_state, _now), do: :ok

  defp create_and_bind(actor, organization, mirror, request_metadata) do
    Repo.transaction(fn ->
      with %OrganizationMirror{state: :ready_to_bootstrap} = locked <- lock_mirror(mirror.id),
           :ok <- validate_mirror_identity(locked, organization),
           {:ok, %ImportRun{} = run} <-
             ForgeImports.create_run(actor, run_attrs(organization, locked, request_metadata)),
           {:ok, %OrganizationMirror{} = bound} <-
             ForgeMirrors.update_organization_mirror(actor, locked, %{
               bootstrap_import_run_id: run.id
             }),
           {:ok, %OrganizationMirror{state: :bootstrapping} = bootstrapping} <-
             ForgeMirrors.transition_organization_mirror(actor, bound, :bootstrapping) do
        %{run: run, mirror: bootstrapping}
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
        _invalid -> Repo.rollback(:invalid_transition)
      end
    end)
  end

  defp lock_mirror(id) do
    OrganizationMirror
    |> where([mirror], mirror.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_bootstrap_mirror(run_id) do
    OrganizationMirror
    |> where(
      [mirror],
      mirror.bootstrap_import_run_id == ^run_id and mirror.provider == "github"
    )
    |> order_by([mirror], desc: mirror.id)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp validate_handoffs(%ImportRun{id: run_id, state: state}, mirror)
       when state in [:completed, :completed_with_warnings] do
    published_item_ids =
      Repo.all(
        from item in RepositoryItem,
          where:
            item.import_run_id == ^run_id and item.selected == true and
              item.state in [:published, :completed],
          select: item.id
      )

    active_item_ids =
      Repo.all(
        from repository in RepositoryMirror,
          where:
            repository.organization_mirror_id == ^mirror.id and
              repository.bootstrap_repository_item_id in ^published_item_ids,
          select: repository.bootstrap_repository_item_id
      )

    if MapSet.new(published_item_ids) == MapSet.new(active_item_ids),
      do: :ok,
      else: {:error, :bootstrap_handoff_incomplete}
  end

  defp validate_handoffs(%ImportRun{}, _mirror), do: :ok

  defp finalize_mirror(%OrganizationMirror{state: :paused} = mirror, _run_state, _now),
    do: {:ok, mirror}

  defp finalize_mirror(%OrganizationMirror{state: :active} = mirror, :completed, _now),
    do: {:ok, mirror}

  defp finalize_mirror(mirror, :completed, now) do
    with {:ok, catching_up} <- transition_if_needed(mirror, :catching_up),
         {:ok, scheduled} <-
           catching_up
           |> OrganizationMirror.update_changeset(%{next_reconcile_at: now})
           |> Repo.update() do
      {:ok, scheduled}
    end
  end

  defp finalize_mirror(mirror, :completed_with_warnings, now) do
    with {:ok, degraded} <- transition_if_needed(mirror, :degraded) do
      degraded
      |> OrganizationMirror.update_changeset(%{next_reconcile_at: now})
      |> Repo.update()
    end
  end

  defp finalize_mirror(mirror, :failed, _now), do: transition_if_needed(mirror, :degraded)

  defp finalize_mirror(%OrganizationMirror{state: :bootstrapping} = mirror, :canceled, _now) do
    mirror
    |> OrganizationMirror.transition_changeset(:paused, :bootstrapping)
    |> Repo.update()
  end

  defp finalize_mirror(mirror, :canceled, _now), do: {:ok, mirror}
  defp finalize_mirror(mirror, _state, _now), do: {:ok, mirror}

  defp transition_if_needed(%OrganizationMirror{state: target} = mirror, target),
    do: {:ok, mirror}

  defp transition_if_needed(mirror, target) do
    if OrganizationMirror.legal_transition?(mirror.state, target) do
      mirror
      |> OrganizationMirror.transition_changeset(target)
      |> Repo.update()
    else
      {:error, :invalid_transition}
    end
  end

  defp validate_mirror_identity(mirror, organization) do
    cond do
      mirror.organization_id != organization.id ->
        {:error, :forbidden}

      mirror.provider != "github" ->
        {:error, :invalid_transition}

      not (is_integer(mirror.github_installation_id) and mirror.github_installation_id > 0) ->
        {:error, :invalid_transition}

      not (is_integer(mirror.github_account_id) and mirror.github_account_id > 0) ->
        {:error, :invalid_transition}

      not (is_binary(mirror.github_account_login) and mirror.github_account_login != "") ->
        {:error, :invalid_transition}

      true ->
        :ok
    end
  end

  defp validate_installation(mirror) do
    case Repo.get_by(GitHubAppInstallation,
           github_installation_id: mirror.github_installation_id
         ) do
      %GitHubAppInstallation{
        state: :active,
        account_type: :organization,
        github_account_id: account_id
      }
      when account_id == mirror.github_account_id ->
        :ok

      %GitHubAppInstallation{state: :suspended} ->
        {:error, :installation_suspended}

      %GitHubAppInstallation{state: :revoked} ->
        {:error, :installation_revoked}

      _missing_or_mismatch ->
        {:error, :invalid_installation}
    end
  end

  defp validate_bootstrap_actions(%{missing_permissions: missing}) when missing != [],
    do: {:error, :missing_permissions}

  defp validate_bootstrap_actions(%{actions: %{bootstrap: true}}), do: :ok
  defp validate_bootstrap_actions(_settings), do: {:error, :invalid_transition}

  defp refresh_installation(mirror, now, opts) do
    fetch = Keyword.get(opts, :installation_fetch, &fetch_installation/1)

    with true <- is_function(fetch, 1),
         {:ok,
          %AppInstallation{
            id: installation_id,
            account_id: account_id,
            account_type: :organization,
            state: :active
          } = installation} <- fetch.(mirror.github_installation_id),
         true <- installation_id == mirror.github_installation_id,
         true <- account_id == mirror.github_account_id,
         {:ok, persisted} <-
           ForgeMirrors.observe_github_app_installation(%{
             github_installation_id: installation.id,
             github_account_id: installation.account_id,
             github_account_login: installation.account_login,
             account_type: installation.account_type,
             repository_selection: installation.repository_selection,
             permissions: installation.permissions,
             state: installation.state,
             last_verified_at: now
           }) do
      {:ok, persisted}
    else
      false -> {:error, :invalid_installation}
      {:ok, %AppInstallation{state: :suspended}} -> {:error, :installation_suspended}
      {:ok, %AppInstallation{}} -> {:error, :invalid_installation}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_installation}
    end
  rescue
    _exception -> {:error, :bootstrap_unavailable}
  end

  defp fetch_installation(installation_id) do
    with {:ok, config} <- AppConfig.fetch() do
      AppAuthentication.get_installation(config, installation_id)
    end
  end

  defp run_attrs(organization, mirror, request_metadata) do
    %{
      source_kind: :organization,
      credential_source: :github_app,
      source_owner_github_id: mirror.github_account_id,
      source_owner_login: mirror.github_account_login,
      destination_organization_action: :existing,
      destination_organization_slug: organization.username,
      destination_organization_id: organization.id,
      destination_organization_status: :clean,
      request_metadata: request_metadata
    }
  end

  defp validate_attrs(attrs) do
    keys = attrs |> Map.keys() |> Enum.map(&to_string/1)
    selection = Map.get(attrs, :repository_selection) || Map.get(attrs, "repository_selection")

    if keys == ["repository_selection"] and selection == @selection,
      do: :ok,
      else: {:error, :invalid_request}
  rescue
    _exception -> {:error, :invalid_request}
  end
end
