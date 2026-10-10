defmodule ForgeImports.TestSupport.LFSImportFixture do
  import ExUnit.Assertions

  alias ForgeImports.GitHub.LFSImporter
  alias Fornacast.Repo

  def complete!(item, run), do: complete!(item, run, 20)

  defp complete!(item, run, remaining) when remaining > 0 do
    transfer = fn _, _, _ -> {:error, :unexpected_fixture_lfs_objects} end

    case LFSImporter.advance(item, run, transfer, fn -> :ok end) do
      {state, checkpoint} when state in [:complete, :incomplete] ->
        item =
          item
          |> Ecto.Changeset.change(checkpoint: checkpoint)
          |> Repo.update!()

        if state == :complete do
          assert LFSImporter.complete?(item)
          item
        else
          complete!(item, run, remaining - 1)
        end

      {:error, reason} ->
        flunk("fixture LFS import failed: #{inspect(reason)}")
    end
  end

  defp complete!(_item, _run, 0), do: flunk("fixture LFS import did not complete")
end
