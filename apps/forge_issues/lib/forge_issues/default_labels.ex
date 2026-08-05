defmodule ForgeIssues.DefaultLabels do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeIssues.Label
  alias Fornacast.Repo

  @labels [
    %{name: "bug", color: "d73a4a", description: "Something isn't working"},
    %{
      name: "documentation",
      color: "0075ca",
      description: "Improvements or additions to documentation"
    },
    %{
      name: "duplicate",
      color: "cfd3d7",
      description: "This issue or pull request already exists"
    },
    %{name: "enhancement", color: "a2eeef", description: "New feature or request"},
    %{name: "good first issue", color: "7057ff", description: "Good for newcomers"},
    %{name: "help wanted", color: "008672", description: "Extra attention is needed"},
    %{name: "invalid", color: "e4e669", description: "This doesn't seem right"},
    %{name: "question", color: "d876e3", description: "Further information is requested"},
    %{name: "wontfix", color: "ffffff", description: "This will not be worked on"}
  ]

  @spec ensure(ForgeRepos.Repository.t()) :: [Label.t()]
  def ensure(%ForgeRepos.Repository{has_issues: false}), do: []

  def ensure(%ForgeRepos.Repository{} = repository) do
    if Repo.in_transaction?() do
      provision(repository)
    else
      multi =
        Multi.run(Multi.new(), :labels, fn _repo, _changes -> {:ok, provision(repository)} end)

      {:ok, %{labels: labels}} = ForgeIssues.transaction(multi)
      labels
    end
  end

  def normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()

  defp provision(repository) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      Label,
      Enum.map(@labels, fn label ->
        Map.merge(label, %{
          repository_id: repository.id,
          normalized_name: normalize_name(label.name),
          default: true,
          inserted_at: now,
          updated_at: now
        })
      end),
      on_conflict: :nothing,
      conflict_target: [:repository_id, :normalized_name]
    )

    Label
    |> where([label], label.repository_id == ^repository.id)
    |> order_by([label], asc: label.normalized_name)
    |> Repo.all()
  end
end
