defmodule ForgeImports.OrganizationSync do
  @moduledoc "Organization-scoped orchestration for the GitHub mirror settings surface."

  alias ForgeAccounts.{Organization, User}

  alias ForgeGitHub.{
    AppAuthentication,
    AppConfig,
    AppInstallation,
    Error,
    InstallationTokenBroker
  }

  alias ForgeMirrors.OrganizationMirror

  @intent_seconds 600
  @state_pattern ~r/\A[A-Za-z0-9_-]{43}\z/

  def get_settings(%User{} = actor, %Organization{id: organization_id}) do
    with {:ok, view} <- ForgeMirrors.organization_settings(actor, organization_id) do
      {:ok,
       update_in(view, [:actions], fn actions ->
         Map.put(actions, :resolve_pull_merge_conflict, pull_merge_worker_enabled?())
       end)}
    end
  end

  def get_settings(_actor, _organization), do: {:error, :forbidden}

  def begin_installation(
        %User{} = actor,
        %Organization{id: organization_id},
        state,
        request_metadata
      ) do
    now = DateTime.utc_now(:second)

    with true <- valid_state?(state),
         {:ok, _metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, %AppConfig{} = config} <- AppConfig.fetch(),
         state_digest <- :crypto.hash(:sha256, state),
         {:ok, %{intent: _intent, mirror: _mirror}} <-
           ForgeMirrors.begin_github_installation(
             actor,
             organization_id,
             state_digest,
             now,
             DateTime.add(now, @intent_seconds)
           ) do
      {:ok, %{url: installation_url(config.app_slug, state)}}
    else
      false -> {:error, :invalid_request}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def begin_installation(_actor, _organization, _state, _request_metadata),
    do: {:error, :forbidden}

  def complete_installation(
        %User{} = actor,
        %Organization{id: organization_id},
        %{installation_id: installation_id, setup_action: setup_action, state: state},
        request_metadata
      ) do
    now = DateTime.utc_now(:second)

    with true <- valid_state?(state),
         true <- is_integer(installation_id) and installation_id > 0,
         true <- setup_action in [:install, :update],
         {:ok, _metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, %AppConfig{} = config} <- AppConfig.fetch(),
         {:ok, %AppInstallation{account_type: :organization} = installation} <-
           AppAuthentication.get_installation(config, installation_id),
         {:ok, _persisted_installation} <- observe_installation(installation, now),
         {:ok, result} <-
           ForgeMirrors.record_github_installation_callback(
             actor,
             organization_id,
             :crypto.hash(:sha256, state),
             installation_id,
             setup_action,
             now
           ) do
      {:ok, result}
    else
      false -> {:error, :invalid_callback}
      {:ok, %AppInstallation{}} -> {:error, :invalid_installation}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def complete_installation(_actor, _organization, _attrs, _request_metadata),
    do: {:error, :forbidden}

  def update_settings(
        %User{} = actor,
        %Organization{id: organization_id},
        attrs,
        request_metadata
      )
      when is_map(attrs) do
    with {:ok, _metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata) do
      ForgeMirrors.update_organization_settings(actor, organization_id, attrs)
    end
  end

  def update_settings(_actor, _organization, _attrs, _request_metadata),
    do: {:error, :forbidden}

  def resolve_pull_merge_conflict(
        %User{} = actor,
        %Organization{id: organization_id},
        %{conflict_id: conflict_id, lock_version: lock_version, action: action},
        request_metadata
      )
      when is_integer(conflict_id) and conflict_id > 0 and is_integer(lock_version) and
             lock_version > 0 and is_binary(action) and is_map(request_metadata) do
    with {:ok, safe_metadata} <-
           ForgeAccounts.validate_github_request_metadata(request_metadata),
         true <- pull_merge_worker_enabled?() do
      ForgeMirrors.recheck_pull_merge_conflict(
        actor,
        organization_id,
        %ForgeMirrors.MirrorConflict{id: conflict_id, lock_version: lock_version},
        action,
        DateTime.utc_now(:second),
        safe_metadata
      )
    else
      false -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_pull_merge_conflict(_actor, _organization, _attrs, _request_metadata),
    do: {:error, :forbidden}

  def bootstrap(%User{} = actor, %Organization{} = organization, attrs, request_metadata)
      when is_map(attrs) do
    ForgeImports.OrganizationSync.Bootstrap.start(actor, organization, attrs, request_metadata)
  end

  def bootstrap(_actor, _organization, _attrs, _request_metadata), do: {:error, :forbidden}

  @doc false
  def bootstrap(
        %User{} = actor,
        %Organization{} = organization,
        attrs,
        request_metadata,
        opts
      )
      when is_map(attrs) and is_list(opts) do
    ForgeImports.OrganizationSync.Bootstrap.start(
      actor,
      organization,
      attrs,
      request_metadata,
      opts
    )
  end

  def bootstrap(_actor, _organization, _attrs, _request_metadata, _opts),
    do: {:error, :forbidden}

  def reconcile(%User{} = actor, %Organization{id: organization_id}, request_metadata) do
    with {:ok, _metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, mirror} <- active_mirror(organization_id) do
      ForgeMirrors.schedule_reconciliation(actor, mirror, DateTime.utc_now(:second))
    end
  end

  def reconcile(_actor, _organization, _request_metadata), do: {:error, :forbidden}

  def pause(%User{} = actor, %Organization{id: organization_id}, request_metadata) do
    with {:ok, _metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, mirror} <- active_mirror(organization_id) do
      ForgeMirrors.pause(actor, mirror)
    end
  end

  def pause(_actor, _organization, _request_metadata), do: {:error, :forbidden}

  def resume(%User{} = actor, %Organization{id: organization_id}, request_metadata) do
    with {:ok, _metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, mirror} <- active_mirror(organization_id) do
      ForgeMirrors.resume(actor, mirror)
    end
  end

  def resume(_actor, _organization, _request_metadata), do: {:error, :forbidden}

  def disconnect(%User{} = actor, %Organization{id: organization_id}, request_metadata) do
    with {:ok, _metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, %OrganizationMirror{} = mirror} <- active_mirror(organization_id),
         {:ok, revoked} <- ForgeMirrors.transition_organization_mirror(actor, mirror, :revoked) do
      if is_integer(revoked.github_installation_id),
        do: InstallationTokenBroker.revoke(revoked.github_installation_id)

      {:ok, revoked}
    end
  end

  def disconnect(_actor, _organization, _request_metadata), do: {:error, :forbidden}

  defp active_mirror(organization_id),
    do: ForgeMirrors.get_organization_mirror_for_organization(organization_id, "github")

  defp observe_installation(installation, now) do
    ForgeMirrors.observe_github_app_installation(%{
      github_installation_id: installation.id,
      github_account_id: installation.account_id,
      github_account_login: installation.account_login,
      account_type: installation.account_type,
      repository_selection: installation.repository_selection,
      permissions: installation.permissions,
      state: installation.state,
      last_verified_at: now
    })
  end

  defp installation_url(app_slug, state) do
    URI.to_string(%URI{
      scheme: "https",
      host: "github.com",
      path: "/apps/#{app_slug}/installations/new",
      query: URI.encode_query(%{"state" => state})
    })
  end

  defp valid_state?(state) when is_binary(state), do: Regex.match?(@state_pattern, state)
  defp valid_state?(_state), do: false

  defp normalize_error(:disabled), do: :not_configured
  defp normalize_error(:invalid_configuration), do: :not_configured
  defp normalize_error(%Error{kind: :not_found}), do: :invalid_installation
  defp normalize_error(%Error{kind: kind}), do: kind
  defp normalize_error(reason), do: reason

  defp pull_merge_worker_enabled?,
    do: is_pid(Process.whereis(ForgeGitHub.PullMergeWorker))
end
