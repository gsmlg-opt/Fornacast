defmodule ForgeMirrors.ResourceDecision do
  @moduledoc """
  Pure three-way comparison for canonical issue metadata.

  Callers supply normalized scalar values and sets of immutable mapped identities.
  `:missing` means no trustworthy baseline; `nil` is an ordinary scalar value.
  Mutating decisions retain observed preconditions for the eventual write.
  """

  @type decision(value) ::
          {:confirm, value}
          | {:apply_local, value, value}
          | {:apply_remote, value, value}
          | {:apply_both, value, value, value}
          | {:conflict, :missing_baseline | :concurrent_edit}

  @spec scalar(term(), term(), term()) :: decision(term())
  def scalar(_baseline, same, same), do: {:confirm, same}
  def scalar(:missing, _local, _remote), do: {:conflict, :missing_baseline}
  def scalar(baseline, baseline, remote), do: {:apply_local, baseline, remote}
  def scalar(baseline, local, baseline), do: {:apply_remote, baseline, local}
  def scalar(_baseline, _local, _remote), do: {:conflict, :concurrent_edit}

  @doc "Merges additions and removals relative to the confirmed baseline, never a plain union."
  @spec set(MapSet.t() | :missing, MapSet.t(), MapSet.t()) :: decision(MapSet.t())
  def set(:missing, %MapSet{} = local, %MapSet{} = remote) do
    if MapSet.equal?(local, remote),
      do: {:confirm, local},
      else: {:conflict, :missing_baseline}
  end

  def set(%MapSet{} = baseline, %MapSet{} = local, %MapSet{} = remote) do
    removals =
      MapSet.union(MapSet.difference(baseline, local), MapSet.difference(baseline, remote))

    merged = MapSet.difference(MapSet.union(local, remote), removals)

    cond do
      MapSet.equal?(local, remote) -> {:confirm, merged}
      MapSet.equal?(merged, local) -> {:apply_remote, remote, merged}
      MapSet.equal?(merged, remote) -> {:apply_local, local, merged}
      true -> {:apply_both, local, remote, merged}
    end
  end
end
