defmodule FornacastWeb.PullRequestController do
  use FornacastWeb, :controller

  alias FornacastWeb.{
    PullRequestHTML,
    RepositoryCollaborationPage,
    RepositoryHTML,
    RepositoryPage,
    RepositoryWeb,
    RequestMetadata
  }

  @authenticated_actions [:new, :create]
  @filter_keys ~w(page state head base sort direction)
  @route_keys ~w(owner repo)
  @pull_ref_errors [:invalid_head, :invalid_base, :cross_repository_head, :head_equals_base]

  plug :redirect_unauthenticated_with_return when action in @authenticated_actions
  plug FornacastWeb.Plugs.RequireUser when action in @authenticated_actions

  def index(conn, %{"owner" => owner_slug, "repo" => repository_slug} = params) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, page} <- positive_integer(Map.get(params, "page", "1")),
         {:ok, filters} <- pull_filters(params, page),
         {:ok, result} <-
           collaboration_page(conn).pulls(
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

  def new(conn, %{"owner" => owner_slug, "repo" => repository_slug} = params) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, branches} <- pulls(conn).branch_options(context.repository, context.viewer),
         {:ok, result} <- pull_page(conn, context) do
      case new_values(params, context.repository.default_branch) do
        {:ok, values} ->
          case comparison(conn, context, values) do
            {:ok, comparison} ->
              render_new(conn, result, branches, values, comparison, [])

            {:error, reason} when reason in @pull_ref_errors ->
              render_new(
                conn,
                result,
                branches,
                values,
                nil,
                ref_errors(reason),
                :unprocessable_entity
              )

            {:error, reason} ->
              RepositoryWeb.error(conn, context.repository, reason)
          end

        {:error, {:validation, errors}} ->
          values = safe_new_values(params, context.repository.default_branch)
          render_new(conn, result, branches, values, nil, errors, :unprocessable_entity)
      end
    else
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def create(conn, %{"owner" => owner_slug, "repo" => repository_slug} = params) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, attrs} <- pull_attrs(params),
         {:ok, pull} <-
           pulls(conn).create_pull_request(
             context.repository,
             context.viewer,
             attrs,
             RequestMetadata.from_conn(conn)
           ) do
      conn
      |> put_private_cache_headers()
      |> redirect(to: RepositoryHTML.pull_path(path_chrome(context), pull.issue.number))
    else
      {:error, {:validation, errors}} ->
        render_create_error(conn, owner_slug, repository_slug, params, errors)

      {:error, reason} when reason in @pull_ref_errors ->
        render_create_error(conn, owner_slug, repository_slug, params, ref_errors(reason))

      {:error, reason} ->
        RepositoryWeb.error(conn, nil, reason)
    end
  end

  defp render_create_error(conn, owner_slug, repository_slug, params, errors) do
    with {:ok, context} <- RepositoryWeb.fetch(conn, owner_slug, repository_slug),
         {:ok, branches} <- pulls(conn).branch_options(context.repository, context.viewer),
         {:ok, result} <- pull_page(conn, context) do
      values = safe_pull_attrs(params)
      render_new(conn, result, branches, values, nil, errors, :unprocessable_entity)
    else
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  defp pull_page(conn, context) do
    collaboration_page(conn).pulls(
      context.repository,
      context.owner,
      context.viewer,
      default_filters(),
      []
    )
  end

  defp render_new(conn, result, branches, values, comparison, errors, status \\ :ok) do
    result = %{
      result
      | content:
          Map.merge(result.content, %{
            branches: branches,
            comparison: comparison,
            values: values,
            errors: errors
          })
    }

    conn
    |> put_status(status)
    |> RepositoryWeb.render(result, html_module(conn), :new)
  end

  defp comparison(conn, context, %{"head" => head, "base" => base}) do
    if blank?(head) or blank?(base) do
      {:ok, nil}
    else
      pulls(conn).compare(context.repository, context.viewer, head, base, [])
    end
  end

  defp pull_filters(params, page) do
    if Enum.any?(Map.keys(params), &(&1 not in (@filter_keys ++ @route_keys))) do
      validation("filter")
    else
      with {:ok, state} <- enum_filter(params, "state", :open, ~w(open closed all)),
           {:ok, sort} <-
             enum_filter(params, "sort", :created, ~w(created updated popularity long-running)),
           {:ok, direction} <-
             enum_filter(params, "direction", default_direction(sort), ~w(asc desc)),
           {:ok, head} <- optional_filter(params, "head"),
           {:ok, base} <- optional_filter(params, "base") do
        {:ok,
         %{
           page: page,
           per_page: 30,
           state: state,
           head: head,
           base: base,
           sort: sort,
           direction: direction
         }}
      end
    end
  end

  defp enum_filter(params, field, default, accepted) do
    case Map.get(params, field) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        if value in accepted,
          do: {:ok, value |> String.replace("-", "_") |> String.to_existing_atom()},
          else: validation(field)

      _value ->
        validation(field)
    end
  end

  defp optional_filter(params, field) do
    case Map.get(params, field) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> validation(field)
    end
  end

  defp default_direction(:created), do: :desc
  defp default_direction(_sort), do: :asc

  defp default_filters do
    %{
      page: 1,
      per_page: 30,
      state: :open,
      head: nil,
      base: nil,
      sort: :created,
      direction: :desc
    }
  end

  defp new_values(params, default_branch) do
    with {:ok, head} <- query_string(params, "head", ""),
         {:ok, base} <- query_string(params, "base", default_branch) do
      {:ok, %{"title" => "", "body" => "", "head" => head, "base" => base}}
    end
  end

  defp safe_new_values(params, default_branch) do
    %{
      "title" => "",
      "body" => "",
      "head" => safe_query_string(params, "head", ""),
      "base" => safe_query_string(params, "base", default_branch)
    }
  end

  defp query_string(params, field, default) do
    case Map.fetch(params, field) do
      :error -> {:ok, default}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> validation(field)
    end
  end

  defp safe_query_string(params, field, default) do
    case Map.get(params, field, default) do
      value when is_binary(value) -> value
      _value -> default
    end
  end

  defp pull_attrs(%{"pull" => attrs}) when is_map(attrs) do
    attrs = Map.take(attrs, ["title", "body", "head", "base"])

    case Enum.find(["title", "body", "head", "base"], fn field ->
           Map.has_key?(attrs, field) and not is_binary(attrs[field])
         end) do
      field when is_binary(field) -> validation(field)
      nil -> {:ok, attrs}
    end
  end

  defp pull_attrs(_params), do: validation("base")

  defp safe_pull_attrs(%{"pull" => attrs}) when is_map(attrs) do
    Map.new(["title", "body", "head", "base"], fn field ->
      value = Map.get(attrs, field, "")
      {field, if(is_binary(value), do: value, else: "")}
    end)
  end

  defp safe_pull_attrs(_params),
    do: %{"title" => "", "body" => "", "head" => "", "base" => ""}

  defp ref_errors(:invalid_head), do: [validation_error("head")]
  defp ref_errors(:cross_repository_head), do: [validation_error("head")]
  defp ref_errors(:invalid_base), do: [validation_error("base")]
  defp ref_errors(:head_equals_base), do: [validation_error("base")]

  defp validation(field), do: {:error, {:validation, [validation_error(field)]}}

  defp validation_error(field),
    do: %{resource: "PullRequest", field: field, code: :invalid}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _value -> {:error, :invalid_integer}
    end
  end

  defp positive_integer(_value), do: validation("page")

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

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
    base = "/#{owner}/#{repository}/pulls"

    case conn.private[:phoenix_action] do
      :new -> base <> "/new"
      :create -> base
    end
  end

  defp encode_path_segment(segment), do: URI.encode(segment || "", &URI.char_unreserved?/1)

  defp path_chrome(context) do
    %RepositoryPage.Chrome{
      owner: context.owner,
      repository: context.repository,
      viewer: context.viewer,
      ref_summary: nil,
      snapshot: nil,
      clone: nil,
      collaboration_counts: %{issues: nil, pull_requests: nil}
    }
  end

  defp put_private_cache_headers(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp collaboration_page(conn),
    do: conn.private[:repository_collaboration_page] || RepositoryCollaborationPage

  defp pulls(conn), do: conn.private[:forge_pulls] || ForgePulls
  defp html_module(conn), do: conn.private[:pull_request_html] || PullRequestHTML
end
