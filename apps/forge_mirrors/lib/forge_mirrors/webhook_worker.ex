defmodule ForgeMirrors.WebhookWorker do
  @moduledoc """
  Bounded coordinator for the durable webhook inbox.

  Provider-specific normalization is injected at the application boundary so
  `forge_mirrors` retains provider-neutral scheduling and lease ownership.
  """

  use GenServer

  @default_interval_ms 1_000
  @default_lease_seconds 30
  @default_batch_size 25
  @default_max_concurrency 8
  @default_max_internal_attempts 10
  @default_processor_timeout_ms 25_000
  @default_retry_seconds 30
  @lease_persistence_margin_ms 5_000
  @bounded_internal_failures ~w(processor_crash processor_invalid_result processor_timeout)
  @run_option_keys [
    :lease_seconds,
    :batch_size,
    :max_concurrency,
    :max_concurrency_per_installation,
    :max_internal_attempts,
    :processor_timeout_ms,
    :default_retry_seconds,
    :processor
  ]

  def start_link(options) when is_list(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc false
  @spec run_once(String.t(), keyword()) :: {:ok, list()} | {:error, atom()}
  def run_once(owner, options \\ [])

  def run_once(owner, options) when is_binary(owner) and is_list(options) do
    lease_seconds = bounded_option(options, :lease_seconds, @default_lease_seconds, 1, 3_600)
    batch_size = bounded_option(options, :batch_size, @default_batch_size, 1, 100)

    max_concurrency =
      bounded_option(
        options,
        :max_concurrency,
        config(:webhook_worker_max_concurrency, @default_max_concurrency),
        1,
        64
      )

    max_concurrency_per_installation =
      bounded_option(
        options,
        :max_concurrency_per_installation,
        config(:webhook_worker_max_concurrency_per_installation, 1),
        1,
        max_concurrency
      )

    processor_timeout_ms =
      bounded_option(
        options,
        :processor_timeout_ms,
        config(:webhook_worker_processor_timeout_ms, @default_processor_timeout_ms),
        1,
        3_599_000
      )

    unless processor_timeout_ms <= lease_seconds * 1_000 - @lease_persistence_margin_ms do
      raise ArgumentError, "webhook processor timeout must finish inside its lease"
    end

    max_internal_attempts =
      bounded_option(
        options,
        :max_internal_attempts,
        config(:webhook_worker_max_internal_attempts, @default_max_internal_attempts),
        1,
        1_000
      )

    retry_seconds =
      bounded_option(options, :default_retry_seconds, @default_retry_seconds, 0, 86_400)

    processor = Keyword.get(options, :processor)

    with {:ok, deliveries} <-
           ForgeMirrors.claim_webhook_deliveries(
             owner,
             lease_seconds,
             min(batch_size, max_concurrency),
             max_concurrency_per_installation,
             max_internal_attempts
           ) do
      results =
        deliveries
        |> Task.async_stream(
          &invoke_processor(processor, &1, retry_seconds),
          max_concurrency: max_concurrency,
          ordered: true,
          on_timeout: :kill_task,
          timeout: processor_timeout_ms
        )
        |> Stream.zip(deliveries)
        |> Enum.map(fn {task_result, delivery} ->
          result = task_result(task_result, retry_seconds)
          transition = persist_result(delivery, owner, result, max_internal_attempts)
          {delivery.id, transition}
        end)

      {:ok, results}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  def run_once(_owner, _options), do: {:error, :invalid_argument}

  @impl true
  def init(options) do
    owner = "webhook-#{node()}-#{System.unique_integer([:positive])}"
    run_options = Keyword.take(options, @run_option_keys)

    state = %{
      enabled: Keyword.get(options, :enabled, config(:webhook_worker_enabled, true)),
      interval_ms:
        bounded_option(
          options,
          :interval_ms,
          config(:webhook_worker_interval_ms, @default_interval_ms),
          1,
          3_600_000
        ),
      task_supervisor: Keyword.get(options, :task_supervisor, ForgeMirrors.TaskSupervisor),
      runner: Keyword.get(options, :runner, fn -> run_once(owner, run_options) end),
      task_ref: nil
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{task_ref: nil} = state) do
    case Task.Supervisor.start_child(state.task_supervisor, state.runner) do
      {:ok, pid} ->
        {:noreply, %{state | task_ref: Process.monitor(pid)}}

      {:error, _reason} ->
        schedule(state.interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task_ref: ref} = state) do
    schedule(state.interval_ms)
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp invoke_processor(processor, delivery, default_retry_seconds) do
    cond do
      is_function(processor, 1) ->
        normalize_result(processor.(delivery), default_retry_seconds)

      is_atom(processor) and Code.ensure_loaded?(processor) and
          function_exported?(processor, :process, 1) ->
        normalize_result(processor.process(delivery), default_retry_seconds)

      true ->
        {:retry, "processor_unavailable", default_retry_seconds}
    end
  rescue
    _exception -> {:retry, "processor_crash", default_retry_seconds}
  catch
    _kind, _reason -> {:retry, "processor_crash", default_retry_seconds}
  end

  defp normalize_result(:ok, _default_retry_seconds), do: :ok
  defp normalize_result(:ignore, _default_retry_seconds), do: :ignore
  defp normalize_result(:defer, _default_retry_seconds), do: :defer

  defp normalize_result({:retry, failure_class, seconds}, _default_retry_seconds)
       when is_binary(failure_class) and byte_size(failure_class) in 1..255 and
              is_integer(seconds) and seconds in 0..86_400,
       do: {:retry, failure_class, seconds}

  defp normalize_result({:fail, failure_class}, _default_retry_seconds)
       when is_binary(failure_class) and byte_size(failure_class) in 1..255,
       do: {:fail, failure_class}

  defp normalize_result(_invalid, default_retry_seconds),
    do: {:retry, "processor_invalid_result", default_retry_seconds}

  defp task_result({:ok, result}, _default_retry_seconds), do: result

  defp task_result({:exit, _reason}, default_retry_seconds),
    do: {:retry, "processor_timeout", default_retry_seconds}

  defp persist_result(delivery, owner, :ok, _max_internal_attempts),
    do: ForgeMirrors.complete_webhook_delivery(delivery, owner)

  defp persist_result(delivery, owner, :ignore, _max_internal_attempts),
    do: ForgeMirrors.ignore_webhook_delivery(delivery, owner)

  defp persist_result(delivery, owner, :defer, _max_internal_attempts),
    do: ForgeMirrors.defer_webhook_delivery(delivery, owner)

  defp persist_result(delivery, owner, {:fail, failure_class}, _max_internal_attempts),
    do: ForgeMirrors.fail_webhook_delivery(delivery, owner, failure_class)

  defp persist_result(
         delivery,
         owner,
         {:retry, failure_class, seconds},
         max_internal_attempts
       ) do
    internal_failure_count =
      if failure_class in @bounded_internal_failures,
        do: delivery.internal_failure_count + 1,
        else: 0

    if internal_failure_count >= max_internal_attempts do
      ForgeMirrors.fail_webhook_delivery(
        delivery,
        owner,
        failure_class,
        internal_failure_count
      )
    else
      ForgeMirrors.retry_webhook_delivery(
        delivery,
        owner,
        failure_class,
        seconds,
        internal_failure_count
      )
    end
  end

  defp bounded_option(options, key, default, minimum, maximum) do
    value = Keyword.get(options, key, default)

    if is_integer(value) and value >= minimum and value <= maximum,
      do: value,
      else: raise(ArgumentError, "invalid webhook worker option")
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
  defp config(key, default), do: Application.get_env(:forge_mirrors, key, default)
end
