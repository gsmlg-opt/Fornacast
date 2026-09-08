defmodule ForgeImports.CredentialProvider do
  @moduledoc false

  alias ForgeAccounts.User
  alias ForgeImports.{ImportRun, RepositoryItem}
  alias ForgeImports.CredentialProvider.{GitHubApp, OneTimePAT, SavedPAT}

  @doc false
  def authorize_recovery_locked(%ImportRun{} = run, %RepositoryItem{} = item) do
    import Ecto.Query
    alias Fornacast.Repo

    if Repo.in_transaction?() do
      owners =
        Repo.all(
          from u in User,
            where: u.id in ^[run.actor_user_id, item.destination_owner_id],
            order_by: u.id,
            lock: "FOR UPDATE"
        )

      actor =
        Enum.find(
          owners,
          &(&1.id == run.actor_user_id and &1.kind == :user and &1.state == :active)
        )

      owner = Enum.find(owners, &(&1.id == item.destination_owner_id and &1.state == :active))

      Repo.all(
        from m in ForgeAccounts.OrganizationMember,
          where:
            m.organization_id == ^item.destination_owner_id and m.user_id == ^run.actor_user_id,
          lock: "FOR UPDATE"
      )

      with true <- not is_nil(actor) and not is_nil(owner),
           :ok <- recovery_destination(actor, owner) do
        if run.credential_source == :github_app,
          do: GitHubApp.authorize_recovery_locked(run, actor, owner.id),
          else: :ok
      else
        _ -> {:error, :forbidden}
      end
    else
      {:error, :invalid_context}
    end
  end

  defp recovery_destination(%User{id: id}, %User{id: id, kind: :user}), do: :ok

  defp recovery_destination(actor, %User{id: id, kind: :organization}) do
    case ForgeAccounts.fetch_manageable_organization(actor, id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp recovery_destination(_, _), do: {:error, :forbidden}

  @type capability :: ImportRun.t() | RepositoryItem.t()
  @type context :: %{actor: User.t(), run: ImportRun.t(), capability: capability()}
  @type metadata :: %{git_login: String.t(), gate_key: term()}
  @type callback :: (binary(), metadata() -> :ok | {:error, term()})
  @type checkout_error ::
          :credential_changed
          | :credential_service_unavailable
          | :forbidden
          | :invalid_context
          | :invalid_credential
          | :not_found
          | :unsafe_credential_result
          | {:invalid_credential, term()}
          | {:retryable, :busy | :invalidated | :timeout | :unavailable}
          | {:terminal,
             :binding_mismatch | :invalid_scope | :not_configured | :revoked | :suspended}

  @callback checkout(context(), callback(), keyword()) ::
              {:ok, :acknowledged} | {:error, checkout_error()}

  @spec checkout(context(), callback(), keyword()) ::
          {:ok, :acknowledged} | {:error, checkout_error()}
  def checkout(context, callback, opts \\ [])

  def checkout(
        %{run: %ImportRun{credential_source: :saved}} = context,
        callback,
        opts
      )
      when is_function(callback, 2) and is_list(opts),
      do: SavedPAT.checkout(context, callback, opts)

  def checkout(
        %{run: %ImportRun{credential_source: :one_time}} = context,
        callback,
        opts
      )
      when is_function(callback, 2) and is_list(opts),
      do: OneTimePAT.checkout(context, callback, opts)

  def checkout(
        %{run: %ImportRun{credential_source: :github_app}} = context,
        callback,
        opts
      )
      when is_function(callback, 2) and is_list(opts),
      do: GitHubApp.checkout(context, callback, opts)

  def checkout(_context, _callback, _opts), do: {:error, :invalid_context}
end

defmodule ForgeImports.CredentialProvider.GitHubApp do
  @moduledoc false

  @behaviour ForgeImports.CredentialProvider

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredentialCallback, User}
  alias ForgeGitHub.{InstallationToken, InstallationTokenBroker}
  alias ForgeImports.{ImportAttempt, ImportRun, RepositoryItem}
  alias ForgeMirrors.{GitHubAppInstallation, OrganizationMirror}
  alias Fornacast.Repo

  defmodule CallbackError do
    @moduledoc false
    defexception message: "credential callback failed"
  end

  @doc false
  def authorize_recovery_locked(run, actor, destination_id) do
    if Repo.in_transaction?() do
      with {:ok, selected} <- bound_mirror(run.id),
           %OrganizationMirror{} = mirror <-
             Repo.one(
               from m in OrganizationMirror, where: m.id == ^selected.id, lock: "FOR UPDATE"
             ),
           true <-
             mirror.bootstrap_import_run_id == run.id and mirror.organization_id == destination_id,
           :ok <- runnable_mirror(mirror),
           :ok <- authorize_binding(actor, run, mirror),
           _ <-
             Repo.one(
               from i in GitHubAppInstallation,
                 where: i.github_installation_id == ^mirror.github_installation_id,
                 lock: "FOR UPDATE"
             ),
           {:ok, _} <- active_installation(mirror) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_context}
      end
    else
      {:error, :invalid_context}
    end
  end

  @impl true
  def checkout(
        %{
          actor: %User{id: actor_id} = actor,
          run: %ImportRun{credential_source: :github_app} = expected,
          capability: capability
        },
        callback,
        opts
      )
      when is_integer(actor_id) and is_function(callback, 2) and is_list(opts) and
             (is_struct(capability, ImportRun) or is_struct(capability, RepositoryItem)) do
    with %ImportRun{} = run <- current_run(actor_id, expected, capability),
         {:ok, mirror} <- bound_mirror(run.id),
         :ok <- runnable_mirror(mirror),
         :ok <- authorize_binding(actor, run, mirror),
         {:ok, installation} <- active_installation(mirror),
         {:ok, token} <- fetch_token(installation.github_installation_id, opts),
         :ok <- invoke_callback(token, installation.github_installation_id, callback) do
      {:ok, :acknowledged}
    else
      nil -> {:error, :invalid_context}
      {:error, _reason} = error -> error
    end
  end

  def checkout(_context, _callback, _opts), do: {:error, :invalid_context}

  defp current_run(actor_id, expected, %ImportRun{} = capability) do
    now = DateTime.utc_now(:second)
    terminal_states = ImportRun.terminal_states()

    if expected.id == capability.id do
      Repo.one(
        from run in ImportRun,
          join: actor in User,
          on: actor.id == run.actor_user_id,
          where:
            run.id == ^capability.id and run.actor_user_id == ^actor_id and
              actor.kind == :user and actor.state == :active and
              run.credential_source == :github_app and run.source_kind == :organization and
              run.state not in ^terminal_states and run.lock_version == ^capability.lock_version and
              run.lease_owner == ^capability.lease_owner and not is_nil(run.lease_expires_at) and
              run.lease_expires_at > ^now
      )
    end
  end

  defp current_run(actor_id, expected, %RepositoryItem{} = capability) do
    now = DateTime.utc_now(:second)

    if expected.id == capability.import_run_id do
      Repo.one(
        from item in RepositoryItem,
          join: run in ImportRun,
          on: run.id == item.import_run_id,
          join: actor in User,
          on: actor.id == run.actor_user_id,
          join: attempt in ImportAttempt,
          on:
            attempt.repository_item_id == item.id and
              attempt.attempt_number == item.attempt_count,
          where:
            item.id == ^capability.id and item.import_run_id == ^expected.id and
              item.lock_version == ^capability.lock_version and
              item.lease_owner == ^capability.lease_owner and
              not is_nil(item.lease_expires_at) and item.lease_expires_at > ^now and
              item.selected == true and
              item.state in [:staging_git, :git_staged, :staging_metadata] and
              is_nil(item.cleanup_state) and run.actor_user_id == ^actor_id and
              run.credential_source == :github_app and run.source_kind == :organization and
              run.state == :running and actor.kind == :user and actor.state == :active and
              attempt.state == :running,
          select: run
      )
    end
  end

  defp bound_mirror(run_id) do
    mirrors =
      Repo.all(
        from mirror in OrganizationMirror,
          where: mirror.bootstrap_import_run_id == ^run_id,
          order_by: [desc: mirror.id],
          limit: 2
      )

    case Enum.reject(mirrors, &(&1.state == :revoked)) do
      [mirror] -> {:ok, mirror}
      [] when mirrors != [] -> {:error, {:terminal, :revoked}}
      _other -> {:error, {:terminal, :binding_mismatch}}
    end
  end

  defp authorize_binding(actor, run, mirror) do
    cond do
      mirror.provider != "github" ->
        {:error, {:terminal, :binding_mismatch}}

      mirror.github_account_id != run.source_owner_github_id ->
        {:error, {:terminal, :binding_mismatch}}

      true ->
        case ForgeAccounts.fetch_manageable_organization(actor, mirror.organization_id) do
          {:ok, _organization} -> :ok
          {:error, :forbidden} -> {:error, :forbidden}
          {:error, :not_found} -> {:error, {:terminal, :binding_mismatch}}
        end
    end
  end

  defp runnable_mirror(%OrganizationMirror{state: state})
       when state in [:bootstrapping, :catching_up],
       do: :ok

  defp runnable_mirror(%OrganizationMirror{state: :paused}),
    do: {:error, {:retryable, :busy}}

  defp runnable_mirror(%OrganizationMirror{state: :revoked}),
    do: {:error, {:terminal, :revoked}}

  defp runnable_mirror(%OrganizationMirror{}),
    do: {:error, {:terminal, :binding_mismatch}}

  defp active_installation(mirror) do
    case Repo.get_by(GitHubAppInstallation,
           github_installation_id: mirror.github_installation_id
         ) do
      %GitHubAppInstallation{state: :active, github_account_id: account_id} = installation
      when account_id == mirror.github_account_id ->
        {:ok, installation}

      %GitHubAppInstallation{state: :suspended} ->
        {:error, {:terminal, :suspended}}

      %GitHubAppInstallation{state: :revoked} ->
        {:error, {:terminal, :revoked}}

      %GitHubAppInstallation{} ->
        {:error, {:terminal, :binding_mismatch}}

      nil ->
        {:error, {:terminal, :binding_mismatch}}
    end
  end

  defp fetch_token(installation_id, opts) do
    broker = Keyword.get(opts, :token_broker, InstallationTokenBroker)
    scope = Keyword.get(opts, :scope, %{})

    case InstallationTokenBroker.fetch(broker, installation_id, scope) do
      %InstallationToken{} = token ->
        {:ok, token}

      {:error, reason} when reason in [:busy, :invalidated, :timeout, :unavailable] ->
        {:error, {:retryable, reason}}

      {:error, reason} when reason in [:invalid_scope, :not_configured, :revoked] ->
        {:error, {:terminal, reason}}

      _invalid ->
        {:error, {:retryable, :unavailable}}
    end
  end

  defp invoke_callback(%InstallationToken{token: token}, installation_id, callback) do
    metadata = %{
      git_login: "x-access-token",
      gate_key: {:github_installation, installation_id}
    }

    case GitHubCredentialCallback.invoke(
           fn credential -> callback.(credential, metadata) end,
           token,
           CallbackError
         ) do
      :ok -> :ok
      {:error, _safe_reason} -> :ok
      :unsafe -> {:error, :unsafe_credential_result}
    end
  end
