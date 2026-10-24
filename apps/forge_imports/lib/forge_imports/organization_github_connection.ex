defmodule ForgeImports.OrganizationGitHubConnection do
  @moduledoc "Organization Device Flow verification, installation binding and trusted checkout."

  alias ForgeAccounts.{
    GitHubCredentialCallback,
    GitHubDeviceToken,
    GitHubProfileSafety,
    OrganizationGitHubCredentials
  }

  alias ForgeGitHub.{Client, DeviceFlow, Error, OrganizationCredential, UserInstallation}
  alias ForgeMirrors.OrganizationGitHubConnections, as: Connections

  @app_id 5_412_311
  @app_slug "fornacast"
  @authority_keys [
    :organization_id,
    :connection_id,
    :connection_version,
    :credential_id,
    :verification_version,
    :installation_id,
    :github_organization_id
  ]

  defmodule VerificationError do
    defexception message: "Organization GitHub connection verification failed"
  end

  def installation_url, do: "https://github.com/apps/fornacast/installations/new"

  def reference(actor, organization_id) do
    with {:ok, credential} <- OrganizationGitHubCredentials.reference(actor, organization_id) do
      connection = Connections.get(organization_id)

      {:ok,
       %{
         organization_id: organization_id,
         connection_version: if(connection, do: connection.lock_version, else: 0),
         credential: credential
       }}
    end
  end

  def view(actor, organization_id) do
    with {:ok, reference} <- reference(actor, organization_id) do
      connection = Connections.get(organization_id)

      state =
        cond do
          connection == nil ->
            :disconnected

          connection.state == :disconnected ->
            :disconnected

          reference.credential.status != :valid or
              reference.credential.verification_version != connection.credential_version ->
            :reconnect_required

          true ->
            connection.state
        end

      {:ok,
       %{
         connection: connection,
         credential: reference.credential,
         state: state,
         connection_version: reference.connection_version,
         installation_url: installation_url()
       }}
    end
  end

  def connect(actor, organization_id, value, expected, metadata, opts \\ []) do
    with {:ok, token} <- GitHubDeviceToken.normalize(value),
         true <- token.client_id == DeviceFlow.client_id(),
         {:ok, metadata} <-
           ForgeAccounts.validate_github_request_metadata(metadata, token.access_token),
         {:ok, metadata} <-
           ForgeAccounts.validate_github_request_metadata(metadata, token.refresh_token),
         {:ok, _} <- ForgeAccounts.fetch_manageable_organization(actor, organization_id),
         {:ok, profile} <- verify_profile(token, organization_id, opts),
         :ok <- safe_pair(token, fn -> Keyword.get(opts, :before_save, fn -> :ok end).() end) do
      Connections.transaction(
        actor,
        organization_id,
        expected.connection_version,
        fn connection ->
          with {:ok, credential} <-
                 OrganizationGitHubCredentials.save_device_grant_if_current(
                   actor,
                   organization_id,
                   profile,
                   value,
                   expected.credential,
                   metadata
                 ),
               {:ok, saved} <- Connections.store_grant(connection, credential, actor, metadata) do
            {:ok, saved}
          end
        end
      )
    else
      false -> {:error, :incorrect_client_credentials}
      {:error, _} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  def installations(actor, organization_id, opts \\ []) do
    with {:ok, ref} <- reference(actor, organization_id),
         true <- ref.credential.status == :valid do
      collect_credential(
        ref.credential,
        fn token ->
          with {:ok, items} <-
                 client(opts).user_installations(token, client_opts(opts, ref.credential)),
               true <- is_list(items),
               :ok <- safe_installations(ref.credential, items, token) do
            {:ok, Enum.filter(items, &suitable?(&1, ref.credential.client_id))}
          else
            error -> normalize_error(error)
          end
        end,
        opts
      )
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  def bind(actor, organization_id, installation_id, expected_version, metadata, opts \\ []) do
    with {:ok, metadata} <- ForgeAccounts.validate_github_request_metadata(metadata),
         {:ok, ref} <- reference(actor, organization_id),
         true <- to_string(ref.connection_version) == to_string(expected_version),
         {:ok, id} <- positive_id(installation_id),
         {:ok, verified} <-
           collect_credential(
             ref.credential,
             fn token ->
               verify_installation(token, ref.credential, id, opts, false)
             end,
             opts
           ) do
      Connections.transaction(actor, organization_id, expected_version, fn connection ->
        with {:ok, current} <- OrganizationGitHubCredentials.current_reference(organization_id),
             true <- same_credential?(current, ref.credential),
             true <- current.verification_version == connection.credential_version,
             true <- connection.state != :disconnected do
          Connections.bind(
            connection,
            verified.installation,
            verified.inventory,
            actor,
            metadata,
            verified.ready?
          )
        else
          _ -> {:error, :stale}
        end
      end)
    else
      false -> {:error, :stale}
      {:error, _} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  def disconnect(actor, organization_id, expected_version, metadata) do
    with {:ok, metadata} <- ForgeAccounts.validate_github_request_metadata(metadata),
         {:ok, ref} <- reference(actor, organization_id) do
      Connections.transaction(actor, organization_id, expected_version, fn connection ->
        if connection.id do
          with {:ok, credential} <-
                 OrganizationGitHubCredentials.disconnect_if_current(
                   actor,
                   organization_id,
                   ref.credential,
                   metadata
                 ) do
            Connections.disconnect(connection, credential, actor, metadata)
          end
        else
          {:error, :not_found}
        end
      end)
    end
  end

  def scope(id), do: Connections.scope(id)

  def with_credential(expected, callback, opts \\ []) when is_function(callback, 2) do
    with {:ok, current} <- scope(expected.connection_id),
         true <- same_authority?(expected, current) do
      OrganizationCredential.with_credential(
        current,
        fn token, _credential ->
          with {:ok, verified} <-
                 verify_installation(token, current, current.installation_id, opts),
               true <- verified.installation.account_id == current.github_organization_id,
               {:ok, rechecked} <- scope(expected.connection_id),
               true <- same_authority?(expected, rechecked) do
            callback.(token, %{rechecked | inventory: verified.inventory})
          else
            false -> {:error, :credential_changed}
            error -> normalize_error(error)
          end
        end,
        opts
      )
    else
      false -> {:error, :credential_changed}
      error -> normalize_error(error)
    end
  end

  def validate_repository(scope, repository_id, opts \\ []) do
    case with_credential(
           scope,
           fn _token, current ->
             if Enum.any?(current.inventory["repositories"] || [], &(&1["id"] == repository_id)),
               do: :ok,
               else: {:error, :repository_not_in_installation}
           end,
           opts
         ) do
      {:ok, :ok} -> :ok
      {:ok, {:error, _} = error} -> error
      error -> error
    end
  end

  defp verify_profile(token, organization_id, opts) do
    capture(fn ->
      safe_pair(token, fn ->
        with {:ok, %ForgeGitHub.User{} = user} <-
               client(opts).authenticated_user(
                 token.access_token,
                 Keyword.put(provider_opts(opts), :gate_key, {:account_setup, organization_id})
               ),
             :ok <- GitHubProfileSafety.validate(user, token.access_token),
             :ok <- GitHubProfileSafety.validate(user, token.refresh_token) do
          {:ok,
           %{
             github_user_id: user.id,
             login: user.login,
             name: user.name,
             avatar_url: user.avatar_url,
             profile_url: user.html_url
           }}
        else
          error -> normalize_error(error)
        end
        |> send_result()
      end)
    end)
  end

  defp verify_installation(token, credential, installation_id, opts, require_permissions? \\ true) do
    with {:ok, items} <- client(opts).user_installations(token, client_opts(opts, credential)),
         true <- is_list(items),
         :ok <- safe_installations(credential, items, token),
         %UserInstallation{} = item <- Enum.find(items, &(&1.installation.id == installation_id)),
         true <- suitable?(item, credential.client_id),
         ready? =
           Enum.all?(
             ~w(contents issues pull_requests),
             &(item.installation.permissions[&1] in ["read", "write"])
           ),
         true <- not require_permissions? or ready?,
         {:ok, repositories} <-
           client(opts).user_installation_repositories(
             token,
             installation_id,
             client_opts(opts, credential)
           ),
         true <- is_list(repositories) and length(repositories) <= 10_000,
         true <- Enum.all?(repositories, &(&1.owner_id == item.installation.account_id)),
         true <- length(repositories) == length(Enum.uniq_by(repositories, & &1.id)),
         :ok <- validate_access_profiles(repositories, token),
         :ok <- OrganizationGitHubCredentials.validate_external_profiles(credential, repositories) do
      {:ok,
       %{
         installation: item.installation,
         ready?: ready?,
         inventory: %{
           "repositories" =>
             Enum.map(repositories, fn repo ->
               %{
                 "id" => repo.id,
                 "full_name" => repo.full_name,
                 "visibility" => to_string(repo.visibility)
               }
             end)
         }
       }}
    else
      nil -> {:error, :installation_required}
      false -> {:error, :insufficient_installation_access}
      error -> normalize_error(error)
    end
  end

  defp suitable?(
         %UserInstallation{app_id: @app_id, app_slug: @app_slug, installation: installation} =
           item,
         client_id
       ) do
    installation.account_type == :organization and installation.state == :active and
      (item.client_id == nil or item.client_id == client_id)
  end

  defp suitable?(_, _), do: false

  defp safe_installations(scope, items, token) do
    profiles =
      Enum.map(items, fn %UserInstallation{installation: installation} ->
        %{
          login: installation.account_login,
          description: Enum.join(Map.keys(installation.permissions), ",")
        }
      end)

    with :ok <- validate_access_profiles(profiles, token),
         do: OrganizationGitHubCredentials.validate_external_profiles(scope, profiles)
  end

  defp validate_access_profiles(profiles, token) do
    Enum.reduce_while(profiles, :ok, fn profile, :ok ->
      case GitHubProfileSafety.validate(profile, token) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp collect_credential(scope, callback, opts) do
    capture(fn ->
      OrganizationCredential.with_credential(
        scope,
        fn token, _reference ->
          callback.(token) |> send_result()
        end,
        opts
      )
    end)
  end

  # The trusted callback returns only acknowledgments. Verified provider DTOs
  # travel in this process's private mailbox, as in the existing linking facade.
  defp capture(callback) do
    ref = make_ref()
    previous = Process.put({__MODULE__, :result}, ref)

    try do
      case callback.() do
        :ok -> receive_result(ref)
        {:ok, :ok} -> receive_result(ref)
        error -> normalize_error(error)
      end
    after
      if previous,
        do: Process.put({__MODULE__, :result}, previous),
        else: Process.delete({__MODULE__, :result})

      receive do
        {^ref, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp send_result({:ok, value}) do
    send(self(), {Process.get({__MODULE__, :result}), value})
    :ok
  end

  defp send_result(error), do: normalize_error(error)

  defp receive_result(ref) do
    receive do
      {^ref, value} -> {:ok, value}
    after
      0 -> {:error, :invalid_response}
    end
  end

  defp safe_pair(token, callback) do
    GitHubCredentialCallback.invoke(
      fn _ ->
        GitHubCredentialCallback.invoke(
          fn _ -> callback.() end,
          token.refresh_token,
          VerificationError
        )
      end,
      token.access_token,
      VerificationError
    )
    |> case do
      :unsafe -> {:error, :invalid_response}
      result -> result
    end
  end

  defp same_credential?(a, b),
    do:
      a.status == :valid and
        Map.take(a, [:organization_id, :credential_id, :verification_version]) ==
          Map.take(b, [:organization_id, :credential_id, :verification_version])

  defp same_authority?(a, b), do: Map.take(a, @authority_keys) == Map.take(b, @authority_keys)
  defp client(opts), do: Keyword.get(opts, :client, Client)
  defp provider_opts(opts), do: Keyword.drop(opts, [:client, :before_save, :device_flow_options])

  defp client_opts(opts, scope),
    do:
      Keyword.put(provider_opts(opts), :gate_key, {:organization_credential, scope.credential_id})

  defp positive_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp positive_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp positive_id(_), do: {:error, :invalid_request}
  defp normalize_error({:error, %Error{kind: kind}}) when is_atom(kind), do: {:error, kind}
  defp normalize_error({:error, kind}) when is_atom(kind), do: {:error, kind}
  defp normalize_error({:ok, {:error, kind}}) when is_atom(kind), do: {:error, kind}
  defp normalize_error(_), do: {:error, :invalid_response}
end
