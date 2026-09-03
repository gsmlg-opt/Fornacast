defmodule ForgeImports.RecoveryTestHelper do
  @moduledoc false

  @owner_key {ForgeImports.Reconciler, :sandbox_owner}

  @spec mark_sandbox_owner!(pid()) :: :ok
  def mark_sandbox_owner!(owner \\ self()) when is_pid(owner) do
    :persistent_term.put(@owner_key, owner)
    :ok
  end
end
