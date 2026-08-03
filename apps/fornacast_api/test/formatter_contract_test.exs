defmodule FornacastAPI.FormatterContractTest do
  use ExUnit.Case, async: true

  @formatter Path.expand("../../..", __DIR__) |> Path.join(".formatter.exs")

  test "umbrella formatting excludes app runtime directories" do
    {options, _binding} = Code.eval_file(@formatter)
    inputs = Keyword.fetch!(options, :inputs)

    assert "apps/*/{mix,.formatter}.exs" in inputs
    assert "apps/*/{config,lib,test}/**/*.{ex,exs,heex}" in inputs
    refute Enum.any?(inputs, &String.contains?(&1, "apps}/**/*"))
  end
end
