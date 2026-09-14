defmodule FornacastWeb.ReleaseHTML do
  @moduledoc false

  use FornacastWeb, :html

  alias FornacastWeb.{CollaborationMarkdown, RepositoryHTML}

  embed_templates "release_html/*"

  def total_pages(page), do: Fornacast.Page.total_pages(page)
  def markdown(nil), do: CollaborationMarkdown.render("")
  def markdown(body), do: CollaborationMarkdown.render(body)
  def format_time(value), do: RepositoryHTML.format_time(value)
  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  defdelegate releases_path(chrome), to: RepositoryHTML
  def new_release_path(chrome), do: releases_path(chrome) <> "/new"
  def release_path(chrome, id), do: releases_path(chrome) <> "/" <> encode_segment(id)
  def edit_release_path(chrome, id), do: release_path(chrome, id) <> "/edit"

  def release_tag_path(chrome, tag),
    do: releases_path(chrome) <> "/tag/" <> encode_segment(tag)

  def pagination_base(result), do: releases_path(result.chrome)

  def release_name(%{name: name, tag_name: tag}) when name in [nil, ""], do: tag
  def release_name(%{name: name}), do: name

  def release_state(%{draft: true}), do: "Draft"
  def release_state(%{prerelease: true}), do: "Prerelease"
  def release_state(_release), do: "Published"

  def state_variant(%{draft: true}), do: "neutral"
  def state_variant(%{prerelease: true}), do: "warning"
  def state_variant(_release), do: "success"

  def author_name(%{username: username}) when is_binary(username), do: username
  def author_name(%{login: login}) when is_binary(login), do: login
  def author_name(_author), do: "unknown"

  def form_value(values, key, default \\ ""), do: Map.get(values, key, default) || default

  def checked?(values, key), do: Map.get(values, key, false) in [true, "true", "1", "on"]

  def field_errors(errors, resource, field) do
    errors
    |> Enum.filter(&(&1.resource == resource and &1.field == field))
    |> Enum.map(&validation_message/1)
  end

  def resource_errors(errors, resource) do
    errors
    |> Enum.filter(&(&1.resource == resource and &1.field == "base"))
    |> Enum.map(&validation_message/1)
  end

  attr :result, :any, required: true
  attr :mode, :atom, required: true

  def release_form(assigns) do
    assigns =
      assigns
      |> assign(:action, form_action(assigns.result, assigns.mode))
      |> assign(:title, if(assigns.mode == :new, do: "New release", else: "Edit release"))
      |> assign(:submit, if(assigns.mode == :new, do: "Create release", else: "Save release"))

    ~H"""
    <section class="grid min-w-0 gap-3 p-4" data-release-form>
      <header class="bg-surface-container text-on-surface rounded-lg p-4">
        <p class="text-xs text-on-surface-variant">Repository releases</p>
        <h2 class="text-lg font-semibold">{@title}</h2>
      </header>

      <form
        action={@action}
        method="post"
        class="grid gap-3 bg-surface-container text-on-surface rounded-lg p-4"
      >
        <input type="hidden" name="_csrf_token" value={csrf_token()} />
        <input :if={@mode == :edit} type="hidden" name="_method" value="patch" />

        <.dm_alert :for={error <- resource_errors(@result.content.errors, "Release")} variant="error">
          {error}
        </.dm_alert>

        <.dm_input
          id="release-tag-name"
          name="release[tag_name]"
          label="Tag name"
          value={form_value(@result.content.values, "tag_name")}
          errors={field_errors(@result.content.errors, "Release", "tag_name")}
          maxlength="255"
          required
        />
        <.dm_input
          id="release-name"
          name="release[name]"
          label="Name"
          value={form_value(@result.content.values, "name")}
          errors={field_errors(@result.content.errors, "Release", "name")}
          maxlength="255"
        />
        <.dm_textarea
          id="release-body"
          name="release[body]"
          label="Body"
          value={form_value(@result.content.values, "body")}
          errors={field_errors(@result.content.errors, "Release", "body")}
          rows={12}
        />
        <.dm_input
          id="release-target-commitish"
          name="release[target_commitish]"
          label="Target commitish"
          value={
            form_value(
              @result.content.values,
              "target_commitish",
              @result.chrome.repository.default_branch
            )
          }
          errors={field_errors(@result.content.errors, "Release", "target_commitish")}
          maxlength="255"
          required
        />
        <div class="grid gap-3 md:grid-cols-2">
          <.dm_checkbox
            id="release-draft"
            name="release[draft]"
            label="Draft"
            checked={checked?(@result.content.values, "draft")}
            errors={field_errors(@result.content.errors, "Release", "draft")}
          />
          <.dm_checkbox
            id="release-prerelease"
            name="release[prerelease]"
            label="Prerelease"
            checked={checked?(@result.content.values, "prerelease")}
            errors={field_errors(@result.content.errors, "Release", "prerelease")}
          />
        </div>

        <div class="flex flex-wrap gap-3">
          <.dm_btn type="submit" variant="primary">{@submit}</.dm_btn>
          <.dm_link href={cancel_path(@result, @mode)}>Cancel</.dm_link>
        </div>
      </form>
    </section>
    """
  end

  defp form_action(result, :new), do: releases_path(result.chrome)
  defp form_action(result, :edit), do: release_path(result.chrome, result.content.release.id)
  defp cancel_path(result, :new), do: releases_path(result.chrome)
  defp cancel_path(result, :edit), do: release_path(result.chrome, result.content.release.id)

  defp validation_message(%{resource: "Release", field: "base"}),
    do: "The release could not be processed"

  defp validation_message(%{field: field, code: code}) do
    label = field |> String.replace("_", " ") |> String.capitalize()

    case code do
      :invalid -> "#{label} is invalid"
      :missing -> "#{label} is missing"
      :unprocessable -> "#{label} could not be processed"
      _code -> "#{label} is invalid"
    end
  end

  defp encode_segment(segment), do: URI.encode(to_string(segment), &URI.char_unreserved?/1)
end
