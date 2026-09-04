defmodule ForgeMirrors.InventoryPolicy do
  @moduledoc "Typed repository inclusion and auto-import policy for inventory reconciliation."

  @max_selected_repositories 10_000

  @enforce_keys [:repository_selection, :selected_repository_ids, :auto_import_new_repositories]
  defstruct [:repository_selection, :selected_repository_ids, :auto_import_new_repositories]

  @type t :: %__MODULE__{
          repository_selection: :all | :selected,
          selected_repository_ids: MapSet.t(pos_integer()),
          auto_import_new_repositories: boolean()
        }

  @spec parse(map()) :: {:ok, t()} | {:error, :invalid_policy}
  def parse(policy) when is_map(policy) do
    selection = value(policy, "repository_selection", "all")
    selected_ids = value(policy, "selected_repository_ids", [])
    auto_import = value(policy, "auto_import_new_repositories", false)

    with {:ok, selection} <- selection(selection),
         {:ok, selected_ids} <- selected_ids(selected_ids),
         true <- is_boolean(auto_import) do
      {:ok,
       %__MODULE__{
         repository_selection: selection,
         selected_repository_ids: MapSet.new(selected_ids),
         auto_import_new_repositories: auto_import
       }}
    else
      _invalid -> {:error, :invalid_policy}
    end
  end

  def parse(_policy), do: {:error, :invalid_policy}

  @spec included?(t(), pos_integer()) :: boolean()
  def included?(%__MODULE__{repository_selection: :all}, _github_repository_id), do: true

  def included?(%__MODULE__{selected_repository_ids: selected}, github_repository_id),
    do: MapSet.member?(selected, github_repository_id)

  @spec auto_import?(t(), boolean(), boolean()) :: boolean()
  def auto_import?(%__MODULE__{} = policy, newly_visible?, archived?) do
    policy.auto_import_new_repositories and newly_visible? and not archived?
  end

  defp selection("all"), do: {:ok, :all}
  defp selection(:all), do: {:ok, :all}
  defp selection("selected"), do: {:ok, :selected}
  defp selection(:selected), do: {:ok, :selected}
  defp selection(_selection), do: :error

  defp selected_ids(ids) when is_list(ids) and length(ids) <= @max_selected_repositories do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)) and length(ids) == length(Enum.uniq(ids)),
      do: {:ok, ids},
      else: :error
  end

  defp selected_ids(_ids), do: :error

  defp value(policy, "repository_selection", default),
    do: Map.get(policy, "repository_selection", Map.get(policy, :repository_selection, default))

  defp value(policy, "selected_repository_ids", default),
    do:
      Map.get(
        policy,
        "selected_repository_ids",
        Map.get(policy, :selected_repository_ids, default)
      )

  defp value(policy, "auto_import_new_repositories", default),
    do:
      Map.get(
        policy,
        "auto_import_new_repositories",
        Map.get(policy, :auto_import_new_repositories, default)
      )
end
