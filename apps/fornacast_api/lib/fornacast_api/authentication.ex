defmodule FornacastAPI.Authentication do
  @enforce_keys [:actor, :api_key]
  defstruct [:actor, :api_key]
end
