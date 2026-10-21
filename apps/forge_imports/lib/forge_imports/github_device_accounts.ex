defmodule ForgeImports.GitHubDeviceAccounts do
  @moduledoc false

  alias ForgeAccounts.{GitHubCredentialCallback, GitHubDeviceToken, GitHubProfileSafety, User}
  alias ForgeGitHub.{Client, Error}
  alias ForgeGitHub.DeviceFlow.Token
  alias ForgeGitHub.User, as: GitHubUser

  @client_errors [
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

  defmodule CredentialVerificationError do
    @moduledoc false
    defexception message: "GitHub Device Flow credential verification failed"
  end

  def link(%User{} = actor, %Token{} = value, metadata, original_references, opts)
      when is_map(metadata) and is_list(original_references) and is_list(opts) do
    with {:ok, token} <- GitHubDeviceToken.normalize(value),
         {:ok, metadata} <-
           ForgeAccounts.validate_github_request_metadata(metadata, token.access_token),
         {:ok, metadata} <-
           ForgeAccounts.validate_github_request_metadata(metadata, token.refresh_token),
         {:ok, checked} <- ForgeAccounts.validate_github_link_request(actor, metadata),
         {:ok, client, client_opts, before_save} <- client_options(opts, actor),
         {:ok, profile} <- authenticated_profile(client, client_opts, token),
         :ok <- safe_callback(before_save, token) do
      # Only the authorization-start snapshot can authorize replacement. The
      # current account validation above provides metadata/actor checks alone.
      ForgeAccounts.save_github_device_account(
        actor,
        profile,
        value,
        checked.request_metadata,
        original_references
      )
    end
  end

  def link(_actor, _token, _metadata, _original_references, _opts),
    do: {:error, :forbidden}

  defp client_options(opts, actor) do
    if Keyword.keyword?(opts) and length(Keyword.get_values(opts, :client)) <= 1 and
         length(Keyword.get_values(opts, :before_save)) <= 1 do
      {client, opts} = Keyword.pop(opts, :client, Client)
      {before_save, opts} = Keyword.pop(opts, :before_save, fn -> :ok end)

      if is_atom(client) and Code.ensure_loaded?(client) and
           function_exported?(client, :authenticated_user, 2) and is_function(before_save, 0) do
        {:ok, client, Keyword.put(opts, :gate_key, {:account_setup, actor.id}), before_save}
      else
        {:error, :invalid_response}
      end
    else
      {:error, :invalid_response}
    end
  end

  defp authenticated_profile(client, opts, token) do
    parent = self()
    reference = make_ref()

    case safe_callback(
           fn ->
             result = client.authenticated_user(token.access_token, opts) |> profile_result(token)
             send(parent, {reference, result})
             :ok
           end,
           token
         ) do
      :ok ->
        receive do
          {^reference, result} -> result
        after
          0 -> {:error, :invalid_response}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp profile_result({:ok, %GitHubUser{} = user}, token) do
    with :ok <- GitHubProfileSafety.validate(user, token.access_token),
         :ok <- GitHubProfileSafety.validate(user, token.refresh_token),
         {:ok, validated} <-
           GitHubUser.from_json(%{
             "id" => user.id,
             "node_id" => user.node_id,
             "login" => user.login,
             "name" => user.name,
             "avatar_url" => user.avatar_url,
             "html_url" => user.html_url
           }) do
      {:ok,
       %{
         github_user_id: validated.id,
         login: validated.login,
         name: validated.name,
         avatar_url: validated.avatar_url,
         profile_url: validated.html_url
       }}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp profile_result({:error, %Error{kind: kind}}, _token) when kind in @client_errors,
    do: {:error, kind}

  defp profile_result(_result, _token), do: {:error, :invalid_response}

  defp safe_callback(callback, token) do
    result =
      GitHubCredentialCallback.invoke(
        fn _access ->
          GitHubCredentialCallback.invoke(
            fn _refresh -> callback.() end,
            token.refresh_token,
            CredentialVerificationError
          )
        end,
        token.access_token,
        CredentialVerificationError
      )

    case result do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _unsafe -> {:error, :invalid_response}
    end
  end
end
