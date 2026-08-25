defmodule ForgeAccounts.GitHubAccounts do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi

  alias ForgeAccounts.{
    GitHubAccountView,
    GitHubCredential,
    GitHubCredentialVault,
    GitHubIdentity,
    GitHubIdentityWrite,
    User
  }

  alias Fornacast.{Audit, AuditEvent, Repo}

  @safe_request_metadata_keys ~w(request_id operation_id ip_address user_agent)
  @max_callback_reason_depth 6
  @max_callback_reason_nodes 64
  @max_callback_reason_atom_bytes 120
  @max_callback_stack_depth 12
  @max_callback_stack_nodes 512
  @max_callback_exception_binary_bytes 65_536
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

  @spec save_github_account(User.t(), map(), binary(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, term()}
  def save_github_account(%User{} = actor, verified_profile, pat, request_metadata)
      when is_map(verified_profile) and is_binary(pat) and is_map(request_metadata) do
    verified_at = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.run(:actor, fn repo, _changes -> active_actor(repo, actor, lock?: true) end)
    |> Multi.run(:operation, fn repo, %{actor: active_actor} ->
      guard_operation(repo, active_actor, request_metadata)
    end)
    |> Multi.run(:identity, fn _repo, _changes ->
      ForgeAccounts.observe_github_identity(verified_profile, verified_at)
    end)
    |> Multi.run(:link, fn repo, %{actor: active_actor, identity: identity} ->
      claim_identity(repo, identity.id, active_actor.id)
    end)
    |> Multi.run(:credential, fn repo, %{actor: active_actor, link: link} ->
      save_credential(repo, active_actor, link.identity, pat, verified_at, link.created?)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        changes.credential.action,
        changes.link.identity,
        changes.credential.credential,
        request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{link: link, credential: saved} ->
      {:ok, GitHubAccountView.from(link.identity, saved.credential)}
    end)
    |> transact_view()
  end

  def save_github_account(_actor, _verified_profile, _pat, _request_metadata),
    do: {:error, :forbidden}

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
    verified_at = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.run(:actor, fn repo, _changes -> active_actor(repo, actor, lock?: true) end)
    |> Multi.run(:operation, fn repo, %{actor: active_actor} ->
      guard_operation(repo, active_actor, request_metadata)
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
    |> Multi.run(:credential, fn repo, %{actor: active_actor, identity: identity} ->
      replace_owned_credential(repo, active_actor, identity, pat, verified_at)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.credential.replaced",
        changes.identity,
        changes.credential,
        request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity, credential: credential} ->
      {:ok, GitHubAccountView.from(identity, credential)}
    end)
    |> transact_view()
  end

  def replace_github_credential(
        _actor,
        _identity_id,
        _verified_profile,
        _pat,
        _request_metadata
      ),
      do: {:error, :forbidden}

  @spec refresh_github_account(User.t(), pos_integer(), map(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, term()}
  def refresh_github_account(%User{} = actor, identity_id, verified_profile, request_metadata)
      when is_integer(identity_id) and is_map(verified_profile) and is_map(request_metadata) do
    verified_at = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.run(:actor, fn repo, _changes -> active_actor(repo, actor, lock?: true) end)
    |> Multi.run(:operation, fn repo, %{actor: active_actor} ->
      guard_operation(repo, active_actor, request_metadata)
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
    |> Multi.run(:credential, fn repo, %{actor: active_actor, identity: identity} ->
      refresh_credential(repo, active_actor, identity, verified_at)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.account.reverified",
        changes.identity,
        changes.credential,
        request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity, credential: credential} ->
      {:ok, GitHubAccountView.from(identity, credential)}
    end)
    |> transact_view()
  end

  def refresh_github_account(_actor, _identity_id, _verified_profile, _request_metadata),
    do: {:error, :forbidden}

  @spec delete_github_credential(User.t(), pos_integer(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, term()}
  def delete_github_credential(%User{} = actor, identity_id, request_metadata)
      when is_integer(identity_id) and is_map(request_metadata) do
    Multi.new()
    |> Multi.run(:actor, fn repo, _changes -> active_actor(repo, actor, lock?: true) end)
    |> Multi.run(:operation, fn repo, %{actor: active_actor} ->
      guard_operation(repo, active_actor, request_metadata)
    end)
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      owned_identity(repo, identity_id, active_actor.id)
    end)
    |> Multi.run(:credential, fn repo, %{actor: active_actor, identity: identity} ->
      delete_owned_credential(repo, identity.id, active_actor.id)
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      audit(
        changes.actor,
        "github.credential.deleted",
        changes.identity,
        nil,
        request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{identity: identity} ->
      {:ok, GitHubAccountView.from(identity, nil)}
    end)
    |> transact_view()
  end

  def delete_github_credential(_actor, _identity_id, _request_metadata),
    do: {:error, :forbidden}

  @spec unlink_github_account(User.t(), pos_integer(), map()) ::
          {:ok, GitHubAccountView.t()} | {:error, term()}
  def unlink_github_account(%User{} = actor, identity_id, request_metadata)
      when is_integer(identity_id) and is_map(request_metadata) do
    Multi.new()
    |> Multi.run(:actor, fn repo, _changes -> active_actor(repo, actor, lock?: true) end)
    |> Multi.run(:operation, fn repo, %{actor: active_actor} ->
      guard_operation(repo, active_actor, request_metadata)
    end)
    |> Multi.run(:identity, fn repo, %{actor: active_actor} ->
      owned_identity(repo, identity_id, active_actor.id)
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
        request_metadata
      )
    end)
    |> Multi.run(:view, fn _repo, %{unlink: identity} ->
      {:ok, GitHubAccountView.from(identity, nil)}
    end)
    |> transact_view()
  end

  def unlink_github_account(_actor, _identity_id, _request_metadata),
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

  defp checked_out_result(credential, identity, callback) do
    case GitHubCredentialVault.with_saved_credential(credential, identity, fn pat ->
           callback
           |> invoke_callback(pat)
           |> validate_callback_result(pat)
         end) do
      {:ok, :ok} -> {:ok, :ok}
      {:ok, {:error, _safe_reason} = result} -> {:ok, result}
      {:ok, :unsafe} -> {:error, :unsafe_credential_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke_callback(callback, pat) do
    callback.(pat)
  rescue
    error ->
      stacktrace = __STACKTRACE__

      if credential_in_exception?(error, pat) or
           credential_in_stacktrace?(stacktrace, pat) do
        raise_sanitized_callback_error()
      else
        reraise error, stacktrace
      end
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      if credential_in_term?(reason, pat) != false or
           credential_in_stacktrace?(stacktrace, pat) do
        raise_sanitized_callback_error()
      else
        :erlang.raise(kind, reason, stacktrace)
      end
  end

  defp raise_sanitized_callback_error, do: raise(CredentialCallbackError)

  defp validate_callback_result(:ok, _pat), do: :ok

  defp validate_callback_result({:error, reason} = result, pat) do
    if safe_callback_reason?(reason, pat), do: result, else: :unsafe
  end

  defp validate_callback_result(_result, _pat), do: :unsafe

  defp safe_callback_reason?(reason, pat) when is_atom(reason) do
    safe_reason_atom?(reason, pat)
  end

  defp safe_callback_reason?(reason, pat) when is_tuple(reason) or is_list(reason) do
    match?(
      {:ok, _remaining},
      scan_safe_reason(reason, pat, @max_callback_reason_depth, @max_callback_reason_nodes)
    )
  end

  defp safe_callback_reason?(_reason, _pat), do: false

  defp scan_safe_reason(_term, _pat, _depth, remaining) when remaining <= 0, do: :error
  defp scan_safe_reason(_term, _pat, depth, _remaining) when depth < 0, do: :error

  defp scan_safe_reason(term, pat, _depth, remaining) when is_atom(term) do
    if safe_reason_atom?(term, pat), do: {:ok, remaining - 1}, else: :error
  end

  defp scan_safe_reason(term, _pat, _depth, remaining) when is_integer(term) do
    {:ok, remaining - 1}
  end

  defp scan_safe_reason(term, pat, depth, remaining) when is_tuple(term) and depth > 0 do
    size = tuple_size(term)

    if size + 1 <= remaining do
      scan_safe_reason_tuple(term, pat, depth - 1, remaining - 1, 0, size)
    else
      :error
    end
  end

  defp scan_safe_reason(term, pat, depth, remaining) when is_list(term) and depth > 0 do
    with {:ok, next_remaining} <-
           scan_safe_reason_list(term, pat, depth - 1, remaining - 1),
         false <- credential_charlist?(term, pat) do
      {:ok, next_remaining}
    else
      _ -> :error
    end
  end

  defp scan_safe_reason(_term, _pat, _depth, _remaining), do: :error

  defp scan_safe_reason_list([], _pat, _depth, remaining), do: {:ok, remaining}

  defp scan_safe_reason_list([head | tail], pat, depth, remaining) do
    with {:ok, after_head} <- scan_safe_reason(head, pat, depth, remaining) do
      scan_safe_reason_list(tail, pat, depth, after_head)
    end
  end

  defp scan_safe_reason_list(_improper_tail, _pat, _depth, _remaining), do: :error

  defp scan_safe_reason_tuple(_tuple, _pat, _depth, remaining, size, size),
    do: {:ok, remaining}

  defp scan_safe_reason_tuple(tuple, pat, depth, remaining, index, size) do
    with {:ok, next_remaining} <-
           scan_safe_reason(elem(tuple, index), pat, depth, remaining) do
      scan_safe_reason_tuple(tuple, pat, depth, next_remaining, index + 1, size)
    end
  end

  defp safe_reason_atom?(atom, pat) do
    value = Atom.to_string(atom)

    byte_size(value) <= @max_callback_reason_atom_bytes and
      :binary.match(value, pat) == :nomatch
  end

  defp credential_charlist?(list, pat) do
    case IO.iodata_to_binary(list) do
      binary -> :binary.match(binary, pat) != :nomatch
    end
  rescue
    ArgumentError -> false
  end

  defp credential_in_exception?(error, pat) do
    message_status =
      try do
        credential_in_binary?(Exception.message(error), pat)
      rescue
        _error -> :unknown
      end

    message_status != false or credential_in_term?(error, pat) != false
  end

  defp credential_in_stacktrace?(stacktrace, pat) do
    credential_in_term?(
      stacktrace,
      pat,
      @max_callback_stack_depth,
      @max_callback_stack_nodes
    ) != false
  end

  defp credential_in_term?(
         term,
         pat,
         depth \\ @max_callback_reason_depth,
         nodes \\ @max_callback_reason_nodes
       ) do
    case scan_exception_term(term, pat, depth, nodes) do
      {:found, _remaining} -> true
      {:clear, _remaining} -> false
      :unknown -> :unknown
    end
  end

  defp scan_exception_term(_term, _pat, _depth, remaining) when remaining <= 0,
    do: :unknown

  defp scan_exception_term(_term, _pat, depth, _remaining) when depth < 0,
    do: :unknown

  defp scan_exception_term(term, pat, _depth, remaining) when is_binary(term) do
    case credential_in_binary?(term, pat) do
      true -> {:found, remaining - 1}
      false -> {:clear, remaining - 1}
      :unknown -> :unknown
    end
  end

  defp scan_exception_term(term, pat, _depth, remaining) when is_atom(term) do
    status = if :binary.match(Atom.to_string(term), pat) == :nomatch, do: :clear, else: :found
    {status, remaining - 1}
  end

  defp scan_exception_term(term, _pat, _depth, remaining)
       when is_integer(term) or is_float(term) do
    {:clear, remaining - 1}
  end

  defp scan_exception_term(term, pat, depth, remaining) when is_list(term) and depth > 0 do
    with {:clear, next_remaining} <-
           scan_exception_list(term, pat, depth - 1, remaining - 1) do
      if credential_charlist?(term, pat),
        do: {:found, next_remaining},
        else: {:clear, next_remaining}
    end
  end

  defp scan_exception_term(term, pat, depth, remaining) when is_tuple(term) and depth > 0 do
    size = tuple_size(term)

    if size + 1 <= remaining do
      scan_exception_tuple(term, pat, depth - 1, remaining - 1, 0, size)
    else
      :unknown
    end
  end

  defp scan_exception_term(term, pat, depth, remaining) when is_map(term) and depth > 0 do
    if map_size(term) * 2 + 1 <= remaining do
      term
      |> Map.to_list()
      |> Enum.reduce_while({:clear, remaining - 1}, fn {key, value}, {:clear, budget} ->
        with {:clear, after_key} <- scan_exception_term(key, pat, depth - 1, budget),
             {:clear, after_value} <-
               scan_exception_term(value, pat, depth - 1, after_key) do
          {:cont, {:clear, after_value}}
        else
          {:found, next_budget} -> {:halt, {:found, next_budget}}
          :unknown -> {:halt, :unknown}
        end
      end)
    else
      :unknown
    end
  end

  defp scan_exception_term(_term, _pat, _depth, _remaining), do: :unknown

  defp scan_exception_list([], _pat, _depth, remaining), do: {:clear, remaining}

  defp scan_exception_list([head | tail], pat, depth, remaining) do
    with {:clear, after_head} <- scan_exception_term(head, pat, depth, remaining) do
      scan_exception_list(tail, pat, depth, after_head)
    end
  end

  defp scan_exception_list(_tail, _pat, _depth, _remaining), do: :unknown

  defp scan_exception_tuple(_tuple, _pat, _depth, remaining, size, size),
    do: {:clear, remaining}

  defp scan_exception_tuple(tuple, pat, depth, remaining, index, size) do
    with {:clear, next_remaining} <-
           scan_exception_term(elem(tuple, index), pat, depth, remaining) do
      scan_exception_tuple(tuple, pat, depth, next_remaining, index + 1, size)
    end
  end

  defp credential_in_binary?(binary, _pat)
       when byte_size(binary) > @max_callback_exception_binary_bytes,
       do: :unknown

  defp credential_in_binary?(binary, pat),
    do: :binary.match(binary, pat) != :nomatch

  defp save_credential(repo, actor, identity, pat, verified_at, link_created?) do
    case repo.get_by(GitHubCredential,
           github_identity_id: identity.id,
           local_user_id: actor.id
         ) do
      nil ->
        with {:ok, credential} <- insert_placeholder(repo, actor, identity, verified_at),
             {:ok, encrypted} <- encrypt_credential(credential, identity, pat),
             {:ok, saved} <- persist_envelope(repo, credential, encrypted, verified_at) do
          {:ok,
           %{
             credential: saved,
             action: credential_action(link_created?)
           }}
        end

      %GitHubCredential{} = credential ->
        with {:ok, saved} <- rotate_credential(repo, credential, identity, pat, verified_at) do
          {:ok, %{credential: saved, action: "github.credential.replaced"}}
        end
    end
  end

  defp credential_action(true), do: "github.account.linked"
  defp credential_action(false), do: "github.credential.replaced"

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

  defp replace_owned_credential(repo, actor, identity, pat, verified_at) do
    case repo.get_by(GitHubCredential,
           github_identity_id: identity.id,
           local_user_id: actor.id
         ) do
      %GitHubCredential{} = credential ->
        rotate_credential(repo, credential, identity, pat, verified_at)

      nil ->
        {:error, :not_found}
    end
  end

  defp rotate_credential(repo, credential, identity, pat, verified_at) do
    with {:ok, encrypted} <- encrypt_credential(credential, identity, pat) do
      persist_envelope(repo, credential, encrypted, verified_at)
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

  defp refresh_credential(repo, actor, identity, verified_at) do
    case repo.get_by(GitHubCredential,
           github_identity_id: identity.id,
           local_user_id: actor.id
         ) do
      %GitHubCredential{} = credential ->
        credential
        |> GitHubCredential.changeset(%{status: :valid, last_verified_at: verified_at})
        |> repo.update()

      nil ->
        {:error, :not_found}
    end
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

  defp delete_owned_credential(repo, identity_id, actor_id) do
    case repo.get_by(GitHubCredential,
           github_identity_id: identity_id,
           local_user_id: actor_id
         ) do
      %GitHubCredential{} = credential -> repo.delete(credential)
      nil -> {:error, :not_found}
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
    case request_metadata_value(request_metadata, "operation_id") do
      nil ->
        {:ok, nil}

      operation_id
      when is_binary(operation_id) and byte_size(operation_id) in 1..255 ->
        with :ok <- lock_operation(repo, operation_id),
             false <-
               repo.exists?(from(event in AuditEvent, where: event.operation_id == ^operation_id)) do
          {:ok, operation_id}
        else
          true -> {:error, :duplicate_operation}
          {:error, reason} -> {:error, reason}
        end

      _invalid ->
        {:error, :invalid_operation_id}
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
    Enum.reduce(@safe_request_metadata_keys, %{}, fn key, safe ->
      atom_key = String.to_existing_atom(key)

      cond do
        Map.has_key?(metadata, key) -> Map.put(safe, key, Map.fetch!(metadata, key))
        Map.has_key?(metadata, atom_key) -> Map.put(safe, key, Map.fetch!(metadata, atom_key))
        true -> safe
      end
    end)
  end

  defp request_metadata_value(metadata, key) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(metadata, key) -> Map.fetch!(metadata, key)
      Map.has_key?(metadata, atom_key) -> Map.fetch!(metadata, atom_key)
      true -> nil
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

  defp available_credential(%GitHubCredential{status: :valid}), do: :ok

  defp available_credential(%GitHubCredential{status: :invalid}),
    do: {:error, :credential_invalid}

  defp transact_view(multi) do
    GitHubIdentityWrite.with_retry(fn -> Repo.transaction(multi) end)
    |> case do
      {:ok, %{view: view}} -> {:ok, view}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp turso? do
    Application.get_env(:fornacast, :database_adapter) in ["libsql", "turso"]
  end
end
