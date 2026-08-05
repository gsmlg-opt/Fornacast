defmodule FornacastAPI.IssueFixtureGeneratorTest do
  use ExUnit.Case, async: true

  alias FornacastAPI.{IssueFixtureGenerator, IssueFixtureLiterals}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    fixture_root = Path.join(tmp_dir, "fixtures")
    source_root = Path.expand("fixtures", __DIR__)

    for version <- IssueFixtureLiterals.versions(),
        filename <- Map.keys(IssueFixtureLiterals.files(version)) do
      target = Path.join([fixture_root, version, "issues", filename])
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join([source_root, version, "issues", filename]), target)
    end

    %{fixture_root: fixture_root}
  end

  test "a concurrent generator cleanly refuses the held fixture lock", %{fixture_root: root} do
    parent = self()

    first =
      Task.async(fn ->
        IssueFixtureGenerator.run(
          fixture_root: root,
          after_lock: fn ->
            send(parent, :fixture_lock_held)

            receive do
              :release_fixture_lock -> :ok
            end
          end
        )
      end)

    assert_receive :fixture_lock_held
    assert {:error, :locked} = IssueFixtureGenerator.run(fixture_root: root)

    send(first.pid, :release_fixture_lock)
    assert :ok = Task.await(first)
    assert_current_literals(root)
    assert transaction_artifacts(root) == []
  end

  test "a failed install rolls every fixture back", %{fixture_root: root} do
    before = fixture_bytes(root)

    rename = fn phase, source, target ->
      count = Process.get(:fixture_install_count, 0)

      if phase == :installing and count == 2 do
        {:error, :injected_failure}
      else
        if phase == :installing, do: Process.put(:fixture_install_count, count + 1)
        File.rename(source, target)
      end
    end

    assert_raise RuntimeError, ~r/fixture replacement failed/, fn ->
      IssueFixtureGenerator.run(fixture_root: root, rename: rename)
    end

    assert fixture_bytes(root) == before
    assert_current_literals(root)
    assert transaction_artifacts(root) == []
  end

  test "the next invocation recovers an interrupted backup transaction", %{fixture_root: root} do
    [target | _targets] = root |> fixture_bytes() |> Map.keys() |> Enum.sort()
    template = Path.join(root, ".issue-fixtures.XXXXXXXX")
    {transaction_root, 0} = System.cmd("mktemp", ["-d", template])
    transaction_root = String.trim(transaction_root)
    backup = Path.join([transaction_root, "backup", Path.relative_to(target, root)])
    File.mkdir_p!(Path.dirname(backup))
    File.rename!(target, backup)

    File.write!(Path.join(root, ".issue-fixtures.lock"), "99999999")

    File.write!(
      Path.join(root, ".issue-fixtures.journal"),
      JSON.encode!(%{
        "phase" => "backing_up",
        "transaction_root" => transaction_root
      })
    )

    assert :ok = IssueFixtureGenerator.run(fixture_root: root)
    assert_current_literals(root)
    assert transaction_artifacts(root) == []
  end

  defp assert_current_literals(root) do
    for version <- IssueFixtureLiterals.versions(),
        {filename, literal} <- IssueFixtureLiterals.files(version) do
      target = Path.join([root, version, "issues", filename])
      assert File.read!(target) == JSON.encode!(literal)
    end
  end

  defp fixture_bytes(root) do
    Map.new(
      for version <- IssueFixtureLiterals.versions(),
          filename <- Map.keys(IssueFixtureLiterals.files(version)) do
        target = Path.join([root, version, "issues", filename])
        {target, File.read!(target)}
      end
    )
  end

  defp transaction_artifacts(root), do: Path.wildcard(Path.join(root, ".issue-fixtures*"))
end
