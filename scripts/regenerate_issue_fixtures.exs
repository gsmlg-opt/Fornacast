alias FornacastAPI.IssueFixtureGenerator

hold_ms =
  case System.get_env("FORNACAST_FIXTURE_GENERATOR_HOLD_MS") do
    nil -> 0
    value -> String.to_integer(value)
  end

case IssueFixtureGenerator.run(after_lock: fn -> Process.sleep(hold_ms) end) do
  :ok ->
    IO.puts("Regenerated 10 issue fixtures with byte and schema validation")

  {:error, :locked} ->
    IO.puts(:stderr, "issue fixture generation is already running")
    System.halt(75)
end
