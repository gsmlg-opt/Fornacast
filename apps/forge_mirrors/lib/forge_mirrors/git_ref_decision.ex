defmodule ForgeMirrors.GitRefDecision do
  @moduledoc """
  Pure three-state decision policy for one mirrored branch or tag.

  `baseline` is the last confirmed target, `local` is the current public local target, and
  `remote` is the current GitHub target. `nil` is a confirmed absence; `:missing` means the
  caller has no trustworthy baseline and therefore must fail closed.

  Every mutating result carries the exact currently observed target that the caller must use
  for its local or remote expected-state write.
  """

  @type oid :: String.t()
  @type observed_oid :: oid() | nil
  @type baseline :: observed_oid() | :missing
  @type conflict :: :delete_vs_update | :git_divergence | :missing_baseline | :tag_retarget

  @type decision ::
          {:confirm, observed_oid()}
          | {:apply_local, observed_oid(), oid()}
          | {:apply_remote, observed_oid(), oid()}
          | {:delete_local, oid()}
          | {:delete_remote, oid()}
          | {:conflict, conflict()}
          | {:error, term()}

  @spec decide(
          :branch | :tag,
          baseline(),
          observed_oid(),
          observed_oid(),
          (oid(), oid() -> {:ok, boolean()} | {:error, term()})
        ) :: decision()
  def decide(kind, baseline, local, remote, ancestor?) do
    with :ok <- validate(kind, baseline, local, remote, ancestor?) do
      do_decide(kind, baseline, local, remote, ancestor?)
    end
  end

  defp do_decide(_kind, _baseline, same, same, _ancestor?), do: {:confirm, same}

  defp do_decide(_kind, :missing, _local, _remote, _ancestor?),
    do: {:conflict, :missing_baseline}

  defp do_decide(:tag, baseline, local, remote, _ancestor?) do
    cond do
      local == baseline and is_nil(remote) -> {:delete_local, local}
      remote == baseline and is_nil(local) -> {:delete_remote, remote}
      local == baseline and is_nil(baseline) -> {:apply_local, local, remote}
      remote == baseline and is_nil(baseline) -> {:apply_remote, remote, local}
      is_nil(local) or is_nil(remote) -> {:conflict, :delete_vs_update}
      true -> {:conflict, :tag_retarget}
    end
  end

  defp do_decide(:branch, baseline, local, remote, ancestor?) do
    cond do
      local == baseline -> remote_change(local, remote, :local, ancestor?)
      remote == baseline -> remote_change(remote, local, :remote, ancestor?)
      is_nil(local) or is_nil(remote) -> {:conflict, :delete_vs_update}
      true -> converge_descendants(local, remote, ancestor?)
    end
  end

  defp remote_change(current, nil, :local, _ancestor?), do: {:delete_local, current}
  defp remote_change(current, nil, :remote, _ancestor?), do: {:delete_remote, current}
  defp remote_change(nil, proposed, :local, _ancestor?), do: {:apply_local, nil, proposed}
  defp remote_change(nil, proposed, :remote, _ancestor?), do: {:apply_remote, nil, proposed}

  defp remote_change(current, proposed, side, ancestor?) do
    case ancestor?.(current, proposed) do
      {:ok, true} -> apply_to(side, current, proposed)
      {:ok, false} -> {:conflict, :git_divergence}
      {:error, reason} -> {:error, reason}
    end
  end

  defp converge_descendants(local, remote, ancestor?) do
    case ancestor?.(local, remote) do
      {:ok, true} ->
        {:apply_local, local, remote}

      {:ok, false} ->
        case ancestor?.(remote, local) do
          {:ok, true} -> {:apply_remote, remote, local}
          {:ok, false} -> {:conflict, :git_divergence}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_to(:local, current, proposed), do: {:apply_local, current, proposed}
  defp apply_to(:remote, current, proposed), do: {:apply_remote, current, proposed}

  defp validate(kind, baseline, local, remote, ancestor?) do
    if kind in [:branch, :tag] and valid_baseline?(baseline) and valid_oid?(local) and
         valid_oid?(remote) and is_function(ancestor?, 2),
       do: :ok,
       else: {:error, :invalid_ref_state}
  end

  defp valid_baseline?(:missing), do: true
  defp valid_baseline?(value), do: valid_oid?(value)

  defp valid_oid?(nil), do: true

  defp valid_oid?(value) when is_binary(value) and byte_size(value) in [40, 64],
    do: value == String.downcase(value) and String.match?(value, ~r/\A[0-9a-f]+\z/)

  defp valid_oid?(_value), do: false
end
