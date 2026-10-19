defmodule FornacastAPI.GitDataController do
  use FornacastAPI, :controller
  plug :fetch_query_params
  alias ForgeRepos.{GitData, GitWrites}

  alias FornacastAPI.{
    Authentication,
    ContentsAdmission,
    Error,
    PathValue,
    RequestBody,
    RequestValidator,
    Response,
    Serializer,
    URL
  }

  alias FornacastAPI.Plugs.RequestContext
  @documentation "https://docs.github.com/en/enterprise-server@3.21/rest/repos/contents"

  def branches(conn, params),
    do:
      read(conn, params, :branch_short, fn actor, key, owner, repo, metadata ->
        GitData.list_branches(actor, key, owner, repo, conn.query_params, metadata)
      end)

  def branch(conn, params),
    do:
      read_path(conn, params, :branch, "Branch", "branch", 6, fn actor,
                                                                 key,
                                                                 owner,
                                                                 repo,
                                                                 value,
                                                                 metadata ->
        GitData.get_branch(actor, key, owner, repo, value, metadata)
      end)

  def ref(conn, params),
    do:
      read_path(conn, params, :git_ref, "Reference", "ref", 7, fn actor,
                                                                  key,
                                                                  owner,
                                                                  repo,
                                                                  value,
                                                                  metadata ->
        GitData.get_ref(actor, key, owner, repo, value, metadata)
      end)

  def commits(conn, params),
    do:
      read(conn, params, :commit_summary, fn actor, key, owner, repo, metadata ->
        GitData.list_commits(actor, key, owner, repo, conn.query_params, metadata)
      end)

  def commit(conn, params),
    do:
      read_path(conn, params, :commit_detail, "Commit", "ref", 6, fn actor,
                                                                     key,
                                                                     owner,
                                                                     repo,
                                                                     value,
                                                                     metadata ->
        GitData.get_commit(actor, key, owner, repo, value, metadata)
      end)

  def content(conn, params) do
    read_path(conn, params, :content_file, "Content", "path", 6, fn actor,
                                                                    key,
                                                                    owner,
                                                                    repo,
                                                                    value,
                                                                    metadata ->
      GitData.get_content(actor, key, owner, repo, value, conn.query_params, metadata)
    end)
  end

  def create_ref(conn, params),
    do: mutate(conn, params, :git_create_ref, nil, &GitWrites.create_ref/5)

  def update_ref(conn, params),
    do: mutate(conn, params, :git_update_ref, {"Reference", "ref", 7}, &GitWrites.update_ref/6)

  def put_content(conn, params),
    do: mutate(conn, params, :content_put, {"Content", "path", 6}, &GitWrites.put_content/6)

  def delete_content(conn, params),
    do: mutate(conn, params, :content_delete, {"Content", "path", 6}, &GitWrites.delete_content/6)

  defp read_path(conn, params, resource, kind, field, offset, operation) do
    read(conn, params, resource, fn actor, key, owner, repo, metadata ->
      with {:ok, value} <- PathValue.decode(Enum.drop(conn.path_info, offset), kind, field),
           do: operation.(actor, key, owner, repo, value, metadata)
    end)
  end

  defp read(conn, %{"owner" => owner, "repo" => repo}, resource, operation) do
    conn = fetch_query_params(conn)
    {actor, key} = identity(conn)
    metadata = RequestContext.metadata(conn)

    with {:ok, repository} <- GitData.authorize_read_target(actor, key, owner, repo, metadata) do
      conn =
        assign(
          conn,
          :accepted_scopes,
          ForgeAccounts.APIScope.accepted_scopes(:repository_read, repository.visibility)
        )

      case operation.(actor, key, owner, repo, metadata) do
        {:ok, %Fornacast.Page{} = page} ->
          body = Enum.map(page.entries, &serialize(conn, resource, &1, owner, repo))

          url =
            URL.repository(owner, repo) <>
              "/" <> if(resource == :branch_short, do: "branches", else: "commits")

          url = if conn.query_string == "", do: url, else: url <> "?" <> conn.query_string
          Response.paginated(conn, 200, body, page, url: url)

        {:ok, value} ->
          render_read(conn, resource, value, owner, repo, repository.default_branch)

        {:error, reason} ->
          error(conn, reason)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp render_read(conn, :content_file, value, owner, repo, default_branch) do
    try do
      opts = [owner: owner, repo: repo, ref: conn.query_params["ref"] || default_branch]
      media = content_media(conn)

      cond do
        is_list(value) and media in [:raw, :html] ->
          Response.error(conn, Error.new(406, "Not Acceptable", @documentation))

        is_list(value) ->
          entries =
            Enum.map(
              value,
              &Serializer.render(conn.assigns.api_version, :content_entry, &1, opts)
            )

          Response.json(
            conn,
            200,
            if(media == :object, do: %{type: "dir", entries: entries}, else: entries)
          )

        media in [:raw, :html] ->
          bytes = value.content || ""

          body =
            if media == :html,
              do:
                "<pre>" <>
                  (bytes |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()) <>
                  "</pre>",
              else: bytes

          conn
          |> put_resp_content_type(
            if(media == :raw,
              do: "application/vnd.github.raw+json",
              else: "application/vnd.github.html+json"
            )
          )
          |> send_resp(200, body)

        true ->
          Response.json(
            conn,
            200,
            Serializer.render(conn.assigns.api_version, :content_file, value, opts)
          )
      end
    after
      GitCore.GitData.release_content(value)
    end
  end

  defp render_read(conn, resource, value, owner, repo, _),
    do: Response.json(conn, 200, serialize(conn, resource, value, owner, repo))

  defp mutate(conn, %{"owner" => owner, "repo" => repo}, operation, path_spec, callback) do
    with %Authentication{actor: actor, api_key: key} <- conn.assigns[:api_auth],
         {:ok, repository} <-
           GitData.authorize_mutation_target(
             actor,
             key,
             owner,
             repo,
             RequestContext.metadata(conn)
           ),
         {:ok, value} <- decode_path(conn, path_spec) do
      conn =
        assign(
          conn,
          :accepted_scopes,
          ForgeAccounts.APIScope.accepted_scopes(:repository_mutation, repository.visibility)
        )

      policy = if operation in [:content_put, :content_delete], do: :contents, else: :ordinary

      opts =
        if policy == :contents,
          do: [admission: {ContentsAdmission, :admit, [repository]}],
          else: []

      case RequestBody.read_json(conn, policy, opts) do
        {:ok, body, conn} ->
          try do
            with {:ok, attrs} <-
                   RequestValidator.validate(conn.assigns.api_version, operation, body),
                 {:ok, attrs} <- decode_content(operation, attrs) do
              args = [actor, key, repository] ++ if(is_nil(path_spec), do: [], else: [value])
              args = args ++ [attrs, RequestContext.metadata(conn)]

              apply(callback, args)
              |> mutation_response(conn, operation, owner, repo, attrs, repository.default_branch)
            else
              {:error, reason} -> error(conn, reason)
            end
          after
            if lease = conn.assigns[:contents_reservation], do: ContentsAdmission.release(lease)
          end

        {:error, %Error{} = error, _, conn} ->
          Response.error(conn, error)
      end
    else
      nil -> error(conn, :requires_authentication)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp mutation_response({:ok, reference}, conn, operation, owner, repo, _, _) do
    Response.json(
      conn,
      if(operation == :git_create_ref, do: 201, else: 200),
      serialize(conn, :git_ref, reference, owner, repo)
    )
  end

  defp mutation_response(
         {:ok, status, content, commit},
         conn,
         _,
         owner,
         repo,
         attrs,
         default_branch
       ) do
    opts = [owner: owner, repo: repo, ref: attrs["branch"] || default_branch]

    Response.json(conn, if(status == :created, do: 201, else: 200), %{
      content:
        if(content,
          do: Serializer.render(conn.assigns.api_version, :content_entry, content, opts),
          else: nil
        ),
      commit: Serializer.render(conn.assigns.api_version, :content_commit, commit, opts)
    })
  end

  defp mutation_response({:error, reason}, conn, _, _, _, _, _), do: error(conn, reason)
  defp decode_path(_, nil), do: {:ok, nil}

  defp decode_path(conn, {resource, field, offset}),
    do: PathValue.decode(Enum.drop(conn.path_info, offset), resource, field)

  defp decode_content(:content_put, attrs) do
    case Base.decode64(attrs["content"], padding: true) do
      {:ok, bytes} when byte_size(bytes) <= 104_857_600 ->
        cond do
          not canonical_padding?(attrs["content"]) ->
            GitData.invalid("Content", "content")

          byte_size(bytes) > GitCore.Limits.get(:blob_bytes) ->
            {:error, {:payload_too_large, :contents}}

          true ->
            {:ok, attrs |> Map.delete("content") |> Map.put("decoded_content", bytes)}
        end

      {:ok, _} ->
        {:error, {:payload_too_large, :contents}}

      :error ->
        GitData.invalid("Content", "content")
    end
  end

  defp decode_content(_, attrs), do: {:ok, attrs}

  # Decoding accepts nonzero unused padding bits. Check those bits without
  # allocating another full encoded body alongside the admitted JSON and blob.
  defp canonical_padding?(encoded) do
    cond do
      String.ends_with?(encoded, "==") -> padding_bits_zero?(encoded, 3, 15)
      String.ends_with?(encoded, "=") -> padding_bits_zero?(encoded, 2, 3)
      true -> true
    end
  end

  defp padding_bits_zero?(encoded, offset, mask) do
    character = :binary.at(encoded, byte_size(encoded) - offset)

    case :binary.match(
           "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
           <<character>>
         ) do
      {value, 1} -> Bitwise.band(value, mask) == 0
      :nomatch -> false
    end
  end

  defp identity(conn) do
    case conn.assigns[:api_auth] do
      %Authentication{actor: actor, api_key: key} -> {actor, key}
      nil -> {nil, nil}
    end
  end

  defp serialize(conn, resource, value, owner, repo),
    do: Serializer.render(conn.assigns.api_version, resource, value, owner: owner, repo: repo)

  defp error(conn, reason), do: Response.error(conn, Error.from_domain(reason, @documentation))
  defp content_media(conn), do: FornacastAPI.Plugs.MediaType.contents_media(conn)
end
