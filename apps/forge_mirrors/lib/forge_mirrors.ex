defmodule ForgeMirrors do
  @moduledoc """
  Provider-neutral durable organization mirror policy and operation scheduler.

  This context persists intent and confirmed state only. Provider calls and
  domain-specific synchronization engines live in later delivery slices.
  """

  import Ecto.Query

  alias Fornacast.{DomainOutboxEvent, Repo}

  alias ForgeMirrors.{
    GitHubAppInstallation,
    InventoryPolicy,
    MirrorConflict,
    MirrorOperation,
    MirrorWebhookDelivery,
    OrganizationMirror,
    RepositoryMirror
  }

  @max_claim_batch 100
  @inventory_operation_kind "reconcile.organization_inventory"

  @type provider :: :github
  @type direction :: :inbound | :outbound
  @type resource_kind :: :organization | :repository | :git | :lfs | :issue | :pull | :release

  @spec observe_github_app_installation(map()) ::
          {:ok, GitHubAppInstallation.t()}
          | {:error, Ecto.Changeset.t() | :identity_mismatch | :invalid_transition}
  def observe_github_app_installation(attrs) when is_map(attrs) do
    changeset = GitHubAppInstallation.observation_changeset(%GitHubAppInstallation{}, attrs)

    if changeset.valid? do
      installation_id = Ecto.Changeset.get_field(changeset, :github_installation_id)
      observation = normalized_installation_observation(changeset)

      Repo.transaction(fn ->
        lock_github_installation_identity!(installation_id)

        existing =
          GitHubAppInstallation
          |> where([installation], installation.github_installation_id == ^installation_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        result =
          case existing do
            nil -> Repo.insert(changeset)
            %GitHubAppInstallation{} = installation -> observe_existing(installation, observation)
          end

        case result do
          {:ok, installation} -> installation
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction_result()
    else
      {:error, changeset}
    end
  end

  def observe_github_app_installation(_attrs),
    do: {:error, GitHubAppInstallation.observation_changeset(%GitHubAppInstallation{}, %{})}

  @spec get_github_app_installation(pos_integer()) ::
          {:ok, GitHubAppInstallation.t()} | {:error, :not_found | :invalid_argument}
  def get_github_app_installation(installation_id)
      when is_integer(installation_id) and installation_id > 0 do
    case Repo.get_by(GitHubAppInstallation, github_installation_id: installation_id) do
      nil -> {:error, :not_found}
      installation -> {:ok, installation}
    end
  end

  def get_github_app_installation(_installation_id), do: {:error, :invalid_argument}

  @doc false
  def begin_github_installation(actor, organization_id, state_digest, now, expires_at),
    do:
      ForgeMirrors.InstallationIntents.begin(
        actor,
        organization_id,
        state_digest,
        now,
        expires_at
      )

  @doc false
  def record_github_installation_callback(
        actor,
        organization_id,
        state_digest,
        installation_id,
        setup_action,
        now
      ),
      do:
        ForgeMirrors.InstallationIntents.record_callback(
          actor,
          organization_id,
          state_digest,
          installation_id,
          setup_action,
          now
        )

  @doc false
  def confirm_github_installation_webhook(installation_id, sender_github_user_id, now),
    do:
      ForgeMirrors.InstallationIntents.confirm_webhook(
        installation_id,
        sender_github_user_id,
        now
      )

  @spec suspend_github_app_installation(pos_integer(), DateTime.t()) ::
          {:ok, GitHubAppInstallation.t()}
          | {:error, :not_found | :invalid_argument | :invalid_transition}
  def suspend_github_app_installation(installation_id, %DateTime{} = observed_at),
    do: transition_github_app_installation(installation_id, :suspended, observed_at)

  def suspend_github_app_installation(_installation_id, _observed_at),
    do: {:error, :invalid_argument}

  @spec revoke_github_app_installation(pos_integer(), DateTime.t()) ::
          {:ok, GitHubAppInstallation.t()}
          | {:error, :not_found | :invalid_argument | :invalid_transition}
  def revoke_github_app_installation(installation_id, %DateTime{} = observed_at),
    do: transition_github_app_installation(installation_id, :revoked, observed_at)

  def revoke_github_app_installation(_installation_id, _observed_at),
    do: {:error, :invalid_argument}

  defp transition_github_app_installation(installation_id, target, observed_at)
       when is_integer(installation_id) and installation_id > 0 do
    Repo.transaction(fn ->
      lock_github_installation_identity!(installation_id)

      installation =
        GitHubAppInstallation
        |> where([record], record.github_installation_id == ^installation_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      result =
        case installation do
          nil ->
            {:error, :not_found}

          %GitHubAppInstallation{} = installation ->
            cond do
              not DateTime.after?(observed_at, installation.last_verified_at) ->
                {:ok, installation}

              GitHubAppInstallation.legal_transition?(installation.state, target) ->
                installation
                |> GitHubAppInstallation.update_observation_changeset(%{
                  state: target,
                  last_verified_at: observed_at
                })
                |> Repo.update()

              true ->
                {:error, :invalid_transition}
            end
        end

      case result do
        {:ok, updated} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp observe_existing(installation, attrs) do
    account_id = fetch_attr(attrs, :github_account_id)
    account_type = fetch_attr(attrs, :account_type)
    observed_at = fetch_attr(attrs, :last_verified_at)
    target_state = fetch_attr(attrs, :state)

    cond do
      installation.github_account_id != account_id or installation.account_type != account_type ->
        {:error, :identity_mismatch}

      not match?(%DateTime{}, observed_at) ->
        {:error, :invalid_transition}

      not DateTime.after?(observed_at, installation.last_verified_at) ->
        {:ok, installation}

      installation.state == :revoked ->
        {:error, :invalid_transition}

      not GitHubAppInstallation.legal_transition?(installation.state, target_state) ->
        {:error, :invalid_transition}

      true ->
        installation
        |> GitHubAppInstallation.update_observation_changeset(attrs)
        |> Repo.update()
    end
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp normalized_installation_observation(changeset) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.take([
      :github_installation_id,
      :github_account_id,
      :github_account_login,
      :account_type,
      :repository_selection,
      :permissions,
      :state,
      :last_verified_at
    ])
  end

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp lock_github_installation_identity!(installation_id) do
    if Repo.__adapter__() == Ecto.Adapters.Postgres do
      Ecto.Adapters.SQL.query!(Repo, "select pg_advisory_xact_lock($1)", [installation_id])
    end

    :ok
  end

  @spec enqueue_webhook_delivery(map(), atom()) ::
          {:ok, MirrorWebhookDelivery.t(), :enqueued | :duplicate}
          | {:error, Ecto.Changeset.t() | :delivery_collision | :invalid_argument | :unavailable}
  def enqueue_webhook_delivery(attrs, state)
      when is_map(attrs) and state in [:pending, :pending_unsupported, :ignored] do
    Repo.transaction(fn ->
      now = database_now!()

      persisted_attrs =
        attrs
        |> Map.put(:state, state)
        |> Map.put(:attempt_count, 0)
        |> Map.put(:internal_failure_count, 0)
        |> Map.put(:next_attempt_at, now)
        |> Map.put(:received_at, now)
        |> Map.put(:processed_at, if(state == :ignored, do: now, else: nil))
        |> Map.put(:lease_owner, nil)
        |> Map.put(:lease_expires_at, nil)
        |> Map.put(:failure_class, nil)
        |> Map.put(:lock_version, 1)

      changeset =
        MirrorWebhookDelivery.persistence_changeset(%MirrorWebhookDelivery{}, persisted_attrs)

      result =
        if changeset.valid? do
          delivery_guid = Ecto.Changeset.get_field(changeset, :delivery_guid)
          lock_webhook_delivery_guid!(delivery_guid)

          case Repo.get_by(MirrorWebhookDelivery, delivery_guid: delivery_guid) do
            nil ->
              case Repo.insert(changeset) do
                {:ok, delivery} -> {:ok, delivery, :enqueued}
                {:error, %Ecto.Changeset{} = invalid} -> {:error, invalid}
              end

            existing ->
              compare_webhook_redelivery(existing, persisted_attrs)
          end
        else
          {:error, changeset}
        end

      case result do
        {:ok, delivery, status} -> {delivery, status}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {delivery, status}} -> {:ok, delivery, status}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def enqueue_webhook_delivery(_attrs, _state), do: {:error, :invalid_argument}

  @spec get_webhook_delivery(String.t()) ::
          {:ok, MirrorWebhookDelivery.t()} | {:error, :not_found | :invalid_argument}
  def get_webhook_delivery(delivery_guid)
      when is_binary(delivery_guid) and byte_size(delivery_guid) in 1..255 do
    case Repo.get_by(MirrorWebhookDelivery, delivery_guid: delivery_guid) do
      nil -> {:error, :not_found}
      delivery -> {:ok, delivery}
    end
  end

  def get_webhook_delivery(_delivery_guid), do: {:error, :invalid_argument}

  @spec claim_webhook_deliveries(String.t(), pos_integer(), pos_integer()) ::
          {:ok, [MirrorWebhookDelivery.t()]} | {:error, :invalid_argument | :unavailable}
  def claim_webhook_deliveries(owner, lease_seconds, limit)
      when is_binary(owner) and is_integer(lease_seconds) and is_integer(limit),
      do:
        claim_webhook_deliveries(
          owner,
          lease_seconds,
          limit,
          1,
          webhook_max_internal_attempts()
        )

  def claim_webhook_deliveries(_owner, _lease_seconds, _limit),
    do: {:error, :invalid_argument}

  @spec claim_webhook_deliveries(String.t(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, [MirrorWebhookDelivery.t()]} | {:error, :invalid_argument | :unavailable}
  def claim_webhook_deliveries(owner, lease_seconds, limit, max_per_installation)
      when is_binary(owner) and is_integer(lease_seconds) and is_integer(limit) and
             is_integer(max_per_installation),
      do:
        claim_webhook_deliveries(
          owner,
          lease_seconds,
          limit,
          max_per_installation,
          webhook_max_internal_attempts()
        )

  def claim_webhook_deliveries(_owner, _lease_seconds, _limit, _max_per_installation),
    do: {:error, :invalid_argument}

  @doc false
  @spec claim_webhook_deliveries(
          String.t(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, [MirrorWebhookDelivery.t()]} | {:error, :invalid_argument | :unavailable}
  def claim_webhook_deliveries(
        owner,
        lease_seconds,
        limit,
        max_per_installation,
        max_internal_attempts
      )
      when is_binary(owner) and is_integer(lease_seconds) and lease_seconds in 1..3_600 and
             is_integer(limit) and limit in 1..@max_claim_batch and
             is_integer(max_per_installation) and max_per_installation in 1..@max_claim_batch and
             is_integer(max_internal_attempts) and max_internal_attempts in 1..1_000 do
    with :ok <- validate_owner(owner) do
      Repo.transaction(fn ->
        now = database_now!()
        recover_expired_webhook_deliveries!(now, max_internal_attempts)
        # `:utc_datetime` truncates fractional seconds. One extra stored second
        # keeps the requested lease duration from being shortened by that truncation.
        expires_at = DateTime.add(now, lease_seconds + 1, :second)

        claim_due_webhook_deliveries(
          owner,
          now,
          expires_at,
          limit,
          max_per_installation
        )
      end)
      |> case do
        {:ok, deliveries} -> {:ok, deliveries}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def claim_webhook_deliveries(
        _owner,
        _lease_seconds,
        _limit,
        _max_per_installation,
        _max_internal_attempts
      ),
      do: {:error, :invalid_argument}

  @spec complete_webhook_delivery(MirrorWebhookDelivery.t(), String.t()) ::
          {:ok, MirrorWebhookDelivery.t()}
          | {:error, :invalid_argument | :invalid_transition | :lost_lease}
  def complete_webhook_delivery(%MirrorWebhookDelivery{state: :processing} = delivery, owner) do
    owned_webhook_transition(delivery, owner,
      state: :completed,
      processed_at: :server_now,
      lease_owner: nil,
      lease_expires_at: nil,
      failure_class: nil,
      internal_failure_count: 0
    )
  end

  def complete_webhook_delivery(%MirrorWebhookDelivery{}, _owner),
    do: {:error, :invalid_transition}

  def complete_webhook_delivery(_delivery, _owner), do: {:error, :invalid_argument}

  @spec ignore_webhook_delivery(MirrorWebhookDelivery.t(), String.t()) ::
          {:ok, MirrorWebhookDelivery.t()}
          | {:error, :invalid_argument | :invalid_transition | :lost_lease}
  def ignore_webhook_delivery(%MirrorWebhookDelivery{state: :processing} = delivery, owner) do
    owned_webhook_transition(delivery, owner,
      state: :ignored,
      processed_at: :server_now,
      lease_owner: nil,
      lease_expires_at: nil,
      failure_class: nil,
      internal_failure_count: 0
    )
  end

  def ignore_webhook_delivery(%MirrorWebhookDelivery{}, _owner),
    do: {:error, :invalid_transition}

  def ignore_webhook_delivery(_delivery, _owner), do: {:error, :invalid_argument}

  @spec defer_webhook_delivery(MirrorWebhookDelivery.t(), String.t()) ::
          {:ok, MirrorWebhookDelivery.t()}
          | {:error, :invalid_argument | :invalid_transition | :lost_lease}
  def defer_webhook_delivery(%MirrorWebhookDelivery{state: :processing} = delivery, owner) do
    owned_webhook_transition(delivery, owner,
      state: :pending_unsupported,
      processed_at: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      failure_class: nil,
      internal_failure_count: 0
    )
  end

  def defer_webhook_delivery(%MirrorWebhookDelivery{}, _owner),
    do: {:error, :invalid_transition}

  def defer_webhook_delivery(_delivery, _owner), do: {:error, :invalid_argument}

  @spec retry_webhook_delivery(
          MirrorWebhookDelivery.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) ::
          {:ok, MirrorWebhookDelivery.t()}
          | {:error, :invalid_argument | :invalid_transition | :lost_lease}
  def retry_webhook_delivery(
        %MirrorWebhookDelivery{state: :processing} = delivery,
        owner,
        failure_class,
        delay_seconds
      )
      when is_integer(delay_seconds),
      do: retry_webhook_delivery(delivery, owner, failure_class, delay_seconds, 0)

  def retry_webhook_delivery(%MirrorWebhookDelivery{}, _owner, _failure_class, _delay_seconds),
    do: {:error, :invalid_transition}

  def retry_webhook_delivery(_delivery, _owner, _failure_class, _delay_seconds),
    do: {:error, :invalid_argument}

  @doc false
  @spec retry_webhook_delivery(
          MirrorWebhookDelivery.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, MirrorWebhookDelivery.t()}
          | {:error, :invalid_argument | :invalid_transition | :lost_lease}
  def retry_webhook_delivery(
        %MirrorWebhookDelivery{state: :processing} = delivery,
        owner,
        failure_class,
        delay_seconds,
        internal_failure_count
      )
      when is_integer(delay_seconds) and delay_seconds in 0..86_400 and
             is_integer(internal_failure_count) and internal_failure_count in 0..1_000 do
    with :ok <- validate_webhook_failure_class(failure_class) do
      owned_webhook_transition(delivery, owner,
        state: :pending,
        next_attempt_at: {:server_after, delay_seconds},
        processed_at: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        failure_class: failure_class,
        internal_failure_count: internal_failure_count
      )
    end
  end

  def retry_webhook_delivery(
        %MirrorWebhookDelivery{},
        _owner,
        _failure_class,
        _delay_seconds,
        _internal_failure_count
      ),
      do: {:error, :invalid_transition}

  def retry_webhook_delivery(
        _delivery,
        _owner,
        _failure_class,
        _delay_seconds,
        _internal_failure_count
      ),
      do: {:error, :invalid_argument}

  @spec fail_webhook_delivery(MirrorWebhookDelivery.t(), String.t(), String.t()) ::
          {:ok, MirrorWebhookDelivery.t()}
          | {:error, :invalid_argument | :invalid_transition | :lost_lease}
  def fail_webhook_delivery(
        %MirrorWebhookDelivery{state: :processing} = delivery,
        owner,
        failure_class
      ),
      do: fail_webhook_delivery(delivery, owner, failure_class, 0)

  def fail_webhook_delivery(%MirrorWebhookDelivery{}, _owner, _failure_class),
    do: {:error, :invalid_transition}

  def fail_webhook_delivery(_delivery, _owner, _failure_class),
    do: {:error, :invalid_argument}

  @doc false
  @spec fail_webhook_delivery(
          MirrorWebhookDelivery.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) ::
          {:ok, MirrorWebhookDelivery.t()}
          | {:error, :invalid_argument | :invalid_transition | :lost_lease}
  def fail_webhook_delivery(
        %MirrorWebhookDelivery{state: :processing} = delivery,
        owner,
        failure_class,
        internal_failure_count
      )
      when is_integer(internal_failure_count) and internal_failure_count in 0..1_000 do
    with :ok <- validate_webhook_failure_class(failure_class) do
      owned_webhook_transition(delivery, owner,
        state: :failed,
        processed_at: :server_now,
        lease_owner: nil,
        lease_expires_at: nil,
        failure_class: failure_class,
        internal_failure_count: internal_failure_count
      )
    end
  end

  def fail_webhook_delivery(
        %MirrorWebhookDelivery{},
        _owner,
        _failure_class,
        _internal_failure_count
      ),
      do: {:error, :invalid_transition}

  def fail_webhook_delivery(_delivery, _owner, _failure_class, _internal_failure_count),
    do: {:error, :invalid_argument}

  @spec recover_expired_webhook_deliveries() ::
          {:ok, non_neg_integer()} | {:error, :unavailable}
  def recover_expired_webhook_deliveries do
    Repo.transaction(fn ->
      now = database_now!()
      recover_expired_webhook_deliveries!(now, webhook_max_internal_attempts())
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  @doc false
  @spec retain_webhook_inventory_trigger(pos_integer(), String.t()) ::
          {:ok, :deferred | {:scheduled, MirrorOperation.t()}}
          | {:error, :invalid_argument | :unavailable | term()}
  def retain_webhook_inventory_trigger(installation_id, delivery_guid)
      when is_integer(installation_id) and installation_id > 0 and is_binary(delivery_guid) and
             byte_size(delivery_guid) in 1..255 do
    Repo.transaction(fn ->
      mirror =
        OrganizationMirror
        |> where(
          [candidate],
          candidate.provider == "github" and
            candidate.github_installation_id == ^installation_id and
            candidate.state != :revoked
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      case mirror do
        nil ->
          :deferred

        %OrganizationMirror{} = mirror ->
          now = database_now!()

          with {:ok, operation} <-
                 enqueue_operation(%{
                   organization_mirror_id: mirror.id,
                   kind: "reconcile.organization_inventory",
                   dedupe_key: "webhook:#{delivery_guid}:organization_inventory",
                   cursor: %{"delivery_guid" => delivery_guid},
                   next_attempt_at: now
                 }),
               {:ok, _updated} <-
                 mirror
                 |> OrganizationMirror.update_changeset(%{last_webhook_at: now})
                 |> cas_update() do
            {:scheduled, operation}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def retain_webhook_inventory_trigger(_installation_id, _delivery_guid),
    do: {:error, :invalid_argument}

  @doc false
  @spec revoke_bound_organization_from_webhook(pos_integer()) ::
          {:ok, :unbound | OrganizationMirror.t()}
          | {:error, :invalid_argument | :unavailable | :invalid_transition}
  def revoke_bound_organization_from_webhook(installation_id)
      when is_integer(installation_id) and installation_id > 0 do
    Repo.transaction(fn ->
      mirror =
        OrganizationMirror
        |> where(
          [candidate],
          candidate.provider == "github" and
            candidate.github_installation_id == ^installation_id
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      case mirror do
        nil ->
          :unbound

        %OrganizationMirror{state: :revoked} = mirror ->
          mirror

        %OrganizationMirror{} = mirror ->
          if OrganizationMirror.legal_transition?(mirror.state, :revoked) do
            now = database_now!()

            mirror
            |> OrganizationMirror.transition_changeset(:revoked)
            |> Ecto.Changeset.put_change(:last_webhook_at, now)
            |> cas_update()
            |> case do
              {:ok, revoked} -> revoked
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            Repo.rollback(:invalid_transition)
          end
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, :invalid_transition} -> {:error, :invalid_transition}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def revoke_bound_organization_from_webhook(_installation_id),
    do: {:error, :invalid_argument}

  @spec create_organization_mirror(ForgeAccounts.User.t(), map()) ::
          {:ok, OrganizationMirror.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def create_organization_mirror(actor, attrs) when is_map(attrs) do
    changeset = OrganizationMirror.create_changeset(%OrganizationMirror{}, attrs)

    if changeset.valid? do
      organization_id = Ecto.Changeset.get_field(changeset, :organization_id)

      with {:ok, _organization} <-
             ForgeAccounts.fetch_manageable_organization(actor, organization_id) do
        Repo.insert(changeset)
      end
    else
      {:error, changeset}
    end
  end

  def create_organization_mirror(_actor, _attrs), do: {:error, :forbidden}

  @spec get_organization_mirror(pos_integer()) ::
          {:ok, OrganizationMirror.t()} | {:error, :not_found | :invalid_argument}
  def get_organization_mirror(id) when is_integer(id) and id > 0 do
    case Repo.get(OrganizationMirror, id) do
      nil -> {:error, :not_found}
      mirror -> {:ok, mirror}
    end
  end

  def get_organization_mirror(_id), do: {:error, :invalid_argument}

  @spec get_organization_mirror_for_organization(pos_integer(), String.t()) ::
          {:ok, OrganizationMirror.t()} | {:error, :not_found | :invalid_argument}
  def get_organization_mirror_for_organization(organization_id, provider \\ "github")

  def get_organization_mirror_for_organization(organization_id, provider)
      when is_integer(organization_id) and organization_id > 0 and is_binary(provider) do
    query =
      from mirror in OrganizationMirror,
        where:
          mirror.organization_id == ^organization_id and mirror.provider == ^provider and
            mirror.state != :revoked,
        order_by: [desc: mirror.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      mirror -> {:ok, mirror}
    end
  end

  def get_organization_mirror_for_organization(_organization_id, _provider),
    do: {:error, :invalid_argument}

  @spec organization_settings(ForgeAccounts.User.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def organization_settings(actor, organization_id),
    do: ForgeMirrors.Settings.view(actor, organization_id)

  @spec update_organization_settings(ForgeAccounts.User.t(), pos_integer(), map()) ::
          {:ok, OrganizationMirror.t()} | {:error, term()}
  def update_organization_settings(actor, organization_id, attrs),
    do: ForgeMirrors.Settings.update(actor, organization_id, attrs)

  @spec update_organization_mirror(ForgeAccounts.User.t(), OrganizationMirror.t(), map()) ::
          {:ok, OrganizationMirror.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found | :stale}
  def update_organization_mirror(actor, %OrganizationMirror{} = mirror, attrs)
      when is_map(attrs) do
    with {:ok, persisted} <- load_organization_mirror_capability(mirror),
         {:ok, _organization} <- authorize_organization_mirror(actor, persisted),
         :ok <- validate_capability_version(mirror, persisted) do
      persisted
      |> OrganizationMirror.update_changeset(attrs)
      |> cas_update()
    end
  end

  def update_organization_mirror(_actor, _mirror, _attrs), do: {:error, :forbidden}

  @spec transition_organization_mirror(
          ForgeAccounts.User.t(),
          OrganizationMirror.t(),
          atom()
        ) ::
          {:ok, OrganizationMirror.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :invalid_transition | :not_found | :stale}
  def transition_organization_mirror(actor, %OrganizationMirror{} = mirror, target) do
    with {:ok, persisted} <- load_organization_mirror_capability(mirror),
         {:ok, _organization} <- authorize_organization_mirror(actor, persisted),
         :ok <- validate_capability_version(mirror, persisted) do
      if OrganizationMirror.legal_transition?(persisted.state, target) and
           (persisted.state != :paused or target == :revoked) do
        persisted
        |> OrganizationMirror.transition_changeset(target)
        |> cas_update()
      else
        {:error, :invalid_transition}
      end
    end
  end

  def transition_organization_mirror(_actor, _mirror, _target), do: {:error, :forbidden}

  @spec pause(ForgeAccounts.User.t(), OrganizationMirror.t()) ::
          {:ok, OrganizationMirror.t()}
          | {:error, :forbidden | :invalid_transition | :not_found | :stale}
  def pause(actor, %OrganizationMirror{} = mirror) do
    with {:ok, persisted} <- load_organization_mirror_capability(mirror),
         {:ok, _organization} <- authorize_organization_mirror(actor, persisted),
         :ok <- validate_capability_version(mirror, persisted) do
      if OrganizationMirror.legal_transition?(persisted.state, :paused) do
        persisted
        |> OrganizationMirror.transition_changeset(:paused, persisted.state)
        |> cas_update()
      else
        {:error, :invalid_transition}
      end
    end
  end

  def pause(_actor, _mirror), do: {:error, :forbidden}

  @spec resume(ForgeAccounts.User.t(), OrganizationMirror.t()) ::
          {:ok, OrganizationMirror.t()}
          | {:error, :forbidden | :invalid_transition | :not_found | :stale}
  def resume(actor, %OrganizationMirror{} = mirror) do
    with {:ok, persisted} <- load_organization_mirror_capability(mirror),
         {:ok, _organization} <- authorize_organization_mirror(actor, persisted),
         :ok <- validate_capability_version(mirror, persisted) do
      case persisted do
        %OrganizationMirror{state: :paused, resume_state: target} when not is_nil(target) ->
          if OrganizationMirror.legal_transition?(:paused, target) do
            persisted
            |> OrganizationMirror.transition_changeset(target)
            |> cas_update()
          else
            {:error, :invalid_transition}
          end

        _other ->
          {:error, :invalid_transition}
      end
    end
  end

  def resume(_actor, _mirror), do: {:error, :forbidden}

  @spec bind_repository(ForgeAccounts.User.t(), map()) ::
          {:ok, RepositoryMirror.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def bind_repository(actor, attrs) when is_map(attrs) do
    changeset = RepositoryMirror.create_changeset(%RepositoryMirror{}, attrs)

    if changeset.valid? do
      with {:ok, organization_mirror} <- load_binding_organization_mirror(changeset),
           {:ok, _organization} <- authorize_organization_mirror(actor, organization_mirror),
           {:ok, _validated_mirror} <- validate_repository_binding_scope(changeset) do
        Repo.insert(changeset)
      end
    else
      {:error, changeset}
    end
  end

  def bind_repository(_actor, _attrs), do: {:error, :forbidden}

  @spec get_repository_mirror(pos_integer()) ::
          {:ok, RepositoryMirror.t()} | {:error, :not_found | :invalid_argument}
  def get_repository_mirror(id) when is_integer(id) and id > 0 do
    case Repo.get(RepositoryMirror, id) do
      nil -> {:error, :not_found}
      mirror -> {:ok, mirror}
    end
  end

  def get_repository_mirror(_id), do: {:error, :invalid_argument}

  @spec update_repository_mirror(ForgeAccounts.User.t(), RepositoryMirror.t(), map()) ::
          {:ok, RepositoryMirror.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found | :stale}
  def update_repository_mirror(actor, %RepositoryMirror{} = mirror, attrs)
      when is_map(attrs) do
    with {:ok, persisted} <- load_repository_mirror_capability(mirror),
         {:ok, organization_mirror} <- load_repository_organization_mirror(persisted),
         {:ok, _organization} <- authorize_organization_mirror(actor, organization_mirror),
         :ok <- validate_capability_version(mirror, persisted) do
      changeset = RepositoryMirror.update_changeset(persisted, attrs)

      if changeset.valid? do
        with {:ok, _organization_mirror} <- validate_repository_binding_scope(changeset) do
          cas_update(changeset)
        end
      else
        {:error, changeset}
      end
    end
  end

  def update_repository_mirror(_actor, _mirror, _attrs), do: {:error, :forbidden}

  @spec transition_repository_mirror(
          ForgeAccounts.User.t(),
          RepositoryMirror.t(),
          atom()
        ) ::
          {:ok, RepositoryMirror.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :invalid_transition | :not_found | :stale}
  def transition_repository_mirror(actor, %RepositoryMirror{} = mirror, target) do
    with {:ok, persisted} <- load_repository_mirror_capability(mirror),
         {:ok, organization_mirror} <- load_repository_organization_mirror(persisted),
         {:ok, _organization} <- authorize_organization_mirror(actor, organization_mirror),
         :ok <- validate_capability_version(mirror, persisted) do
      if RepositoryMirror.legal_transition?(persisted.state, target) do
        persisted
        |> RepositoryMirror.transition_changeset(target)
        |> cas_update()
      else
        {:error, :invalid_transition}
      end
    end
  end

  def transition_repository_mirror(_actor, _mirror, _target), do: {:error, :forbidden}

  @spec enqueue_operation(map()) ::
          {:ok, MirrorOperation.t()}
          | {:error, Ecto.Changeset.t() | :dedupe_conflict | :not_found}
  def enqueue_operation(attrs) when is_map(attrs) do
    attrs = canonicalize_cursor(attrs)
    changeset = MirrorOperation.enqueue_changeset(%MirrorOperation{}, attrs)

    if changeset.valid? do
      case validate_operation_scope(changeset) do
        :ok -> insert_idempotent_operation(changeset)
        error -> error
      end
    else
      {:error, changeset}
    end
  end

  def enqueue_operation(_attrs), do: invalid_changeset(%MirrorOperation{})

  @spec claim_operations(String.t(), DateTime.t(), pos_integer(), pos_integer()) ::
          {:ok, [MirrorOperation.t()]} | {:error, :invalid_argument | :unavailable}
  def claim_operations(owner, %DateTime{} = now, lease_seconds, limit)
      when is_binary(owner) and is_integer(lease_seconds) and lease_seconds > 0 and
             is_integer(limit) and limit in 1..@max_claim_batch do
    do_claim_operations(owner, now, lease_seconds, limit, nil)
  end

  def claim_operations(_owner, _now, _lease_seconds, _limit), do: {:error, :invalid_argument}

  @doc "Claims only operations whose kind is in the bounded allowlist."
  @spec claim_operations(String.t(), DateTime.t(), pos_integer(), pos_integer(), [String.t()]) ::
          {:ok, [MirrorOperation.t()]} | {:error, :invalid_argument | :unavailable}
  def claim_operations(owner, %DateTime{} = now, lease_seconds, limit, kinds)
      when is_binary(owner) and is_integer(lease_seconds) and lease_seconds > 0 and
             is_integer(limit) and limit in 1..@max_claim_batch and is_list(kinds) do
    with :ok <- validate_operation_kinds(kinds) do
      do_claim_operations(owner, now, lease_seconds, limit, kinds)
    end
  end

  def claim_operations(_owner, _now, _lease_seconds, _limit, _kinds),
    do: {:error, :invalid_argument}

  @doc false
  @spec inventory_operation_context(MirrorOperation.t()) ::
          {:ok,
           %{
             cursor: pos_integer(),
             github_account_id: pos_integer(),
             github_installation_id: pos_integer(),
             installation_selection: :all | :selected,
             sweep_marker: String.t()
           }}
          | {:error, :lost_lease | :invalid_transition | :invalid_policy}
  def inventory_operation_context(%MirrorOperation{} = operation) do
    Repo.transaction(fn ->
      with :ok <- lock_inventory_organization(operation),
           {:ok, persisted} <- load_owned_inventory_operation(operation),
           {:ok, organization, installation, _policy} <-
             load_inventory_scope(persisted.organization_mirror_id),
           {:ok, cursor} <- inventory_checkpoint_cursor(persisted.checkpoint) do
        %{
          cursor: cursor,
          github_account_id: organization.github_account_id,
          github_installation_id: organization.github_installation_id,
          installation_selection: installation.repository_selection,
          sweep_marker: inventory_sweep_marker(persisted.id)
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    _exception -> {:error, :lost_lease}
  end

  def inventory_operation_context(_operation), do: {:error, :invalid_transition}

  @doc false
  @spec record_inventory_page(
          MirrorOperation.t(),
          [map()],
          pos_integer() | nil,
          DateTime.t()
        ) ::
          {:ok, %{operation: MirrorOperation.t(), classifications: map()}}
          | {:error,
             Ecto.Changeset.t()
             | :identity_conflict
             | :invalid_argument
             | :invalid_policy
             | :invalid_transition
             | :lost_lease}
  def record_inventory_page(
        %MirrorOperation{} = operation,
        repositories,
        next_cursor,
        %DateTime{} = observed_at
      )
      when is_list(repositories) and length(repositories) <= 100 and
             (is_nil(next_cursor) or
                (is_integer(next_cursor) and next_cursor in 2..100)) do
    with :ok <- validate_utc(observed_at),
         {:ok, observations} <- normalize_inventory_repositories(repositories) do
      Repo.transaction(fn ->
        with :ok <- lock_inventory_organization(operation),
             {:ok, persisted} <- load_owned_inventory_operation(operation),
             {:ok, organization, installation, policy} <-
               load_inventory_scope(persisted.organization_mirror_id),
             {:ok, cursor} <- inventory_checkpoint_cursor(persisted.checkpoint),
             :ok <- validate_inventory_next_cursor(cursor, next_cursor),
             sweep_marker = inventory_sweep_marker(persisted.id),
             {:ok, classifications} <-
               persist_inventory_repositories(
                 organization,
                 installation,
                 policy,
                 observations,
                 sweep_marker,
                 observed_at
               ),
             {:ok, classifications} <-
               maybe_finish_inventory_sweep(
                 organization,
                 next_cursor,
                 sweep_marker,
                 observed_at,
                 classifications
               ),
             {:ok, updated_operation} <-
               persist_inventory_checkpoint(persisted, next_cursor, sweep_marker, observed_at) do
          %{operation: updated_operation, classifications: classifications}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction_result()
    end
  rescue
    _exception -> {:error, :lost_lease}
  end

  def record_inventory_page(_operation, _repositories, _next_cursor, _observed_at),
    do: {:error, :invalid_argument}

  @spec mark_external_effect(MirrorOperation.t(), DateTime.t(), map()) ::
          {:ok, MirrorOperation.t()}
          | {:error, :lost_lease | :invalid_transition | :invalid_argument | :paused}
  def mark_external_effect(
        %MirrorOperation{state: :processing} = operation,
        %DateTime{} = now,
        marker
      )
      when is_map(marker) and map_size(marker) > 0 do
    with :ok <- validate_utc(now), :ok <- validate_bounded_object(marker) do
      now = DateTime.truncate(now, :second)

      Repo.transaction(fn ->
        with :ok <- lock_effect_scope(operation),
             {:ok, marked} <-
               owned_transition(operation, now, [:processing],
                 state: :effect_pending,
                 external_effect_marker: canonical_map(marker),
                 effect_marked_at: now
               ) do
          marked
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, marked} ->
          {:ok, marked}

        {:error, reason} when reason in [:lost_lease, :invalid_transition, :paused] ->
          {:error, reason}

        {:error, _reason} ->
          {:error, :lost_lease}
      end
    end
  rescue
    _ -> {:error, :lost_lease}
  end

  def mark_external_effect(%MirrorOperation{}, %DateTime{}, _marker),
    do: {:error, :invalid_transition}

  def mark_external_effect(_operation, _now, _marker), do: {:error, :invalid_argument}

  @spec failure_disposition(String.t()) ::
          {:ok, :retry | :degraded | :conflict | :terminal} | {:error, :invalid_argument}
  def failure_disposition(failure_class) do
    case MirrorOperation.failure_disposition(failure_class) do
      {:ok, disposition} -> {:ok, disposition}
      :error -> {:error, :invalid_argument}
    end
  end

  @spec complete_operation(MirrorOperation.t(), DateTime.t()) ::
          {:ok, MirrorOperation.t()}
          | {:error, :lost_lease | :invalid_transition | :invalid_argument}
  def complete_operation(%MirrorOperation{state: state} = operation, %DateTime{} = now)
      when state in [:processing, :effect_pending] do
    with :ok <- validate_utc(now) do
      now = DateTime.truncate(now, :second)

      owned_transition(operation, now, [state],
        state: :completed,
        lease_owner: nil,
        lease_expires_at: nil,
        external_effect_marker: nil,
        effect_marked_at: nil,
        completed_at: now,
        failure_class: nil,
        failure_disposition: nil,
        failure_detail: nil
      )
    end
  end

  def complete_operation(%MirrorOperation{}, %DateTime{}), do: {:error, :invalid_transition}
  def complete_operation(_operation, _now), do: {:error, :invalid_argument}

  @spec retry_operation(
          MirrorOperation.t(),
          DateTime.t(),
          DateTime.t(),
          String.t() | nil,
          keyword()
        ) ::
          {:ok, MirrorOperation.t()}
          | {:error, :lost_lease | :invalid_transition | :invalid_argument}
  def retry_operation(operation, now, next_attempt_at, failure_class, options \\ [])

  def retry_operation(
        %MirrorOperation{state: state} = operation,
        %DateTime{} = now,
        %DateTime{} = next_attempt_at,
        failure_class,
        options
      )
      when state in [:processing, :effect_pending] and is_list(options) do
    with :ok <- validate_utc(now),
         :ok <- validate_utc(next_attempt_at),
         :ok <- validate_retryable_failure_class(failure_class),
         :ok <- validate_keyword(options),
         :ok <- validate_failure_detail(Keyword.get(options, :failure_detail)),
         :ok <- validate_effect_retry(state, options) do
      owned_transition(operation, DateTime.truncate(now, :second), [state],
        state: :pending,
        next_attempt_at: DateTime.truncate(next_attempt_at, :second),
        lease_owner: nil,
        lease_expires_at: nil,
        external_effect_marker: nil,
        effect_marked_at: nil,
        failure_class: failure_class,
        failure_disposition: :retry,
        failure_detail: Keyword.get(options, :failure_detail)
      )
    end
  end

  def retry_operation(%MirrorOperation{}, %DateTime{}, %DateTime{}, _failure_class, _options),
    do: {:error, :invalid_transition}

  def retry_operation(_operation, _now, _next_attempt_at, _failure_class, _options),
    do: {:error, :invalid_argument}

  @spec fail_operation(MirrorOperation.t(), DateTime.t(), String.t(), String.t() | nil) ::
          {:ok, MirrorOperation.t()}
          | {:error, :lost_lease | :invalid_transition | :invalid_argument}
  def fail_operation(operation, now, failure_class, failure_detail \\ nil)

  def fail_operation(
        %MirrorOperation{state: state} = operation,
        %DateTime{} = now,
        failure_class,
        failure_detail
      )
      when state in [:processing, :effect_pending] do
    with :ok <- validate_utc(now),
         {:ok, failure_disposition} <- nonretryable_failure_disposition(failure_class),
         :ok <- validate_failure_detail(failure_detail) do
      owned_transition(operation, DateTime.truncate(now, :second), [state],
        state: :failed,
        lease_owner: nil,
        lease_expires_at: nil,
        external_effect_marker: nil,
        effect_marked_at: nil,
        failure_class: failure_class,
        failure_disposition: failure_disposition,
        failure_detail: failure_detail
      )
    end
  end

  def fail_operation(%MirrorOperation{}, %DateTime{}, _failure_class, _failure_detail),
    do: {:error, :invalid_transition}

  def fail_operation(_operation, _now, _failure_class, _failure_detail),
    do: {:error, :invalid_argument}

  @spec recover_expired_operations(DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_argument | :unavailable}
  def recover_expired_operations(%DateTime{} = now) do
    with :ok <- validate_utc(now) do
      now = DateTime.truncate(now, :second)

      Repo.transaction(fn ->
        {processing_count, _} =
          MirrorOperation
          |> where(
            [operation],
            operation.state == :processing and operation.lease_expires_at <= ^now
          )
          |> Repo.update_all(
            set: [
              state: :pending,
              next_attempt_at: now,
              lease_owner: nil,
              lease_expires_at: nil,
              updated_at: now
            ],
            inc: [lock_version: 1]
          )

        {effect_count, _} =
          MirrorOperation
          |> where(
            [operation],
            operation.state == :effect_pending and not is_nil(operation.lease_expires_at) and
              operation.lease_expires_at <= ^now
          )
          |> Repo.update_all(
            set: [lease_owner: nil, lease_expires_at: nil, updated_at: now],
            inc: [lock_version: 1]
          )

        processing_count + effect_count
      end)
      |> case do
        {:ok, count} -> {:ok, count}
        {:error, _} -> {:error, :unavailable}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def recover_expired_operations(_now), do: {:error, :invalid_argument}

  @spec record_conflict(map()) ::
          {:ok, MirrorConflict.t()}
          | {:error, Ecto.Changeset.t() | :dedupe_conflict | :not_found}
  def record_conflict(attrs) when is_map(attrs) do
    changeset = MirrorConflict.record_changeset(%MirrorConflict{}, attrs)

    if changeset.valid? do
      with :ok <- validate_conflict_scope(changeset) do
        case Repo.insert(changeset) do
          {:ok, conflict} -> {:ok, conflict}
          {:error, %Ecto.Changeset{} = invalid} -> conflict_insert_error(invalid, attrs)
        end
      end
    else
      {:error, changeset}
    end
  end

  def record_conflict(_attrs), do: invalid_changeset(%MirrorConflict{})

  @spec resolve_conflict(
          ForgeAccounts.User.t(),
          MirrorConflict.t(),
          map(),
          DateTime.t()
        ) ::
          {:ok, MirrorConflict.t()}
          | {:error,
             Ecto.Changeset.t()
             | :forbidden
             | :invalid_transition
             | :not_found
             | :stale
             | :invalid_argument}
  def resolve_conflict(
        %ForgeAccounts.User{id: actor_id} = actor,
        %MirrorConflict{} = conflict,
        resolution,
        %DateTime{} = now
      )
      when is_integer(actor_id) and is_map(resolution) do
    with {:ok, persisted} <- load_conflict_capability(conflict),
         {:ok, organization_mirror} <- load_conflict_organization_mirror(persisted),
         {:ok, _organization} <- authorize_organization_mirror(actor, organization_mirror),
         :ok <- validate_utc(now) do
      resolution = canonical_map(resolution)

      case persisted do
        %MirrorConflict{state: :open} ->
          with :ok <- validate_capability_version(conflict, persisted) do
            persisted
            |> MirrorConflict.resolve_changeset(
              resolution,
              actor_id,
              DateTime.truncate(now, :second)
            )
            |> cas_update()
            |> resolve_idempotently(persisted.id, resolution)
          end

        %MirrorConflict{state: :resolved, resolution: ^resolution} ->
          {:ok, persisted}

        %MirrorConflict{} ->
          {:error, :invalid_transition}
      end
    end
  end

  def resolve_conflict(_actor, _conflict, _resolution, _now), do: {:error, :forbidden}

  @spec organization_status(pos_integer()) ::
          {:ok, map()} | {:error, :not_found | :invalid_argument}
  def organization_status(id) when is_integer(id) and id > 0 do
    with {:ok, mirror} <- get_organization_mirror(id) do
      repository_states = grouped_counts(RepositoryMirror, :organization_mirror_id, id)
      operation_counts = grouped_counts(MirrorOperation, :organization_mirror_id, id)

      conflict_count =
        Repo.aggregate(
          from(conflict in MirrorConflict,
            where: conflict.organization_mirror_id == ^id and conflict.state == :open
          ),
          :count
        )

      {:ok,
       %{
         mirror: mirror,
         repository_states: repository_states,
         operation_counts: operation_counts,
         open_conflicts: conflict_count,
         last_webhook_at: mirror.last_webhook_at,
         last_reconciled_at: mirror.last_reconciled_at,
         next_reconcile_at: mirror.next_reconcile_at
       }}
    end
  end

  def organization_status(_id), do: {:error, :invalid_argument}

  @spec list_organization_status(pos_integer()) ::
          {:ok, map()} | {:error, :not_found | :invalid_argument}
  def list_organization_status(id), do: organization_status(id)

  @spec schedule_reconciliation(
          ForgeAccounts.User.t(),
          OrganizationMirror.t(),
          DateTime.t()
        ) ::
          {:ok, MirrorOperation.t()} | {:error, term()}
  def schedule_reconciliation(actor, %OrganizationMirror{} = mirror, %DateTime{} = scheduled_at) do
    with {:ok, persisted} <- load_organization_mirror_capability(mirror),
         {:ok, _organization} <- authorize_organization_mirror(actor, persisted),
         :ok <- validate_capability_version(mirror, persisted),
         :ok <- validate_utc(scheduled_at) do
      scheduled_at = DateTime.truncate(scheduled_at, :second)

      enqueue_operation(%{
        organization_mirror_id: persisted.id,
        kind: "reconcile.organization_inventory",
        dedupe_key: "reconcile:organization:#{persisted.id}:#{DateTime.to_unix(scheduled_at)}",
        cursor: %{},
        next_attempt_at: scheduled_at
      })
    end
  end

  def schedule_reconciliation(_actor, _mirror, _scheduled_at), do: {:error, :forbidden}

  @doc false
  def schedule_due_reconciliations(%DateTime{} = now, limit, interval_seconds)
      when is_integer(limit) and limit in 1..@max_claim_batch and is_integer(interval_seconds) and
             interval_seconds > 0 do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      OrganizationMirror
      |> where(
        [mirror],
        mirror.state not in [:paused, :revoked] and not is_nil(mirror.next_reconcile_at) and
          mirror.next_reconcile_at <= ^now
      )
      |> order_by([mirror], asc: mirror.next_reconcile_at, asc: mirror.id)
      |> limit(^limit)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> Repo.all()
      |> Enum.map(&schedule_due_mirror(&1, now, interval_seconds))
    end)
  end

  @doc false
  @spec materialize_outbox_event(DomainOutboxEvent.t()) ::
          {:ok, {:materialized, [MirrorOperation.t()]}}
          | {:ok,
             {:ignored,
              :non_repository_event
              | :non_local_event
              | :repository_missing
              | :unbound_repository
              | :unmirrored_owner}}
          | {:error, :invalid_payload | :repository_binding_conflict | term()}
  def materialize_outbox_event(%DomainOutboxEvent{} = event) do
    case event do
      %DomainOutboxEvent{aggregate_type: "repository", origin: origin}
      when origin != :fornacast ->
        ignore_repository_event(event, :non_local_event)

      %DomainOutboxEvent{aggregate_type: "repository", event_type: "repository.created"} ->
        materialize_created_repository(event)

      %DomainOutboxEvent{aggregate_type: "repository", event_type: "repository." <> _suffix} ->
        materialize_existing_repository(event)

      %DomainOutboxEvent{aggregate_type: "repository"} ->
        ignore_repository_event(event, :non_repository_event)

      %DomainOutboxEvent{} ->
        {:ok, {:ignored, :non_repository_event}}
    end
  end

  defp ignore_repository_event(event, reason) do
    with {:ok, {repository_id, owner_id}} <- repository_identity_from_event(event),
         :ok <- validate_local_repository_identity(owner_id, repository_id) do
      {:ok, {:ignored, reason}}
    end
  end

  defp schedule_due_mirror(mirror, now, interval_seconds) do
    scheduled_at = mirror.next_reconcile_at

    result =
      enqueue_operation(%{
        organization_mirror_id: mirror.id,
        kind: "reconcile.organization_inventory",
        dedupe_key: "periodic-reconcile:#{mirror.id}:#{DateTime.to_unix(scheduled_at)}",
        cursor: %{},
        next_attempt_at: now
      })

    {:ok, _updated} =
      mirror
      |> OrganizationMirror.update_changeset(%{
        next_reconcile_at: DateTime.add(scheduled_at, interval_seconds, :second)
      })
      |> cas_update()

    result
  end

  defp materialize_created_repository(event) do
    with {:ok, {repository_id, owner_id}} <- repository_identity_from_event(event) do
      materialize_in_transaction(fn ->
        with :ok <- validate_local_repository_identity(owner_id, repository_id),
             {:ok, organization_mirror} <- lock_non_revoked_organization_mirror(owner_id),
             {:ok, repository_mirror} <-
               find_or_create_local_repository_mirror(organization_mirror, repository_id),
             {:ok, operation} <- materialize_repository_operation(repository_mirror, event) do
          {:materialized, [operation]}
        else
          {:error, :repository_missing} -> {:ignored, :repository_missing}
          {:error, :unmirrored_owner} -> {:ignored, :unmirrored_owner}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp materialize_existing_repository(event) do
    with {:ok, {repository_id, owner_id}} <- repository_identity_from_event(event) do
      materialize_in_transaction(fn ->
        with :ok <- validate_local_repository_identity(owner_id, repository_id),
             {:ok, organization_mirror} <- lock_non_revoked_organization_mirror(owner_id) do
          case find_bound_repository_mirror(organization_mirror.id, repository_id) do
            %RepositoryMirror{} = repository_mirror ->
              case materialize_repository_operation(repository_mirror, event) do
                {:ok, operation} -> {:materialized, [operation]}
                {:error, reason} -> Repo.rollback(reason)
              end

            nil ->
              {:ignored, :unbound_repository}
          end
        else
          {:error, :repository_missing} -> {:ignored, :repository_missing}
          {:error, :unmirrored_owner} -> {:ignored, :unmirrored_owner}
          {:error, :invalid_payload} -> Repo.rollback(:invalid_payload)
        end
      end)
    end
  end

  defp materialize_in_transaction(callback) when is_function(callback, 0) do
    case Repo.transaction(callback) do
      {:ok, decision} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp lock_non_revoked_organization_mirror(owner_id) do
    case OrganizationMirror
         |> where(
           [mirror],
           mirror.organization_id == ^owner_id and mirror.provider == "github" and
             mirror.state != :revoked
         )
         |> order_by([mirror], desc: mirror.id)
         |> limit(1)
         |> lock("FOR UPDATE")
         |> Repo.one() do
      %OrganizationMirror{} = mirror -> {:ok, mirror}
      nil -> {:error, :unmirrored_owner}
    end
  end

  defp find_or_create_local_repository_mirror(organization_mirror, repository_id) do
    case non_tombstoned_repository_mirror(repository_id) do
      %RepositoryMirror{organization_mirror_id: organization_mirror_id} = mirror
      when organization_mirror_id == organization_mirror.id ->
        {:ok, mirror}

      %RepositoryMirror{} ->
        {:error, :repository_binding_conflict}

      nil ->
        %RepositoryMirror{}
        |> RepositoryMirror.create_changeset(%{
          organization_mirror_id: organization_mirror.id,
          repository_id: repository_id,
          state: :discovered
        })
        |> Repo.insert()
    end
  end

  defp non_tombstoned_repository_mirror(repository_id) do
    RepositoryMirror
    |> where(
      [mirror],
      mirror.repository_id == ^repository_id and mirror.state != :tombstoned
    )
    |> order_by([mirror], desc: mirror.id)
    |> limit(1)
    |> Repo.one()
  end

  defp find_bound_repository_mirror(organization_mirror_id, repository_id) do
    RepositoryMirror
    |> where(
      [mirror],
      mirror.organization_mirror_id == ^organization_mirror_id and
        mirror.repository_id == ^repository_id and mirror.state != :tombstoned
    )
    |> order_by([mirror], desc: mirror.id)
    |> limit(1)
    |> Repo.one()
  end

  defp materialize_repository_operation(repository, event) do
    enqueue_operation(%{
      organization_mirror_id: repository.organization_mirror_id,
      repository_mirror_id: repository.id,
      kind: event.event_type,
      dedupe_key: "outbox:#{event.event_id}:#{repository.id}",
      cursor: %{"outbox_event_id" => event.event_id},
      next_attempt_at: event.available_at
    })
  end

  defp validate_local_repository_identity(owner_id, repository_id) do
    case ForgeRepos.fetch_live_repository(repository_id) do
      {:ok, %ForgeRepos.Repository{owner_user_id: ^owner_id}} -> :ok
      {:ok, %ForgeRepos.Repository{}} -> {:error, :invalid_payload}
      {:error, :not_found} -> {:error, :repository_missing}
    end
  end

  defp repository_identity_from_event(%DomainOutboxEvent{
         aggregate_id: aggregate_id,
         payload: payload
       })
       when is_binary(aggregate_id) and is_map(payload) do
    with {repository_id, ""} when repository_id > 0 <- Integer.parse(aggregate_id),
         ^repository_id <- Map.get(payload, "repository_id"),
         owner_id when is_integer(owner_id) and owner_id > 0 <- Map.get(payload, "owner_id") do
      {:ok, {repository_id, owner_id}}
    else
      _invalid -> {:error, :invalid_payload}
    end
  end

  defp repository_identity_from_event(_event), do: {:error, :invalid_payload}

  defp insert_idempotent_operation(changeset) do
    options = if Repo.in_transaction?(), do: [mode: :savepoint], else: []

    case Repo.insert(changeset, options) do
      {:ok, operation} ->
        {:ok, operation}

      {:error, %Ecto.Changeset{} = invalid} ->
        dedupe_key = Ecto.Changeset.get_field(changeset, :dedupe_key)

        if Keyword.has_key?(invalid.errors, :dedupe_key) do
          existing = Repo.get_by!(MirrorOperation, dedupe_key: dedupe_key)

          if operation_identity(existing) == changeset_identity(changeset),
            do: {:ok, existing},
            else: {:error, :dedupe_conflict}
        else
          {:error, invalid}
        end
    end
  end

  defp operation_identity(operation) do
    {operation.organization_mirror_id, operation.repository_mirror_id, operation.kind,
     operation.cursor}
  end

  defp changeset_identity(changeset) do
    {
      Ecto.Changeset.get_field(changeset, :organization_mirror_id),
      Ecto.Changeset.get_field(changeset, :repository_mirror_id),
      Ecto.Changeset.get_field(changeset, :kind),
      Ecto.Changeset.get_field(changeset, :cursor)
    }
  end

  defp load_organization_mirror_capability(%OrganizationMirror{
         id: id,
         lock_version: lock_version
       })
       when is_integer(id) and id > 0 and is_integer(lock_version) do
    case Repo.get(OrganizationMirror, id) do
      nil -> {:error, :not_found}
      %OrganizationMirror{} = persisted -> {:ok, persisted}
    end
  end

  defp load_organization_mirror_capability(_mirror), do: {:error, :not_found}

  defp load_repository_mirror_capability(%RepositoryMirror{
         id: id,
         lock_version: lock_version
       })
       when is_integer(id) and id > 0 and is_integer(lock_version) do
    case Repo.get(RepositoryMirror, id) do
      nil -> {:error, :not_found}
      %RepositoryMirror{} = persisted -> {:ok, persisted}
    end
  end

  defp load_repository_mirror_capability(_mirror), do: {:error, :not_found}

  defp load_conflict_capability(%MirrorConflict{id: id, lock_version: lock_version})
       when is_integer(id) and id > 0 and is_integer(lock_version) do
    case Repo.get(MirrorConflict, id) do
      nil -> {:error, :not_found}
      %MirrorConflict{} = persisted -> {:ok, persisted}
    end
  end

  defp load_conflict_capability(_conflict), do: {:error, :not_found}

  defp validate_capability_version(
         %{lock_version: lock_version},
         %{lock_version: lock_version}
       ),
       do: :ok

  defp validate_capability_version(_provided, _persisted), do: {:error, :stale}

  defp authorize_organization_mirror(actor, %OrganizationMirror{organization_id: id}) do
    ForgeAccounts.fetch_manageable_organization(actor, id)
  end

  defp load_repository_organization_mirror(%RepositoryMirror{
         organization_mirror_id: organization_mirror_id
       }) do
    case Repo.get(OrganizationMirror, organization_mirror_id) do
      %OrganizationMirror{} = mirror -> {:ok, mirror}
      nil -> {:error, :not_found}
    end
  end

  defp load_conflict_organization_mirror(%MirrorConflict{
         organization_mirror_id: organization_mirror_id
       }) do
    case Repo.get(OrganizationMirror, organization_mirror_id) do
      %OrganizationMirror{} = mirror -> {:ok, mirror}
      nil -> {:error, :not_found}
    end
  end

  defp validate_repository_binding_scope(changeset) do
    organization_mirror_id =
      Ecto.Changeset.get_field(changeset, :organization_mirror_id)

    repository_id = Ecto.Changeset.get_field(changeset, :repository_id)

    with %OrganizationMirror{} = organization_mirror <-
           Repo.get(OrganizationMirror, organization_mirror_id),
         %ForgeAccounts.Organization{} <-
           ForgeAccounts.get_organization(organization_mirror.organization_id),
         :ok <-
           validate_local_repository_scope(organization_mirror.organization_id, repository_id) do
      {:ok, organization_mirror}
    else
      _ -> {:error, :not_found}
    end
  end

  defp load_binding_organization_mirror(changeset) do
    changeset
    |> Ecto.Changeset.get_field(:organization_mirror_id)
    |> then(&Repo.get(OrganizationMirror, &1))
    |> case do
      %OrganizationMirror{} = organization_mirror -> {:ok, organization_mirror}
      nil -> {:error, :not_found}
    end
  end

  defp validate_local_repository_scope(_organization_id, nil), do: :ok

  defp validate_local_repository_scope(organization_id, repository_id) do
    case ForgeRepos.fetch_organization_repository(organization_id, repository_id) do
      {:ok, _repository} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp validate_conflict_scope(changeset) do
    organization_mirror_id =
      Ecto.Changeset.get_field(changeset, :organization_mirror_id)

    repository_mirror_id = Ecto.Changeset.get_field(changeset, :repository_mirror_id)

    with %OrganizationMirror{} <- Repo.get(OrganizationMirror, organization_mirror_id),
         :ok <- validate_repository_scope(repository_mirror_id, organization_mirror_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp validate_operation_scope(changeset) do
    organization_id = Ecto.Changeset.get_field(changeset, :organization_mirror_id)
    repository_id = Ecto.Changeset.get_field(changeset, :repository_mirror_id)

    with %OrganizationMirror{} <- Repo.get(OrganizationMirror, organization_id),
         :ok <- validate_repository_scope(repository_id, organization_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp validate_repository_scope(nil, _organization_id), do: :ok

  defp validate_repository_scope(repository_id, organization_id) do
    case Repo.get(RepositoryMirror, repository_id) do
      %RepositoryMirror{organization_mirror_id: ^organization_id} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp lock_effect_scope(%MirrorOperation{id: id}) when is_integer(id) and id > 0 do
    case Repo.get(MirrorOperation, id) do
      %MirrorOperation{} = persisted ->
        organization =
          OrganizationMirror
          |> where([mirror], mirror.id == ^persisted.organization_mirror_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        repository = lock_effect_repository(persisted.repository_mirror_id)

        with %OrganizationMirror{} = organization <- organization,
             {:ok, repository} <- repository,
             :ok <- validate_effect_organization(organization),
             :ok <- validate_effect_repository(repository) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :lost_lease}
        end

      nil ->
        {:error, :lost_lease}
    end
  end

  defp lock_effect_scope(_operation), do: {:error, :lost_lease}

  defp lock_effect_repository(nil), do: {:ok, nil}

  defp lock_effect_repository(repository_mirror_id) do
    case RepositoryMirror
         |> where([mirror], mirror.id == ^repository_mirror_id)
         |> lock("FOR UPDATE")
         |> Repo.one() do
      %RepositoryMirror{} = repository -> {:ok, repository}
      nil -> {:error, :lost_lease}
    end
  end

  defp validate_effect_organization(%OrganizationMirror{state: :paused}), do: {:error, :paused}

  defp validate_effect_organization(%OrganizationMirror{state: :revoked}),
    do: {:error, :invalid_transition}

  defp validate_effect_organization(%OrganizationMirror{}), do: :ok

  defp validate_effect_repository(nil), do: :ok

  defp validate_effect_repository(%RepositoryMirror{state: state})
       when state in [:discovered, :active],
       do: :ok

  defp validate_effect_repository(%RepositoryMirror{}), do: {:error, :invalid_transition}

  defp lock_webhook_delivery_guid!(delivery_guid) do
    if Repo.__adapter__() == Ecto.Adapters.Postgres do
      Ecto.Adapters.SQL.query!(
        Repo,
        "select pg_advisory_xact_lock(hashtextextended($1, 0))",
        [delivery_guid]
      )
    end

    :ok
  end

  defp compare_webhook_redelivery(existing, attrs) do
    fields = [
      :delivery_guid,
      :hook_id,
      :event,
      :action,
      :installation_id,
      :github_repository_id,
      :signature_version,
      :raw_payload
    ]

    expected = Map.new(fields, &{&1, attr(attrs, &1)})
    actual = Map.take(existing, fields)

    if expected == actual,
      do: {:ok, existing, :duplicate},
      else: {:error, :delivery_collision}
  end

  defp claim_due_webhook_deliveries(
         owner,
         now,
         expires_at,
         limit,
         max_per_installation
       ) do
    sql = """
    with pending_ranked as (
      select candidate.id,
             row_number() over (
               partition by candidate.installation_id
               order by candidate.id
             ) as installation_position
      from mirror_webhook_deliveries candidate
      where candidate.state = 'pending'
    ),
    active_counts as (
      select active.installation_id, count(*) as active_count
      from mirror_webhook_deliveries active
      where active.state = 'processing'
        and active.lease_expires_at > $1
      group by active.installation_id
    )
    select delivery.id
    from mirror_webhook_deliveries delivery
    join pending_ranked ranked on ranked.id = delivery.id
    left join active_counts active on active.installation_id = delivery.installation_id
    where delivery.state = 'pending'
      and delivery.next_attempt_at <= $1
      and (
        (
          delivery.event in ('installation', 'installation_repositories', 'repository')
          and coalesce(active.active_count, 0) = 0
          and not exists (
            select 1
            from mirror_webhook_deliveries earlier
            where earlier.installation_id = delivery.installation_id
              and earlier.id < delivery.id
              and earlier.state in ('pending', 'processing')
          )
        )
        or
        (
          delivery.event not in ('installation', 'installation_repositories', 'repository')
          and ranked.installation_position + coalesce(active.active_count, 0) <= $2
          and not exists (
            select 1
            from mirror_webhook_deliveries serialized
            where serialized.installation_id = delivery.installation_id
              and serialized.event in ('installation', 'installation_repositories', 'repository')
              and (
                serialized.state = 'processing'
                or (serialized.state = 'pending' and serialized.id < delivery.id)
              )
          )
        )
      )
    order by delivery.next_attempt_at, delivery.id
    for update of delivery skip locked
    limit $3
    """

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(Repo, sql, [now, max_per_installation, limit])

    Enum.map(rows, fn [id] -> claim_webhook_delivery!(id, owner, now, expires_at) end)
  end

  defp claim_webhook_delivery!(id, owner, now, expires_at) do
    delivery = Repo.get!(MirrorWebhookDelivery, id)

    {1, _} =
      MirrorWebhookDelivery
      |> where(
        [candidate],
        candidate.id == ^id and candidate.state == :pending and
          candidate.lock_version == ^delivery.lock_version
      )
      |> Repo.update_all(
        set: [
          state: :processing,
          lease_owner: owner,
          lease_expires_at: expires_at,
          failure_class: nil,
          updated_at: now
        ],
        inc: [attempt_count: 1, lock_version: 1]
      )

    Repo.get!(MirrorWebhookDelivery, id)
  end

  defp recover_expired_webhook_deliveries!(now, max_internal_attempts) do
    sql = """
    update mirror_webhook_deliveries
    set state = case
          when internal_failure_count + 1 >= $2 then 'failed'
          else 'pending'
        end,
        next_attempt_at = $1,
        lease_owner = null,
        lease_expires_at = null,
        processed_at = case
          when internal_failure_count + 1 >= $2 then $1
          else null
        end,
        failure_class = 'worker_crash',
        internal_failure_count = internal_failure_count + 1,
        lock_version = lock_version + 1,
        updated_at = $1
    where state = 'processing'
      and lease_expires_at <= $1
    """

    %{num_rows: count} =
      Ecto.Adapters.SQL.query!(Repo, sql, [now, max_internal_attempts])

    count
  end

  defp webhook_max_internal_attempts do
    case Application.get_env(:forge_mirrors, :webhook_worker_max_internal_attempts, 10) do
      value when is_integer(value) and value in 1..1_000 -> value
      _invalid -> raise ArgumentError, "invalid webhook worker internal attempt limit"
    end
  end

  defp owned_webhook_transition(delivery, owner, updates) when is_list(updates) do
    with :ok <- validate_owner(owner),
         true <- webhook_capability?(delivery) do
      Repo.transaction(fn ->
        now = database_now!()

        updates =
          Enum.map(updates, fn
            {:processed_at, :server_now} ->
              {:processed_at, now}

            {:next_attempt_at, {:server_after, seconds}} ->
              {:next_attempt_at, DateTime.add(now, seconds, :second)}

            update ->
              update
          end)

        query =
          from candidate in MirrorWebhookDelivery,
            where:
              candidate.id == ^delivery.id and candidate.state == :processing and
                candidate.lease_owner == ^owner and
                candidate.lease_owner == ^delivery.lease_owner and
                candidate.lease_expires_at == ^delivery.lease_expires_at and
                candidate.lease_expires_at > fragment("timezone('UTC', clock_timestamp())") and
                candidate.lock_version == ^delivery.lock_version

        case Repo.update_all(query,
               set: Keyword.put(updates, :updated_at, now),
               inc: [lock_version: 1]
             ) do
          {1, _} -> Repo.get!(MirrorWebhookDelivery, delivery.id)
          {0, _} -> Repo.rollback(:lost_lease)
        end
      end)
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, :lost_lease} -> {:error, :lost_lease}
        {:error, _reason} -> {:error, :lost_lease}
      end
    else
      false -> {:error, :lost_lease}
      {:error, _reason} -> {:error, :invalid_argument}
    end
  rescue
    _exception -> {:error, :lost_lease}
  end

  defp webhook_capability?(%MirrorWebhookDelivery{
         id: id,
         state: :processing,
         lease_owner: owner,
         lease_expires_at: %DateTime{},
         lock_version: lock_version
       }) do
    is_integer(id) and is_binary(owner) and is_integer(lock_version) and lock_version > 0
  end

  defp webhook_capability?(_delivery), do: false

  defp validate_webhook_failure_class(failure_class) do
    if is_binary(failure_class) and byte_size(failure_class) in 1..255 and
         String.valid?(failure_class) and failure_class == String.trim(failure_class) and
         :binary.match(failure_class, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, :invalid_argument}
  end

  defp database_now! do
    %{rows: [[naive]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "select date_trunc('second', timezone('UTC', clock_timestamp()))",
        []
      )

    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp do_claim_operations(owner, now, lease_seconds, limit, kinds) do
    with :ok <- validate_owner(owner), :ok <- validate_utc(now) do
      now = DateTime.truncate(now, :second)
      expires_at = DateTime.add(now, lease_seconds, :second)

      case Repo.transaction(fn -> claim_due_operations(owner, now, expires_at, limit, kinds) end) do
        {:ok, operations} -> {:ok, operations}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp claim_due_operations(owner, now, expires_at, limit, kinds) do
    sql = """
    select operation.id
    from mirror_operations operation
    join organization_mirrors organization
      on organization.id = operation.organization_mirror_id
    left join repository_mirrors repository
      on repository.id = operation.repository_mirror_id
    left join github_app_installations installation
      on installation.github_installation_id = organization.github_installation_id
    where organization.state not in ('paused', 'revoked')
      and (operation.repository_mirror_id is null or repository.state in ('discovered', 'active'))
      and ($3::text[] is null or operation.kind = any($3))
      and (
        operation.kind <> 'reconcile.organization_inventory'
        or (
          organization.provider = 'github'
          and installation.state = 'active'
          and installation.github_account_id = organization.github_account_id
        )
      )
      and (
        (operation.state = 'pending' and operation.next_attempt_at <= $1)
        or (operation.state = 'processing' and operation.lease_expires_at <= $1)
        or (operation.state = 'effect_pending' and
              (operation.lease_expires_at is null or operation.lease_expires_at <= $1))
      )
      and not exists (
        select 1 from mirror_operations earlier
        where earlier.id < operation.id
          and earlier.state in ('pending', 'processing', 'effect_pending')
          and (
            (operation.repository_mirror_id is not null and
              earlier.repository_mirror_id = operation.repository_mirror_id)
            or
            (operation.repository_mirror_id is null and earlier.repository_mirror_id is null and
              earlier.organization_mirror_id = operation.organization_mirror_id)
          )
      )
      and not exists (
        select 1 from mirror_operations active
        where active.id <> operation.id
          and active.state in ('processing', 'effect_pending')
          and active.lease_expires_at > $1
          and (
            (operation.repository_mirror_id is not null and
              active.repository_mirror_id = operation.repository_mirror_id)
            or
            (operation.repository_mirror_id is null and active.repository_mirror_id is null and
              active.organization_mirror_id = operation.organization_mirror_id)
          )
      )
    order by operation.next_attempt_at, operation.id
    for update of operation skip locked
    limit $2
    """

    %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, [now, limit, kinds])
    Enum.map(rows, fn [id] -> claim_operation!(id, owner, now, expires_at) end)
  end

  defp load_owned_inventory_operation(%MirrorOperation{} = operation) do
    if owned_capability?(operation) do
      query =
        from candidate in MirrorOperation,
          where:
            candidate.id == ^operation.id and candidate.kind == @inventory_operation_kind and
              is_nil(candidate.repository_mirror_id) and candidate.state == :processing and
              candidate.lease_owner == ^operation.lease_owner and
              candidate.lease_expires_at == ^operation.lease_expires_at and
              candidate.lease_expires_at > fragment("timezone('UTC', clock_timestamp())") and
              candidate.lock_version == ^operation.lock_version,
          lock: "FOR UPDATE"

      case Repo.one(query) do
        %MirrorOperation{} = persisted -> {:ok, persisted}
        nil -> {:error, :lost_lease}
      end
    else
      {:error, :lost_lease}
    end
  end

  defp lock_inventory_organization(%MirrorOperation{id: id}) when is_integer(id) and id > 0 do
    case Repo.get(MirrorOperation, id) do
      %MirrorOperation{organization_mirror_id: organization_mirror_id} ->
        case OrganizationMirror
             |> where([mirror], mirror.id == ^organization_mirror_id)
             |> lock("FOR UPDATE")
             |> Repo.one() do
          %OrganizationMirror{} -> :ok
          nil -> {:error, :lost_lease}
        end

      nil ->
        {:error, :lost_lease}
    end
  end

  defp lock_inventory_organization(_operation), do: {:error, :lost_lease}

  defp load_inventory_scope(organization_mirror_id) do
    organization =
      OrganizationMirror
      |> where([mirror], mirror.id == ^organization_mirror_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    with %OrganizationMirror{
           provider: "github",
           state: state,
           github_installation_id: installation_id,
           github_account_id: account_id,
           policy: policy
         } = organization
         when state not in [:paused, :revoked] and is_integer(installation_id) and
                is_integer(account_id) <- organization,
         %GitHubAppInstallation{
           state: :active,
           github_account_id: ^account_id
         } = installation <-
           GitHubAppInstallation
           |> where([record], record.github_installation_id == ^installation_id)
           |> lock("FOR UPDATE")
           |> Repo.one(),
         {:ok, inventory_policy} <- InventoryPolicy.parse(policy) do
      {:ok, organization, installation, inventory_policy}
    else
      {:error, :invalid_policy} = error -> error
      _invalid -> {:error, :invalid_transition}
    end
  end

  defp inventory_checkpoint_cursor(checkpoint) when checkpoint == %{}, do: {:ok, 1}

  defp inventory_checkpoint_cursor(%{"next_cursor" => cursor})
       when is_integer(cursor) and cursor in 2..100,
       do: {:ok, cursor}

  defp inventory_checkpoint_cursor(_checkpoint), do: {:error, :invalid_transition}

  defp validate_inventory_next_cursor(100, nil), do: :ok
  defp validate_inventory_next_cursor(cursor, nil) when cursor in 1..100, do: :ok

  defp validate_inventory_next_cursor(cursor, next_cursor)
       when cursor in 1..99 and next_cursor == cursor + 1,
       do: :ok

  defp validate_inventory_next_cursor(_cursor, _next_cursor),
    do: {:error, :invalid_argument}

  defp inventory_sweep_marker(operation_id), do: "inventory-operation:#{operation_id}"

  defp normalize_inventory_repositories(repositories) do
    repositories
    |> Enum.reduce_while({:ok, [], MapSet.new(), MapSet.new()}, fn repository,
                                                                   {:ok, normalized, ids, nodes} ->
      with {:ok, observation} <- normalize_inventory_repository(repository),
           false <- MapSet.member?(ids, observation.github_repository_id),
           false <- MapSet.member?(nodes, observation.github_node_id) do
        {:cont,
         {:ok, [observation | normalized], MapSet.put(ids, observation.github_repository_id),
          MapSet.put(nodes, observation.github_node_id)}}
      else
        _invalid -> {:halt, {:error, :invalid_argument}}
      end
    end)
    |> case do
      {:ok, normalized, _ids, _nodes} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_inventory_repository(repository) when is_map(repository) do
    github_repository_id = fetch_attr(repository, :github_repository_id)
    github_node_id = fetch_attr(repository, :github_node_id)
    github_full_name = fetch_attr(repository, :github_full_name)
    github_archived = fetch_attr(repository, :github_archived)

    if is_integer(github_repository_id) and github_repository_id > 0 and
         bounded_trimmed_string?(github_node_id, 255) and
         bounded_trimmed_string?(github_full_name, 255) and is_boolean(github_archived) do
      {:ok,
       %{
         github_repository_id: github_repository_id,
         github_node_id: github_node_id,
         github_full_name: github_full_name,
         github_archived: github_archived
       }}
    else
      {:error, :invalid_argument}
    end
  end

  defp normalize_inventory_repository(_repository), do: {:error, :invalid_argument}

  defp bounded_trimmed_string?(value, max_bytes) do
    is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
      value == String.trim(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp persist_inventory_repositories(
         organization,
         installation,
         policy,
         repositories,
         sweep_marker,
         observed_at
       ) do
    initial = %{added: [], renamed: [], archive_changed: [], access_revoked: []}

    repositories
    |> Enum.reduce_while({:ok, initial}, fn repository, {:ok, classifications} ->
      case upsert_inventory_repository(
             organization,
             installation,
             policy,
             repository,
             sweep_marker,
             observed_at,
             classifications
           ) do
        {:ok, classifications} -> {:cont, {:ok, classifications}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, classifications} -> {:ok, reverse_classifications(classifications)}
      error -> error
    end
  end

  defp upsert_inventory_repository(
         organization,
         installation,
         policy,
         repository,
         sweep_marker,
         observed_at,
         classifications
       ) do
    existing =
      RepositoryMirror
      |> where(
        [mirror],
        mirror.github_repository_id == ^repository.github_repository_id and
          mirror.state != :tombstoned
      )
      |> order_by([mirror], desc: mirror.id)
      |> limit(1)
      |> lock("FOR UPDATE")
      |> Repo.one()

    included = InventoryPolicy.included?(policy, repository.github_repository_id)

    attrs =
      repository
      |> Map.merge(%{
        organization_mirror_id: organization.id,
        inventory_included: included,
        inventory_selection: installation.repository_selection,
        last_inventory_sweep: sweep_marker,
        last_inventory_at: observed_at
      })

    with {:ok, mirror, newly_visible?, renamed?, archive_changed?} <-
           persist_inventory_repository(existing, organization.id, attrs),
         {:ok, _bootstrap} <-
           maybe_enqueue_inventory_bootstrap(
             organization,
             mirror,
             policy,
             included,
             newly_visible?,
             repository.github_archived,
             observed_at
           ) do
      {:ok,
       classifications
       |> maybe_classify(:added, newly_visible?, mirror.id)
       |> maybe_classify(:renamed, renamed?, mirror.id)
       |> maybe_classify(:archive_changed, archive_changed?, mirror.id)}
    end
  end

  defp persist_inventory_repository(nil, _organization_mirror_id, attrs) do
    case %RepositoryMirror{}
         |> RepositoryMirror.inventory_create_changeset(attrs)
         |> Repo.insert() do
      {:ok, mirror} ->
        {:ok, mirror, true, false, false}

      {:error, changeset} ->
        if constraint_error?(changeset, "repository_mirrors_active_github_repository_index"),
          do: {:error, :identity_conflict},
          else: {:error, changeset}
    end
  end

  defp persist_inventory_repository(
         %RepositoryMirror{organization_mirror_id: organization_mirror_id},
         expected_organization_mirror_id,
         _attrs
       )
       when organization_mirror_id != expected_organization_mirror_id,
       do: {:error, :identity_conflict}

  defp persist_inventory_repository(%RepositoryMirror{} = existing, _organization_id, attrs) do
    newly_visible? = existing.state == :revoked and is_nil(existing.repository_id)

    renamed? =
      not is_nil(existing.github_full_name) and
        existing.github_full_name != attrs.github_full_name

    archive_changed? = existing.github_archived != attrs.github_archived

    case existing
         |> RepositoryMirror.inventory_update_changeset(attrs)
         |> cas_update() do
      {:ok, mirror} ->
        {:ok, mirror, newly_visible?, renamed?, archive_changed?}

      {:error, :stale} ->
        {:error, :lost_lease}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :github_node_id),
          do: {:error, :identity_conflict},
          else: {:error, changeset}
    end
  end

  defp maybe_enqueue_inventory_bootstrap(
         organization,
         mirror,
         policy,
         included?,
         newly_visible?,
         archived?,
         observed_at
       ) do
    if included? and InventoryPolicy.auto_import?(policy, newly_visible?, archived?) do
      enqueue_operation(%{
        organization_mirror_id: organization.id,
        repository_mirror_id: mirror.id,
        kind: "bootstrap.repository_import",
        dedupe_key: "inventory-bootstrap:#{mirror.id}",
        cursor: %{
          "github_repository_id" => mirror.github_repository_id,
          "source" => "inventory"
        },
        next_attempt_at: observed_at
      })
    else
      {:ok, nil}
    end
  end

  defp maybe_classify(classifications, _kind, false, _id), do: classifications

  defp maybe_classify(classifications, kind, true, id),
    do: Map.update!(classifications, kind, &[id | &1])

  defp reverse_classifications(classifications) do
    Map.new(classifications, fn {kind, ids} -> {kind, Enum.reverse(ids)} end)
  end

  defp maybe_finish_inventory_sweep(
         _organization,
         next_cursor,
         _sweep_marker,
         _observed_at,
         classifications
       )
       when not is_nil(next_cursor),
       do: {:ok, classifications}

  defp maybe_finish_inventory_sweep(
         organization,
         nil,
         sweep_marker,
         observed_at,
         classifications
       ) do
    unseen_query =
      from mirror in RepositoryMirror,
        where:
          mirror.organization_mirror_id == ^organization.id and
            not is_nil(mirror.github_repository_id) and
            mirror.state not in [:revoked, :tombstoned] and
            fragment("? is distinct from ?", mirror.last_inventory_sweep, ^sweep_marker)

    unseen_ids = unseen_query |> select([mirror], mirror.id) |> Repo.all()

    Repo.update_all(unseen_query,
      set: [state: :revoked, updated_at: observed_at],
      inc: [lock_version: 1]
    )

    case organization
         |> OrganizationMirror.update_changeset(%{last_reconciled_at: observed_at})
         |> cas_update() do
      {:ok, _organization} ->
        {:ok, Map.put(classifications, :access_revoked, unseen_ids)}

      {:error, :stale} ->
        {:error, :lost_lease}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp persist_inventory_checkpoint(operation, next_cursor, sweep_marker, observed_at) do
    updates =
      if is_nil(next_cursor) do
        [
          state: :completed,
          checkpoint: %{"completed_sweep" => sweep_marker},
          lease_owner: nil,
          lease_expires_at: nil,
          completed_at: observed_at,
          failure_class: nil,
          failure_disposition: nil,
          failure_detail: nil
        ]
      else
        [
          state: :pending,
          checkpoint: %{"next_cursor" => next_cursor},
          next_attempt_at: observed_at,
          lease_owner: nil,
          lease_expires_at: nil,
          failure_class: nil,
          failure_disposition: nil,
          failure_detail: nil
        ]
      end

    owned_transition(operation, observed_at, [:processing], updates)
  end

  defp validate_operation_kinds(kinds) do
    if kinds != [] and length(kinds) <= 16 and length(kinds) == length(Enum.uniq(kinds)) and
         Enum.all?(kinds, &bounded_trimmed_string?(&1, 255)),
       do: :ok,
       else: {:error, :invalid_argument}
  end

  defp constraint_error?(changeset, constraint_name) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      options[:constraint_name] == constraint_name
    end)
  end

  defp claim_operation!(id, owner, now, expires_at) do
    operation = Repo.get!(MirrorOperation, id)
    state = if operation.state == :effect_pending, do: :effect_pending, else: :processing

    {1, _} =
      MirrorOperation
      |> where(
        [candidate],
        candidate.id == ^id and candidate.lock_version == ^operation.lock_version
      )
      |> Repo.update_all(
        set: [
          state: state,
          lease_owner: owner,
          lease_expires_at: expires_at,
          started_at: operation.started_at || now,
          updated_at: now
        ],
        inc: [attempt_count: 1, lock_version: 1]
      )

    Repo.get!(MirrorOperation, id)
  end

  defp owned_transition(operation, now, states, updates) do
    if owned_capability?(operation) do
      query =
        from candidate in MirrorOperation,
          where:
            candidate.id == ^operation.id and candidate.state in ^states and
              candidate.lease_owner == ^operation.lease_owner and
              candidate.lease_expires_at == ^operation.lease_expires_at and
              candidate.lease_expires_at >
                fragment("timezone('UTC', clock_timestamp())") and
              candidate.lock_version == ^operation.lock_version

      case Repo.update_all(query,
             set: Keyword.put(updates, :updated_at, now),
             inc: [lock_version: 1]
           ) do
        {1, _} -> {:ok, Repo.get!(MirrorOperation, operation.id)}
        {0, _} -> {:error, :lost_lease}
      end
    else
      {:error, :lost_lease}
    end
  rescue
    _ -> {:error, :lost_lease}
  end

  defp owned_capability?(%MirrorOperation{
         id: id,
         lease_owner: owner,
         lease_expires_at: %DateTime{},
         lock_version: version
       }) do
    is_integer(id) and is_binary(owner) and owner != "" and is_integer(version)
  end

  defp owned_capability?(_operation), do: false

  defp conflict_insert_error(changeset, attrs) do
    if Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
         opts[:constraint_name] == "mirror_conflicts_one_open_identity_index"
       end) do
      organization_id = attr(attrs, :organization_mirror_id)
      repository_id = attr(attrs, :repository_mirror_id)
      resource_kind = attr(attrs, :resource_kind)
      resource_identity = attr(attrs, :resource_identity)

      query =
        from conflict in MirrorConflict,
          where:
            conflict.organization_mirror_id == ^organization_id and
              conflict.resource_kind == ^resource_kind and
              conflict.resource_identity == ^resource_identity and conflict.state == :open

      query =
        if is_nil(repository_id),
          do: where(query, [conflict], is_nil(conflict.repository_mirror_id)),
          else: where(query, [conflict], conflict.repository_mirror_id == ^repository_id)

      existing = Repo.one!(query)

      expected =
        {
          attr(attrs, :conflict_kind),
          canonical_map(attr(attrs, :baseline_snapshot) || %{}),
          canonical_map(attr(attrs, :local_snapshot) || %{}),
          canonical_map(attr(attrs, :remote_snapshot) || %{})
        }

      actual =
        {existing.conflict_kind, existing.baseline_snapshot, existing.local_snapshot,
         existing.remote_snapshot}

      if expected == actual, do: {:ok, existing}, else: {:error, :dedupe_conflict}
    else
      {:error, changeset}
    end
  end

  defp resolve_idempotently({:error, :stale}, conflict_id, resolution) do
    case Repo.get(MirrorConflict, conflict_id) do
      %MirrorConflict{state: :resolved, resolution: ^resolution} = conflict -> {:ok, conflict}
      _ -> {:error, :stale}
    end
  end

  defp resolve_idempotently(result, _conflict_id, _resolution), do: result

  defp cas_update(changeset) do
    changeset
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update(stale_error_field: :lock_version, stale_error_message: "is stale")
    |> case do
      {:error, %Ecto.Changeset{} = stale} = error ->
        if Keyword.has_key?(stale.errors, :lock_version), do: {:error, :stale}, else: error

      result ->
        result
    end
  end

  defp grouped_counts(schema, foreign_key, id) do
    schema
    |> where([row], field(row, ^foreign_key) == ^id)
    |> group_by([row], row.state)
    |> select([row], {row.state, count(row.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp validate_owner(owner) do
    if byte_size(owner) in 1..255 and owner == String.trim(owner),
      do: :ok,
      else: {:error, :invalid_argument}
  end

  defp validate_utc(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: :ok
  defp validate_utc(_now), do: {:error, :invalid_argument}

  defp validate_retryable_failure_class(failure_class) do
    case failure_disposition(failure_class) do
      {:ok, :retry} -> :ok
      _ -> {:error, :invalid_argument}
    end
  end

  defp nonretryable_failure_disposition(failure_class) do
    case failure_disposition(failure_class) do
      {:ok, :retry} -> {:error, :invalid_argument}
      {:ok, disposition} -> {:ok, disposition}
      {:error, :invalid_argument} = error -> error
    end
  end

  defp validate_failure_detail(nil), do: :ok

  defp validate_failure_detail(detail) when is_binary(detail) do
    if byte_size(detail) in 1..2_048 and detail == String.trim(detail),
      do: :ok,
      else: {:error, :invalid_argument}
  end

  defp validate_failure_detail(_detail), do: {:error, :invalid_argument}

  defp validate_effect_retry(:processing, options) do
    if Keyword.keyword?(options), do: :ok, else: {:error, :invalid_argument}
  end

  defp validate_effect_retry(:effect_pending, options) do
    if Keyword.keyword?(options) and Keyword.get(options, :external_effect_reconciled) == true,
      do: :ok,
      else: {:error, :invalid_transition}
  end

  defp validate_keyword(options) do
    if Keyword.keyword?(options), do: :ok, else: {:error, :invalid_argument}
  end

  defp validate_bounded_object(value) do
    if value |> JSON.encode_to_iodata!() |> IO.iodata_length() <= 65_536,
      do: :ok,
      else: {:error, :invalid_argument}
  rescue
    _ -> {:error, :invalid_argument}
  end

  defp canonicalize_cursor(attrs) do
    cond do
      Map.has_key?(attrs, :cursor) -> Map.update!(attrs, :cursor, &canonicalize_cursor_value/1)
      Map.has_key?(attrs, "cursor") -> Map.update!(attrs, "cursor", &canonicalize_cursor_value/1)
      true -> attrs
    end
  end

  defp canonicalize_cursor_value(value) when is_map(value), do: canonical_map(value)
  defp canonicalize_cursor_value(value), do: value

  defp canonical_map(value) when is_map(value) do
    value |> JSON.encode!() |> JSON.decode!()
  rescue
    _ -> value
  end

  defp attr(attrs, field), do: Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

  defp invalid_changeset(struct) do
    {:error, Ecto.Changeset.add_error(Ecto.Changeset.change(struct), :base, "is invalid")}
  end
end
