defmodule ForgeMirrors.InstallationIntents do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{GitHubIdentity, User}

  alias ForgeMirrors.{
    GitHubAppInstallation,
    GitHubInstallationIntent,
    MirrorWebhookDelivery,
    OrganizationMirror
  }

  alias Fornacast.Repo

  @max_intent_seconds 900
  def begin(actor, organization_id, state_digest, now, expires_at) do
    with {:ok, actor, organization} <- authorize(actor, organization_id),
         :ok <- validate_digest(state_digest),
         :ok <- validate_window(now, expires_at),
         true <- linked_github_identities(actor) != [] do
      transact(fn ->
        lock_organization!(organization.id)

        with {:ok, mirror} <- lock_or_create_pending_mirror(actor, organization.id),
             :ok <- cancel_open_intents(mirror.id, now),
             {:ok, intent} <-
               %GitHubInstallationIntent{}
               |> GitHubInstallationIntent.create_changeset(%{
                 organization_mirror_id: mirror.id,
                 organization_id: organization.id,
                 actor_user_id: actor.id,
                 state_digest: state_digest,
                 expires_at: expires_at
               })
               |> Repo.insert() do
          %{intent: intent, mirror: mirror}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      false -> {:error, :github_identity_required}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def record_callback(
        actor,
        organization_id,
        state_digest,
        installation_id,
        setup_action,
        now
      ) do
    with {:ok, actor, _organization} <- authorize(actor, organization_id),
         :ok <- validate_digest(state_digest),
         :ok <- validate_now(now),
         true <- is_integer(installation_id) and installation_id > 0,
         true <- setup_action in [:install, :update] do
      transact_callback(fn ->
        lock_organization!(organization_id)

        case lock_pending_intent(actor.id, organization_id, state_digest) do
          %GitHubInstallationIntent{} = intent ->
            record_live_callback(intent, installation_id, setup_action, now)

          nil ->
            {:intent_error, :invalid_installation_intent}
        end
      end)
    else
      false -> {:error, :invalid_installation_intent}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def confirm_webhook(installation_id, sender_github_user_id, now) do
    with true <- is_integer(installation_id) and installation_id > 0,
         true <- is_integer(sender_github_user_id) and sender_github_user_id > 0,
         :ok <- validate_now(now) do
      transact_callback(fn ->
        case lock_callback_intent(installation_id) do
          %GitHubInstallationIntent{} = intent ->
            confirm_live_intent(intent, sender_github_user_id, now)

          nil ->
            :unclaimed
        end
      end)
    else
      _invalid -> {:error, :invalid_argument}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp record_live_callback(intent, installation_id, setup_action, now) do
    cond do
      DateTime.compare(intent.expires_at, now) != :gt ->
        expire_intent(intent)
        {:intent_error, :expired_installation_intent}

      true ->
        with %GitHubAppInstallation{} <- active_organization_installation(installation_id),
             {:ok, callback_intent} <-
               intent
               |> GitHubInstallationIntent.callback_changeset(installation_id, setup_action, now)
               |> Repo.update() do
          # The setup callback records provider provenance only.  A historical
          # installation.created delivery is never current authorization for a
          # new binding; completion must go through the live authorization
          # boundary below.
          %{status: :pending_webhook, intent: callback_intent, mirror: lock_mirror(intent)}
        else
          nil -> Repo.rollback(:invalid_installation)
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp confirm_live_intent(intent, sender_github_user_id, now) do
    if DateTime.compare(intent.expires_at, now) != :gt do
      expire_intent(intent)
      :unclaimed
    else
      case complete_intent(intent, sender_github_user_id, now) do
        :unclaimed -> :unclaimed
        result -> result
      end
    end
  end

  defp complete_intent(intent, sender_github_user_id, now) do
    # Reload the actor and organization inside the same transaction that locks
    # the intent and mirror.  The actor supplied when the intent began may have
    # been demoted or removed from the organization meanwhile.
    with %User{} = actor <- Repo.get(User, intent.actor_user_id),
         {:ok, organization} <-
           ForgeAccounts.fetch_manageable_organization(actor, intent.organization_id),
         true <- organization.id == intent.organization_id,
         true <- linked_sender?(actor, sender_github_user_id),
         %GitHubAppInstallation{} = installation <-
           active_organization_installation(intent.github_installation_id),
         %OrganizationMirror{state: :pending_installation} = mirror <- lock_mirror(intent),
         true <- is_nil(mirror.github_installation_id) and is_nil(mirror.github_account_id),
         {:ok, ready} <- bind_mirror(mirror, installation, now),
         {:ok, completed} <-
           intent
           |> GitHubInstallationIntent.complete_changeset(now)
           |> Repo.update() do
      associate_buffered_deliveries(ready, installation.github_installation_id)
      %{status: :ready, intent: completed, mirror: ready}
    else
      {:error, :forbidden} -> :unclaimed
      {:error, :not_found} -> :unclaimed
      false -> :unclaimed
      nil -> :unclaimed
      _invalid -> Repo.rollback(:installation_binding_conflict)
    end
  end

  defp bind_mirror(mirror, installation, now) do
    if OrganizationMirror.legal_transition?(mirror.state, :ready_to_bootstrap) do
      mirror
      |> OrganizationMirror.update_changeset(%{
        github_installation_id: installation.github_installation_id,
        github_account_id: installation.github_account_id,
        github_account_login: installation.github_account_login,
        last_webhook_at: DateTime.truncate(now, :second)
      })
      |> Ecto.Changeset.put_change(:state, :ready_to_bootstrap)
      |> Ecto.Changeset.put_change(:resume_state, nil)
      |> Repo.update()
    else
      {:error, :invalid_transition}
    end
  end

  defp associate_buffered_deliveries(mirror, installation_id) do
    from(delivery in MirrorWebhookDelivery,
      where:
        delivery.installation_id == ^installation_id and
          is_nil(delivery.organization_mirror_id)
    )
    |> Repo.update_all(
      set: [organization_mirror_id: mirror.id, updated_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  defp linked_sender?(%User{} = actor, sender_github_user_id) do
    Enum.any?(linked_github_identities(actor), fn identity ->
      identity.github_user_id == sender_github_user_id
    end)
  end

  defp linked_github_identities(%User{} = actor) do
    actor
    |> ForgeAccounts.list_github_identities()
    |> Enum.filter(fn
      %GitHubIdentity{kind: :user, last_verified_at: %DateTime{}} -> true
      _identity -> false
    end)
  end

  defp active_organization_installation(installation_id) do
    Repo.get_by(GitHubAppInstallation,
      github_installation_id: installation_id,
      account_type: :organization,
      state: :active
    )
  end

  defp lock_pending_intent(actor_id, organization_id, state_digest) do
    GitHubInstallationIntent
    |> where(
      [intent],
      intent.actor_user_id == ^actor_id and intent.organization_id == ^organization_id and
        intent.state_digest == ^state_digest and intent.state == :pending
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_callback_intent(installation_id) do
    GitHubInstallationIntent
    |> where(
      [intent],
      intent.github_installation_id == ^installation_id and intent.state == :callback_received
    )
    |> order_by([intent], desc: intent.id)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_mirror(%GitHubInstallationIntent{organization_mirror_id: mirror_id}) do
    OrganizationMirror
    |> where([mirror], mirror.id == ^mirror_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_or_create_pending_mirror(_actor, organization_id) do
    mirror =
      OrganizationMirror
      |> where(
        [candidate],
        candidate.organization_id == ^organization_id and candidate.provider == "github" and
          candidate.state != :revoked
      )
      |> order_by([candidate], desc: candidate.id)
      |> limit(1)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case mirror do
      nil ->
        %OrganizationMirror{}
        |> OrganizationMirror.create_changeset(%{
          organization_id: organization_id,
          provider: "github",
          capabilities: default_capabilities(),
          policy: default_policy()
        })
        |> Repo.insert()

      %OrganizationMirror{state: :pending_installation} = mirror ->
        {:ok, mirror}

      %OrganizationMirror{} ->
        {:error, :already_connected}
    end
  end

  defp cancel_open_intents(mirror_id, now) do
    from(intent in GitHubInstallationIntent,
      where:
        intent.organization_mirror_id == ^mirror_id and
          intent.state in [:pending, :callback_received]
    )
    |> Repo.update_all(set: [state: :cancelled, updated_at: DateTime.truncate(now, :second)])

    :ok
  end

  defp expire_intent(intent) do
    intent
    |> GitHubInstallationIntent.terminate_changeset(:expired)
    |> Repo.update!()
  end

  defp authorize(%User{} = actor, organization_id)
       when is_integer(organization_id) and organization_id > 0 do
    case ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
      {:ok, organization} -> {:ok, actor, organization}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize(_actor, _organization_id), do: {:error, :forbidden}

  defp validate_digest(digest) when is_binary(digest) and byte_size(digest) == 32, do: :ok
  defp validate_digest(_digest), do: {:error, :invalid_installation_intent}

  defp validate_window(%DateTime{} = now, %DateTime{} = expires_at) do
    seconds = DateTime.diff(expires_at, now, :second)

    if now.time_zone == "Etc/UTC" and expires_at.time_zone == "Etc/UTC" and
         seconds in 1..@max_intent_seconds,
       do: :ok,
       else: {:error, :invalid_installation_intent}
  end

  defp validate_window(_now, _expires_at), do: {:error, :invalid_installation_intent}

  defp validate_now(%DateTime{time_zone: "Etc/UTC"}), do: :ok
  defp validate_now(_now), do: {:error, :invalid_argument}

  defp lock_organization!(organization_id) do
    Ecto.Adapters.SQL.query!(Repo, "select pg_advisory_xact_lock($1)", [organization_id])
    :ok
  end

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp transact_callback(fun) do
    case Repo.transaction(fun) do
      {:ok, {:intent_error, reason}} -> {:error, reason}
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp normalize_error(%Ecto.Changeset{}), do: :invalid_installation_intent
  defp normalize_error(reason) when is_atom(reason), do: reason
  defp normalize_error(_reason), do: :unavailable

  defp default_policy do
    %{
      "repository_selection" => "all",
      "selected_repository_ids" => [],
      "auto_import_new_repositories" => false,
      "auto_create_remote_repositories" => false,
      "repository_deletion_policy" => "retain",
      "conflict_notification_policy" => "dashboard_only"
    }
  end

  defp default_capabilities do
    %{
      "git" => "enabled",
      "lfs" => "enabled",
      "issues" => "enabled",
      "pulls" => "enabled",
      "releases" => "enabled"
    }
  end
end
