defmodule ForgeMirrors.PatSettings do
  @moduledoc "Organization-owner PAT configuration, separate from active App mirrors."
  import Ecto.Query
  import Ecto.Changeset
  alias ForgeMirrors.PatConfiguration
  alias Fornacast.{Repo, Audit}

  def view(actor, organization_id) do
    with {:ok, organization} <-
           ForgeAccounts.fetch_manageable_organization(actor, organization_id),
         {:ok, owners} <- ForgeAccounts.organization_github_owners(actor, organization_id) do
      config =
        Repo.get_by(PatConfiguration, organization_id: organization_id) ||
          %PatConfiguration{
            organization_id: organization_id,
            github_organization: organization.username
          }

      {:ok, %{config: config, owners: owners, credential: credential(config, owners)}}
    end
  end

  def save(actor, organization_id, attrs, metadata) when is_map(attrs) do
    mutate(actor, organization_id, attrs["lock_version"], metadata, fn config, owners ->
      if Map.has_key?(attrs, "lock_version") and
           Enum.all?(
             Map.keys(attrs),
             &(&1 in ~w(owner_user_id github_identity_id github_organization enabled paused trigger_mode interval_minutes lock_version))
           ) do
        changeset = PatConfiguration.changeset(config, attrs)
        candidate = apply_changes(changeset)

        cond do
          not changeset.valid? ->
            {:error, :invalid_request}

          candidate.owner_user_id != nil and candidate.owner_user_id != config.owner_user_id and
              not Enum.any?(owners, &(&1.id == candidate.owner_user_id)) ->
            {:error, :credential_unavailable}

          candidate.enabled and not valid_credential?(credential(candidate, owners)) ->
            {:error, :credential_unavailable}

          candidate.github_identity_id != nil and credential(candidate, owners) == nil and
              (candidate.github_identity_id != config.github_identity_id or
                 candidate.owner_user_id != config.owner_user_id) ->
            {:error, :credential_unavailable}

          true ->
            changed_source =
              Enum.any?(
                [:owner_user_id, :github_identity_id, :github_organization],
                &(Map.get(candidate, &1) != Map.get(config, &1))
              )

            changeset =
              if changed_source do
                change(changeset,
                  inventory: %{},
                  inventory_refreshed_at: nil,
                  selected_repository_ids: [],
                  repository_selection: "all"
                )
              else
                changeset
              end

            {:ok, changeset}
        end
      else
        {:error, :invalid_request}
      end
    end)
  end

  def mark_sync(actor, organization_id, status, metadata)
      when status in ["running", "succeeded", "failed"] do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(metadata),
         {:ok, %{config: config}} <- view(actor, organization_id) do
      changes = change(config, last_sync_at: DateTime.utc_now(:second), last_sync_status: status)

      with {:ok, saved} <- Repo.update(changes),
           {:ok, _audit} <-
             Audit.record(
               actor,
               "organization.github_pat.sync",
               "organization",
               organization_id,
               %{"status" => status},
               request_metadata: safe_metadata
             ) do
        {:ok, saved}
      end
    end
  end

  def set_paused(actor, organization_id, paused, metadata) when is_boolean(paused) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(metadata),
         {:ok, %{config: config}} <- view(actor, organization_id),
         {:ok, saved} <- Repo.update(change(config, paused: paused)),
         {:ok, _audit} <-
           Audit.record(
             actor,
             "organization.github_pat.pause",
             "organization",
             organization_id,
             %{"paused" => paused},
             request_metadata: safe_metadata
           ) do
      {:ok, saved}
    end
  end

  def select_repositories(actor, organization_id, attrs, metadata) when is_map(attrs) do
    mutate(actor, organization_id, attrs["lock_version"], metadata, fn config, _owners ->
      with true <-
             Enum.sort(Map.keys(attrs)) ==
               Enum.sort(~w(lock_version repository_selection selected_repository_ids)),
           mode when mode in ["all", "selected"] <- attrs["repository_selection"],
           values when is_list(values) and length(values) <= 10_001 <-
             attrs["selected_repository_ids"],
           {:ok, ids} <- ids(Enum.reject(values, &(&1 == ""))),
           true <- mode == "all" or ids != [],
           available = config.inventory |> Map.get("repositories", []) |> Enum.map(& &1["id"]),
           true <- Enum.all?(ids, &(&1 in available)) do
        {:ok, change(config, repository_selection: mode, selected_repository_ids: ids)}
      else
        _ -> {:error, :invalid_request}
      end
    end)
  end

  @doc false
  def store_inventory(actor, organization_id, version, inventory, metadata) do
    mutate(actor, organization_id, version, metadata, fn config, owners ->
      if valid_credential?(credential(config, owners)) do
        {:ok,
         change(config, inventory: inventory, inventory_refreshed_at: DateTime.utc_now(:second))}
      else
        {:error, :credential_unavailable}
      end
    end)
  end

  defp mutate(actor, organization_id, version, metadata, fun) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(metadata) do
      Repo.transact(fn ->
        with {:ok, _organization} <-
               ForgeAccounts.fetch_manageable_organization(actor, organization_id),
             # Serialize creation as well as later configuration changes.
             _ <-
               Repo.one(
                 from o in ForgeAccounts.Organization,
                   where: o.id == ^organization_id,
                   lock: "FOR UPDATE"
               ),
             {:ok, %{config: config, owners: owners}} <- view(actor, organization_id),
             true <- to_string(config.lock_version) == version,
             {:ok, changeset} <- fun.(config, owners),
             {:ok, saved} <-
               Repo.insert_or_update(change(changeset, lock_version: config.lock_version + 1)),
             {:ok, _audit} <-
               Audit.record(
                 actor,
                 "organization.github_pat.configure",
                 "organization",
                 organization_id,
                 %{},
                 request_metadata: safe_metadata
               ) do
          {:ok, saved}
        else
          false -> {:error, :stale}
          {:error, %Ecto.Changeset{}} -> {:error, :invalid_request}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  defp credential(config, owners) do
    with %{accounts: accounts} <- Enum.find(owners, &(&1.id == config.owner_user_id)) do
      Enum.find(accounts, &(&1.identity_id == config.github_identity_id))
    end
  end

  defp valid_credential?(%{credential_present: true, credential_status: :valid}), do: true
  defp valid_credential?(_), do: false

  defp ids(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case is_binary(value) && Integer.parse(value) do
        {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 ->
          if Integer.to_string(id) == value and id not in acc,
            do: {:cont, {:ok, [id | acc]}},
            else: {:halt, {:error, :invalid_request}}

        _ ->
          {:halt, {:error, :invalid_request}}
      end
    end)
  end
end
