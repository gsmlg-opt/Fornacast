defmodule ForgeGitHub.RelationshipClient do
  @moduledoc "Fresh names for previously authenticated numeric-ID/node-ID relationships."

  alias ForgeGitHub.{Client, Error}

  @query """
  query($labels: [ID!]!, $assignees: [ID!]!) {
    labels: nodes(ids: $labels) {
      __typename id
      ... on Label { name repository { id } }
    }
    assignees: nodes(ids: $assignees) {
      __typename id
      ... on User { login }
      ... on Bot { login }
    }
  }
  """
  @test_options if(Mix.env() == :test,
                  do: [:plug, :resolver, :now, :transport_api, :request_timeout],
                  else: []
                )

  @doc """
  Resolves exact node identities, never names supplied by a previous observation.

  Inputs must come from authenticated numeric-ID/node-ID mappings. GitHub's Label
  node does not expose its numeric REST ID, so this function cannot establish that
  association. The two 512-entry limits are local budgets, not live-service proof.
  """
  def resolve(token, repository, labels, assignees, opts) do
    with true <- identity?(repository, :github_object_id),
         true <- identities?(labels, :github_object_id),
         true <- identities?(assignees, :github_user_id),
         true <- disjoint?(labels, assignees),
         true <- options?(opts),
         true <- text?(token, 16_384) and token != "",
         true <- safe_nodes?([repository | labels ++ assignees], token),
         :ok <- deadline(opts) do
      if labels == [] and assignees == [] do
        {:ok, %{labels: [], assignees: []}}
      else
        payload = %{
          "query" => @query,
          "variables" => %{
            "labels" => Enum.map(labels, & &1.github_node_id),
            "assignees" => Enum.map(assignees, & &1.github_node_id)
          }
        }

        with {:ok, response} <- Client.pull_graphql_request(token, payload, opts),
             :ok <- deadline(opts) do
          with {:ok, result} <- decode(response, repository, labels, assignees) do
            if safe_names?(result, token), do: {:ok, result}, else: error(:invalid_response)
          end
        end
      end
    else
      {:error, %Error{}} = error -> error
      _ -> error(:invalid_request)
    end
  end

  defp decode(
         %{"data" => %{"labels" => labels, "assignees" => users}} = response,
         repo,
         expected_labels,
         expected_users
       ) do
    with false <- Map.has_key?(response, "errors"),
         {:ok, labels} <- nodes(labels, expected_labels, :github_object_id, repo),
         {:ok, users} <- nodes(users, expected_users, :github_user_id, repo) do
      {:ok, %{labels: labels, assignees: users}}
    else
      _ -> error(:invalid_response)
    end
  end

  defp decode(_, _, _, _), do: error(:invalid_response)

  defp nodes(nodes, expected, key, repo)
       when is_list(nodes) and length(nodes) == length(expected) do
    catalog = Map.new(expected, &{&1.github_node_id, &1})

    Enum.reduce_while(nodes, {:ok, %{}}, fn node, {:ok, found} ->
      id = if is_map(node), do: node["id"]

      with %{^key => numeric_id} <- catalog[id],
           false <- Map.has_key?(found, id),
           {:ok, field, value} <- node_value(node, key, repo) do
        value = %{key => numeric_id, :github_node_id => id, field => value}
        {:cont, {:ok, Map.put(found, id, value)}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, found |> Map.values() |> Enum.sort_by(&Map.fetch!(&1, key))}
      _ -> :error
    end
  end

  defp nodes(_, _, _, _), do: :error

  defp node_value(
         %{"__typename" => "Label", "name" => name, "repository" => %{"id" => repo_node}},
         :github_object_id,
         repo
       ) do
    if repo_node == repo.github_node_id and text?(name, 1020) and name != "" and
         length(String.codepoints(name)) <= 255, do: {:ok, :name, name}, else: :error
  end

  defp node_value(%{"__typename" => type, "login" => login}, :github_user_id, _)
       when type in ["User", "Bot"] do
    if text?(login, 420) and
         Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?(?:\[bot\])?\z/, login),
       do: {:ok, :login, login},
       else: :error
  end

  defp node_value(_, _, _), do: :error

  defp identities?(values, key) when is_list(values) and length(values) <= 512 do
    Enum.all?(values, &identity?(&1, key)) and
      length(Enum.uniq_by(values, &Map.fetch!(&1, key))) == length(values) and
      length(Enum.uniq_by(values, & &1.github_node_id)) == length(values)
  end

  defp identities?(_, _), do: false

  defp identity?(value, key) when is_map(value) and map_size(value) == 2 do
    id = Map.get(value, key)
    node = Map.get(value, :github_node_id)

    is_integer(id) and id in 1..9_223_372_036_854_775_807 and
      text?(node, 512) and node != "" and String.trim(node) == node
  end

  defp identity?(_, _), do: false

  defp disjoint?(labels, users) do
    MapSet.disjoint?(
      MapSet.new(labels, & &1.github_node_id),
      MapSet.new(users, & &1.github_node_id)
    )
  end

  defp safe_nodes?(identities, token) do
    Enum.all?(identities, fn identity ->
      ForgeAccounts.GitHubProfileSafety.validate(
        %{github_node_id: identity.github_node_id},
        token
      ) == :ok
    end)
  end

  defp safe_names?(result, token) do
    values = Enum.map(result.labels, & &1.name) ++ Enum.map(result.assignees, & &1.login)

    # Field lengths are already checked above. The larger description text slot
    # reuses credential checks without imposing the profile name's 255-byte cap
    # on a valid 255-codepoint label. Nothing is persisted as a description.
    Enum.all?(values, fn value ->
      ForgeAccounts.GitHubProfileSafety.validate(%{description: value}, token) == :ok
    end)
  end

  defp options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and
      length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
      Keyword.keys(opts) -- [:gate_key, :deadline_monotonic_ms | @test_options] == [] and
      match?(
        {:github_installation, id} when is_integer(id) and id > 0,
        Keyword.get(opts, :gate_key)
      )
  end

  defp options?(_), do: false

  defp deadline(opts) do
    case Keyword.fetch(opts, :deadline_monotonic_ms) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) ->
        if value > System.monotonic_time(:millisecond), do: :ok, else: error(:timeout)

      _ ->
        error(:invalid_request)
    end
  end

  defp text?(value, bytes) when is_binary(value) and byte_size(value) <= bytes,
    do: String.valid?(value) and :binary.match(value, <<0>>) == :nomatch

  defp text?(_, _), do: false
  defp error(kind), do: {:error, Error.new(kind)}
end
