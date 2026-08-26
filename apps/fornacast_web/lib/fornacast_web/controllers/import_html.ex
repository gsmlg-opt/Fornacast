defmodule FornacastWeb.ImportHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "import_html/*"

  attr :repositories, :list, required: true
  attr :editable, :boolean, required: true

  def repository_table(assigns) do
    ~H"""
    <div class="overflow-x-auto" data-repository-read-only={!@editable}>
      <table class="table" aria-label="Discovered repositories">
        <caption class="sr-only">Discovered repositories</caption>
        <thead>
          <tr>
            <th scope="col">{if(@editable, do: "Include", else: "Selection")}</th>
            <th scope="col">GitHub repository</th>
            <th scope="col">Destination</th>
            <th scope="col">State</th>
            <th scope="col">Warnings</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={repository <- @repositories}
            data-repository-item={repository.id}
            data-collision={repository.state == :awaiting_resolution}
          >
            <td>
              <label
                :if={@editable}
                class="inline-flex items-center gap-2"
                for={"repository-selection-#{repository.github_repository_id}"}
              >
                <input
                  id={"repository-selection-#{repository.github_repository_id}"}
                  type="checkbox"
                  class="checkbox checkbox-primary"
                  name="selection[repository_ids][]"
                  value={repository.github_repository_id}
                  checked={repository.selected}
                  aria-label={"Include #{repository.source_full_name}"}
                />
                <span class="sr-only">Include</span>
              </label>
              <.dm_badge :if={!@editable} variant="secondary" soft size="sm">
                {if(repository.selected, do: "Selected", else: "Not selected")}
              </.dm_badge>
            </td>
            <th scope="row">{repository.source_full_name}</th>
            <td>{repository.destination_slug || "Needs a slug"}</td>
            <td>
              <.dm_badge variant={state_variant(repository.state)} soft size="sm">
                {humanize(repository.state)}
              </.dm_badge>
            </td>
            <td>
              <span :if={repository.wait_reason}>{humanize(repository.wait_reason)}</span>
              <span :if={!repository.wait_reason} class="text-on-surface-variant">None</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  def resolution_editable?(%{state: :awaiting_resolution}), do: true
  def resolution_editable?(_run), do: false

  def discovering?(%{state: :discovering}), do: true
  def discovering?(_run), do: false

  def read_only_state(%{state: :awaiting_resolution}), do: nil
  def read_only_state(%{state: state}), do: state

  def run_guidance(%{state: :discovering}),
    do: "GitHub is discovering repositories and destination evidence."

  def run_guidance(_run),
    do: "Review discovered repositories and destination evidence for this import."

  def account_options(accounts) do
    Enum.map(accounts, &{&1.display_name, &1.identity_id})
  end

  def organization_options(organizations) do
    Enum.map(organizations, &{&1.username, &1.id})
  end

  def source_label(%{repository_full_name: full_name}) when is_binary(full_name), do: full_name
  def source_label(%{owner_login: login}) when is_binary(login), do: login
  def source_label(_source), do: "GitHub"

  def destination_label(%{organization_slug: slug}) when is_binary(slug), do: slug
  def destination_label(_destination), do: "Needs a destination"

  def destination_warning?(%{organization_status: status})
      when status in [:conflict, :invalid],
      do: true

  def destination_warning?(_destination), do: false

  def destination_warning_variant(%{organization_status: :invalid}), do: "error"
  def destination_warning_variant(%{organization_status: :conflict}), do: "warning"

  def destination_warning_classification(%{organization_classification: classification})
      when is_binary(classification),
      do: classification

  def humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  def humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def humanize(_value), do: "Unknown"

  def state_variant(state) when state in [:completed, :published], do: "success"
  def state_variant(state) when state in [:failed, :canceled], do: "error"

  def state_variant(state)
      when state in [:awaiting_resolution, :awaiting_credential, :cancel_requested],
      do: "warning"

  def state_variant(_state), do: "info"

  def outcome_variant(:warning), do: "warning"
  def outcome_variant(:failed), do: "error"
  def outcome_variant(:imported), do: "success"
  def outcome_variant(_outcome), do: "info"

  def datetime_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  def datetime_label(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %d, %Y at %H:%M UTC")
  end

  def organization_run?(%{source: %{kind: :organization}}), do: true
  def organization_run?(_run), do: false

  def existing_destination?(%{destination: %{organization_action: :existing}}), do: true
  def existing_destination?(_run), do: false

  def destination_slug(%{destination: %{organization_slug: slug}}) when is_binary(slug),
    do: slug

  def destination_slug(_run), do: nil

  def editable_new_destination_slug(run) do
    if existing_destination?(run), do: nil, else: destination_slug(run)
  end

  def destination_organization_id(%{destination: %{organization_id: id}})
      when is_integer(id),
      do: id

  def destination_organization_id(_run), do: nil
end
