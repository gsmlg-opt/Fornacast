defmodule ForgeGitHub.WebhookProcessor do
  @moduledoc """
  Composes provider-specific webhook normalization with durable mirror effects.

  Mutable notifications are always refreshed from GitHub. Installation deletion
  is the sole payload-applied event because it is immutable and carries complete
  installation identity evidence.
  """

  alias ForgeGitHub.{
    AppAuthentication,
    AppConfig,
    AppInstallation,
    Error,
    InstallationTokenBroker
  }

  alias ForgeMirrors.{GitHubAppInstallation, MirrorWebhookDelivery}

  @retryable_error_kinds [
    :primary_rate_limit,
    :secondary_rate_limit,
    :upstream_unavailable,
    :unexpected_status,
    :transport,
    :timeout,
    :host_unavailable,
    :request_gate_busy
  ]

  @spec process(MirrorWebhookDelivery.t()) ::
          :ok | :ignore | {:retry, String.t(), non_neg_integer()} | {:fail, String.t()}
  def process(delivery), do: process(delivery, [])

  @doc false
  @spec process(MirrorWebhookDelivery.t(), keyword()) ::
          :ok | :ignore | {:retry, String.t(), non_neg_integer()} | {:fail, String.t()}
  def process(%MirrorWebhookDelivery{} = delivery, options) when is_list(options) do
    with {:ok, payload} <- decode_payload(delivery.raw_payload),
         :ok <- validate_routing(delivery, payload) do
      dispatch(delivery, payload, options)
    else
      {:error, :routing_mismatch} -> {:fail, "webhook_routing_mismatch"}
      {:error, _invalid_payload} -> {:fail, "invalid_webhook_payload"}
    end
  rescue
    _exception -> {:retry, "processor_crash", 30}
  catch
    _kind, _reason -> {:retry, "processor_crash", 30}
  end

  def process(_delivery, _options), do: {:fail, "invalid_webhook_delivery"}

  defp dispatch(%{event: "installation", action: "deleted"} = delivery, payload, options),
    do: process_installation_deletion(delivery, payload, options)

  defp dispatch(%{event: event} = delivery, _payload, options)
       when event in ["installation", "installation_repositories"],
       do: refetch_installation(delivery, options)

  defp dispatch(%{event: "repository"} = delivery, _payload, options) do
    case retain_inventory_trigger(delivery, options) do
      {:ok, :deferred} -> :defer
      {:ok, :scheduled} -> :ok
      {:ok, {:scheduled, _operation}} -> :ok
      {:error, :inventory_unavailable} -> {:retry, "inventory_trigger_unavailable", 30}
    end
  end

  defp dispatch(_delivery, _payload, _options), do: :ignore

  defp refetch_installation(delivery, options) do
    config_fetch = Keyword.get(options, :config_fetch, &AppConfig.fetch/0)

    installation_fetch =
      Keyword.get(options, :installation_fetch, &AppAuthentication.get_installation/2)

    now = current_time(options)

    with {:ok, config} <- safe_call(config_fetch),
         {:ok, %AppInstallation{} = installation} <-
           safe_call(installation_fetch, [config, delivery.installation_id]),
         {:ok, _persisted} <- observe(installation_attrs(installation, now), options),
         {:ok, inventory_retention} <- retain_inventory_trigger(delivery, options),
         :ok <- invalidate_token(delivery.installation_id, options) do
      case inventory_retention do
        :deferred -> :defer
        :scheduled -> :ok
        {:scheduled, _operation} -> :ok
      end
    else
      {:error, %Error{kind: :not_found}} ->
        :ignore

      {:error, %Error{} = error} ->
        classify_provider_error(error, now)

      {:error, reason} when reason in [:disabled, :invalid_configuration] ->
        {:retry, "github_app_unavailable", 30}

      {:error, %Ecto.Changeset{}} ->
        {:fail, "invalid_canonical_installation"}

      {:error, reason} when reason in [:identity_mismatch, :invalid_transition] ->
        {:fail, "installation_state_conflict"}

      {:error, :token_broker_unavailable} ->
        {:retry, "token_broker_unavailable", 30}

      {:error, :inventory_unavailable} ->
        {:retry, "inventory_trigger_unavailable", 30}

      _invalid ->
        {:retry, "processor_dependency_unavailable", 30}
    end
  end

  defp process_installation_deletion(delivery, payload, options) do
    with %{"installation" => installation_payload} <- payload,
         {:ok, %AppInstallation{} = installation} <-
           AppInstallation.from_json(installation_payload),
         true <- installation.id == delivery.installation_id,
         :ok <- persist_revocation(installation, current_time(options), options),
         :ok <- revoke_bound_organization(delivery.installation_id, options),
         :ok <- revoke_token(delivery.installation_id, options) do
      :ok
    else
      false ->
        {:fail, "webhook_routing_mismatch"}

      {:error, :invalid_response} ->
        {:fail, "invalid_webhook_payload"}

      {:error, %Ecto.Changeset{}} ->
        {:fail, "invalid_webhook_payload"}

      {:error, reason} when reason in [:identity_mismatch, :invalid_transition] ->
        {:fail, "installation_state_conflict"}

      {:error, :token_broker_unavailable} ->
        {:retry, "token_broker_unavailable", 30}

      {:error, :organization_mirror_unavailable} ->
        {:retry, "organization_mirror_unavailable", 30}

      _invalid ->
        {:retry, "processor_dependency_unavailable", 30}
    end
  end

  defp persist_revocation(installation, observed_at, options) do
    get_installation =
      Keyword.get(options, :installation_get, &ForgeMirrors.get_github_app_installation/1)

    revoke_installation =
      Keyword.get(options, :installation_revoke, &ForgeMirrors.revoke_github_app_installation/2)

    case safe_call(get_installation, [installation.id]) do
      {:ok, %GitHubAppInstallation{} = persisted} ->
        if same_installation_identity?(persisted, installation) do
          persist_existing_revocation(
            persisted,
            installation.id,
            observed_at,
            revoke_installation
          )
        else
          {:error, :identity_mismatch}
        end

      {:error, :not_found} ->
        attrs = installation_attrs(installation, observed_at) |> Map.put(:state, :revoked)

        case observe(attrs, options) do
          {:ok, %GitHubAppInstallation{state: :revoked}} -> :ok
          other -> other
        end

      other ->
        other
    end
  end

  defp persist_existing_revocation(
         %GitHubAppInstallation{state: :revoked},
         _installation_id,
         _observed_at,
         _revoke_installation
       ),
       do: :ok

  defp persist_existing_revocation(
         %GitHubAppInstallation{},
         installation_id,
         observed_at,
         revoke_installation
       ) do
    case safe_call(revoke_installation, [installation_id, observed_at]) do
      {:ok, %GitHubAppInstallation{state: :revoked}} -> :ok
      other -> other
    end
  end

  defp same_installation_identity?(persisted, installation) do
    persisted.github_account_id == installation.account_id and
      persisted.account_type == installation.account_type
  end

  defp observe(attrs, options) do
    observer =
      Keyword.get(options, :installation_observe, &ForgeMirrors.observe_github_app_installation/1)

    safe_call(observer, [attrs])
  end

  defp invalidate_token(installation_id, options) do
    invalidator = Keyword.get(options, :token_invalidate, &InstallationTokenBroker.invalidate/1)
    normalize_token_result(safe_call(invalidator, [installation_id]))
  end

  defp revoke_token(installation_id, options) do
    revoker = Keyword.get(options, :token_revoke, &InstallationTokenBroker.revoke/1)
    normalize_token_result(safe_call(revoker, [installation_id]))
  end

  defp normalize_token_result(:ok), do: :ok
  defp normalize_token_result(_error), do: {:error, :token_broker_unavailable}

  defp revoke_bound_organization(installation_id, options) do
    revoker =
      Keyword.get(
        options,
        :organization_revoke,
        &ForgeMirrors.revoke_bound_organization_from_webhook/1
      )

    case safe_call(revoker, [installation_id]) do
      {:ok, _unbound_or_mirror} -> :ok
      _error -> {:error, :organization_mirror_unavailable}
    end
  end

  defp retain_inventory_trigger(delivery, options) do
    scheduler =
      Keyword.get(
        options,
        :inventory_schedule,
        &ForgeMirrors.retain_webhook_inventory_trigger/2
      )

    case safe_call(scheduler, [delivery.installation_id, delivery.delivery_guid]) do
      {:ok, result} when result in [:deferred, :scheduled] -> {:ok, result}
      {:ok, {:scheduled, _operation} = result} -> {:ok, result}
      _error -> {:error, :inventory_unavailable}
    end
  end

  defp installation_attrs(installation, observed_at) do
    %{
      github_installation_id: installation.id,
      github_account_id: installation.account_id,
      github_account_login: installation.account_login,
      account_type: installation.account_type,
      repository_selection: installation.repository_selection,
      permissions: installation.permissions,
      state: installation.state,
      last_verified_at: observed_at
    }
  end

  defp decode_payload(raw_payload) when is_binary(raw_payload) do
    case JSON.decode(raw_payload) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _invalid -> {:error, :invalid_payload}
    end
  end

  defp decode_payload(_raw_payload), do: {:error, :invalid_payload}

  defp validate_routing(delivery, payload) do
    payload_action = Map.get(payload, "action")
    payload_installation_id = get_in(payload, ["installation", "id"])

    payload_repository_id =
      case Map.get(payload, "repository") do
        %{"id" => id} -> id
        nil -> nil
        _invalid -> :invalid
      end

    if payload_action == delivery.action and payload_installation_id == delivery.installation_id and
         payload_repository_id == delivery.github_repository_id,
       do: :ok,
       else: {:error, :routing_mismatch}
  end

  defp classify_provider_error(%Error{kind: kind, retry_at: retry_at}, now)
       when kind in @retryable_error_kinds do
    seconds =
      case retry_at do
        %DateTime{} -> DateTime.diff(retry_at, now, :second) |> max(0) |> min(86_400)
        _none -> 30
      end

    {:retry, "github_#{kind}", seconds}
  end

  defp classify_provider_error(%Error{kind: kind}, _now),
    do: {:fail, "github_#{kind}"}

  defp current_time(options) do
    now = Keyword.get(options, :now, fn -> DateTime.utc_now(:microsecond) end).()

    case now do
      %DateTime{time_zone: "Etc/UTC"} -> DateTime.truncate(now, :microsecond)
      _invalid -> raise ArgumentError, "invalid webhook processor clock"
    end
  end

  defp safe_call(function, arguments \\ []) when is_function(function) do
    apply(function, arguments)
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end
end
