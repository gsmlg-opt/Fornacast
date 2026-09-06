defmodule ForgeGitHub.LFS.EgressPolicyTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.LFS.EgressPolicy

  test "accepts only non-empty sets of public addresses for the requested host" do
    assert {:ok, [{203, 0, 114, 10}]} =
             EgressPolicy.resolve_public("objects.example.test",
               resolver: fn "objects.example.test" -> {:ok, [{203, 0, 114, 10}]} end
             )

    for addresses <- [
          [{127, 0, 0, 1}],
          [{169, 254, 169, 254}],
          [{10, 0, 0, 1}],
          [{203, 0, 114, 10}, {192, 168, 1, 1}],
          [{0, 0, 0, 0, 0, 0, 0, 1}]
        ] do
      assert {:error, :unsafe_host} =
               EgressPolicy.resolve_public("objects.example.test",
                 resolver: fn "objects.example.test" -> {:ok, addresses} end
               )
    end
  end

  test "rejects malformed hostnames and bounds DNS resolution by a deadline" do
    for host <- ["", "localhost", "metadata", "bad host", String.duplicate("a", 254)] do
      assert {:error, :unsafe_host} =
               EgressPolicy.resolve_public(host,
                 resolver: fn _host -> flunk("invalid host reached DNS") end
               )
    end

    assert {:error, :timeout} =
             EgressPolicy.resolve_public("objects.example.test",
               deadline: System.monotonic_time(:millisecond),
               resolver: fn _host -> flunk("expired request reached DNS") end
             )
  end
end
