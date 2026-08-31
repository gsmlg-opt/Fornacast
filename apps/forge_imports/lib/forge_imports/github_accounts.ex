defmodule ForgeImports.GitHubAccounts do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{
    GitHubAccountView,
    GitHubCredentialCallback,
    GitHubCredentialVerification,
    GitHubProfileSafety,
    User
  }

  alias ForgeImports.GitHub.{Client, Error, RequestGate}
  alias ForgeImports.GitHub.User, as: GitHubUser
  alias ForgeImports.{ImportRun, RepositoryItem}
  alias Fornacast.Repo

  @client_error_kinds [
    :invalid_request,
    :invalid_credential,
    :forbidden,
    :not_found,
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
    :invalid_response,
    :invalid_pagination,
    :pagination_limit,
    :request_gate_busy
  ]
  @terminal_run_states [:completed, :completed_with_warnings, :canceled, :failed]
  @terminal_item_states [:completed, :skipped, :canceled, :failed]
  defmodule CredentialVerificationError do
    @moduledoc false
    defexception message: "GitHub credential verification failed"
  end

  @spec list(User.t()) :: {:ok, [GitHubAccountView.t()]} | {:error, atom()}
  def list(%User{} = actor), do: ForgeAccounts.list_github_accounts(actor)
  def list(_actor), do: {:error, :forbidden}

  @spec link(User.t(), binary(), map(), keyword()) ::
          {:ok, GitHubAccountView.t()} | {:error, atom()}
  def link(%User{} = actor, pat, request_metadata, opts)
      when is_binary(pat) and is_map(request_metadata) and is_list(opts) do
    with {:ok, safe_metadata} <-
           ForgeAccounts.validate_github_request_metadata(request_metadata, pat),
         {:ok, checked} <- ForgeAccounts.validate_github_link_request(actor, safe_metadata),
         {:ok, client, client_opts} <- client_options(opts),
         {:ok, user} <-
           authenticated_user(client, pat, client_opts, {:account_setup, actor.id}),
         {:ok, view} <-
           persist_verified_link(
             actor,
             checked.references,
             user,
             pat,
             checked.request_metadata
           ) do
      {:ok, view}
    else
      {:error, reason} -> {:error, normalize_domain_error(reason)}
    end
  end

  def link(_actor, _pat, _request_metadata, _opts), do: {:error, :forbidden}

  defp persist_verified_link(actor, snapshot, user, pat, request_metadata) do
    case Enum.find(snapshot, &(&1.github_user_id == user.id)) do
      nil ->
        ForgeAccounts.save_github_account_if_absent(
          actor,
          verified_profile(user),
          pat,
          request_metadata
        )

      %{identity_id: identity_id, credential: nil} ->
        ForgeAccounts.save_github_credential_if_absent(
          actor,
          identity_id,
          verified_profile(user),
          pat,
          request_metadata
        )

      %{
        identity_id: identity_id,
        credential: %GitHubCredentialVerification{} = reference
      } ->
        ForgeAccounts.replace_github_credential_if_current(
          actor,
          identity_id,
          reference,
          verified_profile(user),
          pat,
          request_metadata
        )
    end
  end

  @spec replace(User.t(), pos_integer(), binary(), map(), keyword()) ::
          {:ok, GitHubAccountView.t()} | {:error, atom()}
  def replace(%User{} = actor, identity_id, pat, request_metadata, opts)
      when is_integer(identity_id) and is_binary(pat) and is_map(request_metadata) and
             is_list(opts) do
    with {:ok, safe_metadata} <-
           ForgeAccounts.validate_github_request_metadata(request_metadata, pat),
         {:ok, checked} <-
           ForgeAccounts.validate_github_account_request(actor, identity_id, safe_metadata),
         account = checked.reference,
         %GitHubCredentialVerification{} = reference <- account.credential,
         {:ok, client, client_opts} <- client_options(opts),
         {:ok, user} <-
           authenticated_user(
             client,
             pat,
             client_opts,
             {:saved_credential, reference.credential_id}
           ),
         :ok <- exact_identity(user, account.github_user_id),
         {:ok, view} <-
           ForgeAccounts.replace_github_credential_if_current(
             actor,
             identity_id,
             reference,
             verified_profile(user),
             pat,
             checked.request_metadata
           ) do
      {:ok, view}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_domain_error(reason)}
    end
  end

  def replace(_actor, _identity_id, _pat, _request_metadata, _opts),
    do: {:error, :forbidden}

  @spec reverify(User.t(), pos_integer(), map(), keyword()) ::
          {:ok, GitHubAccountView.t()} | {:error, atom()}
  def reverify(%User{} = actor, identity_id, request_metadata, opts)
      when is_integer(identity_id) and is_map(request_metadata) and is_list(opts) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, checked} <-
           ForgeAccounts.validate_github_account_request(actor, identity_id, safe_metadata),
         account = checked.reference,
         %GitHubCredentialVerification{} <- account.credential,
         {:ok, client, client_opts} <- client_options(opts),
         {:ok, callback_result} <-
           ForgeAccounts.with_github_credential_for_verification(
             actor,
             identity_id,
             fn pat, reference ->
               reverify_checked_out(
                 actor,
                 identity_id,
                 account.github_user_id,
                 pat,
                 reference,
                 checked.request_metadata,
                 client,
                 client_opts
               )
             end
           ),
         :ok <- callback_result,
         {:ok, view} <- account_view(actor, identity_id) do
      {:ok, view}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_domain_error(reason)}
    end
  end

  def reverify(_actor, _identity_id, _request_metadata, _opts), do: {:error, :forbidden}

  @spec delete_credential(User.t(), pos_integer(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, atom()}
  def delete_credential(%User{} = actor, identity_id, request_metadata)
      when is_integer(identity_id) and is_map(request_metadata) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, checked} <-
           ForgeAccounts.validate_github_account_request(actor, identity_id, safe_metadata),
         account = checked.reference,
         %GitHubCredentialVerification{} = reference <- account.credential do
      gate_delete(reference, fn ->
        ForgeAccounts.delete_github_credential(
          actor,
          identity_id,
          checked.request_metadata,
          &credential_may_be_deleted(&1, reference)
        )
      end)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_domain_error(reason)}
    end
  end

  def delete_credential(_actor, _identity_id, _request_metadata), do: {:error, :forbidden}

  @spec unlink(User.t(), pos_integer(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, atom()}
  def unlink(%User{} = actor, identity_id, request_metadata)
      when is_integer(identity_id) and is_map(request_metadata) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, checked} <-
           ForgeAccounts.validate_github_account_request(actor, identity_id, safe_metadata),
         account = checked.reference do
      case account.credential do
        %GitHubCredentialVerification{} = reference ->
          gate_delete(reference, fn ->
            ForgeAccounts.unlink_github_account(
              actor,
              identity_id,
              checked.request_metadata,
              &credential_may_be_deleted(&1, reference)
            )
          end)

        nil ->
          ForgeAccounts.unlink_github_account(
            actor,
            identity_id,
            checked.request_metadata,
            &credential_may_be_deleted(&1, nil)
          )
          |> normalize_result()
      end
    else
      {:error, reason} -> {:error, normalize_domain_error(reason)}
    end
  end

  def unlink(_actor, _identity_id, _request_metadata), do: {:error, :forbidden}

  defp reverify_checked_out(
         actor,
         identity_id,
         github_user_id,
         pat,
         reference,
         request_metadata,
         client,
         client_opts
       ) do
    with {:ok, checked_metadata} <-
           ForgeAccounts.validate_github_request_metadata(request_metadata, pat) do
      reverify_with_checked_metadata(
        actor,
        identity_id,
        github_user_id,
        pat,
        reference,
        checked_metadata,
        client,
        client_opts
      )
    end
  end

  defp reverify_with_checked_metadata(
         actor,
         identity_id,
         github_user_id,
         pat,
         reference,
         request_metadata,
         client,
         client_opts
       ) do
    case authenticated_user(
           client,
           pat,
           client_opts,
           {:saved_credential, reference.credential_id}
         ) do
      {:ok, user} ->
        with :ok <- exact_identity(user, github_user_id),
             {:ok, _view} <-
               ForgeAccounts.refresh_github_account_if_current(
                 actor,
                 identity_id,
                 reference,
                 verified_profile(user),
                 request_metadata
               ) do
          :ok
        else
          {:error, reason} -> {:error, normalize_domain_error(reason)}
        end

      {:error, :invalid_credential} ->
        case ForgeAccounts.mark_github_credential_invalid(
               actor,
               identity_id,
               reference,
               request_metadata
             ) do
          {:ok, _view} -> {:error, :invalid_credential}
          {:error, reason} -> {:error, normalize_domain_error(reason)}
        end

      {:error, reason} ->
        {:error, normalize_domain_error(reason)}
    end
  end

  defp authenticated_user(client, pat, opts, gate_key) do
    reference = make_ref()
    parent = self()
    opts = opts |> Keyword.delete(:gate_key) |> Keyword.put(:gate_key, gate_key)

    case GitHubCredentialCallback.invoke(
           fn checked_out_pat ->
             result = client_authenticated_user(client, checked_out_pat, opts)
             send(parent, {reference, result})
             :ok
           end,
           pat,
           CredentialVerificationError
         ) do
      :ok ->
        receive do
          {^reference, result} -> result
        after
          0 -> {:error, :invalid_response}
        end

      :unsafe ->
        {:error, :invalid_response}
    end
  end

  defp client_authenticated_user(client, pat, opts) do
    client.authenticated_user(pat, opts)
    |> normalize_client_result(pat)
  end

  defp normalize_client_result({:ok, %GitHubUser{} = user}, pat) do
    with {:ok, validated} <- validate_user(user),
         :ok <- GitHubProfileSafety.validate(validated, pat) do
      {:ok, validated}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp normalize_client_result({:error, %Error{kind: kind}}, _pat)
       when kind in @client_error_kinds,
       do: {:error, kind}

  defp normalize_client_result(_result, _pat), do: {:error, :invalid_response}

  defp validate_user(%GitHubUser{} = user) do
    GitHubUser.from_json(%{
      "id" => user.id,
      "login" => user.login,
      "name" => user.name,
      "avatar_url" => user.avatar_url,
      "html_url" => user.html_url
    })
  end

  defp verified_profile(%GitHubUser{} = user) do
    %{
      github_user_id: user.id,
      login: user.login,
      name: user.name,
      avatar_url: user.avatar_url,
      profile_url: user.html_url
    }
  end

  defp exact_identity(%GitHubUser{id: id}, id), do: :ok
  defp exact_identity(%GitHubUser{}, _expected), do: {:error, :identity_mismatch}

  defp account_view(actor, identity_id) do
    with {:ok, accounts} <- ForgeAccounts.list_github_accounts(actor),
         %GitHubAccountView{} = view <-
           Enum.find(accounts, &(&1.identity_id == identity_id)) do
      {:ok, view}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp gate_delete(reference, callback) do
    case RequestGate.run({:saved_credential, reference.credential_id}, callback) do
      {:error, :busy} -> {:error, :busy}
      result -> normalize_result(result)
    end
  end

  defp credential_may_be_deleted(current, expected) do
    with :ok <- current_reference_matches(current.credential, expected),
         :ok <- reject_live_leases(current.credential),
         :ok <- reject_active_runs(current.credential) do
      :ok
    end
  end

  defp current_reference_matches(nil, nil), do: :ok

  defp current_reference_matches(
         %GitHubCredentialVerification{} = current,
         %GitHubCredentialVerification{} = expected
       ) do
    if current == expected, do: :ok, else: {:error, :stale}
  end

  defp current_reference_matches(_current, _expected), do: {:error, :stale}

  defp reject_live_leases(nil), do: :ok

  defp reject_live_leases(%GitHubCredentialVerification{credential_id: credential_id}) do
    now = DateTime.utc_now(:second)

    live_run? =
      Repo.exists?(
        from run in ImportRun,
          where:
            run.github_credential_id == ^credential_id and not is_nil(run.lease_expires_at) and
              run.lease_expires_at > ^now
      )

    live_item? =
      Repo.exists?(
        from item in RepositoryItem,
          join: run in ImportRun,
          on: run.id == item.import_run_id,
          where:
            run.github_credential_id == ^credential_id and
              item.state not in ^@terminal_item_states and
              not is_nil(item.lease_expires_at) and item.lease_expires_at > ^now
      )

    if live_run? or live_item?, do: {:error, :busy}, else: :ok
  end

  defp reject_active_runs(nil), do: :ok

  defp reject_active_runs(%GitHubCredentialVerification{credential_id: credential_id}) do
    active? =
      Repo.exists?(
        from run in ImportRun,
          where:
            run.github_credential_id == ^credential_id and
              run.state not in ^@terminal_run_states and run.state != :awaiting_credential
      )

    if active?, do: {:error, :credential_in_use}, else: :ok
  end

  defp client_options(opts) do
    if Keyword.keyword?(opts) and length(Keyword.get_values(opts, :client)) <= 1 do
      {client, client_opts} = Keyword.pop(opts, :client, Client)

      if is_atom(client) and Code.ensure_loaded?(client) and
           function_exported?(client, :authenticated_user, 2),
         do: {:ok, client, client_opts},
         else: {:error, :invalid_response}
    else
      {:error, :invalid_response}
    end
  end

  defp normalize_result({:ok, %GitHubAccountView{}} = result), do: result
  defp normalize_result({:error, reason}), do: {:error, normalize_domain_error(reason)}
  defp normalize_result(_result), do: {:error, :account_update_failed}

  defp normalize_domain_error(reason)
       when reason in [
              :forbidden,
              :not_found,
              :already_linked,
              :identity_mismatch,
              :invalid_credential,
              :credential_invalid,
              :credential_service_unavailable,
              :unsafe_credential_result,
              :duplicate_operation,
              :invalid_operation_id,
              :invalid_request_metadata,
              :credential_in_use,
              :busy,
              :stale
            ],
       do: reason

  defp normalize_domain_error(reason) when reason in @client_error_kinds, do: reason
  defp normalize_domain_error(_reason), do: :account_update_failed
end
