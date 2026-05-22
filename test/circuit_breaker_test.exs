# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.CircuitBreakerTest do
  @moduledoc """
  Unit tests for the circuit breaker FSM.

  Covers the full state machine:
    - closed: normal operation, failure accumulation, trip threshold
    - open: rejects allow? requests, timer transitions to half_open
    - half_open: single probe — success closes, failure re-opens
    - status / all_states / reset public API
    - Unregistered backends (opt-in behaviour)

  The concurrency aspects are covered by test/concurrency_test.exs; this
  file focuses on correctness of each state transition in isolation.
  """

  use ExUnit.Case, async: false

  alias HttpCapabilityGateway.CircuitBreaker

  setup_all do
    case Process.whereis(CircuitBreaker) do
      nil -> {:ok, _} = CircuitBreaker.start_link([])
      _pid -> :ok
    end

    # Short half-open timer for tests. This affects ALL test runs since
    # the config is application-wide; we choose a value short enough to
    # keep tests fast but long enough to observe transitions.
    Application.put_env(:http_capability_gateway, :circuit_breaker, %{
      failure_threshold: 3,
      half_open_after_ms: 200
    })

    :ok
  end

  # Each test uses a unique backend name so tests don't interfere.
  defp unique_backend(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  # Wait for a GenServer cast to propagate to ETS. Calls status/1 after
  # the cast, which serializes through the GenServer mailbox.
  defp await_cast(backend) do
    # A status read doesn't go through the GenServer (it's a direct ETS read),
    # so we issue a synchronous call instead to ensure the cast has been
    # processed. all_states/0 is also direct-ETS; use reset on an unrelated
    # backend as a synchronous GenServer call.
    _ = CircuitBreaker.reset("__unused_sync_marker__")
    CircuitBreaker.status(backend)
  end

  # ── Closed State ──────────────────────────────────────────────────

  describe "closed state" do
    test "unregistered backend is treated as closed and allowed" do
      backend = unique_backend("fresh")
      assert CircuitBreaker.allow?(backend) == true
    end

    test "status of unregistered backend returns default closed" do
      backend = unique_backend("unreg")
      status = CircuitBreaker.status(backend)
      assert status.state == :closed
      assert status.failure_count == 0
      assert status.opened_at == nil
    end

    test "single failure stays closed" do
      backend = unique_backend("one-fail")
      CircuitBreaker.record_failure(backend)
      status = await_cast(backend)

      assert status.state == :closed
      assert status.failure_count == 1
      assert CircuitBreaker.allow?(backend) == true
    end

    test "success resets failure count" do
      backend = unique_backend("reset-count")
      CircuitBreaker.record_failure(backend)
      CircuitBreaker.record_failure(backend)
      _ = await_cast(backend)

      CircuitBreaker.record_success(backend)
      status = await_cast(backend)

      assert status.state == :closed
      assert status.failure_count == 0
    end
  end

  # ── Transition to Open ────────────────────────────────────────────

  describe "transition: closed → open" do
    test "trips open when failure count reaches threshold" do
      backend = unique_backend("trip")

      # Default threshold is 3 (set in setup_all)
      for _ <- 1..3, do: CircuitBreaker.record_failure(backend)
      status = await_cast(backend)

      assert status.state == :open
      assert status.failure_count >= 3
      refute is_nil(status.opened_at)
    end

    test "allow? returns false after trip" do
      backend = unique_backend("trip-reject")

      for _ <- 1..3, do: CircuitBreaker.record_failure(backend)
      _ = await_cast(backend)

      assert CircuitBreaker.allow?(backend) == false
    end

    test "manual trip/1 opens immediately" do
      backend = unique_backend("manual-trip")

      CircuitBreaker.trip(backend)
      status = await_cast(backend)

      assert status.state == :open
      assert CircuitBreaker.allow?(backend) == false
    end

    test "failures below threshold do not trip" do
      backend = unique_backend("sub-threshold")

      for _ <- 1..2, do: CircuitBreaker.record_failure(backend)
      status = await_cast(backend)

      assert status.state == :closed
      assert status.failure_count == 2
      assert CircuitBreaker.allow?(backend) == true
    end
  end

  # ── Open State ────────────────────────────────────────────────────

  describe "open state" do
    test "failures in open state do not change count" do
      backend = unique_backend("open-noop")

      CircuitBreaker.trip(backend)
      status_after_trip = await_cast(backend)

      CircuitBreaker.record_failure(backend)
      CircuitBreaker.record_failure(backend)
      status_after_more = await_cast(backend)

      assert status_after_trip.state == :open
      assert status_after_more.state == :open
      # failure_count shouldn't change from additional failures in open state
      assert status_after_more.failure_count == status_after_trip.failure_count
    end

    test "success in open state does nothing (stays open)" do
      backend = unique_backend("open-success")

      CircuitBreaker.trip(backend)
      _ = await_cast(backend)

      CircuitBreaker.record_success(backend)
      status = await_cast(backend)

      # The circuit should stay open; record_success on :open is a no-op.
      assert status.state == :open
    end
  end

  # ── Transition to Half-Open ───────────────────────────────────────

  describe "transition: open → half_open (timer)" do
    test "transitions to half_open after configured delay" do
      backend = unique_backend("half-timer")

      CircuitBreaker.trip(backend)
      status = await_cast(backend)
      assert status.state == :open

      # Wait for half_open timer (200ms in setup + generous buffer)
      Process.sleep(350)

      status_after = CircuitBreaker.status(backend)
      assert status_after.state == :half_open
    end

    test "allow? returns true in half_open (probe permitted)" do
      backend = unique_backend("half-probe")

      CircuitBreaker.trip(backend)
      Process.sleep(350)

      assert CircuitBreaker.status(backend).state == :half_open
      assert CircuitBreaker.allow?(backend) == true
    end
  end

  # ── Half-Open → Closed (recovery) ─────────────────────────────────

  describe "transition: half_open → closed" do
    test "success in half_open recovers (closes) the circuit" do
      backend = unique_backend("recover")

      CircuitBreaker.trip(backend)
      Process.sleep(350)
      assert CircuitBreaker.status(backend).state == :half_open

      CircuitBreaker.record_success(backend)
      status = await_cast(backend)

      assert status.state == :closed
      assert status.failure_count == 0
      assert CircuitBreaker.allow?(backend) == true
    end
  end

  # ── Half-Open → Open (failed probe) ───────────────────────────────

  describe "transition: half_open → open" do
    test "failure in half_open re-opens the circuit" do
      backend = unique_backend("reopen")

      CircuitBreaker.trip(backend)
      Process.sleep(350)
      assert CircuitBreaker.status(backend).state == :half_open

      CircuitBreaker.record_failure(backend)
      status = await_cast(backend)

      assert status.state == :open
      refute is_nil(status.opened_at)
      assert CircuitBreaker.allow?(backend) == false
    end
  end

  # ── Manual Reset ──────────────────────────────────────────────────

  describe "reset/1" do
    test "reset returns open circuit to closed" do
      backend = unique_backend("reset")

      CircuitBreaker.trip(backend)
      _ = await_cast(backend)
      assert CircuitBreaker.status(backend).state == :open

      assert :ok = CircuitBreaker.reset(backend)

      status = CircuitBreaker.status(backend)
      assert status.state == :closed
      assert status.failure_count == 0
      assert status.opened_at == nil
      assert CircuitBreaker.allow?(backend) == true
    end

    test "reset cancels pending half-open timer" do
      backend = unique_backend("reset-timer")

      CircuitBreaker.trip(backend)
      _ = await_cast(backend)

      # Reset before the timer fires
      CircuitBreaker.reset(backend)

      # Wait past the original timer (200ms)
      Process.sleep(350)

      # State should still be closed — the cancelled timer did not fire.
      status = CircuitBreaker.status(backend)
      assert status.state == :closed
    end
  end

  # ── all_states/0 Snapshot ────────────────────────────────────────

  describe "all_states/0" do
    test "returns map of all registered backends" do
      b1 = unique_backend("all-1")
      b2 = unique_backend("all-2")

      CircuitBreaker.record_failure(b1)
      CircuitBreaker.trip(b2)
      _ = await_cast(b2)

      states = CircuitBreaker.all_states()
      assert is_map(states)
      assert Map.has_key?(states, b1)
      assert Map.has_key?(states, b2)
      assert states[b2].state == :open
    end
  end

  # ── Edge Cases ────────────────────────────────────────────────────

  describe "edge cases" do
    test "allow? with non-string backend returns true (defensive)" do
      assert CircuitBreaker.allow?(nil) == true
      assert CircuitBreaker.allow?(:atom_backend) == true
      assert CircuitBreaker.allow?(12345) == true
    end

    test "empty string backend is handled" do
      # Empty string is a binary; allow? takes the binary clause.
      assert CircuitBreaker.allow?("") == true
    end

    test "record_success on unregistered backend is a no-op (no crash)" do
      backend = unique_backend("success-unreg")
      assert :ok = CircuitBreaker.record_success(backend)
      # The backend remains unregistered (status returns default)
      status = await_cast(backend)
      assert status.state == :closed
      assert status.failure_count == 0
    end
  end
end
