defmodule FornacastWeb.GitHubDeviceAttemptTest do
  use ExUnit.Case, async: true

  alias FornacastWeb.GitHubDeviceAttempt, as: Attempt

  @grant %{
    device_code: "server-only-device-secret",
    user_code: "ABCD-EFGH",
    verification_uri: "https://github.com/login/device",
    expires_in: 900,
    interval: 5
  }

  test "the browser projection omits device secrets and enforces the polling interval" do
    {{:ok, id}, state} = Attempt.transition(nil, :begin, 0)
    {:ok, state} = Attempt.transition(state, {:authorize, id, @grant, "client", []}, 0)
    {{:ok, public}, ^state} = Attempt.transition(state, :view, 1_000)
    assert public.user_code == "ABCD-EFGH"
    refute inspect(public) =~ @grant.device_code
    refute inspect(state) =~ @grant.device_code
    assert {{:wait, 4}, ^state} = Attempt.transition(state, {:claim, id}, 1_000)

    {{:ok, claim}, state} = Attempt.transition(state, {:claim, id}, 5_000)
    assert claim.device_code == @grant.device_code
    assert {{:wait, _}, ^state} = Attempt.transition(state, {:claim, id}, 5_001)

    {:ok, state} = Attempt.transition(state, {:pending, id, claim.id, 10}, 5_001)
    assert {{:wait, 10}, ^state} = Attempt.transition(state, {:claim, id}, 5_002)
    assert {{:ok, _}, _} = Attempt.transition(state, {:claim, id}, 15_001)
  end

  test "cancelled and superseded attempts cannot complete or regain their claim" do
    {{:ok, id}, state} = Attempt.transition(nil, :begin, 0)
    {:ok, state} = Attempt.transition(state, {:authorize, id, @grant, "client", []}, 0)
    {{:ok, claim}, state} = Attempt.transition(state, {:claim, id}, 5_000)
    {:ok, cancelled} = Attempt.transition(state, {:cancel, id}, 5_001)

    assert {{:error, :stale}, ^cancelled} =
             Attempt.transition(cancelled, {:check, id, claim.id}, 5_002)

    {{:ok, new_id}, replacement} = Attempt.transition(state, :begin, 5_003)
    refute new_id == id

    assert {{:error, :stale}, ^replacement} =
             Attempt.transition(replacement, {:complete, id, claim.id}, 5_004)
  end

  test "expiry is checked again before a successful exchange can save an account" do
    {{:ok, id}, state} = Attempt.transition(nil, :begin, 0)
    {:ok, state} = Attempt.transition(state, {:authorize, id, @grant, "client", [:snapshot]}, 0)
    {{:ok, claim}, state} = Attempt.transition(state, {:claim, id}, 5_000)

    assert {{:ok, [:snapshot]}, ^state} =
             Attempt.transition(state, {:check, id, claim.id}, 899_999)

    assert {{:error, :expired_token}, expired} =
             Attempt.transition(state, {:check, id, claim.id}, 900_000)

    refute inspect(expired) =~ @grant.device_code
  end

  test "completion is consumed once and terminal state drops secret material" do
    {{:ok, id}, state} = Attempt.transition(nil, :begin, 0)
    {:ok, state} = Attempt.transition(state, {:authorize, id, @grant, "client", []}, 0)
    {{:ok, claim}, state} = Attempt.transition(state, {:claim, id}, 5_000)
    {:ok, state} = Attempt.transition(state, {:prepare_save, id, claim.id}, 5_001)
    {:ok, state} = Attempt.transition(state, {:complete, id, claim.id}, 900_001)
    assert {{:done, :complete}, ^state} = Attempt.transition(state, {:claim, id}, 5_002)
    assert {{:error, :stale}, ^state} = Attempt.transition(state, {:cancel, id}, 900_002)
    assert {{:error, :stale}, ^state} = Attempt.transition(state, {:fail, id, :stale}, 900_002)
    refute inspect(Map.from_struct(state)) =~ @grant.device_code
  end

  test "expired exchanges cannot reserve a save" do
    {{:ok, id}, state} = Attempt.transition(nil, :begin, 0)
    {:ok, state} = Attempt.transition(state, {:authorize, id, @grant, "client", []}, 0)
    {{:ok, claim}, state} = Attempt.transition(state, {:claim, id}, 5_000)

    assert {{:error, :stale}, ^state} =
             Attempt.transition(state, {:complete, id, claim.id}, 5_001)

    assert {{:error, :expired_token}, _} =
             Attempt.transition(state, {:prepare_save, id, claim.id}, 900_000)
  end

  test "session diagnostics redact authorization messages, failures and event logs" do
    status =
      FornacastWeb.UserSession.SessionState.format_status(%{
        state: %{user_id: 7, github_device: %{device_code: "private-device"}},
        message: {:authorize, "private-device"},
        reason: {:error, "private-access"},
        log: [{:reply, "private-refresh"}]
      })

    assert status.state == %{user_id: 7}
    refute inspect(status) =~ "private-"
  end
end
