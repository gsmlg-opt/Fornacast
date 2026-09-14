defmodule ForgeImports.OrganizationSync.InventoryImportWorker do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.Organization
  alias ForgeImports.{ImportRun, RepositoryItem, Worker}
  alias Fornacast.Repo

  @kind "bootstrap.repository_import"
  @retryable_discovery_failures ~w(
    credential_service_unavailable
    github_primary_rate_limit
    github_secondary_rate_limit
    github_upstream_unavailable
    github_unexpected_status
    github_transport
    github_timeout
    github_host_unavailable
    github_request_gate_busy
  )

  @doc false
  def run_once(owner, opts \\ [])

  def run_once(owner, opts) when is_binary(owner) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now(:second) end)
    claim = Keyword.get(opts, :claim, &ForgeMirrors.claim_operations/5)

    with {:ok, operations} <-
           claim.(owner, now, Keyword.get(opts, :lease_seconds, 120), 1, [@kind]) do
      {:ok, Enum.map(operations, &{&1.id, process(&1, owner, now, opts)})}
    end
  end

  def run_once(_, _), do: {:error, :invalid_argument}

  defp process(operation, owner, now, opts) do
    context = Keyword.get(opts, :context, &ForgeMirrors.inventory_import_operation_context/1)

    with {:ok, context} <- context.(operation),
         {:ok, run} <- find_or_create_run(context, operation) do
      process_run(operation, run, owner, now, opts)
    else
      {:error, _reason} = error -> error
      _other -> {:error, :persistence_unavailable}
    end
  end

  defp process_run(operation, %ImportRun{state: :failed} = run, _owner, now, _opts) do
    ForgeMirrors.fail_operation(
      operation,
      now,
      terminal_failure_class(run.failure_kind),
      "inventory import discovery failed"
    )
  end

  defp process_run(operation, %ImportRun{state: :canceled}, _owner, now, _opts) do
    ForgeMirrors.fail_operation(
      operation,
      now,
      "provider_validation",
      "inventory import discovery was canceled"
    )
  end

  defp process_run(operation, run, owner, now, opts) do
    case selected_item(run.id) do
      {:ok, item} when item.state in [:published, :completed] ->
        case operation.cursor do
          %{"import_run_id" => run_id, "repository_item_id" => item_id}
          when run_id == run.id and item_id == item.id ->
            ForgeMirrors.complete_inventory_import_operation(operation, item.id, now)

          _other ->
            materialize_or_defer(operation, run, item, now)
        end

      {:ok, item} ->
        with {:ok, materialized} <-
               ForgeMirrors.record_inventory_import_materialization(
                 operation,
                 run.id,
                 item.id,
                 now
               ),
             {:ok, _operation} <-
               ForgeMirrors.retry_operation(
                 materialized,
                 now,
                 DateTime.add(now, 5, :second),
                 "network",
                 failure_detail: "inventory import awaiting publication"
               ) do
          :pending
        end

      {:error, :pending} ->
        discovery = Keyword.get(opts, :discovery, &Worker.run_discovery/3)
        _result = discovery.(run.id, owner, Keyword.get(opts, :discovery_options, []))

        ForgeMirrors.retry_operation(
          operation,
          now,
          DateTime.add(now, 5, :second),
          "network",
          failure_detail: "inventory import discovery pending"
        )
    end
  end

  defp materialize_or_defer(operation, run, item, now) do
    with {:ok, materialized} <-
           ForgeMirrors.record_inventory_import_materialization(operation, run.id, item.id, now) do
      ForgeMirrors.retry_operation(
        materialized,
        now,
        DateTime.add(now, 5, :second),
        "network",
        failure_detail: "inventory import awaiting publication"
      )
    end
  end

  defp find_or_create_run(context, operation) do
    case current_run(operation.id) do
      %ImportRun{} = run -> verify_run(run, context)
      nil -> create_run(context, operation, retryable_predecessor(operation.id))
    end
  end

  defp create_run(
         %{actor: actor, organization_mirror: organization, repository_mirror: repository},
         operation,
         predecessor
       ) do
    destination = Repo.get(Organization, organization.organization_id)

    attrs =
      %{
        mirror_operation_id: operation.id,
        source_kind: :repository,
        credential_source: :github_app,
        source_owner_github_id: organization.github_account_id,
        source_owner_login: organization.github_account_login,
        source_repository_github_id: repository.github_repository_id,
        source_repository_full_name: repository.github_full_name,
        destination_organization_action: :existing,
        destination_organization_id: organization.organization_id,
        destination_organization_slug: destination.username,
        destination_organization_status: :clean,
        request_metadata: %{"operation_id" => "inventory-import-#{operation.id}"}
      }
      |> maybe_put_predecessor(predecessor)

    case ForgeImports.create_run(actor, attrs) do
      {:ok, run} ->
        {:ok, run}

      {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
        case current_run(operation.id) do
          %ImportRun{} = run ->
            verify_run(run, %{organization_mirror: organization, repository_mirror: repository})

          nil ->
            {:error, :persistence_unavailable}
        end

      error ->
        error
    end
  end

  defp verify_run(run, %{organization_mirror: organization, repository_mirror: repository}) do
    if run.credential_source == :github_app and run.source_kind == :repository and
         run.source_owner_github_id == organization.github_account_id and
         run.source_repository_github_id == repository.github_repository_id and
         run.destination_organization_id == organization.organization_id,
       do: {:ok, run},
       else: {:error, :invalid_transition}
  end

  defp current_run(operation_id) do
    Repo.one(
      from run in ImportRun,
        where:
          run.mirror_operation_id == ^operation_id and
            (run.state != :failed or is_nil(run.failure_kind) or
               run.failure_kind not in ^@retryable_discovery_failures),
        order_by: [desc: run.id],
        limit: 1
    )
  end

  defp retryable_predecessor(operation_id) do
    Repo.one(
      from run in ImportRun,
        where:
          run.mirror_operation_id == ^operation_id and run.state == :failed and
            run.failure_kind in ^@retryable_discovery_failures,
        order_by: [desc: run.id],
        limit: 1
    )
  end

  defp maybe_put_predecessor(attrs, %ImportRun{id: predecessor_id}),
    do: Map.put(attrs, :predecessor_run_id, predecessor_id)

  defp maybe_put_predecessor(attrs, nil), do: attrs

  defp terminal_failure_class(failure_kind)
       when failure_kind in ["github_forbidden", "github_not_found"],
       do: "permission_missing"

  defp terminal_failure_class("github_revoked"), do: "credential_revoked"
  defp terminal_failure_class(_failure_kind), do: "provider_validation"

  defp selected_item(run_id) do
    case Repo.one(
           from item in RepositoryItem,
             where: item.import_run_id == ^run_id and item.selected == true,
             order_by: [asc: item.id],
             limit: 1
         ) do
      %RepositoryItem{} = item -> {:ok, item}
      nil -> {:error, :pending}
    end
  end
end
