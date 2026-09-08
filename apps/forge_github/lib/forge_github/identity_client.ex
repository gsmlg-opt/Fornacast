defmodule ForgeGitHub.IdentityClient do
  @moduledoc "Authenticated lookup of a user by immutable numeric ID, including its opaque node ID."
  alias ForgeGitHub.{Client, Error, User}

  def get_user(token, id, opts) when is_integer(id) and id in 1..9_223_372_036_854_775_807 do
    if installation_options?(opts) do
      with {:ok, raw} <- Client.request(token, :get, "/user/#{id}", opts),
           {:ok, %User{id: ^id, node_id: node} = user} when is_binary(node) <- User.from_json(raw),
           :ok <- ForgeAccounts.GitHubProfileSafety.validate(user, token) do
        {:ok, user}
      else
        {:error, %Error{}} = error -> error
        _ -> {:error, Error.new(:invalid_response)}
      end
    else
      {:error, Error.new(:invalid_request)}
    end
  end

  def get_user(_, _, _), do: {:error, Error.new(:invalid_request)}

  defp installation_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and not Keyword.has_key?(opts, :json) and
      length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
      match?(
        {:github_installation, id} when is_integer(id) and id in 1..9_223_372_036_854_775_807,
        Keyword.get(opts, :gate_key)
      )
  end

  defp installation_options?(_), do: false
end
