defmodule FornacastWeb.IssueController do
  use FornacastWeb, :controller

  alias FornacastWeb.{IssueHTML, RepositoryCollaborationPage, RepositoryHTML, RepositoryWeb}

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

  defp html_module(conn), do: conn.private[:issue_html] || IssueHTML
end
