defmodule ForgeAccounts.GitHubAccounts do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi

  alias ForgeAccounts.{
    GitHubAccountView,
    GitHubCredentialCallback,
    GitHubCredential,
    GitHubCredentialVerification,
    GitHubCredentialVault,
    GitHubIdentity,
    GitHubIdentityWrite,
    GitHubProfileSafety,
    GitHubRequestMetadata,
    User
  }

  alias Fornacast.{Audit, AuditEvent, Repo}

  @placeholder_envelope %{
    ciphertext: <<0>>,
    nonce: <<0::96>>,
    tag: <<0::128>>,
    key_id: "pending"
  }

  @spec list_github_accounts(User.t()) ::
          {:ok, [GitHubAccountView.t()]} | {:error, :forbidden}
  def list_github_accounts(%User{} = actor) do
    with {:ok, %User{id: actor_id}} <- active_actor(Repo, actor) do
      accounts =
        GitHubIdentity
        |> join(:left, [identity], credential in GitHubCredential,
          on:
            credential.github_identity_id == identity.id and
              credential.local_user_id == ^actor_id
        )
        |> list_scope(actor_id)
        |> order_by(
          [identity, _credential],
          asc: identity.login,
          asc: identity.github_user_id,
          asc: identity.id
        )
        |> select([identity, credential], {identity, credential})
        |> Repo.all()
        |> Enum.map(fn {identity, credential} -> GitHubAccountView.from(identity, credential) end)

      {:ok, accounts}
    end
  end

  def list_github_accounts(_actor), do: {:error, :forbidden}

  @type account_reference :: %{
          identity_id: pos_integer(),
          github_user_id: pos_integer(),
          credential: GitHubCredentialVerification.t() | nil
        }

  @spec github_account_reference(User.t(), pos_integer()) ::
          {:ok, account_reference()} | {:error, :forbidden | :not_found}
  def github_account_reference(%User{} = actor, identity_id) when is_integer(identity_id) do
    with {:ok, %User{id: actor_id}} <- active_actor(Repo, actor),
         {:ok, identity} <- owned_identity(Repo, identity_id, actor_id, lock?: false) do
      credential =
        Repo.get_by(GitHubCredential,
          github_identity_id: identity.id,
          local_user_id: actor_id
        )

      {:ok,
       %{
         identity_id: identity.id,
         github_user_id: identity.github_user_id,
         credential: verification_reference(credential, identity)
       }}
    end
  end

  def github_account_reference(_actor, _identity_id), do: {:error, :forbidden}

  @spec github_account_references(User.t()) ::
          {:ok, [account_reference()]} | {:error, :forbidden}
  def github_account_references(%User{} = actor) do
    with {:ok, %User{id: actor_id} = active_actor} <- active_actor(Repo, actor) do
      references =
        actor_id
        |> owned_account_rows()
        |> Enum.map(fn {identity, credential} ->
          account_reference(active_actor, identity, credential)
        end)

      {:ok, references}
    end
  end

  def github_account_references(_actor), do: {:error, :forbidden}

  @doc false
  def validate_github_link_request(%User{} = actor, request_metadata)
      when is_map(request_metadata) do
    validate_github_link_inputs(actor, request_metadata, nil, nil)
  end

  def validate_github_link_request(_actor, _request_metadata), do: {:error, :forbidden}

  defp validate_github_link_inputs(
         %User{} = actor,
         request_metadata,
         verified_profile,
         submitted_credential
       ) do
    transact_checked(fn ->
      with {:ok, safe_metadata} <- GitHubRequestMetadata.validate(request_metadata),
           {:ok, active_actor} <- active_github_actor(Repo, actor),
           {:ok, checked_metadata} <-
             validate_actor_inputs(
               active_actor,
               safe_metadata,
               verified_profile,
               submitted_credential
             ),
           rows <- owned_account_rows(active_actor.id) do
        references =
          Enum.map(rows, fn {identity, credential} ->
            account_reference(active_actor, identity, credential)
          end)

        {:ok, %{request_metadata: checked_metadata, references: references}}
      end
    end)
  end

  @doc false
  def validate_github_account_request(%User{} = actor, identity_id, request_metadata)
      when is_integer(identity_id) and is_map(request_metadata) do
    transact_checked(fn ->
      with {:ok, safe_metadata} <- GitHubRequestMetadata.validate(request_metadata),
           {:ok, active_actor} <- active_github_actor(Repo, actor),
           :ok <- GitHubCredentialVault.ready?(),
           {:ok, checked_metadata} <-
             validate_owned_credentials(active_actor.id, safe_metadata),
           rows <- owned_account_rows(active_actor.id),
           {:ok, {identity, credential}} <- find_account_row(rows, identity_id) do
        {:ok,
         %{
           request_metadata: checked_metadata,
           reference: account_reference(active_actor, identity, credential)
         }}
      end
    end)
  end

  def validate_github_account_request(_actor, _identity_id, _request_metadata),
    do: {:error, :forbidden}

  @spec save_github_account(User.t(), map(), binary(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, term()}
  def save_github_account(%User{} = actor, verified_profile, pat, request_metadata)
      when is_map(verified_profile) and is_binary(pat) and is_map(request_metadata) do
    with {:ok, safe_metadata} <- GitHubRequestMetadata.validate(request_metadata, pat),
         {:ok, checked} <-
           validate_github_link_inputs(actor, safe_metadata, verified_profile, pat) do
      save_github_account_from_snapshot(
        actor,
        checked.references,
        verified_profile,
        pat,
        checked.request_metadata
      )
    end
  end

  def save_github_account(_actor, _verified_profile, _pat, _request_metadata),
    do: {:error, :forbidden}

  @doc false
  def save_github_account_if_absent(%User{} = actor, verified_profile, pat, request_metadata)
      when is_map(verified_profile) and is_binary(pat) and is_map(request_metadata) do
    with {:ok, safe_metadata} <- GitHubRequestMetadata.validate(request_metadata, pat) do
      save_absent_github_account(actor, verified_profile, pat, safe_metadata)
    end
  end

  def save_github_account_if_absent(_actor, _verified_profile, _pat, _request_metadata),
    do: {:error, :forbidden}

  @doc false
  def save_github_credential_if_absent(
        %User{} = actor,
        identity_id,
        verified_profile,
        pat,
        request_metadata
      )
      when is_integer(identity_id) and is_map(verified_profile) and is_binary(pat) and
             is_map(request_metadata) do
    with {:ok, safe_metadata} <- GitHubRequestMetadata.validate(request_metadata, pat) do
      save_absent_github_credential(
        actor,
        identity_id,
        verified_profile,
        pat,
        safe_metadata
      )
    end
  end

  def save_github_credential_if_absent(
        _actor,
        _identity_id,
        _verified_profile,
        _pat,
        _request_metadata
      ),
      do: {:error, :forbidden}

  defp save_github_account_from_snapshot(actor, snapshot, profile, pat, request_metadata) do
    github_user_id = profile_github_user_id(profile)

    case Enum.find(snapshot, &(&1.github_user_id == github_user_id)) do
      nil ->
        save_github_account_if_absent(actor, profile, pat, request_metadata)

      %{identity_id: identity_id, credential: nil} ->
        save_github_credential_if_absent(
          actor,
          identity_id,
          profile,
          pat,
          request_metadata
        )

      %{
        identity_id: identity_id,
        credential: %GitHubCredentialVerification{} = reference
      } ->
        replace_github_credential_if_current(
          actor,
          identity_id,
          reference,
          profile,
          pat,
          request_metadata
        )
    end
  end

  defp save_absent_github_account(actor, verified_profile, pat, request_metadata) do
    verified_at = DateTime.utc_now(:second)

    github_mutation(actor, request_metadata,
      verified_profile: verified_profile,
      submitted_credential: pat
    )
    |> Multi.run(:identity_candidate, fn repo, %{actor: active_actor} ->
      absent_link_candidate(repo, active_actor, verified_profile)
    end)
    |> Multi.run(:identity, fn _repo, %{identity_candidate: candidate} ->
      observe_absent_link_candidate(candidate, verified_profile, verified_at)
    end)
    |> Multi.run(:link, fn repo, %{actor: active_actor, identity: identity} ->
      claim_identity(repo, identity.id, active_actor.id)
    end)
    |> Multi.run(:credential, fn repo, %{actor: active_actor, link: link} ->
      insert_absent_credential(repo, active_actor, link.identity, pat, verified_at)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.account.linked",
        changes.link.identity,
        changes.credential,
        changes.request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{link: link, credential: credential} ->
      {:ok, GitHubAccountView.from(link.identity, credential)}
    end)
    |> transact_view()
  end

  defp save_absent_github_credential(
         actor,
         identity_id,
         verified_profile,
         pat,
         request_metadata
       ) do
    verified_at = DateTime.utc_now(:second)

    github_mutation(actor, request_metadata,
      verified_profile: verified_profile,
      submitted_credential: pat
    )
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      observe_selected_identity(
        repo,
        active_actor.id,
        identity_id,
        verified_profile,
        verified_at
      )
    end)
    |> Multi.run(:credential, fn repo, %{actor: active_actor, identity: identity} ->
      insert_absent_credential(repo, active_actor, identity, pat, verified_at)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.credential.replaced",
        changes.identity,
        changes.credential,
        changes.request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity, credential: credential} ->
      {:ok, GitHubAccountView.from(identity, credential)}
    end)
    |> transact_view()
  end

  @spec replace_github_credential(User.t(), pos_integer(), map(), binary(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, term()}
  def replace_github_credential(
        %User{} = actor,
        identity_id,
        verified_profile,
        pat,
        request_metadata
      )
      when is_integer(identity_id) and is_map(verified_profile) and is_binary(pat) and
             is_map(request_metadata) do
    with {:ok, safe_metadata} <- GitHubRequestMetadata.validate(request_metadata, pat) do
      replace_verified_github_credential(
        actor,
        identity_id,
        verified_profile,
        pat,
        safe_metadata
      )
    end
  end

  def replace_github_credential(
        _actor,
        _identity_id,
        _verified_profile,
        _pat,
        _request_metadata
      ),
      do: {:error, :forbidden}

  defp replace_verified_github_credential(
         actor,
         identity_id,
         verified_profile,
         pat,
         request_metadata
       ) do
    verified_at = DateTime.utc_now(:second)

    github_mutation(actor, request_metadata,
      verified_profile: verified_profile,
      submitted_credential: pat
    )
    |> Multi.run(:selected_identity, fn repo, %{actor: active_actor} ->
      owned_identity(repo, identity_id, active_actor.id)
    end)
    |> Multi.run(:current_credential, fn repo, changes ->
      required_owned_credential(repo, changes.actor, changes.selected_identity)
    end)
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      observe_selected_identity(
        repo,
        active_actor.id,
        identity_id,
        verified_profile,
        verified_at
      )
    end)
    |> Multi.run(:credential, fn repo, changes ->
      rotate_credential(repo, changes.current_credential, changes.identity, pat, verified_at)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.credential.replaced",
        changes.identity,
        changes.credential,
        changes.request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity, credential: credential} ->
      {:ok, GitHubAccountView.from(identity, credential)}
    end)
    |> transact_view()
  end

  @spec replace_github_credential_if_current(
          User.t(),
          pos_integer(),
          GitHubCredentialVerification.t(),
          map(),
          binary(),
          map()
        ) :: {:ok, GitHubAccountView.t()} | {:error, term()}
  def replace_github_credential_if_current(
        %User{} = actor,
        identity_id,
        %GitHubCredentialVerification{} = reference,
        verified_profile,
        pat,
        request_metadata
      )
      when is_integer(identity_id) and is_map(verified_profile) and is_binary(pat) and
             is_map(request_metadata) do
    with {:ok, safe_metadata} <- GitHubRequestMetadata.validate(request_metadata, pat) do
      replace_verified_github_credential_if_current(
        actor,
        identity_id,
        reference,
        verified_profile,
        pat,
        safe_metadata
      )
    end
  end

  def replace_github_credential_if_current(
        _actor,
        _identity_id,
        _reference,
        _verified_profile,
        _pat,
        _request_metadata
      ),
      do: {:error, :forbidden}

  defp replace_verified_github_credential_if_current(
         actor,
         identity_id,
         reference,
         verified_profile,
         pat,
         request_metadata
       ) do
    verified_at = DateTime.utc_now(:second)

    github_mutation(actor, request_metadata,
      verified_profile: verified_profile,
      submitted_credential: pat
    )
    |> Multi.run(:selected_identity, fn repo, %{actor: active_actor} ->
      owned_identity(repo, identity_id, active_actor.id)
    end)
    |> Multi.run(:current_credential, fn repo, changes ->
      current_verification_credential(
        repo,
        changes.actor,
        changes.selected_identity,
        reference
      )
    end)
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      observe_selected_identity(
        repo,
        active_actor.id,
        identity_id,
        verified_profile,
        verified_at
      )
    end)
    |> Multi.run(:credential, fn repo, changes ->
      rotate_credential_if_current(
        repo,
        changes.current_credential,
        changes.identity,
        pat,
        verified_at,
        reference
      )
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.credential.replaced",
        changes.identity,
        changes.credential,
        changes.request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity, credential: credential} ->
      {:ok, GitHubAccountView.from(identity, credential)}
    end)
    |> transact_view()
  end

  @spec refresh_github_account(User.t(), pos_integer(), map(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, term()}
  def refresh_github_account(%User{} = actor, identity_id, verified_profile, request_metadata)
      when is_integer(identity_id) and is_map(verified_profile) and is_map(request_metadata) do
    verified_at = DateTime.utc_now(:second)

    github_mutation(actor, request_metadata, verified_profile: verified_profile)
    |> Multi.run(:selected_identity, fn repo, %{actor: active_actor} ->
      owned_identity(repo, identity_id, active_actor.id)
    end)
    |> Multi.run(:current_credential, fn repo, changes ->
      required_owned_credential(repo, changes.actor, changes.selected_identity)
    end)
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      observe_selected_identity(
        repo,
        active_actor.id,
        identity_id,
        verified_profile,
        verified_at
      )
    end)
    |> Multi.run(:credential, fn repo, changes ->
      update_verification(repo, changes.current_credential, :valid, verified_at)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.account.reverified",
        changes.identity,
        changes.credential,
        changes.request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity, credential: credential} ->
      {:ok, GitHubAccountView.from(identity, credential)}
    end)
    |> transact_view()
  end

  def refresh_github_account(_actor, _identity_id, _verified_profile, _request_metadata),
    do: {:error, :forbidden}

  @spec refresh_github_account_if_current(
          User.t(),
          pos_integer(),
          GitHubCredentialVerification.t(),
          map(),
          map()
        ) :: {:ok, GitHubAccountView.t()} | {:error, term()}
  def refresh_github_account_if_current(
        %User{} = actor,
        identity_id,
        %GitHubCredentialVerification{} = reference,
        verified_profile,
        request_metadata
      )
      when is_integer(identity_id) and is_map(verified_profile) and is_map(request_metadata) do
    verified_at = DateTime.utc_now(:second)

    github_mutation(actor, request_metadata, verified_profile: verified_profile)
    |> Multi.run(:selected_identity, fn repo, %{actor: active_actor} ->
      owned_identity(repo, identity_id, active_actor.id)
    end)
    |> Multi.run(:current_credential, fn repo, changes ->
      current_verification_credential(
        repo,
        changes.actor,
        changes.selected_identity,
        reference
      )
    end)
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      observe_selected_identity(
        repo,
        active_actor.id,
        identity_id,
        verified_profile,
        verified_at
      )
    end)
    |> Multi.run(:credential, fn repo, changes ->
      update_verification_if_current(
        repo,
        changes.current_credential,
        reference,
        :valid,
        verified_at
      )
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.account.reverified",
        changes.identity,
        changes.credential,
        changes.request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity, credential: credential} ->
      {:ok, GitHubAccountView.from(identity, credential)}
    end)
    |> transact_view()
  end

  def refresh_github_account_if_current(
        _actor,
        _identity_id,
        _reference,
        _verified_profile,
        _request_metadata
      ),
      do: {:error, :forbidden}

  @spec mark_github_credential_invalid(
          User.t(),
          pos_integer(),
          GitHubCredentialVerification.t(),
          map()
        ) :: {:ok, GitHubAccountView.t()} | {:error, term()}
  def mark_github_credential_invalid(
        %User{} = actor,
        identity_id,
        %GitHubCredentialVerification{} = reference,
        request_metadata
      )
      when is_integer(identity_id) and is_map(request_metadata) do
    github_mutation(actor, request_metadata)
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      owned_identity(repo, identity_id, active_actor.id)
    end)
    |> Multi.run(:current_credential, fn repo, changes ->
      current_verification_credential(repo, changes.actor, changes.identity, reference)
    end)
    |> Multi.run(:credential, fn repo, changes ->
      update_verification_if_current(
        repo,
        changes.current_credential,
        reference,
        :invalid,
        changes.current_credential.last_verified_at
      )
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.credential.invalidated",
        changes.identity,
        changes.credential,
        changes.request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity, credential: credential} ->
      {:ok, GitHubAccountView.from(identity, credential)}
    end)
    |> transact_view()
  end

  def mark_github_credential_invalid(
        _actor,
        _identity_id,
        _reference,
        _request_metadata
      ),
      do: {:error, :forbidden}

  @spec delete_github_credential(User.t(), pos_integer(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, term()}
  def delete_github_credential(%User{} = actor, identity_id, request_metadata)
      when is_integer(identity_id) and is_map(request_metadata) do
    delete_github_credential(actor, identity_id, request_metadata, fn _reference -> :ok end)
  end

  def delete_github_credential(_actor, _identity_id, _request_metadata),
    do: {:error, :forbidden}

  @doc false
  def delete_github_credential(%User{} = actor, identity_id, request_metadata, before_delete)
      when is_integer(identity_id) and is_map(request_metadata) and
             is_function(before_delete, 1) do
    github_mutation(actor, request_metadata)
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      owned_identity(repo, identity_id, active_actor.id)
    end)
    |> Multi.run(:credential_record, fn repo, changes ->
      required_owned_credential(repo, changes.actor, changes.identity)
    end)
    |> Multi.run(:reference, fn _repo, changes ->
      {:ok, account_reference(changes.actor, changes.identity, changes.credential_record)}
    end)
    |> Multi.run(:before_delete, fn _repo, %{reference: reference} ->
      invoke_before_credential_delete(before_delete, reference)
    end)
    |> Multi.run(:credential, fn repo, %{credential_record: credential} ->
      repo.delete(credential)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.credential.deleted",
        changes.identity,
        nil,
        changes.request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity} ->
      {:ok, GitHubAccountView.from(identity, nil)}
    end)
    |> transact_view()
  end

  def delete_github_credential(_actor, _identity_id, _request_metadata, _before_delete),
    do: {:error, :forbidden}

  @spec unlink_github_account(User.t(), pos_integer(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, term()}
  def unlink_github_account(%User{} = actor, identity_id, request_metadata)
      when is_integer(identity_id) and is_map(request_metadata) do
    unlink_github_account(actor, identity_id, request_metadata, fn _reference -> :ok end)
  end

  def unlink_github_account(_actor, _identity_id, _request_metadata),
    do: {:error, :forbidden}

  @doc false
  def unlink_github_account(%User{} = actor, identity_id, request_metadata, before_unlink)
      when is_integer(identity_id) and is_map(request_metadata) and
             is_function(before_unlink, 1) do
    github_mutation(actor, request_metadata)
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      owned_identity(repo, identity_id, active_actor.id)
    end)
    |> Multi.run(:credential_record, fn repo, changes ->
      optional_owned_credential(repo, changes.actor, changes.identity)
    end)
    |> Multi.run(:reference, fn _repo, changes ->
      {:ok, account_reference(changes.actor, changes.identity, changes.credential_record)}
    end)
    |> Multi.run(:before_unlink, fn _repo, %{reference: reference} ->
      invoke_before_credential_delete(before_unlink, reference)
    end)
    |> Multi.run(:unlink, fn repo, %{actor: active_actor, identity: identity} ->
      unlink(repo, identity, active_actor.id)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.account.unlinked",
        changes.unlink,
        nil,
        changes.request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{unlink: identity} ->
      {:ok, GitHubAccountView.from(identity, nil)}
    end)
    |> transact_view()
  end

  def unlink_github_account(_actor, _identity_id, _request_metadata, _before_unlink),
    do: {:error, :forbidden}

  defmodule CredentialCallbackError do
    @moduledoc false
    defexception message: "credential callback failed"
  end

  @type callback_result :: :ok | {:error, atom() | tuple() | list()}

  @spec with_github_credential(User.t(), pos_integer(), (binary() -> callback_result())) ::
          {:ok, callback_result()}
          | {:error,
             :forbidden
             | :not_found
             | :credential_invalid
             | :credential_service_unavailable
             | :unsafe_credential_result}
  def with_github_credential(%User{} = actor, identity_id, callback)
      when is_integer(identity_id) and is_function(callback, 1) do
    with {:ok, %User{id: actor_id}} <- active_actor(Repo, actor),
         {:ok, identity} <- owned_identity(Repo, identity_id, actor_id, lock?: false),
         %GitHubCredential{} = credential <-
           Repo.get_by(GitHubCredential,
             github_identity_id: identity.id,
             local_user_id: actor_id
           ),
         :ok <- available_credential(credential) do
      checked_out_result(credential, identity, callback)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def with_github_credential(_actor, _identity_id, _callback), do: {:error, :forbidden}

  @spec with_github_credential_for_verification(
          User.t(),
          pos_integer(),
          (binary(), GitHubCredentialVerification.t() -> callback_result())
        ) ::
          {:ok, callback_result()}
          | {:error,
             :forbidden
             | :not_found
             | :credential_service_unavailable
             | :unsafe_credential_result}
  def with_github_credential_for_verification(%User{} = actor, identity_id, callback)
      when is_integer(identity_id) and is_function(callback, 2) do
    with {:ok, %User{id: actor_id}} <- active_actor(Repo, actor),
         {:ok, identity} <- owned_identity(Repo, identity_id, actor_id, lock?: false),
         %GitHubCredential{} = credential <-
           Repo.get_by(GitHubCredential,
             github_identity_id: identity.id,
             local_user_id: actor_id
           ) do
      reference = verification_reference(credential, identity)

      checked_out_result(credential, identity, fn pat -> callback.(pat, reference) end)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def with_github_credential_for_verification(_actor, _identity_id, _callback),
    do: {:error, :forbidden}

  defp checked_out_result(credential, identity, callback) do
    case GitHubCredentialVault.with_saved_credential(credential, identity, fn pat ->
           GitHubCredentialCallback.invoke(callback, pat, CredentialCallbackError)
         end) do
      {:ok, :ok} -> {:ok, :ok}
      {:ok, {:error, _safe_reason} = result} -> {:ok, result}
      {:ok, :unsafe} -> {:error, :unsafe_credential_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_absent_credential(repo, actor, identity, pat, verified_at) do
    case repo.get_by(GitHubCredential,
           github_identity_id: identity.id,
           local_user_id: actor.id
         ) do
      nil ->
        with {:ok, credential} <- insert_absent_placeholder(repo, actor, identity, verified_at),
             {:ok, encrypted} <- encrypt_credential(credential, identity, pat),
             {:ok, saved} <- persist_envelope(repo, credential, encrypted, verified_at) do
          {:ok, saved}
        end

      %GitHubCredential{} ->
        {:error, :stale}
    end
  end

  defp insert_absent_placeholder(repo, actor, identity, verified_at) do
    case insert_placeholder(repo, actor, identity, verified_at) do
      {:ok, credential} -> {:ok, credential}
      {:error, %Ecto.Changeset{}} -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_placeholder(repo, actor, identity, verified_at) do
    attrs =
      Map.merge(@placeholder_envelope, %{
        local_user_id: actor.id,
        github_identity_id: identity.id,
        status: :valid,
        last_verified_at: verified_at
      })

    %GitHubCredential{}
    |> GitHubCredential.changeset(attrs)
    |> repo.insert()
  end

  defp rotate_credential(repo, credential, identity, pat, verified_at) do
    with {:ok, encrypted} <- encrypt_credential(credential, identity, pat) do
      persist_rotated_envelope(repo, credential, encrypted, verified_at)
    end
  end

  defp rotate_credential_if_current(
         repo,
         credential,
         identity,
         pat,
         verified_at,
         _reference
       ) do
    with {:ok, encrypted} <- encrypt_credential(credential, identity, pat) do
      persist_rotated_envelope(repo, credential, encrypted, verified_at)
    end
  end

  defp encrypt_credential(credential, identity, pat) do
    GitHubCredentialVault.encrypt_saved(credential, identity, pat)
  end

  defp persist_envelope(repo, credential, envelope, verified_at) do
    credential
    |> GitHubCredential.changeset(%{
      ciphertext: envelope.ciphertext,
      nonce: envelope.nonce,
      tag: envelope.tag,
      key_id: envelope.key_id,
      status: :valid,
      last_verified_at: verified_at
    })
    |> repo.update()
  end

  defp persist_rotated_envelope(repo, credential, envelope, verified_at) do
    now = DateTime.utc_now(:second)

    query =
      GitHubCredential
      |> where(
        [saved],
        saved.id == ^credential.id and saved.local_user_id == ^credential.local_user_id and
          saved.github_identity_id == ^credential.github_identity_id
      )
      |> match_loaded_generation(credential)

    updates = [
      ciphertext: envelope.ciphertext,
      nonce: envelope.nonce,
      tag: envelope.tag,
      key_id: envelope.key_id,
      status: :valid,
      last_verified_at: verified_at,
      updated_at: now
    ]

    case repo.update_all(query, set: updates, inc: [verification_version: 1]) do
      {1, _} -> {:ok, repo.get!(GitHubCredential, credential.id)}
      {0, _} -> {:error, :stale}
    end
  end

  defp update_verification(repo, credential, status, verified_at) do
    now = DateTime.utc_now(:second)

    query =
      GitHubCredential
      |> where([saved], saved.id == ^credential.id)
      |> match_loaded_generation(credential)

    case repo.update_all(
           query,
           set: [status: status, last_verified_at: verified_at, updated_at: now],
           inc: [verification_version: 1]
         ) do
      {1, _} -> {:ok, repo.get!(GitHubCredential, credential.id)}
      {0, _} -> {:error, :stale}
    end
  end

  defp update_verification_if_current(repo, credential, _reference, status, verified_at) do
    now = DateTime.utc_now(:second)

    query =
      GitHubCredential
      |> where(
        [saved],
        saved.id == ^credential.id and saved.local_user_id == ^credential.local_user_id and
          saved.github_identity_id == ^credential.github_identity_id
      )
      |> match_loaded_generation(credential)

    case repo.update_all(query,
           set: [status: status, last_verified_at: verified_at, updated_at: now],
           inc: [verification_version: 1]
         ) do
      {1, _} -> {:ok, repo.get!(GitHubCredential, credential.id)}
      {0, _} -> {:error, :stale}
    end
  end

  defp current_verification_credential(
         repo,
         %User{id: actor_id},
         %GitHubIdentity{id: identity_id},
         %GitHubCredentialVerification{} = reference
       ) do
    query =
      from saved in GitHubCredential,
        where:
          saved.id == ^reference.credential_id and saved.local_user_id == ^actor_id and
            saved.github_identity_id == ^identity_id and
            saved.verification_version == ^reference.verification_version

    cond do
      reference.local_user_id != actor_id ->
        {:error, :stale}

      reference.identity_id != identity_id ->
        {:error, :stale}

      credential = repo.one(query) ->
        if generation_matches?(credential, reference),
          do: {:ok, credential},
          else: {:error, :stale}

      true ->
        {:error, :stale}
    end
  end

  defp match_loaded_generation(query, credential) do
    where(
      query,
      [saved],
      saved.verification_version == ^credential.verification_version and
        saved.ciphertext == ^credential.ciphertext and saved.nonce == ^credential.nonce and
        saved.tag == ^credential.tag and saved.key_id == ^credential.key_id
    )
  end

  defp claim_identity(repo, identity_id, actor_id) do
    {updated, _} =
      GitHubIdentity
      |> where(
        [identity],
        identity.id == ^identity_id and identity.kind == :user and
          is_nil(identity.local_user_id)
      )
      |> repo.update_all(set: [local_user_id: actor_id, updated_at: DateTime.utc_now(:second)])

    case {updated, repo.get(GitHubIdentity, identity_id)} do
      {1, %GitHubIdentity{kind: :user, local_user_id: ^actor_id} = identity} ->
        {:ok, %{identity: identity, created?: true}}

      {0, %GitHubIdentity{kind: :user, local_user_id: ^actor_id} = identity} ->
        {:ok, %{identity: identity, created?: false}}

      {_updated, %GitHubIdentity{kind: :user}} ->
        {:error, :already_linked}

      {_updated, %GitHubIdentity{}} ->
        {:error, :forbidden}

      {_updated, nil} ->
        {:error, :not_found}
    end
  end

  defp absent_link_candidate(repo, actor, profile) do
    case profile_github_user_id(profile) do
      github_user_id when is_integer(github_user_id) and github_user_id > 0 ->
        query =
          GitHubIdentity
          |> where(
            [identity],
            identity.github_user_id == ^github_user_id and identity.kind == :user
          )
          |> maybe_lock(true)

        case repo.one(query) do
          nil -> {:ok, :new}
          %GitHubIdentity{local_user_id: nil} = identity -> {:ok, {:existing, identity.id}}
          %GitHubIdentity{local_user_id: actor_id} when actor_id == actor.id -> {:error, :stale}
          %GitHubIdentity{} -> {:error, :already_linked}
        end

      _invalid ->
        {:error, :invalid}
    end
  end

  defp observe_absent_link_candidate(candidate, profile, verified_at) do
    case ForgeAccounts.observe_github_identity(profile, verified_at) do
      {:ok, identity} -> verify_absent_link_candidate(candidate, identity)
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_absent_link_candidate(:new, identity), do: {:ok, identity}

  defp verify_absent_link_candidate(
         {:existing, identity_id},
         %GitHubIdentity{id: identity_id} = identity
       ),
       do: {:ok, identity}

  defp verify_absent_link_candidate(_candidate, _identity), do: {:error, :stale}

  defp observe_selected_identity(repo, actor_id, identity_id, profile, verified_at) do
    with {:ok, identity} <- owned_identity(repo, identity_id, actor_id),
         true <- profile_github_user_id(profile) == identity.github_user_id,
         {:ok, %GitHubIdentity{id: ^identity_id} = observed} <-
           ForgeAccounts.observe_github_identity(profile, verified_at) do
      {:ok, observed}
    else
      false -> {:error, :identity_mismatch}
      {:ok, %GitHubIdentity{}} -> {:error, :identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp owned_identity(repo, identity_id, actor_id, opts \\ []) do
    query =
      GitHubIdentity
      |> where(
        [identity],
        identity.id == ^identity_id and identity.kind == :user and
          identity.local_user_id == ^actor_id
      )
      |> maybe_lock(Keyword.get(opts, :lock?, true))

    case repo.one(query) do
      %GitHubIdentity{} = identity -> {:ok, identity}
      nil -> {:error, :not_found}
    end
  end

  defp maybe_lock(query, true) do
    if postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end

  defp maybe_lock(query, false), do: query

  defp list_scope(query, actor_id) do
    if turso?() do
      # WORKAROUND(upstream): gsmlg-dev/concord#80
      # Turso's local-user FK and deleted-identity constraint make the kind filter redundant.
      where(query, [identity, _credential], identity.local_user_id == ^actor_id)
    else
      where(
        query,
        [identity, _credential],
        identity.kind == :user and identity.local_user_id == ^actor_id
      )
    end
  end

  defp owned_account_rows(actor_id) do
    GitHubIdentity
    |> join(:left, [identity], credential in GitHubCredential,
      on: credential.github_identity_id == identity.id and credential.local_user_id == ^actor_id
    )
    |> list_scope(actor_id)
    |> order_by([identity, _credential], asc: identity.github_user_id, asc: identity.id)
    |> select([identity, credential], {identity, credential})
    |> Repo.all()
  end

  defp owned_credential_rows(actor_id) do
    GitHubCredential
    |> join(:inner, [credential], identity in GitHubIdentity,
      on: identity.id == credential.github_identity_id
    )
    |> where([credential, _identity], credential.local_user_id == ^actor_id)
    |> order_by([credential, _identity], asc: credential.id)
    |> select([credential, identity], {identity, credential})
    |> Repo.all()
  end

  defp validate_owned_credentials(actor_id, request_metadata, verified_profile \\ nil) do
    actor_id
    |> owned_credential_rows()
    |> validate_account_rows(request_metadata, verified_profile)
  end

  defp validate_account_rows(rows, request_metadata, verified_profile) do
    Enum.reduce_while(rows, {:ok, request_metadata}, fn
      {identity, credential}, {:ok, safe_metadata} ->
        case validate_saved_inputs(credential, identity, safe_metadata, verified_profile) do
          {:ok, checked_metadata} -> {:cont, {:ok, checked_metadata}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp find_account_row(rows, identity_id) do
    case Enum.find(rows, fn {identity, _credential} -> identity.id == identity_id end) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp required_owned_credential(repo, actor, identity) do
    case repo.get_by(GitHubCredential,
           github_identity_id: identity.id,
           local_user_id: actor.id
         ) do
      %GitHubCredential{} = credential -> {:ok, credential}
      nil -> {:error, :not_found}
    end
  end

  defp optional_owned_credential(repo, actor, identity) do
    {:ok,
     repo.get_by(GitHubCredential,
       github_identity_id: identity.id,
       local_user_id: actor.id
     )}
  end

  defp validate_saved_inputs(credential, identity, request_metadata, verified_profile) do
    with {:ok, safe_metadata} <- GitHubRequestMetadata.validate(request_metadata) do
      case GitHubCredentialVault.with_saved_credential(credential, identity, fn pat ->
             with {:ok, checked_metadata} <- GitHubRequestMetadata.validate(safe_metadata, pat),
                  :ok <- GitHubProfileSafety.validate(verified_profile, pat) do
               {:ok, checked_metadata}
             end
           end) do
        {:ok, {:ok, checked_metadata}} ->
          {:ok, checked_metadata}

        {:ok, {:error, :invalid_request_metadata}} ->
          {:error, :invalid_request_metadata}

        {:ok, {:error, :invalid_response}} ->
          {:error, :invalid_response}

        {:error, reason} ->
          validate_legacy_owned_profile(credential, identity, verified_profile, reason)
      end
    end
  end

  defp validate_legacy_owned_profile(_credential, _identity, nil, reason),
    do: {:error, reason}

  defp validate_legacy_owned_profile(credential, identity, verified_profile, reason) do
    case GitHubCredentialVault.validate_actor_owned_profile(
           credential,
           identity,
           credential.local_user_id,
           verified_profile
         ) do
      {:error, :invalid_response} -> {:error, :invalid_response}
      _unavailable_or_safe -> {:error, reason}
    end
  end

  defp account_reference(actor, identity, credential) do
    %{
      identity_id: identity.id,
      github_user_id: identity.github_user_id,
      local_user_id: actor.id,
      credential: verification_reference(credential, identity)
    }
  end

  defp verification_reference(nil, _identity), do: nil

  defp verification_reference(%GitHubCredential{} = credential, %GitHubIdentity{} = identity) do
    %GitHubCredentialVerification{
      credential_id: credential.id,
      identity_id: identity.id,
      local_user_id: credential.local_user_id,
      verification_version: credential.verification_version,
      generation_digest: generation_digest(credential)
    }
  end

  defp generation_matches?(credential, reference) do
    digest = generation_digest(credential)

    is_binary(reference.generation_digest) and byte_size(reference.generation_digest) == 32 and
      :crypto.hash_equals(digest, reference.generation_digest)
  end

  defp generation_digest(credential) do
    payload = [
      length_prefixed("fornacast.github-credential-generation.v1"),
      <<credential.id::unsigned-64, credential.local_user_id::unsigned-64,
        credential.github_identity_id::unsigned-64,
        credential.verification_version::unsigned-64>>,
      length_prefixed(credential.ciphertext),
      length_prefixed(credential.nonce),
      length_prefixed(credential.tag),
      length_prefixed(credential.key_id)
    ]

    :crypto.hash(:sha256, payload)
  end

  defp length_prefixed(value) when is_binary(value),
    do: [<<byte_size(value)::unsigned-64>>, value]

  defp invoke_before_credential_delete(callback, reference) do
    case callback.(reference) do
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, reason}
      _unsafe -> {:error, :credential_in_use}
    end
  end

  defp unlink(repo, identity, actor_id) do
    case repo.get_by(GitHubCredential,
           github_identity_id: identity.id,
           local_user_id: actor_id
         ) do
      %GitHubCredential{} = credential ->
        with {:ok, _credential} <- repo.delete(credential) do
          clear_identity_link(repo, identity, actor_id)
        end

      nil ->
        clear_identity_link(repo, identity, actor_id)
    end
  end

  defp clear_identity_link(repo, identity, actor_id) do
    {updated, _} =
      GitHubIdentity
      |> where(
        [saved],
        saved.id == ^identity.id and saved.kind == :user and saved.local_user_id == ^actor_id
      )
      |> repo.update_all(set: [local_user_id: nil, updated_at: DateTime.utc_now(:second)])

    case {updated, repo.get(GitHubIdentity, identity.id)} do
      {1, %GitHubIdentity{local_user_id: nil} = unlinked} -> {:ok, unlinked}
      _ -> {:error, :not_found}
    end
  end

  defp audit(actor, action, identity, credential, request_metadata) do
    status = if credential, do: Atom.to_string(credential.status), else: "absent"

    Audit.record(
      actor,
      action,
      "github_identity",
      identity.id,
      %{
        "github_user_id" => identity.github_user_id,
        "login" => identity.login,
        "status" => status,
        "result" => "success"
      },
      request_metadata: safe_request_metadata(request_metadata)
    )
  end

  defp guard_operation(repo, _actor, request_metadata) do
    with {:ok, safe_metadata} <- GitHubRequestMetadata.validate(request_metadata) do
      case Map.get(safe_metadata, "operation_id") do
        nil ->
          {:ok, nil}

        operation_id
        when is_binary(operation_id) and byte_size(operation_id) in 1..255 ->
          with :ok <- lock_operation(repo, operation_id),
               false <-
                 repo.exists?(
                   from(event in AuditEvent, where: event.operation_id == ^operation_id)
                 ) do
            {:ok, operation_id}
          else
            true -> {:error, :duplicate_operation}
            {:error, reason} -> {:error, reason}
          end

        _invalid ->
          {:error, :invalid_operation_id}
      end
    end
  end

  defp lock_operation(repo, operation_id) do
    if postgres?() do
      case Ecto.Adapters.SQL.query(
             repo,
             "select pg_advisory_xact_lock(hashtextextended($1::text, 0))",
             [operation_id]
           ) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp safe_request_metadata(metadata) do
    case GitHubRequestMetadata.validate(metadata) do
      {:ok, safe} -> safe
      {:error, :invalid_request_metadata} -> %{}
    end
  end

  defp profile_github_user_id(profile) do
    Enum.find_value([:github_user_id, "github_user_id", :id, "id"], fn key ->
      if Map.has_key?(profile, key), do: {:present, Map.fetch!(profile, key)}
    end)
    |> case do
      {:present, value} -> value
      nil -> nil
    end
  end

  defp active_actor(repo, actor, opts \\ [])

  defp active_actor(repo, %User{id: actor_id}, opts) when is_integer(actor_id) do
    query =
      User
      |> where([user], user.id == ^actor_id and user.kind == :user and user.state == :active)
      |> maybe_lock(Keyword.get(opts, :lock?, false))

    case repo.one(query) do
      %User{} = active_actor -> {:ok, active_actor}
      nil -> {:error, :forbidden}
    end
  end

  defp active_actor(_repo, _actor, _opts), do: {:error, :forbidden}

  defp active_github_actor(repo, actor) do
    with {:ok, active_actor} <- active_actor(repo, actor, lock?: true),
         :ok <- lock_turso_actor(repo, active_actor) do
      {:ok, active_actor}
    end
  end

  defp lock_turso_actor(repo, actor) do
    if turso?() do
      case repo.update_all(
             from(user in User, where: user.id == ^actor.id and user.state == :active),
             set: [updated_at: actor.updated_at]
           ) do
        {1, _} -> :ok
        {0, _} -> {:error, :forbidden}
      end
    else
      :ok
    end
  end

  defp github_mutation(actor, request_metadata, opts \\ []) do
    verified_profile = Keyword.get(opts, :verified_profile)
    submitted_credential = Keyword.get(opts, :submitted_credential)

    Multi.new()
    |> Multi.run(:safe_request_metadata, fn _repo, _changes ->
      GitHubRequestMetadata.validate(request_metadata)
    end)
    |> Multi.run(:actor, fn repo, _changes -> active_github_actor(repo, actor) end)
    |> Multi.run(:request_metadata, fn _repo, changes ->
      validate_actor_inputs(
        changes.actor,
        changes.safe_request_metadata,
        verified_profile,
        submitted_credential
      )
    end)
    |> Multi.run(:operation, fn repo, changes ->
      guard_operation(repo, changes.actor, changes.request_metadata)
    end)
  end

  defp validate_actor_inputs(actor, request_metadata, verified_profile, submitted_credential) do
    with :ok <- GitHubCredentialVault.ready?(),
         :ok <- GitHubProfileSafety.validate(verified_profile),
         :ok <- GitHubProfileSafety.validate(verified_profile, submitted_credential) do
      validate_owned_credentials(actor.id, request_metadata, verified_profile)
    end
  end

  defp available_credential(%GitHubCredential{status: :valid}), do: :ok

  defp available_credential(%GitHubCredential{status: :invalid}),
    do: {:error, :credential_invalid}

  defp transact_view(multi) do
    try do
      GitHubIdentityWrite.with_retry(fn -> Repo.transaction(multi) end)
      |> case do
        {:ok, %{view: view}} -> {:ok, view}
        {:error, _step, reason, _changes} -> normalize_transaction_error(reason)
      end
    rescue
      error in [Ecto.ConstraintError, Turso.Error] ->
        if credential_in_use_constraint?(error),
          do: {:error, :credential_in_use},
          else: reraise(error, __STACKTRACE__)
    end
  end

  defp transact_checked(callback) do
    transaction = fn ->
      Repo.transaction(fn ->
        case callback.() do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    case GitHubIdentityWrite.with_retry(transaction) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_transaction_error(%Ecto.Changeset{} = changeset) do
    if credential_in_use_constraint?(changeset),
      do: {:error, :credential_in_use},
      else: {:error, changeset}
  end

  defp normalize_transaction_error(reason), do: {:error, reason}

  defp credential_in_use_constraint?(value) do
    rendered = inspect(value)

    String.contains?(rendered, "github_import_runs_credential_consistency_check") or
      String.contains?(rendered, "github_import_runs_github_credential_id_fkey")
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp turso? do
    Application.get_env(:fornacast, :database_adapter) in ["libsql", "turso"]
  end
end