end

defmodule ForgeImports.CredentialProvider.OneTimePAT do
  @moduledoc false

  @behaviour ForgeImports.CredentialProvider

  alias ForgeAccounts.{GitHubIdentity, User}
  alias ForgeImports.{ImportRun, OneTimeCredential, RepositoryItem}
  alias Fornacast.Repo

  @impl true
  def checkout(
        %{
          actor: %User{id: actor_id} = actor,
          run: %ImportRun{credential_source: :one_time} = run,
          capability: %ImportRun{id: run_id} = capability
        },
        callback,
        opts
      )
      when is_integer(actor_id) and run_id == run.id and is_function(callback, 2) and
             is_list(opts) do
    with %GitHubIdentity{kind: :user, login: login} <-
           Repo.get(GitHubIdentity, run.github_identity_id) do
      metadata = %{git_login: login, gate_key: {:one_time_run, run.id}}
      keyring = Keyword.get(opts, :keyring, Fornacast.Config.github_credential_keyring())

      OneTimeCredential.with_credential(
        actor,
        capability,
        fn credential -> callback.(credential, metadata) end,
        keyring
      )
    else
      _missing_or_invalid -> {:error, :not_found}
    end
  end

  def checkout(
        %{
          actor: %User{id: actor_id} = actor,
          run: %ImportRun{credential_source: :one_time} = run,
          capability: %RepositoryItem{import_run_id: run_id} = capability
        },
        callback,
        opts
      )
      when is_integer(actor_id) and run_id == run.id and is_function(callback, 2) and
             is_list(opts) do
    with %GitHubIdentity{kind: :user, login: login} <-
           Repo.get(GitHubIdentity, run.github_identity_id) do
      metadata = %{git_login: login, gate_key: {:one_time_run, run.id}}
      keyring = Keyword.get(opts, :keyring, Fornacast.Config.github_credential_keyring())

      OneTimeCredential.with_item_credential(
        actor,
        capability,
        fn credential -> callback.(credential, metadata) end,
        keyring
      )
    else
      _missing_or_invalid -> {:error, :not_found}
    end
  end

  def checkout(_context, _callback, _opts), do: {:error, :invalid_context}
