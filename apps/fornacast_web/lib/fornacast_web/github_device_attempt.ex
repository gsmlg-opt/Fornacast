defmodule FornacastWeb.GitHubDeviceAttempt do
  @moduledoc false

  @derive {Inspect, only: [:id, :status, :interval]}
  defstruct [
    :id,
    :status,
    :device_code,
    :client_id,
    :user_code,
    :verification_uri,
    :expires_at,
    :next_poll_at,
    :interval,
    :claim_id,
    :references,
    :error
  ]

  def transition(_attempt, :begin, _now) do
    attempt = %__MODULE__{id: reference(), status: :starting}
    {{:ok, attempt.id}, attempt}
  end

  def transition(
        %__MODULE__{id: id, status: :starting} = attempt,
        {:authorize, id, grant, client_id, references},
        now
      ) do
    {:ok,
     %{
       attempt
       | status: :pending,
         device_code: grant.device_code,
         client_id: client_id,
         user_code: grant.user_code,
         verification_uri: grant.verification_uri,
         expires_at: now + grant.expires_in * 1_000,
         next_poll_at: now + grant.interval * 1_000,
         interval: grant.interval,
         references: references
     }}
  end

  def transition(nil, :view, _now), do: {{:ok, nil}, nil}

  def transition(%__MODULE__{} = attempt, operation, now) do
    if expired?(attempt, now) do
      expired = terminal(attempt, :expired, :expired_token)

      if operation == :view,
        do: {{:ok, public(expired, now)}, expired},
        else: {{:error, :expired_token}, expired}
    else
      active_transition(attempt, operation, now)
    end
  end

  def transition(attempt, _operation, _now), do: {{:error, :stale}, attempt}

  defp active_transition(attempt, :view, now), do: {{:ok, public(attempt, now)}, attempt}

  defp active_transition(%{id: id, status: :pending} = attempt, {:claim, id}, now) do
    if now < attempt.next_poll_at do
      {{:wait, seconds(attempt.next_poll_at - now)}, attempt}
    else
      claim_id = reference()
      claim = %{id: claim_id, device_code: attempt.device_code, client_id: attempt.client_id}
      {{:ok, claim}, %{attempt | status: :polling, claim_id: claim_id}}
    end
  end

  defp active_transition(%{id: id, status: :polling} = attempt, {:claim, id}, _now),
    do: {{:wait, attempt.interval}, attempt}

  defp active_transition(%{id: id, status: :complete} = attempt, {:claim, id}, _now),
    do: {{:done, :complete}, attempt}

  defp active_transition(
         %{id: id, status: :polling, claim_id: claim} = attempt,
         {:pending, id, claim, interval},
         now
       )
       when is_integer(interval) and interval > 0 do
    interval = max(interval, attempt.interval)

    {:ok,
     %{
       attempt
       | status: :pending,
         claim_id: nil,
         interval: interval,
         next_poll_at: now + interval * 1_000
     }}
  end

  defp active_transition(
         %{id: id, status: :polling, claim_id: claim} = attempt,
         {:check, id, claim},
         _now
       ),
       do: {{:ok, attempt.references}, attempt}

  defp active_transition(
         %{id: id, status: :polling, claim_id: claim} = attempt,
         {:prepare_save, id, claim},
         _now
       ),
       do: {:ok, %{attempt | status: :saving}}

  # A save admitted before the deadline may finish after it. The request-side
  # user lock serializes this reservation with cancellation and session logout.
  defp active_transition(
         %{id: id, status: :saving, claim_id: claim} = attempt,
         {:complete, id, claim},
         _now
       ),
       do: {:ok, terminal(attempt, :complete)}

  defp active_transition(%{id: id, status: status} = attempt, {:cancel, id}, _now)
       when status in [:starting, :pending, :polling],
       do: {:ok, terminal(attempt, :cancelled)}

  defp active_transition(%{id: id, status: status} = attempt, {:fail, id, reason}, _now)
       when status in [:starting, :pending, :polling, :saving],
       do: {:ok, terminal(attempt, :failed, reason)}

  defp active_transition(attempt, _operation, _now), do: {{:error, :stale}, attempt}

  defp public(attempt, now) do
    %{
      id: attempt.id,
      status: attempt.status,
      user_code: attempt.user_code,
      verification_uri: attempt.verification_uri,
      interval: attempt.interval || 5,
      expires_in: if(attempt.expires_at, do: max(seconds(attempt.expires_at - now), 0), else: 0),
      error: attempt.error
    }
  end

  defp expired?(%{status: status, expires_at: deadline}, now)
       when status in [:pending, :polling] and is_integer(deadline), do: now >= deadline

  defp expired?(_attempt, _now), do: false

  defp terminal(attempt, status, error \\ nil),
    do: %{
      attempt
      | status: status,
        error: error,
        device_code: nil,
        claim_id: nil,
        references: nil
    }

  defp seconds(milliseconds), do: div(milliseconds + 999, 1_000)
  defp reference, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
