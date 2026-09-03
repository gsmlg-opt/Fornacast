defmodule FornacastWeb.ImportStatusJSON do
  @moduledoc false

  alias ForgeImports.RunView

  @terminal_states [:completed, :completed_with_warnings, :canceled, :failed]
  @published_states [:published, :completed]

  @spec show(RunView.t()) :: map()
  def show(%RunView{} = run) do
    owner = destination_owner(run)

    %{
      id: run.id,
      state: atom_string(run.state),
      wait_reason: run.wait_reason,
      resume_state: atom_string(run.resume_state),
      next_attempt_at: datetime(run.next_attempt_at),
      terminal: terminal?(run),
      poll: poll?(run),
      counts: counts(run.counts),
      repositories: Enum.map(run.repositories, &repository(&1, owner)),
      updated_at: datetime(run.updated_at)
    }
  end

  defp repository(repository, owner) do
    %{
      id: repository.id,
      source_full_name: repository.source_full_name,
      selected: repository.selected,
      state: atom_string(repository.state),
      wait_reason: repository.wait_reason,
      next_attempt_at: datetime(repository.next_attempt_at),
      published_href: published_href(owner, repository),
      counts: counts(repository.counts)
    }
  end

  defp counts(nil), do: %{}

  defp counts(counts) when is_map(counts) do
    counts
    |> Map.new(fn {key, value} -> {key, value} end)
  end

  defp published_href(owner, %{state: state, destination_slug: slug, selected: true})
       when state in @published_states and is_binary(owner) and is_binary(slug) and slug != "" do
    "/#{owner}/#{slug}"
  end

  defp published_href(_owner, _repository), do: nil

  defp destination_owner(%RunView{
         destination_organization: %{username: username}
       })
       when is_binary(username) and username != "" do
    username
  end

  defp destination_owner(%RunView{destination: %{organization_slug: slug}})
       when is_binary(slug) and slug != "" do
    slug
  end

  defp destination_owner(_run), do: nil

  defp terminal?(%RunView{state: state}), do: state in @terminal_states
  defp poll?(%RunView{} = run), do: not terminal?(run)

  defp datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime(_value), do: nil

  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: value
end
