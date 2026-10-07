defmodule ForgeBlobs.DigestLockTest do
  use ExUnit.Case, async: false

  test "a joined filesystem actor retains the digest lock after its coordinator dies" do
    digest = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    caller = self()

    coordinator =
      spawn(fn ->
        owner = self()

        ForgeBlobs.with_digest_lock(digest, fn ->
          actor =
            spawn(fn ->
              ForgeBlobs.with_digest_lock(digest, owner, fn ->
                send(caller, {:joined, self()})

                receive do
                  :finish -> :ok
                end
              end)
            end)

          send(caller, {:coordinator, owner, actor})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:coordinator, ^coordinator, actor}
    assert_receive {:joined, ^actor}
    coordinator_ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :killed}
    lock = {{ForgeBlobs, :digest, digest}, self()}
    refute :global.set_lock(lock, [node()], 0)
    actor_ref = Process.monitor(actor)
    send(actor, :finish)
    assert_receive {:DOWN, ^actor_ref, :process, ^actor, :normal}
    assert :global.set_lock(lock, [node()], 0)
    :global.del_lock(lock, [node()])
  end
end
