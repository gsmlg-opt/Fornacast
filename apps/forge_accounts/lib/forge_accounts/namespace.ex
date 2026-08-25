defmodule ForgeAccounts.Namespace do
  @reserved MapSet.new([
              "assets",
              "health",
              "setup",
              "login",
              "logout",
              "issues",
              "pulls",
              "ssh-keys",
              "settings",
              "organizations",
              "repos",
              "imports",
              "api",
              ".well-known"
            ])

  @account_slug ~r/^[a-z0-9][a-z0-9_-]{1,38}[a-z0-9]$/

  @spec validate(term()) :: {:ok, String.t()} | {:error, :invalid | :reserved}
  def validate(value) when is_binary(value) do
    normalized = String.trim(String.downcase(value))

    cond do
      MapSet.member?(@reserved, normalized) -> {:error, :reserved}
      Regex.match?(@account_slug, normalized) -> {:ok, normalized}
      true -> {:error, :invalid}
    end
  end

  def validate(_value), do: {:error, :invalid}

  def reserved?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&MapSet.member?(@reserved, &1))
  end

  def reserved?(_value), do: false
end
