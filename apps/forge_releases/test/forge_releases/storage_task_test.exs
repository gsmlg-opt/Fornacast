defmodule ForgeReleases.StorageTaskTest do
  use ExUnit.Case, async: false

  test "a timed-out filesystem task releases its joined fence without killing the caller" do
    digest = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    caller = self()

    ForgeBlobs.with_digest_lock(digest, fn ->
      assert {:error, :unavailable} =
               ForgeReleases.StorageTask.run(
                 digest,
                 fn ->
                   send(caller, {:filesystem_actor, self()})
                   Process.sleep(:infinity)
                 end,
                 50
               )

      assert_receive {:filesystem_actor, actor}
      refute Process.alive?(actor)
      assert Process.alive?(caller)
    end)

    assert :ok = ForgeBlobs.with_digest_lock(digest, fn -> :ok end)
  end
end
