defmodule FornacastWeb.ImportController do
  use FornacastWeb, :controller

  alias ForgeAccounts.{GitHubAccountView, Organization, User}
  alias ForgeAccounts.GitHubAccounts.CredentialCallbackError
  alias ForgeImports.Discovery.CredentialBootstrapError
  alias ForgeImports.GitHubAccounts.CredentialVerificationError
  alias ForgeImports.{ImportRun, RepositoryItem, RunView, SafeValue}
  alias FornacastWeb.{ImportHTML, RequestMetadata}

  plug :require_active_user

  @max_id 9_223_372_036_854_775_807
  @max_pat_bytes 4_096
  @max_repository_reference_bytes 512
  @max_organization_login_bytes 39
  @max_destination_slug_bytes 255
  @max_replacement_confirmation_bytes 512
  @max_selection_size 10_000
  @canonical_id ~r/\A[1-9][0-9]*\z/
  @recoverable_turso_codes [:busy, :io, :corrupt]

  def repository_new(%Plug.Conn{assigns: %{current_user: actor}} = conn, _params),
    do: render_entry(conn, actor, :repository)

  def organization_new(%Plug.Conn{assigns: %{current_user: actor}} = conn, _params),
    do: render_entry(conn, actor, :organization)

  def repository_discover(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, attrs} <- repository_discovery_params(params),
         result <-
           service_call(fn ->
             imports(conn).create_repository_discovery(
               actor,
               attrs,
               RequestMetadata.from_conn(conn)
             )
           end) do
      handle_discovery_result(conn, actor, :repository, result)
    else
      {:error, reason} -> render_discovery_error(conn, actor, :repository, reason)
    end
  end

  def organization_discover(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, organizations} <- owned_organizations(conn, actor),
         {:ok, attrs} <- organization_discovery_params(organizations, params),
         result <-
           service_call(fn ->
             imports(conn).create_organization_discovery(
               actor,
               attrs,
               RequestMetadata.from_conn(conn)
             )
           end) do
      handle_discovery_result(conn, actor, :organization, result)
    else
      {:error, reason} -> render_discovery_error(conn, actor, :organization, reason)
    end
  end

  def show(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, run_id} <- canonical_id(Map.get(params, "id")) do
      case service_call(fn -> imports(conn).get_run_view(actor, run_id) end) do
        {:ok, %RunView{} = run} ->
          case validate_run_view(run, actor, run_id) do
            :ok ->
              case owned_organizations(conn, actor) do
                {:ok, organizations} -> render_run(conn, run, organizations)
                {:error, _reason} -> render_fixed_error(conn, :unavailable)
              end

            {:error, :not_found} ->
              render_fixed_error(conn, :not_found)

            {:error, :invalid_view} ->
              render_fixed_error(conn, :unavailable)
          end

        {:error, reason} ->
          render_update_error(conn, reason)

        _unexpected ->
          render_fixed_error(conn, :unavailable)
      end
    else
      {:error, :not_found} -> render_fixed_error(conn, :not_found)
    end
  end

  def conflicts(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, run_id} <- canonical_id(Map.get(params, "id")),
         {:ok, run} <- fetch_run_view(conn, actor, run_id) do
      cond do
        not clean_destination?(run) -> redirect_to_run(conn, run_id)
        not conflict_resolution_state?(run) -> redirect_to_run(conn, run_id)
        unresolved_conflicts?(run) -> render_conflicts(conn, run)
        true -> redirect_to_review(conn, run_id)
      end
    else
      {:error, reason} -> render_run_lookup_error(conn, reason)
    end
  end

  def resolve_conflicts(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, run_id} <- canonical_id(Map.get(params, "id")),
         {:ok, run} <- fetch_run_view(conn, actor, run_id) do
      cond do
        not clean_destination?(run) ->
          redirect_to_run(conn, run_id)

        not conflict_resolution_state?(run) ->
          redirect_to_run(conn, run_id)

        not unresolved_conflicts?(run) ->
          redirect_to_review(conn, run_id)

        true ->
          case conflict_decisions(run, params) do
            {:ok, decisions} ->
              result =
                service_call(fn ->
                  imports(conn).resolve_repository_conflicts(
                    actor,
                    run_id,
                    decisions,
                    RequestMetadata.from_conn(conn)
                  )
                end)

              handle_conflict_resolution(conn, actor, run, run_id, result)

            {:error, _reason} ->
              conn
              |> put_status(:unprocessable_entity)
              |> render_conflicts(run, conflict_choices_message())
          end
      end
    else
      {:error, reason} -> render_run_lookup_error(conn, reason)
    end
  end

  def review(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, run_id} <- canonical_id(Map.get(params, "id")),
         {:ok, run} <- fetch_run_view(conn, actor, run_id) do
      cond do
        not clean_destination?(run) ->
          redirect_to_run(conn, run_id)

        not reviewable_state?(run) ->
          redirect_to_run(conn, run_id)

        unresolved_conflicts?(run) and conflict_resolution_state?(run) ->
          redirect_to_conflicts(conn, run_id)

        unresolved_conflicts?(run) ->
          redirect_to_run(conn, run_id)

        true ->
          render_review(conn, run)
      end
    else
      {:error, reason} -> render_run_lookup_error(conn, reason)
    end
  end

  def selection(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, run_id} <- canonical_id(Map.get(params, "id")),
         {:ok, repository_ids} <- selection_params(params),
         result <-
           service_call(fn ->
             imports(conn).update_repository_selection(actor, run_id, repository_ids)
           end) do
      handle_update_result(conn, actor, run_id, result)
    else
      {:error, reason} -> render_update_error(conn, reason)
    end
  end

  def destination(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, run_id} <- canonical_id(Map.get(params, "id")),
         {:ok, organizations} <- owned_organizations(conn, actor),
         {:ok, destination} <-
           destination_params(organizations, params, require_new_slug?: true),
         result <-
           service_call(fn ->
             imports(conn).update_organization_destination(actor, run_id, destination)
           end) do
      handle_update_result(conn, actor, run_id, result)
    else
      {:error, reason} -> render_update_error(conn, reason)
    end
  end

  defp handle_discovery_result(conn, actor, _kind, {:ok, %RunView{} = run}) do
    case validate_run_view(run, actor, run.id) do
      :ok -> redirect_to_run(conn, run.id)
      {:error, _reason} -> render_fixed_error(conn, :unavailable)
    end
  end

  defp handle_discovery_result(conn, actor, kind, {:error, reason}),
    do: render_discovery_error(conn, actor, kind, reason)

  defp handle_discovery_result(conn, actor, kind, _unexpected),
    do: render_discovery_error(conn, actor, kind, :discovery_failed)

  defp handle_update_result(conn, actor, run_id, {:ok, %RunView{} = run}) do
    case validate_run_view(run, actor, run_id) do
      :ok -> redirect_to_run(conn, run_id)
      {:error, _reason} -> render_fixed_error(conn, :unavailable)
    end
  end

  defp handle_update_result(conn, _actor, _run_id, {:error, reason}),
    do: render_update_error(conn, reason)

  defp handle_update_result(conn, _actor, _run_id, _unexpected),
    do: render_fixed_error(conn, :unavailable)

  defp handle_conflict_resolution(conn, actor, _run, run_id, {:ok, %RunView{} = resolved}) do
    case validate_run_view(resolved, actor, run_id) do
      :ok -> redirect_to_review(conn, run_id)
      {:error, :not_found} -> render_fixed_error(conn, :not_found)
      {:error, :invalid_view} -> render_fixed_error(conn, :unavailable)
    end
  end

  defp handle_conflict_resolution(conn, _actor, run, _run_id, {:error, reason}) do
    case error_kind(reason) do
      :not_found ->
        render_fixed_error(conn, :not_found)

      :invalid ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_conflicts(run, conflict_choices_message())

      :conflict ->
        conn
        |> put_status(:conflict)
        |> render_conflicts(run, conflict_message())

      :unavailable ->
        conn
        |> put_status(:service_unavailable)
        |> render_conflicts(run, unavailable_message())
    end
  end

  defp handle_conflict_resolution(conn, _actor, _run, _run_id, _unexpected),
    do: render_fixed_error(conn, :unavailable)

  defp redirect_to_run(conn, run_id) when is_integer(run_id) and run_id in 1..@max_id do
    conn
    |> put_status(:see_other)
    |> redirect(to: "/imports/#{run_id}")
  end

  defp redirect_to_review(conn, run_id) when is_integer(run_id) and run_id in 1..@max_id do
    conn
    |> put_status(:see_other)
    |> redirect(to: "/imports/#{run_id}/review")
  end

  defp redirect_to_conflicts(conn, run_id) when is_integer(run_id) and run_id in 1..@max_id do
    conn
    |> put_status(:see_other)
    |> redirect(to: "/imports/#{run_id}/conflicts")
  end

  defp render_entry(conn, actor, kind, error \\ nil) do
    with {:ok, accounts} <- safe_accounts(conn, actor),
         {:ok, organizations} <- owned_organizations(conn, actor) do
      render_entry_page(conn, kind, %{
        accounts: accounts,
        organizations: organizations,
        error: error,
        __changed__: nil
      })
    else
      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> render_entry_page(kind, %{
          accounts: [],
          organizations: [],
          error: "GitHub discovery is temporarily unavailable.",
          __changed__: nil
        })
    end
  end

  defp render_entry_page(conn, :repository, assigns) do
    render_component_page(conn, "Import repository from GitHub", ImportHTML.repository(assigns))
  end

  defp render_entry_page(conn, :organization, assigns) do
    render_component_page(
      conn,
      "Import organization from GitHub",
      ImportHTML.organization(assigns)
    )
  end

  defp render_run(conn, %RunView{} = run, organizations, error \\ nil) do
    rendered =
      ImportHTML.show(%{
        run: run,
        organizations: organizations,
        error: error,
        __changed__: nil
      })

    render_component_page(conn, "GitHub import", rendered)
  end

  defp render_conflicts(conn, %RunView{} = run, error \\ nil) do
    rendered =
      ImportHTML.conflicts(%{
        run: run,
        error: error,
        __changed__: nil
      })

    render_component_page(conn, "Resolve GitHub import conflicts", rendered)
  end

  defp render_review(conn, %RunView{} = run) do
    rendered = ImportHTML.review(%{run: run, __changed__: nil})
    render_component_page(conn, "Review GitHub import", rendered)
  end

  defp render_component_page(conn, title, rendered) do
    page(conn, title, rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary())
  end

  defp render_discovery_error(conn, actor, kind, reason) do
    case error_kind(reason) do
      :not_found ->
        render_fixed_error(conn, :not_found)

      :invalid ->
        conn |> put_status(:unprocessable_entity) |> render_entry(actor, kind, invalid_message())

      :conflict ->
        conn |> put_status(:conflict) |> render_entry(actor, kind, conflict_message())

      :unavailable ->
        conn
        |> put_status(:service_unavailable)
        |> render_entry(actor, kind, unavailable_message())
    end
  end

  defp render_update_error(conn, reason) do
    case error_kind(reason) do
      :not_found -> render_fixed_error(conn, :not_found)
      :invalid -> render_fixed_error(conn, :invalid_choices)
      :conflict -> render_fixed_error(conn, :conflict)
      :unavailable -> render_fixed_error(conn, :unavailable)
    end
  end

  defp render_run_lookup_error(conn, :not_found), do: render_fixed_error(conn, :not_found)
  defp render_run_lookup_error(conn, :invalid_view), do: render_fixed_error(conn, :unavailable)
  defp render_run_lookup_error(conn, reason), do: render_update_error(conn, reason)

  defp render_fixed_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> page(
      "Import not found",
      fixed_error_markup("Import not found.", "The requested import is unavailable.")
    )
  end

  defp render_fixed_error(conn, :invalid_choices) do
    conn
    |> put_status(:unprocessable_entity)
    |> page(
      "Invalid import choices",
      fixed_error_markup("Check the import choices and try again.", "No changes were saved.")
    )
  end

  defp render_fixed_error(conn, :conflict) do
    conn
    |> put_status(:conflict)
    |> page(
      "Import changed",
      fixed_error_markup("The import changed. Refresh and try again.", "No changes were saved.")
    )
  end

  defp render_fixed_error(conn, :unavailable) do
    conn
    |> put_status(:service_unavailable)
    |> page(
      "Import unavailable",
      fixed_error_markup(
        "GitHub discovery is temporarily unavailable.",
        "Try again later."
      )
    )
  end

  defp fixed_error_markup(heading, detail) do
    """
    <section class="grid gap-2 bg-surface-container text-on-surface rounded-lg border border-outline-variant p-6" role="alert">
      <h2 class="text-lg font-semibold">#{heading}</h2>
      <p class="text-sm text-on-surface-variant">#{detail}</p>
    </section>
    """
  end

  defp invalid_message, do: "Check the GitHub source, credential, and destination."
  defp conflict_message, do: "The import changed. Refresh and try again."
  defp unavailable_message, do: "GitHub discovery is temporarily unavailable."
  defp conflict_choices_message, do: "Check each repository conflict choice and try again."

  defp error_kind(reason) when reason in [:not_found, :forbidden], do: :not_found

  defp error_kind(reason)
       when reason in [
              :invalid_source,
              :invalid_destination,
              :invalid_credential,
              :invalid_request,
              :invalid_request_metadata,
              :invalid_response,
              :invalid_selection,
              :invalid_pat
            ],
       do: :invalid

  defp error_kind(reason)
       when reason in [:busy, :stale, :request_gate_busy, :credential_changed],
       do: :conflict

  defp error_kind(_reason), do: :unavailable

  defp repository_discovery_params(%{"import" => attrs}) when is_map(attrs) do
    with :ok <- exact_keys(attrs, ~w(source credential_source github_identity_id pat)),
         {:ok, source} <- bounded_text(Map.get(attrs, "source"), @max_repository_reference_bytes),
         {:ok, credential} <- credential_params(attrs) do
      {:ok, Map.put(credential, :source, source)}
    end
  end

  defp repository_discovery_params(_params), do: {:error, :invalid_request}

  defp organization_discovery_params(organizations, %{"import" => attrs})
       when is_list(organizations) and is_map(attrs) do
    with :ok <-
           exact_keys(
             attrs,
             ~w(organization credential_source github_identity_id pat destination_action destination_slug destination_organization_id)
           ),
         {:ok, organization} <-
           bounded_text(Map.get(attrs, "organization"), @max_organization_login_bytes),
         {:ok, credential} <- credential_params(attrs),
         {:ok, destination} <- destination_value(organizations, attrs, organization, false) do
      {:ok,
       credential
       |> Map.put(:organization, organization)
       |> Map.put(:destination_organization, destination)}
    end
  end

  defp organization_discovery_params(_organizations, _params), do: {:error, :invalid_request}

  defp credential_params(%{
         "credential_source" => "saved",
         "github_identity_id" => identity_id,
         "pat" => ""
       }) do
    with {:ok, parsed_id} <- canonical_form_id(identity_id, :invalid_credential) do
      {:ok, %{credential_source: "saved", github_identity_id: parsed_id}}
    end
  end

  defp credential_params(%{
         "credential_source" => "one_time",
         "github_identity_id" => "",
         "pat" => pat
       }) do
    if printable_pat?(pat),
      do: {:ok, %{credential_source: "one_time", pat: pat}},
      else: {:error, :invalid_credential}
  end

  defp credential_params(_attrs), do: {:error, :invalid_request}

  defp selection_params(%{"selection" => selection}) when is_map(selection) do
    with :ok <- exact_keys(selection, ~w(present repository_ids)),
         true <- Map.get(selection, "present") == "true",
         repository_ids <- Map.get(selection, "repository_ids", []),
         true <- is_list(repository_ids) and length(repository_ids) <= @max_selection_size,
         {:ok, parsed_ids} <- canonical_ids(repository_ids),
         true <- length(parsed_ids) == length(Enum.uniq(parsed_ids)) do
      {:ok, parsed_ids}
    else
      _invalid -> {:error, :invalid_selection}
    end
  end

  defp selection_params(_params), do: {:error, :invalid_selection}

  defp clean_destination?(%RunView{destination: %{organization_status: :clean}}), do: true
  defp clean_destination?(_run), do: false

  defp conflict_resolution_state?(%RunView{state: state})
       when state in [:awaiting_resolution, :running],
       do: true

  defp conflict_resolution_state?(_run), do: false

  defp reviewable_state?(%RunView{state: state})
       when state in [
              :awaiting_resolution,
              :running,
              :cancel_requested,
              :completed,
              :completed_with_warnings,
              :canceled,
              :failed
            ],
       do: true

  defp reviewable_state?(_run), do: false

  defp unresolved_conflicts?(%RunView{repositories: repositories}) do
    Enum.any?(repositories, fn repository ->
      repository.selected and repository.state == :awaiting_resolution
    end)
  end

  defp conflict_decisions(%RunView{} = run, %{"decisions" => decisions})
       when is_map(decisions) and map_size(decisions) in 1..@max_selection_size do
    allowed_item_ids =
      run.repositories
      |> Enum.filter(&(&1.selected and &1.state == :awaiting_resolution))
      |> MapSet.new(& &1.id)

    submitted =
      Enum.reject(decisions, fn {_raw_id, raw_decision} -> blank_decision?(raw_decision) end)

    if submitted == [] do
      {:error, :invalid_selection}
    else
      Enum.reduce_while(submitted, {:ok, %{}}, fn {raw_id, raw_decision}, {:ok, normalized} ->
        with {:ok, item_id} <- canonical_id(raw_id),
             true <- MapSet.member?(allowed_item_ids, item_id),
             false <- Map.has_key?(normalized, item_id),
             {:ok, decision} <- conflict_decision(raw_decision) do
          {:cont, {:ok, Map.put(normalized, item_id, decision)}}
        else
          _invalid -> {:halt, {:error, :invalid_selection}}
        end
      end)
    end
  end

  defp conflict_decisions(_run, _params), do: {:error, :invalid_selection}

  defp conflict_decision(%{"action" => "skip"} = raw) do
    with :ok <- exact_keys(raw, ~w(action apply_to_similar slug confirmation)),
         :ok <- blank_field(raw, "slug"),
         :ok <- blank_field(raw, "confirmation") do
      case Map.get(raw, "apply_to_similar") do
        nil -> {:ok, %{action: :skip}}
        "" -> {:ok, %{action: :skip}}
        "true" -> {:ok, %{action: :skip, apply_to_similar: true}}
        _invalid -> {:error, :invalid_selection}
      end
    end
  end

  defp conflict_decision(%{"action" => "rename"} = raw) do
    with :ok <- exact_keys(raw, ~w(action apply_to_similar slug confirmation)),
         :ok <- blank_field(raw, "apply_to_similar"),
         :ok <- blank_field(raw, "confirmation"),
         {:ok, slug} <- bounded_text(Map.get(raw, "slug"), @max_destination_slug_bytes) do
      {:ok, %{action: :rename, slug: slug}}
    end
  end

  defp conflict_decision(%{"action" => "replace"} = raw) do
    with :ok <- exact_keys(raw, ~w(action apply_to_similar slug confirmation)),
         :ok <- blank_field(raw, "apply_to_similar"),
         :ok <- blank_field(raw, "slug"),
         {:ok, confirmation} <- replacement_confirmation(Map.get(raw, "confirmation")) do
      {:ok, %{action: :replace, confirmation: confirmation}}
    end
  end

  defp conflict_decision(_raw), do: {:error, :invalid_selection}

  defp blank_decision?(raw) when is_map(raw) do
    exact_keys(raw, ~w(action apply_to_similar slug confirmation)) == :ok and
      Enum.all?(~w(action apply_to_similar slug confirmation), fn key ->
        Map.get(raw, key) in [nil, ""]
      end)
  end

  defp blank_decision?(_raw), do: false

  defp blank_field(map, key) do
    if Map.get(map, key) in [nil, ""],
      do: :ok,
      else: {:error, :invalid_selection}
  end

  defp replacement_confirmation(value)
       when is_binary(value) and byte_size(value) in 1..@max_replacement_confirmation_bytes do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch,
      do: {:ok, value},
      else: {:error, :invalid_selection}
  end

  defp replacement_confirmation(_value), do: {:error, :invalid_selection}

  defp destination_params(organizations, %{"destination" => destination}, opts)
       when is_list(organizations) and is_map(destination) do
    with :ok <- exact_keys(destination, ~w(action slug organization_id)),
         {:ok, value} <-
           destination_value(organizations, destination, nil, opts[:require_new_slug?]) do
      {:ok, value}
    end
  end

  defp destination_params(_organizations, _params, _opts), do: {:error, :invalid_destination}

  defp destination_value(organizations, attrs, default_slug, require_new_slug?) do
    case Map.get(attrs, "destination_action") || Map.get(attrs, "action") do
      "new" -> new_destination(attrs, default_slug, require_new_slug?)
      "existing" -> existing_destination(organizations, attrs)
      _invalid -> {:error, :invalid_destination}
    end
  end

  defp new_destination(attrs, default_slug, require_new_slug?) do
    organization_id =
      Map.get(attrs, "destination_organization_id") || Map.get(attrs, "organization_id")

    submitted_slug = Map.get(attrs, "destination_slug") || Map.get(attrs, "slug")

    with true <- organization_id == "",
         {:ok, slug} <- optional_destination_slug(submitted_slug, default_slug, require_new_slug?) do
      {:ok, %{action: "new", slug: slug}}
    else
      _invalid -> {:error, :invalid_destination}
    end
  end

  defp existing_destination(organizations, attrs) do
    submitted_slug = Map.get(attrs, "destination_slug") || Map.get(attrs, "slug")

    organization_id =
      Map.get(attrs, "destination_organization_id") || Map.get(attrs, "organization_id")

    with :ok <- require_empty_inactive_field(submitted_slug),
         {:ok, id} <- canonical_form_id(organization_id, :invalid_destination),
         :ok <- require_owned_organization(organizations, id) do
      {:ok, %{action: "existing", id: id}}
    end
  end

  defp require_empty_inactive_field(""), do: :ok
  defp require_empty_inactive_field(_value), do: {:error, :invalid_destination}

  defp require_owned_organization(organizations, id) do
    if Enum.any?(organizations, &(&1.id == id)),
      do: :ok,
      else: {:error, :not_found}
  end

  defp optional_destination_slug(value, default_slug, require?) when value in [nil, ""] do
    cond do
      is_binary(default_slug) -> bounded_text(default_slug, @max_destination_slug_bytes)
      require? -> {:error, :invalid_destination}
      true -> {:error, :invalid_destination}
    end
  end

  defp optional_destination_slug(value, _default_slug, _require?),
    do: bounded_text(value, @max_destination_slug_bytes)

  defp canonical_ids(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, ids} ->
      case canonical_id(value) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        {:error, _reason} -> {:halt, {:error, :invalid_selection}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp canonical_id(value) when is_binary(value) do
    with true <- byte_size(value) <= 19,
         true <- Regex.match?(@canonical_id, value),
         {id, ""} when id <= @max_id <- Integer.parse(value) do
      {:ok, id}
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp canonical_id(_value), do: {:error, :not_found}

  defp canonical_form_id(value, error) do
    case canonical_id(value) do
      {:ok, id} -> {:ok, id}
      {:error, _reason} -> {:error, error}
    end
  end

  defp bounded_text(value, max_bytes) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) in 1..max_bytes and String.valid?(value) and String.printable?(value) and
         :binary.match(value, <<0>>) == :nomatch do
      {:ok, value}
    else
      {:error, :invalid_request}
    end
  end

  defp bounded_text(_value, _max_bytes), do: {:error, :invalid_request}

  defp printable_pat?(pat) do
    is_binary(pat) and byte_size(pat) in 1..@max_pat_bytes and String.valid?(pat) and
      printable_ascii?(pat)
  end

  defp printable_ascii?(<<>>), do: true

  defp printable_ascii?(<<byte, rest::binary>>) when byte in 0x21..0x7E,
    do: printable_ascii?(rest)

  defp printable_ascii?(_pat), do: false

  defp exact_keys(map, allowed) do
    keys = Map.keys(map)

    if Enum.all?(keys, &is_binary/1) and length(keys) == length(Enum.uniq(keys)) and
         keys -- allowed == [],
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp safe_accounts(conn, actor) do
    case service_call(fn -> imports(conn).list_github_accounts(actor) end) do
      {:ok, accounts} when is_list(accounts) ->
        if Enum.all?(accounts, &match?(%GitHubAccountView{}, &1)) do
          {:ok, Enum.filter(accounts, &usable_saved_account?/1)}
        else
          {:error, :unavailable}
        end

      _unavailable ->
        {:error, :unavailable}
    end
  end

  defp usable_saved_account?(%GitHubAccountView{
         credential_present: true,
         credential_status: :valid
       }),
       do: true

  defp usable_saved_account?(_account), do: false

  defp owned_organizations(conn, actor) do
    case account_lookup(fn -> account_context(conn).list_repository_owners(actor) end) do
      owners when is_list(owners) ->
        organizations =
          owners
          |> Enum.drop(1)
          |> Enum.flat_map(fn
            %Organization{id: id, kind: :organization, state: :active, username: username}
            when is_integer(id) and id > 0 and is_binary(username) ->
              [%{id: id, username: username}]

            _personal_or_inactive ->
              []
          end)

        {:ok, organizations}

      _invalid_or_unavailable ->
        {:error, :account_service_unavailable}
    end
  end

  defp account_lookup(callback) when is_function(callback, 0) do
    callback.()
  rescue
    _error in [DBConnection.ConnectionError] ->
      {:error, :account_service_unavailable}

    error in [:"Elixir.Turso.Error"] ->
      if error.code in @recoverable_turso_codes do
        {:error, :account_service_unavailable}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp fetch_run_view(conn, actor, run_id) do
    case service_call(fn -> imports(conn).get_run_view(actor, run_id) end) do
      {:ok, %RunView{} = run} ->
        case validate_run_view(run, actor, run_id) do
          :ok -> {:ok, run}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}

      _unexpected ->
        {:error, :unavailable}
    end
  end

  defp validate_run_view(
         %RunView{id: id, actor_user_id: actor_id} = run,
         %User{id: actor_id},
         expected_id
       )
       when is_integer(id) and id > 0 and id == expected_id do
    if valid_run_projection?(run), do: :ok, else: {:error, :invalid_view}
  end

  defp validate_run_view(_run, _actor, _expected_id), do: {:error, :not_found}

  defp valid_run_projection?(%RunView{} = run) do
    run.state in ImportRun.states() and valid_source?(run.source) and
      valid_destination?(run.destination) and valid_counts?(run.counts) and
      is_list(run.repositories) and length(run.repositories) <= @max_selection_size and
      Enum.all?(run.repositories, &valid_repository_projection?/1) and is_list(run.reports) and
      length(run.reports) <= @max_selection_size and
      Enum.all?(run.reports, &valid_report_projection?/1) and
      match?(%DateTime{}, run.inserted_at) and match?(%DateTime{}, run.updated_at)
  end

  defp valid_source?(%{kind: kind, owner_login: login} = source)
       when kind in [:repository, :organization] and is_binary(login) do
    SafeValue.github_source_text?(login, 255, required?: true) and
      valid_optional_source_text(Map.get(source, :repository_full_name), 255)
  end

  defp valid_source?(_source), do: false

  defp valid_optional_source_text(nil, _max), do: true

  defp valid_optional_source_text(value, max),
    do: SafeValue.github_source_text?(value, max, required?: true)

  defp valid_destination?(%{
         organization_action: action,
         organization_slug: slug,
         organization_id: organization_id,
         organization_status: status,
         organization_classification: classification
       })
       when action in [:new, :existing] and status in [:clean, :conflict, :invalid] do
    valid_optional_source_text(slug, @max_destination_slug_bytes) and
      (is_nil(organization_id) or
         (is_integer(organization_id) and organization_id in 1..@max_id)) and
      valid_destination_status?(status, classification)
  end

  defp valid_destination?(_destination), do: false

  defp valid_destination_status?(:clean, nil), do: true

  defp valid_destination_status?(status, classification)
       when status in [:conflict, :invalid] and is_binary(classification),
       do: valid_optional_classification(classification)

  defp valid_destination_status?(_status, _classification), do: false

  defp valid_counts?(%{
         selected: selected,
         published: published,
         skipped: skipped,
         warnings: warnings,
         failures: failures
       }) do
    Enum.all?([selected, published, skipped, warnings, failures], &valid_count?/1)
  end

  defp valid_counts?(_counts), do: false

  defp valid_item_counts?(%{
         imported: imported,
         skipped: skipped,
         warnings: warnings,
         failures: failures
       }) do
    Enum.all?([imported, skipped, warnings, failures], &valid_count?/1)
  end

  defp valid_item_counts?(_counts), do: false

  defp valid_count?(value), do: is_integer(value) and value in 0..@max_id

  defp valid_repository_projection?(repository) when is_map(repository) do
    repository[:state] in RepositoryItem.states() and is_boolean(repository[:selected]) and
      repository[:conflict_action] in [nil, :skip, :rename, :replace] and
      repository[:destination_visibility] in [:public, :private] and
      is_integer(repository[:id]) and repository[:id] in 1..@max_id and
      is_integer(repository[:github_repository_id]) and
      repository[:github_repository_id] in 1..@max_id and
      SafeValue.github_source_text?(repository[:source_full_name], 255, required?: true) and
      valid_optional_source_text(repository[:destination_slug], 255) and
      valid_optional_classification(repository[:wait_reason]) and
      valid_item_counts?(repository[:counts])
  end

  defp valid_repository_projection?(_repository), do: false

  defp valid_report_projection?(report) when is_map(report) do
    report[:scope] in [:run, :repository, :object] and
      report[:outcome] in [:imported, :skipped, :warning, :failed, :canceled, :not_selected] and
      SafeValue.safe_string?(report[:classification], 120,
        required?: true,
        classified?: true
      ) and
      SafeValue.safe_string?(report[:summary], 500, required?: true, classified?: true) and
      valid_count?(report[:source_count])
  end

  defp valid_report_projection?(_report), do: false

  defp valid_optional_classification(nil), do: true

  defp valid_optional_classification(value),
    do: SafeValue.safe_string?(value, 120, required?: true, classified?: true)

  defp service_call(callback) when is_function(callback, 0) do
    callback.()
  rescue
    _error in [
      CredentialBootstrapError,
      CredentialVerificationError,
      CredentialCallbackError,
      DBConnection.ConnectionError
    ] ->
      {:error, :credential_service_unavailable}

    error in [:"Elixir.Turso.Error"] ->
      if error.code in @recoverable_turso_codes do
        {:error, :credential_service_unavailable}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp imports(conn), do: conn.private[:forge_imports] || ForgeImports
  defp account_context(conn), do: conn.private[:forge_accounts] || ForgeAccounts

  defp require_active_user(
         %Plug.Conn{assigns: %{current_user: %User{kind: :user, state: :active}}} = conn,
         _opts
       ),
       do: conn

  defp require_active_user(conn, _opts) do
    conn
    |> delete_session(:user_id)
    |> redirect(to: "/login")
    |> halt()
  end
end
