defmodule ForgeGitHub.RepositoryMetadataProjectionTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.RepositoryMetadataProjection

  test "retains only repository metadata supported by reconciliation" do
    assert {:ok,
            %{
              id: 9,
              node_id: "R_9",
              name: "forge",
              description: nil,
              visibility: :private,
              default_branch: "main",
              archived: false,
              updated_at: ~U[2026-09-14 05:00:00Z]
            }} =
             RepositoryMetadataProjection.from_remote(%{
               id: 9,
               node_id: "R_9",
               name: "forge",
               description: nil,
               visibility: :private,
               default_branch: "main",
               archived: false,
               updated_at: ~U[2026-09-14 05:00:00Z],
               ignored: "not persisted"
             })
  end

  test "rejects canonical repository fields with invalid types or values" do
    for {field, value} <- [
          {:id, 0},
          {:node_id, ""},
          {:name, ""},
          {:description, 42},
          {:visibility, :unlisted},
          {:default_branch, ""},
          {:archived, "false"},
          {:updated_at, "2026-09-14T05:00:00Z"}
        ] do
      assert {:error, :invalid_remote_repository} =
               RepositoryMetadataProjection.from_remote(valid_remote() |> Map.put(field, value))
    end
  end

  test "rejects a non-UTC repository timestamp" do
    timestamp = %DateTime{
      year: 2026,
      month: 9,
      day: 14,
      hour: 5,
      minute: 0,
      second: 0,
      microsecond: {0, 0},
      time_zone: "Etc/GMT+1",
      zone_abbr: "-01",
      utc_offset: -3_600,
      std_offset: 0,
      calendar: Calendar.ISO
    }

    assert {:error, :invalid_remote_repository} =
             RepositoryMetadataProjection.from_remote(
               valid_remote()
               |> Map.put(:updated_at, timestamp)
             )
  end

  defp valid_remote do
    %{
      id: 9,
      node_id: "R_9",
      name: "forge",
      description: nil,
      visibility: :private,
      default_branch: "main",
      archived: false,
      updated_at: ~U[2026-09-14 05:00:00Z]
    }
  end
end
