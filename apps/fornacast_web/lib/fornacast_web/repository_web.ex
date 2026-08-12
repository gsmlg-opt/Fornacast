defmodule FornacastWeb.RepositoryWeb do
  @moduledoc """
  Shared authorization, rendering, and error semantics for repository pages.
  """

  import Plug.Conn

  alias ForgeRepos.Repository
  alias FornacastWeb.{HTML, RepositoryCollaborationPage, RepositoryPage}

  def fetch(conn, owner_slug, repository_slug)
      when is_binary(owner_slug) and is_binary(repository_slug) do
    viewer = conn.assigns[:current_user]

    with %Repository{} = repository <- ForgeRepos.get_repository(owner_slug, repository_slug),
         :ok <- Fornacast.Access.authorize(viewer, :repository_read, repository),
         owner when not is_nil(owner) <- ForgeAccounts.get_account_by_username(owner_slug) do
      {:ok, %{owner: owner, repository: repository, viewer: viewer}}
    else
      _reason -> {:error, :not_found}
    end
  end

  def render(conn, %RepositoryPage.Result{} = result, html_module, template)
      when is_atom(html_module) and is_atom(template) do
    collaboration_page =
      conn.private[:repository_collaboration_page] || RepositoryCollaborationPage

    result = collaboration_page.decorate(result)
    rendered = apply(html_module, template, [%{result: result, __changed__: nil}])

    conn
    |> put_private_cache_headers()
    |> HTML.repository_page(
      "#{result.chrome.owner.username}/#{result.chrome.repository.slug}",
      Phoenix.HTML.Safe.to_iodata(rendered)
    )
  end

  def error(conn, _repository, reason) do
    {status, title, message} = error_response(reason)

    conn
    |> put_private_cache_headers()
    |> put_status(status)
    |> HTML.repository_page(
      title,
      Phoenix.HTML.raw("""
      <article class="repository-page repository-error" data-repository-kind="error">
        <section class="bg-surface-container text-on-surface rounded-lg border border-outline-variant p-4">
          <h1 class="text-lg font-semibold">#{message}</h1>
        </section>
      </article>
      """)
    )
  end

  defp error_response(reason) when reason in [:not_found, :private],
    do: {:not_found, "Repository not found", "Repository not found"}

  defp error_response(:forbidden), do: {:forbidden, "Forbidden", "Access denied"}

  defp error_response(reason) when reason in [:gone, :issues_disabled],
    do: {:gone, "Unavailable", "This feature is unavailable"}

  defp error_response({:validation, _errors}),
    do: {:unprocessable_entity, "Invalid request", "The request was invalid"}

  defp error_response(reason)
       when reason in [:invalid_head, :invalid_base, :cross_repository_head, :head_equals_base],
       do: {:unprocessable_entity, "Invalid request", "The request was invalid"}

  defp error_response(reason) when reason in [:ref_conflict, :head_changed],
    do: {:conflict, "Conflict", "The repository changed; refresh and try again"}

  defp error_response(reason)
       when reason in [:conflict, :method_not_allowed, :merge_commits_disabled],
       do: {:method_not_allowed, "Not allowed", "This operation is not allowed"}

  defp error_response({:unavailable, _reason}),
    do: {:service_unavailable, "Temporarily unavailable", "Repository temporarily unavailable"}

  defp error_response(%GitCore.Error{kind: kind})
       when kind in [:ref_not_found, :commit_not_found, :path_not_found],
       do: error_response(:not_found)

  defp error_response(%GitCore.Error{}),
    do: {:service_unavailable, "Temporarily unavailable", "Repository temporarily unavailable"}

  defp error_response(_reason),
    do: {:service_unavailable, "Temporarily unavailable", "Repository temporarily unavailable"}

  defp put_private_cache_headers(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
