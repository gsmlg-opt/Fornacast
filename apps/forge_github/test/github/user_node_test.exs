defmodule ForgeGitHub.UserNodeTest do
  use ExUnit.Case, async: true

  test "retains optional opaque node from authenticated user JSON" do
    assert {:ok, user} =
             ForgeGitHub.User.from_json(%{
               "id" => 123,
               "login" => "alice",
               "node_id" => "U_not-derived"
             })

    assert Map.get(user, :node_id) == "U_not-derived"
    assert {:ok, absent} = ForgeGitHub.User.from_json(%{"id" => 123, "login" => "alice"})
    assert Map.get(absent, :node_id) == nil
  end

  test "node parser validates exact byte boundary and trimmed UTF8" do
    assert {:ok, user} =
             ForgeGitHub.User.from_json(%{
               "id" => 123,
               "login" => "alice",
               "node_id" => String.duplicate("n", 512)
             })

    assert byte_size(Map.fetch!(user, :node_id)) == 512

    for node <- ["", " padded", "padded ", <<255>>, "bad\0node", String.duplicate("n", 513)] do
      assert {:error, :invalid_response} =
               ForgeGitHub.User.from_json(%{"id" => 123, "login" => "alice", "node_id" => node})
    end
  end
end
