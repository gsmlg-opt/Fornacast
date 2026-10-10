defmodule ForgeReleases.Notes do
  @moduledoc "Release notes and safe body representations from local content."

  alias ForgeReleases.Archives

  def generate(repository, tag_name, previous_tag \\ nil, target_commitish \\ nil) do
    deadline = System.monotonic_time(:millisecond) + GitCore.Limits.get(:content_deadline_ms)

    ForgeRepos.with_repository_read(repository, deadline, fn handle ->
      generate_from_path(
        ForgeRepos.repository_read_repository(handle),
        ForgeRepos.repository_read_path(handle),
        tag_name,
        previous_tag,
        target_commitish
      )
    end)
  end

  @doc false
  def generate_from_path(repository, path, tag_name, previous_tag, target_commitish) do
    target = target_commitish || repository.default_branch

    with {:ok, oid} <- release_target(path, tag_name, target),
         {:ok, previous_oid} <- previous_oid(path, previous_tag, oid),
         range <- if(previous_oid, do: previous_oid <> ".." <> oid, else: oid),
         {:ok, changes} <-
           Archives.git_output(
             path,
             ["log", "--max-count=100", "--format=- %h %s", range],
             65_536
           ) do
      {:ok, %{name: tag_name, body: "## Changes\n\n" <> String.trim(changes)}}
    end
  end

  def body_html(nil), do: ""

  def body_html(body) do
    body
    |> MDEx.parse_document!()
    |> MDEx.to_html!(sanitize: MDEx.Document.default_sanitize_options())
  end

  def body_text(nil), do: ""

  def body_text(body),
    do: body |> MDEx.parse_document!() |> plain_text() |> IO.iodata_to_binary() |> String.trim()

  defp plain_text(%MDEx.HtmlBlock{}), do: ""
  defp plain_text(%MDEx.HtmlInline{}), do: ""
  defp plain_text(%{literal: literal}) when is_binary(literal), do: literal

  defp plain_text(%{nodes: nodes} = node) do
    text = Enum.map(nodes, &plain_text/1)

    if node.__struct__ in [MDEx.Paragraph, MDEx.Heading, MDEx.ListItem],
      do: [text, "\n"],
      else: text
  end

  defp plain_text(%MDEx.SoftBreak{}), do: "\n"
  defp plain_text(%MDEx.LineBreak{}), do: "\n"
  defp plain_text(_node), do: ""

  defp release_target(path, tag, target) do
    case Archives.commit_oid(path, "refs/tags/#{tag}") do
      {:ok, oid} -> {:ok, oid}
      _ -> Archives.commit_oid(path, target)
    end
  end

  defp previous_oid(path, previous_tag, _oid) when is_binary(previous_tag),
    do: Archives.commit_oid(path, "refs/tags/#{previous_tag}")

  defp previous_oid(path, nil, oid) do
    case Archives.git_output(path, ["describe", "--tags", "--abbrev=0", oid <> "^"], 1_024) do
      {:ok, tag} -> Archives.commit_oid(path, "refs/tags/#{String.trim(tag)}")
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end
end