end

defmodule ForgeImports.CredentialProvider.SavedPAT do
  @moduledoc false

  @behaviour ForgeImports.CredentialProvider

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredentialVerification, GitHubIdentity, User}
  alias ForgeImports.{ImportAttempt, ImportRun, RepositoryItem}
  alias Fornacast.Repo

  @impl true
  def checkout(
        %{
          actor: %User{id: actor_id} = actor,
          run: %ImportRun{credential_source: :saved} = run,
          capability: %ImportRun{} = capability
        },
        callback,
        _opts
      )
      when is_integer(actor_id) and is_function(callback, 2) do
    with %ImportRun{} = current <- current_run(actor_id, run, capability) do
      checkout_current(actor, current, callback)
    else
      nil -> {:error, :invalid_context}
    end
  end

  def checkout(
        %{
          actor: %User{id: actor_id} = actor,
          run: %ImportRun{credential_source: :saved} = run,
          capability: %RepositoryItem{} = capability
        },
        callback,
        _opts
      )
      when is_integer(actor_id) and is_function(callback, 2) do
    with %ImportRun{} = current <- current_run(actor_id, run, capability) do
      checkout_current(actor, current, callback)
    else
      nil -> {:error, :invalid_context}
    end
  end

  def checkout(_context, _callback, _opts), do: {:error, :invalid_context}

  defp checkout_current(%User{id: actor_id} = actor, run, callback) do
    reference = make_ref()
    parent = self()

    with %GitHubIdentity{kind: :user, login: login, local_user_id: ^actor_id} <-
           Repo.get(GitHubIdentity, run.github_identity_id) do
      metadata = %{
        git_login: login,
        gate_key: {:saved_credential, run.github_credential_id}
      }

      checkout =
        ForgeAccounts.with_github_import_credential(
          actor,
          run.github_identity_id,
          run.github_credential_id,
          fn credential, verification ->
            if reference_matches?(run, verification) do
              result = callback.(credential, metadata)

              if result == {:error, :invalid_credential},
                do: send(parent, {reference, verification})

              result
            else
              {:error, :credential_changed}
            end
          end
        )

      normalize_checkout(checkout, reference)
    else
      nil -> {:error, :not_found}
    end
  end

  defp current_run(actor_id, expected, %ImportRun{} = capability) do
    now = DateTime.utc_now(:second)
    terminal_states = ImportRun.terminal_states()

    if expected.id == capability.id do
      Repo.one(
        from run in ImportRun,
          join: actor in User,
          on: actor.id == run.actor_user_id,
          where:
            run.id == ^capability.id and run.actor_user_id == ^actor_id and
              actor.kind == :user and actor.state == :active and run.credential_source == :saved and
              run.state not in ^terminal_states and run.lock_version == ^capability.lock_version and
              run.lease_owner == ^capability.lease_owner and not is_nil(run.lease_expires_at) and
              run.lease_expires_at > ^now
      )
    end
  end

  defp current_run(actor_id, expected, %RepositoryItem{} = capability) do
    now = DateTime.utc_now(:second)

    if expected.id == capability.import_run_id do
      Repo.one(
        from item in RepositoryItem,
          join: run in ImportRun,
          on: run.id == item.import_run_id,
          join: actor in User,
          on: actor.id == run.actor_user_id,
          join: attempt in ImportAttempt,
          on:
            attempt.repository_item_id == item.id and
              attempt.attempt_number == item.attempt_count,
          where:
            item.id == ^capability.id and item.import_run_id == ^expected.id and
              item.lock_version == ^capability.lock_version and
              item.lease_owner == ^capability.lease_owner and
              not is_nil(item.lease_expires_at) and item.lease_expires_at > ^now and
              item.selected == true and
              item.state in [:staging_git, :git_staged, :staging_metadata] and
              is_nil(item.cleanup_state) and run.actor_user_id == ^actor_id and
              run.credential_source == :saved and run.state == :running and
              actor.kind == :user and actor.state == :active and attempt.state == :running,
          select: run
      )
    end
  end

  defp reference_matches?(run, %GitHubCredentialVerification{} = reference) do
    reference.credential_id == run.github_credential_id and
      reference.identity_id == run.github_identity_id and
      reference.local_user_id == run.actor_user_id
  end

  defp normalize_checkout({:ok, :ok}, _reference), do: {:ok, :acknowledged}

  defp normalize_checkout({:ok, {:error, :invalid_credential}}, reference) do
    receive do
      {^reference, verification} -> {:error, {:invalid_credential, verification}}
    after
      0 -> {:error, :credential_service_unavailable}
    end
  end

  defp normalize_checkout({:ok, {:error, :credential_changed}}, _reference),
    do: {:error, :credential_changed}

  defp normalize_checkout({:ok, {:error, _reason}}, _reference), do: {:ok, :acknowledged}
  defp normalize_checkout({:error, reason}, _reference), do: {:error, normalize_error(reason)}
  defp normalize_checkout(_result, _reference), do: {:error, :credential_service_unavailable}

  defp normalize_error(reason)
       when reason in [:credential_invalid, :forbidden, :not_found, :unsafe_credential_result],
       do: if(reason == :credential_invalid, do: :invalid_credential, else: reason)

  defp normalize_error(_reason), do: :credential_service_unavailable
end
