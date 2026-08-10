defmodule FornacastWeb.IssueController do
  use FornacastWeb, :controller

  alias FornacastWeb.{
    IssueHTML,
    RepositoryCollaborationPage,
    RepositoryHTML,
    RepositoryPage,
    RepositoryWeb,
    RequestMetadata
  }

  @authenticated_actions [
    :new,
    :edit,
    :create,
    :update,
    :comment,
    :update_comment,
    :delete_comment,
    :state
  ]

  plug :redirect_unauthenticated_with_return when action in @authenticated_actions
  plug FornacastWeb.Plugs.RequireUser when action in @authenticated_actions

  @filter_keys ~w(page state labels assignee creator sort direction)
  @route_keys ~w(owner repo)

  def index(conn, %{"owner" => owner_slug, "repo" => repository_slug} = params) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository),
         {:ok, page} <- positive_integer(Map.get(params, "page", "1")),
         {:ok, filters} <- issue_filters(params, page),
         {:ok, result} <-
           collaboration_page(conn).issues(
             context.repository,
             context.owner,
             context.viewer,
             filters,
             []
           ) do
      RepositoryWeb.render(conn, result, html_module(conn), :index)
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def show(
        conn,
        %{"owner" => owner_slug, "repo" => repository_slug, "number" => number}
      ) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository),
         {:ok, number} <- positive_integer(number),
         {:ok, result} <-
           collaboration_page(conn).issue(
             context.repository,
             context.owner,
             context.viewer,
             number,
             []
           ) do
      case result.content.issue.kind do
        :pull_request -> private_redirect(conn, RepositoryHTML.pull_path(result.chrome, number))
        :issue -> RepositoryWeb.render(conn, result, html_module(conn), :show)
      end
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def new(conn, %{"owner" => owner_slug, "repo" => repository_slug}) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository) do
      render_new(conn, context, %{}, [])
    else
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def create(conn, %{"owner" => owner_slug, "repo" => repository_slug} = params) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository),
         {:ok, attrs} <- issue_attrs(params),
         {:ok, issue} <-
           issues(conn).create(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      redirect_to_issue(conn, context, issue)
    else
      {:error, {:validation, errors}} ->
        with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
             {:ok, attrs} <- issue_attrs(params) do
          render_new(conn, context, attrs, errors, :unprocessable_entity)
        else
          {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
        end

      {:error, reason} ->
        RepositoryWeb.error(conn, nil, reason)
    end
  end

  def edit(conn, %{"owner" => owner_slug, "repo" => repository_slug, "number" => number}) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository),
         {:ok, number} <- positive_integer(number),
         {:ok, result} <-
           collaboration_page(conn).issue(
             context.repository,
             context.owner,
             context.viewer,
             number,
             []
           ) do
      case result.content.issue.kind do
        :pull_request -> private_redirect(conn, RepositoryHTML.pull_path(result.chrome, number))
        :issue -> render_edit(conn, context, result, issue_values(result.content.issue), [])
      end
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def update(
        conn,
        %{"owner" => owner_slug, "repo" => repository_slug, "number" => number} = params
      ) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository),
         {:ok, number} <- positive_integer(number),
         {:ok, attrs} <- issue_attrs(params),
         {:ok, issue} <-
           issues(conn).update(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             number,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      redirect_to_issue(conn, context, issue)
    else
      {:error, {:validation, errors}} ->
        render_edit_error(conn, owner_slug, repository_slug, number, params, errors)

      {:error, :invalid_integer} ->
        RepositoryWeb.error(conn, nil, :not_found)

      {:error, reason} ->
        RepositoryWeb.error(conn, nil, reason)
    end
  end

  def state(
        conn,
        %{"owner" => owner_slug, "repo" => repository_slug, "number" => number} = params
      ) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository),
         {:ok, number} <- positive_integer(number),
         {:ok, attrs} <- state_attrs(params),
         {:ok, issue} <-
           issues(conn).update(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             number,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      redirect_to_issue(conn, context, issue)
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def comment(
        conn,
        %{"owner" => owner_slug, "repo" => repository_slug, "number" => number} = params
      ) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository),
         {:ok, number} <- positive_integer(number),
         {:ok, issue} <-
           issues(conn).get(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             number
           ),
         {:ok, attrs} <- comment_attrs(params),
         {:ok, _comment} <-
           issues(conn).create_comment(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             number,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      redirect_to_issue(conn, context, issue)
    else
      {:error, {:validation, errors}} ->
        render_comment_error(conn, owner_slug, repository_slug, number, :create, params, errors)

      {:error, :invalid_integer} ->
        RepositoryWeb.error(conn, nil, :not_found)

      {:error, reason} ->
        RepositoryWeb.error(conn, nil, reason)
    end
  end

  def update_comment(
        conn,
        %{"owner" => owner_slug, "repo" => repository_slug, "number" => number, "id" => id} =
          params
      ) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository),
         {:ok, number} <- positive_integer(number),
         {:ok, id} <- positive_integer(id),
         {:ok, comment} <-
           issues(conn).get_comment(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             id
           ),
         :ok <- comment_parent(comment, number),
         {:ok, issue} <-
           issues(conn).get(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             number
           ),
         {:ok, attrs} <- comment_attrs(params),
         {:ok, _comment} <-
           issues(conn).update_comment(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             id,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      redirect_to_issue(conn, context, issue)
    else
      {:error, {:validation, errors}} ->
        render_comment_error(
          conn,
          owner_slug,
          repository_slug,
          number,
          {:edit, to_string(id)},
          params,
          errors
        )

      {:error, :invalid_integer} ->
        RepositoryWeb.error(conn, nil, :not_found)

      {:error, reason} ->
        RepositoryWeb.error(conn, nil, reason)
    end
  end

  def delete_comment(
        conn,
        %{"owner" => owner_slug, "repo" => repository_slug, "number" => number, "id" => id}
      ) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         :ok <- issues_enabled(context.repository),
         {:ok, number} <- positive_integer(number),
         {:ok, id} <- positive_integer(id),
         {:ok, comment} <-
           issues(conn).get_comment(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             id
           ),
         :ok <- comment_parent(comment, number),
         {:ok, issue} <-
           issues(conn).get(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             number
           ),
         :ok <-
           issues(conn).delete_comment(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             id,
             RequestMetadata.from_conn(conn)
           ) do
      redirect_to_issue(conn, context, issue)
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  defp redirect_unauthenticated_with_return(
         %Plug.Conn{assigns: %{current_user: nil}} = conn,
         _opts
       ) do
    target = safe_return_target(conn)

    conn
    |> redirect(to: "/login?return_to=#{URI.encode_www_form(target)}")
    |> halt()
  end

  defp redirect_unauthenticated_with_return(conn, _opts), do: conn

  defp safe_return_target(conn) do
    owner = encode_path_segment(conn.path_params["owner"])
    repository = encode_path_segment(conn.path_params["repo"])
    number = encode_path_segment(conn.path_params["number"])
    base = "/#{owner}/#{repository}/issues"

    case conn.private[:phoenix_action] do
      :new ->
        base <> "/new"

      :edit ->
        base <> "/#{number}/edit"

      :create ->
        base

      action
      when action in [:update, :comment, :update_comment, :delete_comment, :state] ->
        base <> "/#{number}"
    end
  end

  defp encode_path_segment(nil), do: ""
  defp encode_path_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp render_new(conn, context, values, errors, status \\ :ok) do
    with {:ok, options} <-
           issues(conn).form_options(
             context.viewer,
             context.owner.username,
             context.repository.slug,
             nil
           ),
         true <- options.capabilities.can_create,
         {:ok, result} <-
           collaboration_page(conn).issues(
             context.repository,
             context.owner,
             context.viewer,
             default_issue_filters(),
             []
           ) do
      result = %{
        result
        | content: %{issue: nil, options: options, values: values, errors: errors}
      }

      conn
      |> put_status(status)
      |> RepositoryWeb.render(result, html_module(conn), :new)
    else
      false -> RepositoryWeb.error(conn, context.repository, :forbidden)
      {:error, reason} -> RepositoryWeb.error(conn, context.repository, reason)
    end
  end

  defp render_edit(conn, context, result, values, errors, status \\ :ok) do
    issue = result.content.issue

    case issues(conn).form_options(
           context.viewer,
           context.owner.username,
           context.repository.slug,
           issue
         ) do
      {:ok, %{capabilities: %{can_edit: true}} = options} ->
        result = %{
          result
          | content: %{issue: issue, options: options, values: values, errors: errors}
        }

        conn
        |> put_status(status)
        |> RepositoryWeb.render(result, html_module(conn), :edit)

      {:error, reason} ->
        RepositoryWeb.error(conn, context.repository, reason)

      {:ok, _options} ->
        RepositoryWeb.error(conn, context.repository, :forbidden)
    end
  end

  defp render_edit_error(conn, owner_slug, repository_slug, number, params, errors) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, number} <- positive_integer(number),
         {:ok, values} <- issue_attrs(params),
         {:ok, result} <-
           collaboration_page(conn).issue(
             context.repository,
             context.owner,
             context.viewer,
             number,
             []
           ) do
      render_edit(conn, context, result, values, errors, :unprocessable_entity)
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  defp render_comment_error(
         conn,
         owner_slug,
         repository_slug,
         number,
         operation,
         params,
         errors
       ) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, number} <- positive_integer(number),
         {:ok, values} <- comment_attrs(params),
         {:ok, result} <-
           collaboration_page(conn).issue(
             context.repository,
             context.owner,
             context.viewer,
             number,
             []
           ) do
      result =
        update_in(result.content, fn content ->
          Map.put(content, :comment_form, %{
            operation: operation,
            values: values,
            errors: errors
          })
        end)

      conn
      |> put_status(:unprocessable_entity)
      |> RepositoryWeb.render(result, html_module(conn), :show)
    else
      {:error, :invalid_integer} -> RepositoryWeb.error(conn, nil, :not_found)
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  defp issue_attrs(%{"issue" => attrs}) when is_map(attrs) do
    attrs =
      attrs
      |> Map.take(["title", "body", "labels", "assignees"])
      |> normalize_relationships()

    {:ok, attrs}
  end

  defp issue_attrs(_params),
    do: {:error, {:validation, [%{resource: "Issue", field: "base", code: :invalid}]}}

  defp comment_attrs(%{"comment" => attrs}) when is_map(attrs),
    do: {:ok, Map.take(attrs, ["body"])}

  defp comment_attrs(_params),
    do: {:error, {:validation, [%{resource: "IssueComment", field: "base", code: :invalid}]}}

  defp normalize_relationships(attrs) do
    Enum.reduce(["labels", "assignees"], attrs, fn field, normalized ->
      case Map.fetch(normalized, field) do
        {:ok, values} -> Map.put(normalized, field, Enum.reject(List.wrap(values), &(&1 == "")))
        :error -> normalized
      end
    end)
  end

  defp state_attrs(%{"state" => "closed"}),
    do: {:ok, %{"state" => "closed", "state_reason" => "completed"}}

  defp state_attrs(%{"state" => "open"}),
    do: {:ok, %{"state" => "open", "state_reason" => "reopened"}}

  defp state_attrs(_params),
    do: {:error, {:validation, [%{resource: "Issue", field: "state", code: :invalid}]}}

  defp issue_values(issue) do
    %{
      "title" => issue.title || "",
      "body" => issue.body || "",
      "labels" => Enum.map(issue.labels, & &1.name),
      "assignees" => Enum.map(issue.assignees, & &1.username)
    }
  end

  defp default_issue_filters do
    %{
      kind: :issue,
      page: 1,
      per_page: 30,
      state: :open,
      labels: "",
      assignee: nil,
      creator: nil,
      sort: :created,
      direction: :desc
    }
  end

  defp comment_parent(%{issue_number: number}, number), do: :ok
  defp comment_parent(_comment, _number), do: {:error, :not_found}

  defp redirect_to_issue(conn, context, %{kind: :pull_request, number: number}) do
    private_redirect(conn, RepositoryHTML.pull_path(path_chrome(context), number))
  end

  defp redirect_to_issue(conn, context, %{number: number}) do
    private_redirect(conn, RepositoryHTML.issue_path(path_chrome(context), number))
  end

  defp path_chrome(context) do
    %RepositoryPage.Chrome{
      owner: context.owner,
      repository: context.repository,
      viewer: context.viewer,
      ref_summary: nil,
      clone: nil
    }
  end

  defp issue_filters(params, page) do
    query_keys = params |> Map.keys() |> Enum.reject(&(&1 in @route_keys))

    with true <- Enum.all?(query_keys, &(&1 in @filter_keys)),
         {:ok, state} <- enum_filter(params, "state", :open, [:open, :closed, :all]),
         {:ok, sort} <- enum_filter(params, "sort", :created, [:created, :updated, :comments]),
         {:ok, direction} <- enum_filter(params, "direction", :desc, [:asc, :desc]),
         {:ok, labels} <- bounded_filter(params, "labels", ""),
         {:ok, assignee} <- bounded_filter(params, "assignee", nil),
         {:ok, creator} <- bounded_filter(params, "creator", nil) do
      {:ok,
       %{
         kind: :issue,
         page: page,
         per_page: 30,
         state: state,
         labels: labels,
         assignee: assignee,
         creator: creator,
         sort: sort,
         direction: direction
       }}
    else
      _reason -> validation_error()
    end
  end

  defp enum_filter(params, key, default, allowed) do
    case Map.get(params, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> Enum.find(allowed, &(Atom.to_string(&1) == value)) |> found()
      _value -> :error
    end
  end

  defp found(nil), do: :error
  defp found(value), do: {:ok, value}

  defp bounded_filter(params, key, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      "" when is_nil(default) ->
        {:ok, nil}

      value when is_binary(value) and byte_size(value) <= 512 ->
        if String.valid?(value) and not String.contains?(value, <<0>>),
          do: {:ok, value},
          else: :error

      _value ->
        :error
    end
  end

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _other -> {:error, :invalid_integer}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_integer}

  defp issues_enabled(%{has_issues: true}), do: :ok
  defp issues_enabled(_repository), do: {:error, :issues_disabled}

  defp private_redirect(conn, path) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
    |> redirect(to: path)
  end

  defp validation_error do
    {:error, {:validation, [%{resource: "Issue", field: "filters", code: :invalid}]}}
  end

  defp collaboration_page(conn),
    do: conn.private[:repository_collaboration_page] || RepositoryCollaborationPage

  defp issues(conn), do: conn.private[:forge_issues] || ForgeIssues
  defp html_module(conn), do: conn.private[:issue_html] || IssueHTML
end
