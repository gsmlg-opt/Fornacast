defmodule FornacastWeb.ImportHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "import_html/*"

  attr :repositories, :list, required: true
  attr :editable, :boolean, required: true
  attr :run, :map, default: nil

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
            <th :if={!@editable} scope="col">Published</th>
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
                <span data-repository-state>{humanize(repository.state)}</span>
              </.dm_badge>
            </td>
            <td>
              <span :if={repository.wait_reason} data-repository-wait>{humanize(
                repository.wait_reason
              )}</span>
              <span
                :if={!repository.wait_reason && repository.next_attempt_at}
                data-repository-wait
              >
                Resume after {datetime_label(repository.next_attempt_at)}
              </span>
              <span
                :if={!repository.wait_reason && !repository.next_attempt_at}
                data-repository-wait
                class="text-on-surface-variant"
              >
                None
              </span>
            </td>
            <td :if={!@editable}>
              <.dm_link
                :if={published_href(@run, repository)}
                href={published_href(@run, repository)}
                data-repository-published-link
              >
                View repository
              </.dm_link>
              <span
                :if={!published_href(@run, repository)}
                class="text-on-surface-variant"
                data-repository-published-link
                hidden
              >
                Not published
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def conflict_repositories(%{repositories: repositories}) when is_list(repositories) do
    Enum.filter(repositories, fn repository ->
      repository.selected and repository.state == :awaiting_resolution
    end)
  end

  def conflict_repositories(_run), do: []

  def replace_available?(%{wait_reason: reason})
      when reason in ["repository_conflict", "destination_changed"],
      do: true

  def replace_available?(_repository), do: false

  def replacement_confirmation(run, repository) do
    "#{destination_label(run.destination)}/#{repository.destination_slug}"
  end

  def decision_label(%{selected: false}), do: "Not selected"
  def decision_label(%{conflict_action: nil}), do: "Create"
  def decision_label(%{conflict_action: action}), do: humanize(action)

  def decision_variant(%{selected: false}), do: "secondary"
  def decision_variant(%{conflict_action: :skip}), do: "secondary"
  def decision_variant(%{conflict_action: :rename}), do: "primary"
  def decision_variant(%{conflict_action: :replace}), do: "warning"
  def decision_variant(_repository), do: "info"

  def workflow_available?(%{
        state: state,
        destination: %{organization_status: :clean},
        repositories: [_first | _rest]
      })
      when state in [:awaiting_resolution, :running],
      do: true

  def workflow_available?(
        %{
          state: state,
          destination: %{organization_status: :clean},
          repositories: [_first | _rest]
        } = run
      )
      when state in [:cancel_requested, :completed, :completed_with_warnings, :canceled, :failed],
      do: conflict_repositories(run) == []

  def workflow_available?(_run), do: false

  def startable?(
        %{state: :awaiting_resolution, destination: %{organization_status: :clean}} = run
      ) do
    not Enum.any?(run.repositories, &(&1.selected and &1.state == :awaiting_resolution))
  end

  def startable?(_run), do: false

  def workflow_path(run) do
    if run.state in [:awaiting_resolution, :running] and conflict_repositories(run) != [],
      do: "/imports/#{run.id}/conflicts",
      else: "/imports/#{run.id}/review"
  end

  def workflow_label(run) do
    if conflict_repositories(run) == [], do: "Review import plan", else: "Resolve conflicts"
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

  @terminal_states [:completed, :completed_with_warnings, :canceled, :failed]
  @cancellable_states [:discovering, :awaiting_resolution, :ready, :running, :awaiting_credential]
  @retryable_states [:failed, :canceled, :completed_with_warnings]

  def pollable?(%{state: state}), do: state not in @terminal_states
  def pollable?(_run), do: false

  def cancellable?(%{state: state}), do: state in @cancellable_states
  def cancellable?(_run), do: false

  def retryable?(%{state: state}), do: state in @retryable_states
  def retryable?(_run), do: false

  def awaiting_credential?(%{state: :awaiting_credential}), do: true
  def awaiting_credential?(_run), do: false

  def report_available?(%{report_finalized_at: %DateTime{}}), do: true
  def report_available?(_run), do: false

  def control_accounts?(%{state: state})
      when state in [:awaiting_credential | @retryable_states],
      do: true

  def control_accounts?(_run), do: false

  def destination_owner_username(%{destination_organization: %{username: username}})
      when is_binary(username) and username != "",
      do: username

  def destination_owner_username(%{destination: %{organization_slug: slug}})
      when is_binary(slug) and slug != "",
      do: slug

  def destination_owner_username(_run), do: nil

  def published_href(nil, _repository), do: nil

  def published_href(run, repository) do
    owner = destination_owner_username(run)
    slug = repository.destination_slug

    if repository.state in [:published, :completed] and is_binary(owner) and is_binary(slug) and
         slug != "" do
      "/#{owner}/#{slug}"
    else
      nil
    end
  end
end
