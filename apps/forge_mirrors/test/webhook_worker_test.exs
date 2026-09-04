defmodule ForgeMirrors.WebhookWorkerTest do
  use ExUnit.Case, async: false

  alias Fornacast.Repo
  alias ForgeMirrors.MirrorWebhookDelivery

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "one bounded run claims a batch and commits processor outcomes under its lease" do
    completed = enqueue!(44)
    retried = enqueue!(45)
    failed = enqueue!(46)
    ignored = enqueue!(47)
    deferred = enqueue!(48)

    processor = fn
      %{installation_id: 44} -> :ok
      %{installation_id: 45} -> {:retry, "github_transport", 17}
      %{installation_id: 46} -> {:fail, "invalid_webhook_payload"}
      %{installation_id: 47} -> :ignore
      %{installation_id: 48} -> :defer
    end

    assert {:ok, results} =
             ForgeMirrors.WebhookWorker.run_once("webhook-test", processor: processor)

    assert length(results) == 5
    assert Repo.get!(MirrorWebhookDelivery, completed.id).state == :completed

    retry_row = Repo.get!(MirrorWebhookDelivery, retried.id)
    assert retry_row.state == :pending
    assert retry_row.failure_class == "github_transport"
    assert DateTime.diff(retry_row.next_attempt_at, retry_row.updated_at) in 16..18

    failure_row = Repo.get!(MirrorWebhookDelivery, failed.id)
    assert failure_row.state == :failed
    assert failure_row.failure_class == "invalid_webhook_payload"
    assert failure_row.processed_at

    assert Repo.get!(MirrorWebhookDelivery, ignored.id).state == :ignored
    assert Repo.get!(MirrorWebhookDelivery, deferred.id).state == :pending_unsupported
  end

  test "processor absence and crashes remain retryable without terminal startup exhaustion" do
    unavailable = enqueue!(50)

    assert {:ok, [_]} =
             ForgeMirrors.WebhookWorker.run_once("webhook-test",
               processor: MissingWebhookProcessor,
               default_retry_seconds: 0
             )

    unavailable = Repo.get!(MirrorWebhookDelivery, unavailable.id)
    assert unavailable.state == :pending
    assert unavailable.failure_class == "processor_unavailable"

    assert {:ok, [_]} =
             ForgeMirrors.WebhookWorker.run_once("webhook-test",
               processor: fn _delivery -> raise "boom" end,
               default_retry_seconds: 0
             )

    retrying = Repo.get!(MirrorWebhookDelivery, unavailable.id)
    assert retrying.state == :pending
    assert retrying.failure_class == "processor_crash"
    assert retrying.attempt_count == 2
  end

  test "claimed deliveries start concurrently and processor timeouts finish inside the lease" do
    first = enqueue!(60, "push")
    second = enqueue!(60, "push")
    parent = self()

    run =
      Task.async(fn ->
        receive do: (:run -> :ok)

        ForgeMirrors.WebhookWorker.run_once("webhook-test",
          lease_seconds: 6,
          max_concurrency: 2,
          max_concurrency_per_installation: 2,
          processor_timeout_ms: 500,
          default_retry_seconds: 0,
          processor: fn delivery ->
            send(parent, {:processor_started, delivery.id, self()})

            receive do
              :finish -> :ok
            end
          end
        )
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), run.pid)
    send(run.pid, :run)

    assert_receive {:processor_started, first_id, first_processor}, 1_000
    assert_receive {:processor_started, second_id, second_processor}, 1_000
    assert Enum.sort([first_id, second_id]) == Enum.sort([first.id, second.id])
    refute first_processor == second_processor
    send(first_processor, :finish)
    send(second_processor, :finish)
    assert {:ok, results} = Task.await(run, 1_000)
    assert length(results) == 2
    assert Repo.get!(MirrorWebhookDelivery, first.id).state == :completed
    assert Repo.get!(MirrorWebhookDelivery, second.id).state == :completed

    timed_out = enqueue!(62)
    started = System.monotonic_time(:millisecond)

    assert {:ok, [_]} =
             ForgeMirrors.WebhookWorker.run_once("webhook-test",
               lease_seconds: 6,
               max_concurrency: 1,
               max_internal_attempts: 1,
               processor_timeout_ms: 100,
               default_retry_seconds: 0,
               processor: fn _delivery -> Process.sleep(5_000) end
             )

    assert System.monotonic_time(:millisecond) - started < 1_500
    timed_out = Repo.get!(MirrorWebhookDelivery, timed_out.id)
    assert timed_out.state == :failed
    assert timed_out.internal_failure_count == 1
    assert timed_out.failure_class == "processor_timeout"
  end

  test "a single coordinator task is bounded and reschedules after failure" do
    parent = self()
    name = Module.concat(__MODULE__, "Coordinator#{System.unique_integer([:positive])}")
    runs = :atomics.new(1, [])

    {:ok, coordinator} =
      ForgeMirrors.WebhookWorker.start_link(
        name: name,
        enabled: true,
        interval_ms: 10,
        runner: fn ->
          run = :atomics.add_get(runs, 1, 1)
          send(parent, {:run, self()})

          if run == 1 do
            Process.sleep(30)
            raise "task failed"
          end
        end
      )

    assert_receive {:run, first_pid}, 200
    refute_receive {:run, _other_pid}, 15
    assert_receive {:run, second_pid}, 200
    refute first_pid == second_pid

    GenServer.stop(coordinator)
  end

  test "repeated internal processor contract failures terminate without exhausting retryable outages" do
    invalid = enqueue!(70)

    for _attempt <- 1..2 do
      assert {:ok, [_]} =
               ForgeMirrors.WebhookWorker.run_once("webhook-test",
                 processor: fn _delivery -> :invalid_result end,
                 max_internal_attempts: 2,
                 default_retry_seconds: 0
               )
    end

    invalid = Repo.get!(MirrorWebhookDelivery, invalid.id)
    assert invalid.state == :failed
    assert invalid.failure_class == "processor_invalid_result"
    assert invalid.processed_at

    unavailable = enqueue!(71)

    for _attempt <- 1..3 do
      assert {:ok, [_]} =
               ForgeMirrors.WebhookWorker.run_once("webhook-test",
                 processor: MissingWebhookProcessor,
                 max_internal_attempts: 1,
                 default_retry_seconds: 0
               )
    end

    unavailable = Repo.get!(MirrorWebhookDelivery, unavailable.id)
    assert unavailable.state == :pending
    assert unavailable.attempt_count == 3
    assert unavailable.internal_failure_count == 0
    assert unavailable.failure_class == "processor_unavailable"

    assert {:ok, [_]} =
             ForgeMirrors.WebhookWorker.run_once("webhook-test",
               processor: fn _delivery -> :invalid_result end,
               max_internal_attempts: 2,
               default_retry_seconds: 0
             )

    assert Repo.get!(MirrorWebhookDelivery, unavailable.id).internal_failure_count == 1

    assert {:ok, [_]} =
             ForgeMirrors.WebhookWorker.run_once("webhook-test",
               processor: MissingWebhookProcessor,
               max_internal_attempts: 2,
               default_retry_seconds: 0
             )

    reset = Repo.get!(MirrorWebhookDelivery, unavailable.id)
    assert reset.state == :pending
    assert reset.internal_failure_count == 0

    for _attempt <- 1..2 do
      assert {:ok, [_]} =
               ForgeMirrors.WebhookWorker.run_once("webhook-test",
                 processor: fn _delivery -> :invalid_result end,
                 max_internal_attempts: 2,
                 default_retry_seconds: 0
               )
    end

    exhausted = Repo.get!(MirrorWebhookDelivery, unavailable.id)
    assert exhausted.state == :failed
    assert exhausted.internal_failure_count == 2
  end

  defp enqueue!(installation_id, event \\ "installation") do
    attrs = %{
      delivery_guid: Ecto.UUID.generate(),
      hook_id: 9_001,
      event: event,
      action: "created",
      installation_id: installation_id,
      github_repository_id: nil,
      signature_version: "sha256",
      raw_payload: ~s({"action":"created","installation":{"id":#{installation_id}}})
    }

    assert {:ok, delivery, :enqueued} =
             ForgeMirrors.enqueue_webhook_delivery(attrs, :pending)

    delivery
  end
end
