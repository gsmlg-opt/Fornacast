defmodule ForgeImports.DiscoveryWorker do
  @moduledoc false

  alias ForgeAccounts.{GitHubCredentialVerification, GitHubProfileSafety, User}
  alias ForgeImports.GitHub.{Error, Organization, Repository}
  alias ForgeImports.{Destination, ImportRun, OneTimeCredential, ReportEntry, RepositoryItem}
  alias Fornacast.{Audit, OperationLease, Repo}

  # F7 bounds one organization lookup, its list bootstrap, and 100 pages at 20s each.
  # This milestone has no heartbeat yet, so 2,400s covers that 2,040s hard bound plus cleanup.
  @default_lease_seconds 2_400
  @max_repositories 10_000

  @spec perform(pos_integer(), keyword()) ::
          {:ok, :awaiting_resolution | :failed | :busy | :ignored}
          | {:error, atom()}
  def perform(run_id, opts \\ [])

  def perform(run_id, opts) when is_integer(run_id) and run_id > 0 and is_list(opts) do
    with {:ok, options} <- options(opts),
         {:ok, capability} <- claim(run_id, options) do
      discover(capability, options)
    else
      :busy -> {:ok, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_run_id, _opts), do: {:error, :invalid_request}

  defp claim(run_id, options) do
    OperationLease.claim(
      ImportRun,
      run_id,
      options.owner,
      DateTime.utc_now(:second),
      options.lease_seconds,
      allowed_states: [:discovering]
    )
  end

  defp discover(%ImportRun{state: :discovering} = capability, options) do
    actor = Repo.get(User, capability.actor_user_id)

    cond do
      not match?(%User{kind: :user, state: :active}, actor) ->
        handle_discovery_result(
          actor || %{id: capability.actor_user_id},
          capability,
          {:error, :forbidden},
          options
        )

      capability.credential_source == :one_time ->
        discover_with_one_time(actor, capability, options)

      capability.credential_source == :saved ->
        discover_with_saved(actor, capability, options)
    end
  end

  defp discover(_capability, _options), do: {:ok, :ignored}

  defp discover_with_one_time(actor, capability, options) do
    reference = make_ref()
    parent = self()

    checkout =
      OneTimeCredential.with_credential(
        actor,
        capability,
        fn pat ->
          result = discover_source(actor, capability, pat, options)
          send(parent, {reference, result})
          :ok
        end,
        options.keyring
      )

    case checkout do
      {:ok, :acknowledged} ->
        handle_discovery_result(actor, capability, receive_result(reference), options)

      {:error, reason} ->
        handle_discovery_result(
          actor,
          capability,
          {:error, normalize_checkout_error(reason)},
          options
        )
    end
  end

  defp discover_with_saved(actor, capability, options) do
    reference = make_ref()
    parent = self()

    with {:ok, callback_result} <-
           ForgeAccounts.with_github_import_credential(
             actor,
             capability.github_identity_id,
             capability.github_credential_id,
             fn pat, %GitHubCredentialVerification{} = current ->
               result =
                 if saved_reference_matches?(capability, current) do
                   discover_source(actor, capability, pat, options)
                 else
                   {:error, :credential_changed}
                 end

               send(parent, {reference, {result, current}})
               :ok
             end
           ),
         :ok <- callback_result do
      handle_saved_discovery_result(actor, capability, receive_result(reference), options)
    else
      {:error, reason} ->
        handle_discovery_result(
          actor,
          capability,
          {:error, normalize_checkout_error(reason)},
          options
        )
    end
  end

  defp saved_reference_matches?(capability, reference) do
    reference.credential_id == capability.github_credential_id and
      reference.identity_id == capability.github_identity_id and
      reference.local_user_id == capability.actor_user_id
  end

  defp discover_source(actor, capability, pat, options) do
    client_options = put_gate(options.client_options, gate_key(capability))

    case capability.source_kind do
      :repository ->
        discover_repository(actor, capability, pat, options.client, client_options)

      :organization ->
        discover_organization(actor, capability, pat, options.client, client_options)
    end
  end

  defp discover_repository(actor, capability, pat, client, client_options) do
    [owner, repository] = String.split(capability.source_repository_full_name, "/", parts: 2)

    with {:ok, source} <- client.repository(pat, owner, repository, client_options),
         {:ok, source} <- validate_repository(actor, source, pat),
         :ok <- exact_repository(source, owner, repository),
         {:ok, destination} <- Destination.personal(actor) do
      {:ok,
       %{
         source_owner_github_id: source.owner_id,
         source_owner_login: source.owner_login,
         source_repository_github_id: source.id,
         source_repository_full_name: source.full_name,
         source_metadata: %{},
         safety_profiles: [source],
         repository_plans:
           Destination.repository_plans([source], destination, DateTime.utc_now(:second))
       }}
    else
      {:error, %Error{kind: kind}} -> {:error, kind}
      {:error, reason} -> {:error, normalize_source_error(reason)}
    end
  end

  defp discover_organization(actor, capability, pat, client, client_options) do
    with {:ok, source} <- client.organization(pat, capability.source_owner_login, client_options),
         {:ok, source} <- validate_organization(actor, source, pat),
         :ok <- exact_organization(source, capability.source_owner_login),
         observed_at = DateTime.utc_now(:second),
         {:ok, repositories} <-
           client.organization_repositories(pat, capability.source_owner_login, client_options),
         {:ok, repositories} <-
           validate_organization_repositories(actor, source, repositories, pat),
         {:ok, destination} <- destination_for_run(actor, capability, source.login) do
      {:ok,
       %{
         source_owner_github_id: source.id,
         source_owner_login: source.login,
         source_repository_github_id: nil,
         source_repository_full_name: nil,
         source_metadata: organization_metadata(source, observed_at),
         safety_profiles: [source | repositories],
         repository_plans: Destination.repository_plans(repositories, destination, observed_at)
       }}
    else
      {:error, %Error{kind: kind}} -> {:error, kind}
      {:error, reason} -> {:error, normalize_source_error(reason)}
    end
  end

  defp validate_repository(actor, %Repository{} = source, pat) do
    json =
      %{
        "id" => source.id,
        "name" => source.name,
        "full_name" => source.full_name,
        "owner" => %{"id" => source.owner_id, "login" => source.owner_login},
        "description" => source.description,
        "visibility" => enum_string(source.visibility),
        "default_branch" => source.default_branch,
        "has_issues" => source.has_issues,
        "fork" => source.fork,
        "archived" => source.archived,
        "html_url" => source.html_url,
        "updated_at" => datetime_string(source.updated_at),
        "pushed_at" => datetime_string(source.pushed_at)
      }
      |> maybe_put_boolean("allow_merge_commit", source.allow_merge_commit)

    with {:ok, safe} <- Repository.from_json(json),
         :ok <- GitHubProfileSafety.validate(safe, pat),
         :ok <- ForgeAccounts.validate_github_external_profile(actor, safe) do
      {:ok, safe}
    else
      {:error, :credential_service_unavailable} = error -> error
      _invalid -> {:error, :invalid_response}
    end
  end

  defp validate_repository(_actor, _source, _pat), do: {:error, :invalid_response}

  defp validate_organization(actor, %Organization{} = source, pat) do
    json = %{
      "id" => source.id,
      "login" => source.login,
      "name" => source.name,
      "description" => source.description,
      "avatar_url" => source.avatar_url,
      "html_url" => source.html_url
    }

    with {:ok, safe} <- Organization.from_json(json),
         :ok <- GitHubProfileSafety.validate(safe, pat),
         :ok <- ForgeAccounts.validate_github_external_profile(actor, safe) do
      {:ok, safe}
    else
      {:error, :credential_service_unavailable} = error -> error
      _invalid -> {:error, :invalid_response}
    end
  end

  defp validate_organization(_actor, _source, _pat), do: {:error, :invalid_response}

  defp validate_organization_repositories(actor, source, repositories, pat)
       when is_list(repositories) and length(repositories) <= @max_repositories do
    repositories
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn repository, {:ok, safe, ids} ->
      with {:ok, repository} <- validate_repository(actor, repository, pat),
           true <- repository.owner_id == source.id,
           true <- String.downcase(repository.owner_login) == String.downcase(source.login),
           true <-
             String.downcase(repository.full_name) ==
               String.downcase("#{source.login}/#{repository.name}"),
           false <- MapSet.member?(ids, repository.id) do
        {:cont, {:ok, [repository | safe], MapSet.put(ids, repository.id)}}
      else
        _invalid -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, safe, _ids} -> {:ok, Enum.reverse(safe)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_organization_repositories(_actor, _source, _repositories, _pat),
    do: {:error, :invalid_response}

  defp exact_repository(source, owner, repository) do
    if String.downcase(source.owner_login) == String.downcase(owner) and
         String.downcase(source.name) == String.downcase(repository) and
         String.downcase(source.full_name) == String.downcase("#{owner}/#{repository}") do
      :ok
    else
      {:error, :source_changed}
    end
  end

  defp exact_organization(source, login) do
    if String.downcase(source.login) == String.downcase(login),
      do: :ok,
      else: {:error, :source_changed}
  end

  defp destination_for_run(actor, %{destination_organization_action: :new} = run, login) do
    Destination.organization(actor, login, %{
      action: :new,
      slug: run.destination_organization_slug
    })
  end

  defp destination_for_run(actor, %{destination_organization_action: :existing} = run, login) do
    Destination.organization(actor, login, %{
      action: :existing,
      id: run.destination_organization_id
    })
  end

  defp destination_for_run(_actor, _run, _login), do: {:error, :invalid_destination}

  defp handle_saved_discovery_result(
         actor,
         capability,
         {{:error, :invalid_credential}, %GitHubCredentialVerification{} = reference},
         options
       ) do
    with {:ok, fresh} <- fresh_capability(capability, options.lease_seconds) do
      case ForgeAccounts.mark_github_credential_invalid(
             actor,
             capability.github_identity_id,
             reference,
             capability.request_metadata
           ) do
        {:ok, _view} ->
          finalize_failure(actor, fresh, :invalid_credential)

        {:error, reason} when reason in [:stale, :not_found] ->
          finalize_failure(actor, fresh, :credential_changed)

        {:error, reason} ->
          finalize_failure(actor, fresh, normalize_checkout_error(reason))
      end
    end
  end

  defp handle_saved_discovery_result(actor, capability, {result, _reference}, options),
    do: handle_discovery_result(actor, capability, result, options)

  defp handle_saved_discovery_result(actor, capability, _invalid, options),
    do: handle_discovery_result(actor, capability, {:error, :invalid_response}, options)

  defp handle_discovery_result(actor, capability, result, options) do
    with {:ok, fresh} <- fresh_capability(capability, options.lease_seconds) do
      finalize_discovery_result(actor, fresh, result)
    end
  end

  defp finalize_discovery_result(actor, capability, {:ok, plan}),
    do: finalize_success(actor, capability, plan)

  defp finalize_discovery_result(actor, capability, {:error, reason}),
    do: finalize_failure(actor, capability, reason)

  defp finalize_discovery_result(actor, capability, _invalid),
    do: finalize_failure(actor, capability, :invalid_response)

  defp fresh_capability(capability, lease_seconds) do
    OperationLease.renew_owned(ImportRun, capability,
      now: DateTime.utc_now(:second),
      lease_seconds: lease_seconds
    )
  end

  defp finalize_success(actor, capability, plan) do
    transaction = fn ->
      case ForgeAccounts.validate_github_external_profiles(actor, plan.safety_profiles) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      inserted =
        Enum.map(plan.repository_plans, fn item_plan ->
          attrs = Map.put(item_plan.attrs, :import_run_id, capability.id)

          case %RepositoryItem{}
               |> RepositoryItem.discovery_plan_changeset(attrs)
               |> Repo.insert() do
            {:ok, item} -> {item, item_plan.warnings}
            {:error, changeset} -> Repo.rollback({:invalid_plan, changeset})
          end
        end)

      Enum.each(inserted, fn {item, warnings} ->
        Enum.each(warnings, &insert_warning!(capability, item, &1))
      end)

      selected_count = length(inserted)

      warning_count =
        Enum.reduce(inserted, 0, fn {_item, warnings}, sum -> sum + length(warnings) end)

      updates = [
        state: :awaiting_resolution,
        source_owner_github_id: plan.source_owner_github_id,
        source_owner_login: plan.source_owner_login,
        source_repository_github_id: plan.source_repository_github_id,
        source_repository_full_name: plan.source_repository_full_name,
        source_metadata: plan.source_metadata,
        selected_count: selected_count,
        warning_count: warning_count
      ]

      with {:ok, updated} <- OperationLease.update_owned(ImportRun, capability, updates),
           {:ok, _audit} <-
             Audit.record(
               actor,
               "github_import.discovered",
               "github_import_run",
               capability.id,
               %{
                 "source_kind" => Atom.to_string(capability.source_kind),
                 "repository_count" => selected_count,
                 "warning_count" => warning_count
               },
               request_metadata: capability.request_metadata
             ) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    case Repo.transaction(transaction) do
      {:ok, %ImportRun{state: :awaiting_resolution}} -> {:ok, :awaiting_resolution}
      {:error, :lost_lease} -> {:error, :lost_lease}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp finalize_failure(actor, capability, reason) do
    {classification, summary} = failure(reason)
    now = DateTime.utc_now(:second)

    transaction = fn ->
      insert_failure!(capability, classification, summary)

      with {:ok, failed} <-
             OperationLease.update_owned(ImportRun, capability,
               state: :failed,
               terminal_at: now,
               report_finalized_at: now,
               failure_kind: classification,
               failure_detail: summary,
               failure_count: 1
             ),
           {:ok, _audit} <-
             Audit.record(
               actor,
               "github_import.discovery_failed",
               "github_import_run",
               capability.id,
               %{"classification" => classification},
               request_metadata: capability.request_metadata
             ) do
        failed
      else
        {:error, error} -> Repo.rollback(error)
      end
    end

    case Repo.transaction(transaction) do
      {:ok, %ImportRun{state: :failed}} -> {:ok, :failed}
      {:error, :lost_lease} -> {:error, :lost_lease}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp insert_warning!(run, item, classification) do
    summary = warning_summary(classification)

    %ReportEntry{}
    |> ReportEntry.create_changeset(%{
      import_run_id: run.id,
      repository_item_id: item.id,
      idempotency_key: "discovery-warning-#{item.github_repository_id}-#{classification}",
      scope: :repository,
      outcome: :warning,
      classification: classification,
      summary: summary,
      metadata: %{"category" => classification},
      source_count: warning_source_count(classification)
    })
    |> Repo.insert!()
  end

  defp insert_failure!(run, classification, summary) do
    %ReportEntry{}
    |> ReportEntry.create_changeset(%{
      import_run_id: run.id,
      idempotency_key: "discovery-failure",
      scope: :run,
      outcome: :failed,
      classification: classification,
      summary: summary,
      metadata: %{"phase" => "discovery"},
      source_count: 0
    })
    |> Repo.insert!()
  end

  defp warning_summary("visibility_downgraded"),
    do: "GitHub internal visibility will be imported as private"

  defp warning_summary("unsupported_fork_relationship"),
    do: "GitHub fork relationships are not imported"

  defp warning_summary("unsupported_archived_state"),
    do: "GitHub archived state is not imported"

  defp warning_summary("unsupported_releases"),
    do: "GitHub releases and release assets are not enumerated or imported"

  defp warning_source_count("unsupported_releases"), do: 0
  defp warning_source_count(_classification), do: 1

  defp failure(reason) do
    classification =
      case reason do
        :credential_service_unavailable -> "credential_service_unavailable"
        :invalid_credential -> "github_invalid_credential"
        :credential_changed -> "github_credential_changed"
        :forbidden -> "github_forbidden"
        :not_found -> "github_not_found"
        :source_changed -> "github_source_changed"
        :invalid_destination -> "invalid_destination"
        :not_owned -> "invalid_destination"
        kind when is_atom(kind) -> "github_#{kind}"
        _ -> "github_discovery_failed"
      end

    {classification, failure_summary(classification)}
  end

  defp failure_summary("credential_service_unavailable"),
    do: "The GitHub credential could not be checked out safely"

  defp failure_summary("github_invalid_credential"), do: "GitHub rejected the credential"
  defp failure_summary("github_forbidden"), do: "The credential cannot access this GitHub source"
  defp failure_summary("github_not_found"), do: "The GitHub source was not found"
  defp failure_summary("github_source_changed"), do: "The GitHub source identity changed"
  defp failure_summary("invalid_destination"), do: "The local destination is not available"
  defp failure_summary(_classification), do: "GitHub discovery could not be completed"

  defp organization_metadata(source, observed_at) do
    %{
      "name" => source.name,
      "description" => source.description,
      "avatar_url" => source.avatar_url,
      "profile_url" => source.html_url,
      "observed_at" => DateTime.to_iso8601(observed_at)
    }
  end

  defp enum_string(value) when is_atom(value), do: Atom.to_string(value)
  defp enum_string(value), do: value
  defp datetime_string(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_string(nil), do: nil

  defp maybe_put_boolean(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp maybe_put_boolean(map, _key, _value), do: map

  defp gate_key(%ImportRun{credential_source: :one_time, id: id}), do: {:one_time_run, id}

  defp gate_key(%ImportRun{credential_source: :saved, github_credential_id: id}),
    do: {:saved_credential, id}

  defp put_gate(options, gate_key),
    do: options |> Keyword.delete(:gate_key) |> Keyword.put(:gate_key, gate_key)

  defp receive_result(reference) do
    receive do
      {^reference, result} -> result
    after
      0 -> {:error, :invalid_response}
    end
  end

  defp normalize_checkout_error(reason)
       when reason in [
              :credential_service_unavailable,
              :unsafe_credential_result,
              :credential_invalid,
              :not_found,
              :forbidden
            ],
       do: if(reason == :credential_invalid, do: :invalid_credential, else: reason)

  defp normalize_checkout_error(_reason), do: :credential_service_unavailable

  defp normalize_source_error(reason)
       when reason in [
              :invalid_response,
              :source_changed,
              :invalid_destination,
              :not_found,
              :forbidden,
              :invalid_credential,
              :credential_service_unavailable,
              :primary_rate_limit,
              :secondary_rate_limit,
              :upstream_unavailable,
              :unexpected_status,
              :transport,
              :timeout,
              :host_unavailable,
              :unsafe_host,
              :response_too_large,
              :invalid_json,
              :invalid_pagination,
              :pagination_limit,
              :request_gate_busy
            ],
       do: reason

  defp normalize_source_error(_reason), do: :invalid_response

  defp options(opts) do
    allowed = ~w(owner lease_seconds client client_options keyring)a

    if Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      client = Keyword.get(opts, :client, ForgeImports.GitHub.Client)
      client_options = Keyword.get(opts, :client_options, [])
      lease_seconds = Keyword.get(opts, :lease_seconds, @default_lease_seconds)
      owner = Keyword.get(opts, :owner, generated_owner())
      keyring = Keyword.get(opts, :keyring, Fornacast.Config.github_credential_keyring())

      if is_atom(client) and Code.ensure_loaded?(client) and Keyword.keyword?(client_options) and
           not Keyword.has_key?(client_options, :gate_key) and is_integer(lease_seconds) and
           lease_seconds in 1..@default_lease_seconds and is_binary(owner) and
           byte_size(owner) in 1..255 do
        {:ok,
         %{
           client: client,
           client_options: client_options,
           lease_seconds: lease_seconds,
           owner: owner,
           keyring: keyring
         }}
      else
        {:error, :invalid_request}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp generated_owner do
    "github-discovery-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end
end
