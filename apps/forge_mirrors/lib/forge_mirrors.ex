defmodule ForgeMirrors do
  @moduledoc """
  Provider-neutral boundary for organization and repository mirror policy.

  This scaffold intentionally exposes types only. Durable state and
  synchronization workers arrive in later changes.
  """

  @type provider :: atom()
  @type direction :: :inbound | :outbound
  @type resource_kind :: :organization | :repository
end
