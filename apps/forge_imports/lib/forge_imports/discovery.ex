defmodule ForgeImports.Discovery do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredentialCallback, GitHubProfileSafety, User}
  alias ForgeImports.GitHub.{Client, Error, RepositoryReference}
  alias ForgeImports.GitHub.User, as: GitHubUser
  alias ForgeImports.{Destination, DiscoveryWorker, ImportRun, Reconciler}
  alias Fornacast.Repo

  @allow_test_options Mix.env() == :test
  @default_lease_seconds 2_400

  defmodule CredentialBootstrapError do
    @moduledoc false
    defexception message: "GitHub import credential bootstrap failed"
  end

  @spec create_repository(User.t(), map(), map(), keyword()) ::
          {:ok, ForgeImports.RunView.t()} | {:error, atom()}
  def create_repository(%User{} = actor, attrs, request_metadata, opts)
      when is_map(attrs) and is_map(request_metadata) and is_list(opts) do
    with :ok <- exact_keys(attrs, ~w(source credential_source github_identity_id pat)),
         {:ok, options} <- options(opts, :repository),
         {:ok, active_actor} <- active_actor(actor),
         {:ok, source} <- RepositoryReference.parse(fetch(attrs, :source)),
         {:ok, destination} <- Destination.personal(active_actor),
         {:ok, credential, safe_metadata} <-
           credential(active_actor, attrs, request_metadata, options),
         {:ok, run} <-
           create_checked_provisional_run(
             active_actor,
             repository_run_attrs(source, destination, credential, safe_metadata),
             credential,
             options,
             repository_source_profile(source),
             destination
           ),
         :ok <- dispatch(run, options) do
      ForgeImports.get_run(active_actor, run.id)
    end
  end

  def create_repository(_actor, _attrs, _request_metadata, _opts), do: {:error, :forbidden}

  @spec create_organization(User.t(), map(), map(), keyword()) ::
          {:ok, ForgeImports.RunView.t()} | {:error, atom()}
  def create_organization(%User{} = actor, attrs, request_metadata, opts)
      when is_map(attrs) and is_map(request_metadata) and is_list(opts) do
    with :ok <-
           exact_keys(
             attrs,
             ~w(organization credential_source github_identity_id pat destination_organization)
           ),
         {:ok, options} <- options(opts, :organization),
         {:ok, active_actor} <- active_actor(actor),
         {:ok, source_login} <- organization_login(fetch(attrs, :organization)),
         {:ok, destination_input} <- destination_input(attrs, source_login),
         {:ok, destination} <-
           Destination.organization(active_actor, source_login, destination_input),
         {:ok, credential, safe_metadata} <-
           credential(active_actor, attrs, request_metadata, options),
         {:ok, run} <-
           create_checked_provisional_run(
             active_actor,
             organization_run_attrs(source_login, destination, credential, safe_metadata),
             credential,
             options,
             %{login: source_login},
             destination
           ),
         :ok <- dispatch(run, options) do
      ForgeImports.get_run(active_actor, run.id)
    end
  end

  def create_organization(_actor, _attrs, _request_metadata, _opts),
    do: {:error, :forbidden}

  defp credential(actor, attrs, request_metadata, options) do
    source = credential_source(fetch(attrs, :credential_source))

    with :ok <- credential_shape(attrs, source) do
      case source do
        :saved -> saved_credential(actor, attrs, request_metadata)
        :one_time -> one_time_credential(actor, attrs, request_metadata, options)
      end
    end
  end

  defp credential_shape(attrs, :saved) do
    if has_field?(attrs, :github_identity_id) and not has_field?(attrs, :pat),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp credential_shape(attrs, :one_time) do
    if has_field?(attrs, :pat) and not has_field?(attrs, :github_identity_id),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp credential_shape(_attrs, :invalid), do: {:error, :invalid_request}

  defp saved_credential(actor, attrs, request_metadata) do
    with {:ok, identity_id} <- positive_id(fetch(attrs, :github_identity_id)),
         {:ok, checked} <-
           ForgeAccounts.validate_github_account_request(actor, identity_id, request_metadata),
         {:ok, accounts} <- ForgeAccounts.list_github_accounts(actor),
         %{credential_present: true, credential_status: :valid} <-
           Enum.find(accounts, &(&1.identity_id == identity_id)),
         %{credential: reference, github_user_id: github_user_id}
         when not is_nil(reference) <- checked.reference do
      {:ok,
       %{
         source: :saved,
         identity_id: identity_id,
         github_user_id: github_user_id,
         credential_id: reference.credential_id,
         reference: reference
       }, checked.request_metadata}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
      _invalid -> {:error, :invalid_credential}
    end
  end

  defp one_time_credential(actor, attrs, request_metadata, options) do
    pat = fetch(attrs, :pat)

    with true <- valid_pat?(pat),
         {:ok, metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata, pat),
         {:ok, checked} <- ForgeAccounts.validate_github_link_request(actor, metadata),
         {:ok, user} <- bootstrap_user(actor, pat, options),
         {:ok, identity} <-
           ForgeAccounts.observe_github_identity(profile(user), DateTime.utc_now(:second)) do
      {:ok,
       %{
         source: :one_time,
         identity_id: identity.id,
         github_user_id: identity.github_user_id,
         pat: pat
       }, checked.request_metadata}
    else
      false -> {:error, :invalid_credential}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp bootstrap_user(actor, pat, options) do
    reference = make_ref()
    parent = self()
    client_options = put_gate(options.client_options, {:import_setup, actor.id})

    case GitHubCredentialCallback.invoke(
           fn checked_out_pat ->
             result =
               options.client.authenticated_user(checked_out_pat, client_options)
               |> normalize_user(actor, checked_out_pat)

             send(parent, {reference, result})
             :ok
           end,
           pat,
           CredentialBootstrapError
         ) do
      :ok -> receive_result(reference)
      :unsafe -> {:error, :invalid_response}
    end
  end

  defp normalize_user({:ok, %GitHubUser{} = user}, actor, pat) do
    with {:ok, safe} <-
           GitHubUser.from_json(%{
             "id" => user.id,
             "login" => user.login,
             "name" => user.name,
             "avatar_url" => user.avatar_url,
             "html_url" => user.html_url
           }),
         :ok <- GitHubProfileSafety.validate(safe, pat),
         :ok <- ForgeAccounts.validate_github_external_profile(actor, safe) do
      {:ok, safe}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp normalize_user({:error, %Error{kind: kind}}, _actor, _pat), do: {:error, kind}
  defp normalize_user(_result, _actor, _pat), do: {:error, :invalid_response}

  defp create_provisional_run(actor, attrs, %{source: :saved}, _options),
    do: ForgeImports.create_run(actor, attrs)

  defp create_provisional_run(actor, attrs, credential, options) do
    transaction = fn ->
      with {:ok, run} <- ForgeImports.create_run(actor, attrs),
           {:ok, envelope} <-
             ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
               run.id,
               actor.id,
               credential.github_user_id,
               credential.pat,
               options.keyring
             ),
           {:ok, attached} <-
             ForgeImports.attach_one_time_credential(actor, run, envelope, options.keyring) do
        attached
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    case Repo.transaction(transaction) do
      {:ok, %ImportRun{} = run} -> {:ok, run}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp create_checked_provisional_run(
         actor,
         attrs,
         credential,
         options,
         source_profile,
         destination
       ) do
    with :ok <- invoke_before_run(options) do
      transaction = fn ->
        with {:ok, checked_attrs} <-
               revalidate_run_inputs(actor, attrs, credential, source_profile),
             :ok <- validate_destination_input(actor, destination, credential),
             {:ok, run} <-
               create_provisional_run(actor, checked_attrs, credential, options) do
          run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      case Repo.transaction(transaction) do
        {:ok, %ImportRun{} = run} -> {:ok, run}
        {:error, reason} -> {:error, normalize_error(reason)}
      end
    end
  end

  defp invoke_before_run(options) do
    case options.before_run.() do
      :ok -> :ok
      _invalid -> {:error, :invalid_request}
    end
  end

  defp dispatch(run, options) do
    case options.dispatch do
      :inline ->
        case DiscoveryWorker.perform(run.id, worker_options(options)) do
          {:ok, _outcome} -> :ok
          {:error, reason} -> {:error, normalize_error(reason)}
        end

      :async ->
        Reconciler.kick(options.reconciler)
        :ok
    end
  end

  defp worker_options(options) do
    [
      client: options.client,
      client_options: options.client_options,
      lease_seconds: options.lease_seconds,
      keyring: options.keyring
    ]
  end

  defp repository_run_attrs(source, destination, credential, request_metadata) do
    credential_attrs(credential)
    |> Map.merge(%{
      source_kind: :repository,
      source_owner_login: source.owner,
      source_repository_full_name: "#{source.owner}/#{source.repository}",
      destination_organization_action: destination.action,
      destination_organization_slug: Map.get(destination, :requested_slug, destination.slug),
      destination_organization_id: destination.organization_id,
      destination_organization_status: destination.status,
      destination_organization_classification: destination.classification,
      request_metadata: request_metadata
    })
  end

  defp organization_run_attrs(source_login, destination, credential, request_metadata) do
    credential_attrs(credential)
    |> Map.merge(%{
      source_kind: :organization,
      source_owner_login: source_login,
      destination_organization_action: destination.action,
      destination_organization_slug: Map.get(destination, :requested_slug, destination.slug),
      destination_organization_id: destination.organization_id,
      destination_organization_status: destination.status,
      destination_organization_classification: destination.classification,
      request_metadata: request_metadata
    })
  end

  defp credential_attrs(%{source: :saved} = credential) do
    %{
      github_identity_id: credential.identity_id,
      credential_source: :saved,
      github_credential_id: credential.credential_id
    }
  end

  defp credential_attrs(%{source: :one_time} = credential) do
    %{github_identity_id: credential.identity_id, credential_source: :one_time}
  end

  defp options(opts, source_kind) do
    allowed =
      if @allow_test_options do
        ~w(dispatch client client_options keyring task_supervisor reconciler lease_seconds before_run)a
      else
        []
      end

    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_request}

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error, :invalid_request}

      Keyword.keys(opts) -- allowed != [] ->
        {:error, :invalid_request}

      true ->
        build_options(opts, source_kind)
    end
  end

  defp build_options(opts, source_kind) do
    client = Keyword.get(opts, :client, Client)
    client_options = Keyword.get(opts, :client_options, [])
    dispatch = Keyword.get(opts, :dispatch, :async)
    task_supervisor = Keyword.get(opts, :task_supervisor, ForgeImports.TaskSupervisor)
    reconciler = Keyword.get(opts, :reconciler, Reconciler)
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_lease_seconds)
    keyring = Keyword.get(opts, :keyring, Fornacast.Config.github_credential_keyring())
    before_run = Keyword.get(opts, :before_run, fn -> :ok end)

    required =
      case source_kind do
        :repository -> [:repository]
        :organization -> [:organization, :organization_repositories]
      end

    valid_client? =
      is_atom(client) and Code.ensure_loaded?(client) and
        function_exported?(client, :authenticated_user, 2) and
        Enum.all?(required, &function_exported?(client, &1, client_arity(&1)))

    if valid_client? and Keyword.keyword?(client_options) and
         not Keyword.has_key?(client_options, :gate_key) and dispatch in [:inline, :async] and
         (dispatch != :inline or @allow_test_options) and
         (is_atom(task_supervisor) or is_pid(task_supervisor)) and is_integer(lease_seconds) and
         lease_seconds in 1..@default_lease_seconds and
         (is_atom(reconciler) or is_pid(reconciler)) and is_function(before_run, 0) do
      {:ok,
       %{
         client: client,
         client_options: client_options,
         dispatch: dispatch,
         task_supervisor: task_supervisor,
         reconciler: reconciler,
         lease_seconds: lease_seconds,
         keyring: keyring,
         before_run: before_run
       }}
    else
      {:error, :invalid_request}
    end
  end

  defp client_arity(:repository), do: 4
  defp client_arity(:organization), do: 3
  defp client_arity(:organization_repositories), do: 3

  defp active_actor(%User{id: actor_id}) when is_integer(actor_id) and actor_id > 0 do
    case Repo.one(
           from user in User,
             where: user.id == ^actor_id and user.kind == :user and user.state == :active
         ) do
      %User{} = active -> {:ok, active}
      nil -> {:error, :forbidden}
    end
  end

  defp active_actor(_actor), do: {:error, :forbidden}

  defp organization_login(value) when is_binary(value) do
    value = String.trim(value)
    if RepositoryReference.valid_owner?(value), do: {:ok, value}, else: {:error, :invalid_source}
  end

  defp organization_login(_value), do: {:error, :invalid_source}

  defp destination_input(attrs, source_login) do
    atom? = Map.has_key?(attrs, :destination_organization)
    string? = Map.has_key?(attrs, "destination_organization")

    case {atom?, string?} do
      {false, false} -> {:ok, %{action: :new, slug: source_login}}
      {true, false} -> destination_value(Map.fetch!(attrs, :destination_organization))
      {false, true} -> destination_value(Map.fetch!(attrs, "destination_organization"))
      {true, true} -> {:error, :invalid_destination}
    end
  end

  defp destination_value(value) when is_map(value), do: {:ok, value}
  defp destination_value(_value), do: {:error, :invalid_destination}

  defp exact_keys(attrs, allowed) do
    keys = Enum.map(Map.keys(attrs), &to_string/1)

    if length(keys) == length(Enum.uniq(keys)) and keys -- allowed == [],
      do: :ok,
      else: {:error, :invalid_request}
  rescue
    Protocol.UndefinedError -> {:error, :invalid_request}
  end

  defp credential_source(:saved), do: :saved
  defp credential_source("saved"), do: :saved
  defp credential_source(:one_time), do: :one_time
  defp credential_source("one_time"), do: :one_time
  defp credential_source(_value), do: :invalid

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp has_field?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp positive_id(value) do
    case Ecto.Type.cast(:integer, value) do
      {:ok, id} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_credential}
    end
  end

  defp valid_pat?(pat) do
    is_binary(pat) and byte_size(pat) in 1..4_096 and String.valid?(pat) and
      :binary.match(pat, <<0>>) == :nomatch
  end

  defp profile(user) do
    %{
      github_user_id: user.id,
      login: user.login,
      avatar_url: user.avatar_url,
      profile_url: user.html_url
    }
  end

  defp repository_source_profile(source) do
    %{
      owner_login: source.owner,
      name: source.repository,
      full_name: "#{source.owner}/#{source.repository}"
    }
  end

  defp revalidate_run_inputs(actor, attrs, %{source: :one_time} = credential, profile) do
    with :ok <- validate_source_input(actor, profile, credential) do
      {:ok, attrs}
    end
  end

  defp revalidate_run_inputs(actor, attrs, %{source: :saved} = credential, profile) do
    with {:ok, checked} <-
           ForgeAccounts.validate_github_import_request(
             actor,
             credential.reference,
             attrs.request_metadata,
             [profile]
           ) do
      {:ok, Map.put(attrs, :request_metadata, checked.request_metadata)}
    end
  end

  defp validate_source_input(actor, profile, %{source: :one_time, pat: pat}) do
    with :ok <- GitHubProfileSafety.validate(profile, pat),
         :ok <- ForgeAccounts.validate_github_external_profile(actor, profile) do
      :ok
    end
  end

  defp validate_destination_input(actor, destination, credential) do
    with {:ok, profiles} <- Destination.safety_profiles(destination),
         :ok <- validate_destination_profiles(actor, profiles, credential) do
      :ok
    else
      {:error, :credential_service_unavailable} = error -> error
      _unsafe -> {:error, :invalid_destination}
    end
  end

  defp validate_destination_profiles(actor, profiles, %{source: :one_time, pat: pat}) do
    with :ok <- validate_profiles(profiles, pat),
         :ok <- ForgeAccounts.validate_github_external_profiles(actor, profiles) do
      :ok
    end
  end

  defp validate_destination_profiles(actor, profiles, %{source: :saved}),
    do: ForgeAccounts.validate_github_external_profiles(actor, profiles)

  defp validate_profiles(profiles, pat) do
    Enum.reduce_while(profiles, :ok, fn profile, :ok ->
      case GitHubProfileSafety.validate(profile, pat) do
        :ok -> {:cont, :ok}
        {:error, :invalid_response} -> {:halt, {:error, :invalid_response}}
      end
    end)
  end

  defp put_gate(options, gate_key),
    do: options |> Keyword.delete(:gate_key) |> Keyword.put(:gate_key, gate_key)

  defp receive_result(reference) do
    receive do
      {^reference, result} -> result
    after
      0 -> {:error, :invalid_response}
    end
  end

  defp normalize_error(reason)
       when reason in [
              :forbidden,
              :not_found,
              :invalid_source,
              :invalid_destination,
              :invalid_credential,
              :credential_service_unavailable,
              :unsafe_credential_result,
              :invalid_request,
              :invalid_request_metadata,
              :invalid_response,
              :recovery_unavailable,
              :credential_changed,
              :stale,
              :busy
            ],
       do: reason

  defp normalize_error(reason)
       when reason in [
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

  defp normalize_error(_reason), do: :discovery_failed
end
