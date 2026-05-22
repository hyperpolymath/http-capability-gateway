# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# HttpCapabilityGateway.CircuitBreaker — ETS-backed circuit breaker FSM for backends.
#
# Implements the three-state circuit breaker pattern (closed/open/half_open)
# to prevent cascading failures when backend services become unavailable.
# The K9Contract module's :circuit_break breach policy delegates to this
# module to trip circuits for degraded routes.
#
# VeriSimDB integration: circuit-open events are asynchronously appended to
# the capgw:audit collection via HttpCapabilityGateway.VeriSimDB for forensic
# replay and Hypatia pattern analysis.

defmodule HttpCapabilityGateway.CircuitBreaker do
  @moduledoc """
  Circuit breaker finite state machine (FSM) for backend and route protection.

  Implements the standard three-state circuit breaker pattern backed by ETS for
  O(1) hot-path state lookups and a GenServer for state transition management.
  This prevents cascading failures when backends become unavailable — instead
  of hammering a dead backend with requests (which delays every caller and can
  worsen the failure), the circuit breaker "trips open" and immediately rejects
  requests to that backend until it has had time to recover.

  ## FSM States

  The circuit breaker for each registered backend transitions through three states:

  ```
    ┌──────────────────────────────────────────────────────────┐
    │                                                          │
    │   ┌──────────┐  failure >= threshold  ┌──────────┐      │
    │   │  CLOSED  │ ─────────────────────> │   OPEN   │      │
    │   │ (normal) │                        │ (reject) │      │
    │   └──────────┘                        └──────────┘      │
    │        ^                                   │            │
    │        │ success                           │ timeout    │
    │        │                                   v            │
    │        │                             ┌───────────┐      │
    │        └──────────────────────────── │ HALF-OPEN │      │
    │                                      │  (probe)  │      │
    │              failure                 └───────────┘      │
    │              ┌───────────────────────────────┘           │
    │              v                                           │
    │         ┌──────────┐                                    │
    │         │   OPEN   │ (timer resets)                     │
    │         └──────────┘                                    │
    └──────────────────────────────────────────────────────────┘
  ```

  - **Closed** (normal operation): All requests flow through. Consecutive failures
    are tracked. When failures reach the configured `failure_threshold`, the circuit
    transitions to Open.
  - **Open** (blocking): All requests are immediately rejected. A timer
    (`half_open_after_ms`) schedules a transition to Half-Open for recovery probing.
  - **Half-Open** (probing): Exactly ONE request is allowed through as a probe.
    If it succeeds, the circuit closes (reset to normal). If it fails, the circuit
    re-opens and the timer restarts.

  ## Architecture

  Two components work together:

  - **ETS table** (`:gateway_circuit_breaker`): Stores per-backend state tuples for
    O(1) reads on the hot path. The `allow?/1` function reads directly from ETS
    without going through the GenServer, so request latency is unaffected by circuit
    breaker checks (~0.5us per lookup).
  - **GenServer** (`HttpCapabilityGateway.CircuitBreaker`): Manages state transitions,
    failure counting, and `Process.send_after/3` timers for half-open probing. All
    writes go through the GenServer to serialize transitions and prevent races.

  ## Configuration

  Per-backend circuit breakers are configured with:

  - `failure_threshold` — Consecutive failures before tripping open (default: 5)
  - `half_open_after_ms` — Milliseconds before probing a tripped backend (default: 30,000)

  Override defaults via application config:

      config :http_capability_gateway, :circuit_breaker,
        failure_threshold: 5,
        half_open_after_ms: 30_000

  ## Integration with K9 Contracts

  The `K9Contract` module's `:circuit_break` breach policy calls `trip/1` when a
  contract's breach threshold is exceeded. This provides automatic circuit breaking
  based on SLA violations without requiring explicit failure recording.

  ## Integration with Gateway Pipeline

  The gateway calls `allow?/1` before proxying requests to backends. If the circuit
  is open, the request is rejected with 503 Service Unavailable without consuming
  backend resources.

  ## ETS Table Schema

    - Name: `:gateway_circuit_breaker`
    - Type: `:set`
    - Key: `backend_name :: String.t()`
    - Value: `{state_atom, failure_count, opened_at}`
    - Options: `[:named_table, :public, :set, read_concurrency: true]`

  ## Telemetry Events

    - `[:http_capability_gateway, :circuit_breaker, :trip]` — Circuit opened
    - `[:http_capability_gateway, :circuit_breaker, :recover]` — Circuit closed from half-open
    - `[:http_capability_gateway, :circuit_breaker, :reject]` — Request rejected by open circuit
    - `[:http_capability_gateway, :circuit_breaker, :half_open]` — Circuit transitioned to half-open
  """

  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Type Specifications
  # ---------------------------------------------------------------------------

  @typedoc """
  Circuit breaker state for a single backend.

  - `state` — Current FSM state: `:closed`, `:open`, or `:half_open`.
  - `failure_count` — Number of consecutive failures since last success.
  - `opened_at` — UTC DateTime when the circuit last opened. `nil` when closed.
  - `config` — Per-backend circuit breaker configuration.
  """
  @type breaker_state :: %{
          state: :closed | :open | :half_open,
          failure_count: non_neg_integer(),
          opened_at: DateTime.t() | nil,
          config: breaker_config()
        }

  @typedoc """
  Per-backend circuit breaker configuration.

  - `failure_threshold` — Consecutive failures required to trip the circuit.
  - `half_open_after_ms` — Milliseconds to wait before probing a tripped backend.
  """
  @type breaker_config :: %{
          failure_threshold: pos_integer(),
          half_open_after_ms: pos_integer()
        }

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  # ETS table name for O(1) hot-path lookups. The table is :named_table,
  # :public (readable from any process without GenServer call), and :set
  # (one entry per backend keyed by name string).
  @ets_table :gateway_circuit_breaker

  # Default configuration applied when a backend is registered or tripped
  # without specifying circuit breaker parameters. These are conservative
  # defaults suitable for most backends — 5 consecutive failures before
  # tripping, 30s recovery wait.
  @default_config %{
    failure_threshold: 5,
    half_open_after_ms: 30_000
  }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Start the circuit breaker GenServer under a supervisor.

  Creates the ETS table on init and is ready to accept requests immediately
  after starting. Should be placed in the supervision tree BEFORE the HTTP
  server so the ETS table exists before the first request arrives.

  ## Options

  No options are currently supported.

  ## Examples

      iex> {:ok, pid} = CircuitBreaker.start_link([])
      iex> is_pid(pid)
      true
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check whether a backend's circuit allows traffic.

  This is the hot-path function called on every request before proxying.
  It reads directly from ETS (no GenServer call) for O(1) performance (~0.5us).
  The gateway calls this after policy evaluation but before forwarding to
  the backend.

  ## Parameters

    - `backend_name` — The backend identifier string (e.g., "default",
      "user-api", or a route pattern like "/api/users/*").

  ## Returns

    - `true` — Circuit is closed or half-open; the request may proceed.
    - `false` — Circuit is open; the backend is unavailable and the request
      should be rejected.

  ## Behaviour by State

    - **Closed**: Returns `true` (normal operation).
    - **Half-Open**: Returns `true` (one probe request allowed through).
    - **Open**: Returns `false` (reject immediately).
    - **Unregistered**: Returns `true` (unregistered backends are treated as
      closed — circuit breaking is opt-in).

  ## Examples

      iex> CircuitBreaker.allow?("default")
      true

      iex> CircuitBreaker.allow?("dead-backend")
      false
  """
  @spec allow?(String.t()) :: boolean()
  def allow?(backend_name) when is_binary(backend_name) do
    case :ets.lookup(@ets_table, backend_name) do
      [{^backend_name, :open, _failure_count, _opened_at}] ->
        # Emit telemetry for rejected request so dashboards can track
        # how many requests are being fast-failed by the circuit breaker.
        :telemetry.execute(
          [:http_capability_gateway, :circuit_breaker, :reject],
          %{count: 1},
          %{backend: backend_name}
        )

        false

      _other ->
        # :closed, :half_open, or not registered (unregistered backends
        # are treated as closed — the circuit breaker is opt-in).
        true
    end
  end

  # Fallback for non-string backend identifiers — always allow.
  # This handles edge cases where a nil or atom backend name is passed.
  def allow?(_), do: true

  @doc """
  Manually trip the circuit breaker for a backend.

  Called by `K9Contract.execute_breach_policy/3` when the `:circuit_break`
  breach policy is triggered, or can be called directly for administrative
  circuit tripping. Sets the backend's circuit to `:open` immediately,
  regardless of the current failure count.

  If the backend is not yet registered, it is auto-registered with default
  config before tripping.

  ## Parameters

    - `backend_name` — The backend identifier string.

  ## Returns

    - `:ok` — Circuit tripped successfully.

  ## Examples

      iex> CircuitBreaker.trip("user-api")
      :ok
  """
  @spec trip(String.t()) :: :ok
  def trip(backend_name) when is_binary(backend_name) do
    GenServer.cast(__MODULE__, {:trip, backend_name})
  end

  @doc """
  Record a successful operation for a backend.

  Called after a request is successfully proxied to a backend. Resets the
  failure counter and, if the circuit was half-open (probing), transitions
  it back to closed (normal operation).

  ## Parameters

    - `backend_name` — The backend identifier string.

  ## Returns

    - `:ok` — Always succeeds. No-op if the backend is not registered.

  ## State Transitions

    - **Closed** -> Closed (failure_count reset to 0)
    - **Half-Open** -> Closed (circuit recovered, failure_count reset to 0)
    - **Open** -> Open (no transition; open circuits ignore successes)

  ## Examples

      iex> CircuitBreaker.record_success("user-api")
      :ok
  """
  @spec record_success(String.t()) :: :ok
  def record_success(backend_name) when is_binary(backend_name) do
    GenServer.cast(__MODULE__, {:record_success, backend_name})
  end

  @doc """
  Record a failed operation for a backend.

  Called after a request to a backend fails (timeout, connection refused,
  5xx response, etc.). Increments the consecutive failure counter. If the
  counter reaches the configured `failure_threshold`, the circuit trips open.

  ## Parameters

    - `backend_name` — The backend identifier string.

  ## Returns

    - `:ok` — Always succeeds. No-op if the backend is not registered.

  ## State Transitions

    - **Closed** + failures < threshold -> Closed (failure_count incremented)
    - **Closed** + failures >= threshold -> Open (circuit trips, timer starts)
    - **Half-Open** -> Open (probe failed, circuit re-opens, timer restarts)
    - **Open** -> Open (no change; failures during open state are ignored)

  ## Examples

      iex> CircuitBreaker.record_failure("user-api")
      :ok
  """
  @spec record_failure(String.t()) :: :ok
  def record_failure(backend_name) when is_binary(backend_name) do
    GenServer.cast(__MODULE__, {:record_failure, backend_name})
  end

  @doc """
  Return the current circuit breaker state for a specific backend.

  Reads directly from ETS for O(1) access. Returns state details including
  the FSM state, failure count, and when the circuit was opened (if applicable).

  ## Parameters

    - `backend_name` — The backend identifier string.

  ## Returns

    - `%{state: atom(), failure_count: integer(), opened_at: DateTime.t() | nil}`
      for registered backends.
    - `%{state: :closed, failure_count: 0, opened_at: nil}` for unregistered
      backends (default state).

  ## Examples

      iex> CircuitBreaker.status("user-api")
      %{state: :closed, failure_count: 0, opened_at: nil}

      iex> CircuitBreaker.status("dead-backend")
      %{state: :open, failure_count: 5, opened_at: ~U[2026-02-28 12:00:00Z]}
  """
  @spec status(String.t()) :: map()
  def status(backend_name) when is_binary(backend_name) do
    case :ets.lookup(@ets_table, backend_name) do
      [{^backend_name, state, failure_count, opened_at}] ->
        %{state: state, failure_count: failure_count, opened_at: opened_at}

      [] ->
        %{state: :closed, failure_count: 0, opened_at: nil}
    end
  end

  @doc """
  Return the current circuit breaker states for ALL registered backends.

  Reads directly from ETS for a consistent snapshot. Useful for dashboards,
  monitoring, and debugging.

  ## Returns

  A map of backend names to their current breaker state:

      %{
        "user-api" => %{state: :closed, failure_count: 0, opened_at: nil},
        "dead-backend" => %{state: :open, failure_count: 5, opened_at: ~U[...]}
      }

  ## Examples

      iex> CircuitBreaker.all_states()
      %{"default" => %{state: :closed, failure_count: 0, opened_at: nil}}
  """
  @spec all_states() :: %{String.t() => map()}
  def all_states do
    if :ets.whereis(@ets_table) != :undefined do
      @ets_table
      |> :ets.tab2list()
      |> Enum.into(%{}, fn {name, state, failure_count, opened_at} ->
        {name, %{state: state, failure_count: failure_count, opened_at: opened_at}}
      end)
    else
      %{}
    end
  end

  @doc """
  Reset a backend's circuit breaker to the closed state.

  Administrative function for manual recovery. Useful when an operator has
  confirmed that a backend is healthy and wants to immediately resume traffic
  without waiting for the half-open probe cycle.

  ## Parameters

    - `backend_name` — The backend identifier string.

  ## Returns

    - `:ok` — Circuit reset to closed.

  ## Examples

      iex> CircuitBreaker.reset("dead-backend")
      :ok
  """
  @spec reset(String.t()) :: :ok
  def reset(backend_name) when is_binary(backend_name) do
    GenServer.call(__MODULE__, {:reset, backend_name})
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @doc false
  @impl true
  def init(_opts) do
    # Create the ETS table for O(1) hot-path reads. The table is:
    # - :named_table — accessible by name from any process
    # - :public — readable without going through the GenServer
    # - :set — one entry per backend (keyed by name)
    # - read_concurrency: true — optimized for concurrent reads (gateway pipeline)
    #
    # Table schema: {backend_name, state_atom, failure_count, opened_at}
    :ets.new(@ets_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    Logger.info("CircuitBreaker started with ETS table #{@ets_table}")

    # GenServer state holds per-backend configs (not stored in ETS because
    # they're only needed during transitions, not on the hot-path).
    # Also holds timer references so we can cancel pending half-open timers
    # when a backend is manually reset.
    {:ok, %{configs: %{}, timers: %{}}}
  end

  @doc false
  @impl true
  def handle_call({:reset, backend_name}, _from, state) do
    # Cancel any pending half-open timer for this backend.
    state = cancel_timer(state, backend_name)

    # Reset to closed with zero failures.
    :ets.insert(@ets_table, {backend_name, :closed, 0, nil})

    Logger.info("CircuitBreaker manually reset #{backend_name} to closed")

    :telemetry.execute(
      [:http_capability_gateway, :circuit_breaker, :recover],
      %{failure_count: 0},
      %{backend: backend_name, reason: :manual_reset}
    )

    {:reply, :ok, state}
  end

  @doc false
  @impl true
  def handle_cast({:trip, backend_name}, state) do
    # Manual trip — set circuit to open immediately.
    config = get_backend_config(state, backend_name)
    now = DateTime.utc_now()

    # Get current failure count if registered, otherwise use threshold.
    failure_count =
      case :ets.lookup(@ets_table, backend_name) do
        [{^backend_name, _state, count, _opened_at}] -> max(count, config.failure_threshold)
        [] -> config.failure_threshold
      end

    :ets.insert(@ets_table, {backend_name, :open, failure_count, now})

    Logger.warning(
      "CircuitBreaker #{backend_name}: manually tripped to open " <>
        "(failure_count=#{failure_count})"
    )

    :telemetry.execute(
      [:http_capability_gateway, :circuit_breaker, :trip],
      %{failure_count: failure_count},
      %{backend: backend_name, reason: :manual_trip}
    )

    # Ensure config is stored for this backend.
    new_configs = Map.put_new(state.configs, backend_name, config)

    # Schedule transition to half-open after the configured timeout.
    state = %{state | configs: new_configs}
    state = schedule_half_open(state, backend_name, config.half_open_after_ms)
    {:noreply, state}
  end

  @doc false
  @impl true
  def handle_cast({:record_success, backend_name}, state) do
    case :ets.lookup(@ets_table, backend_name) do
      [{^backend_name, :half_open, _failure_count, _opened_at}] ->
        # Half-open probe succeeded: close the circuit (recovery complete).
        # Reset failure count to zero — the backend has proven it can handle
        # at least one request, so we give it a clean slate.
        :ets.insert(@ets_table, {backend_name, :closed, 0, nil})

        Logger.info("CircuitBreaker #{backend_name}: half_open -> closed (probe succeeded)")

        :telemetry.execute(
          [:http_capability_gateway, :circuit_breaker, :recover],
          %{failure_count: 0},
          %{backend: backend_name, reason: :probe_success}
        )

      [{^backend_name, :closed, _failure_count, _opened_at}] ->
        # Closed circuit success: reset failure count to zero. Even a single
        # success breaks the consecutive failure chain, preventing false trips
        # from intermittent errors.
        :ets.insert(@ets_table, {backend_name, :closed, 0, nil})

      _other ->
        # Open state or unregistered: no-op. We don't transition from open to
        # closed on success because no requests should reach an open backend
        # through the normal gateway pipeline.
        :ok
    end

    {:noreply, state}
  end

  @doc false
  @impl true
  def handle_cast({:record_failure, backend_name}, state) do
    config = get_backend_config(state, backend_name)

    case :ets.lookup(@ets_table, backend_name) do
      [{^backend_name, :closed, failure_count, _opened_at}] ->
        new_count = failure_count + 1

        if new_count >= config.failure_threshold do
          # Threshold reached: trip the circuit open.
          now = DateTime.utc_now()
          :ets.insert(@ets_table, {backend_name, :open, new_count, now})

          Logger.warning(
            "CircuitBreaker #{backend_name}: closed -> open " <>
              "(#{new_count} consecutive failures >= threshold #{config.failure_threshold})"
          )

          :telemetry.execute(
            [:http_capability_gateway, :circuit_breaker, :trip],
            %{failure_count: new_count},
            %{backend: backend_name, threshold: config.failure_threshold}
          )

          # Async audit: persist circuit-open event to VeriSimDB (capgw:audit)
          HttpCapabilityGateway.VeriSimDB.audit_circuit_open(backend_name)

          # Schedule transition to half-open after the configured timeout.
          state = schedule_half_open(state, backend_name, config.half_open_after_ms)
          {:noreply, state}
        else
          # Below threshold: increment failure count, stay closed.
          :ets.insert(@ets_table, {backend_name, :closed, new_count, nil})

          Logger.debug(
            "CircuitBreaker #{backend_name}: failure #{new_count}/#{config.failure_threshold}"
          )

          {:noreply, state}
        end

      [{^backend_name, :half_open, _failure_count, _opened_at}] ->
        # Half-open probe failed: re-open the circuit and restart the timer.
        now = DateTime.utc_now()
        failure_count = config.failure_threshold
        :ets.insert(@ets_table, {backend_name, :open, failure_count, now})

        Logger.warning(
          "CircuitBreaker #{backend_name}: half_open -> open (probe failed)"
        )

        :telemetry.execute(
          [:http_capability_gateway, :circuit_breaker, :trip],
          %{failure_count: failure_count},
          %{backend: backend_name, threshold: config.failure_threshold}
        )

        state = schedule_half_open(state, backend_name, config.half_open_after_ms)
        {:noreply, state}

      [] ->
        # Not yet registered — auto-register in closed state with first failure.
        new_configs = Map.put_new(state.configs, backend_name, config)
        :ets.insert(@ets_table, {backend_name, :closed, 1, nil})

        Logger.debug(
          "CircuitBreaker #{backend_name}: auto-registered with failure 1/#{config.failure_threshold}"
        )

        {:noreply, %{state | configs: new_configs}}

      _other ->
        # Already open: no-op (failures during open state are ignored).
        {:noreply, state}
    end
  end

  @doc false
  @impl true
  def handle_info({:half_open, backend_name}, state) do
    # Timer fired: transition from open to half-open if still open.
    # (The backend may have been manually reset in the meantime.)
    case :ets.lookup(@ets_table, backend_name) do
      [{^backend_name, :open, failure_count, _opened_at}] ->
        :ets.insert(@ets_table, {backend_name, :half_open, failure_count, nil})

        Logger.info(
          "CircuitBreaker #{backend_name}: open -> half_open (allowing one probe request)"
        )

        :telemetry.execute(
          [:http_capability_gateway, :circuit_breaker, :half_open],
          %{failure_count: failure_count},
          %{backend: backend_name}
        )

      _other ->
        # Not open anymore (manually reset or already half-open): no-op.
        Logger.debug(
          "CircuitBreaker #{backend_name}: half_open timer fired but state is not :open, ignoring"
        )
    end

    # Remove the timer reference since it has fired.
    new_timers = Map.delete(state.timers, backend_name)
    {:noreply, %{state | timers: new_timers}}
  end

  # Catch-all for unexpected messages (OTP best practice — prevents GenServer
  # crash from stray messages in the mailbox).
  @doc false
  @impl true
  def handle_info(msg, state) do
    Logger.debug("CircuitBreaker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  # Retrieves the circuit breaker config for a backend.
  # Uses per-backend config if registered, otherwise falls back to application
  # config, then to @default_config. This layered approach allows:
  #   1. Per-backend overrides (set during registration)
  #   2. Application-wide overrides (in config.exs)
  #   3. Hardcoded defaults (for zero-config operation)
  @spec get_backend_config(map(), String.t()) :: breaker_config()
  defp get_backend_config(state, backend_name) do
    case Map.get(state.configs, backend_name) do
      nil ->
        # No per-backend config — use application config or defaults.
        app_config = Application.get_env(:http_capability_gateway, :circuit_breaker, %{})

        %{
          failure_threshold:
            Map.get(app_config, :failure_threshold, @default_config.failure_threshold),
          half_open_after_ms:
            Map.get(app_config, :half_open_after_ms, @default_config.half_open_after_ms)
        }

      config ->
        config
    end
  end

  # Schedule a timer to transition a backend from :open to :half_open after
  # the configured delay. Cancels any existing timer for this backend first
  # to prevent duplicate transitions.
  @spec schedule_half_open(map(), String.t(), pos_integer()) :: map()
  defp schedule_half_open(state, backend_name, delay_ms) do
    # Cancel any existing timer for this backend (e.g., if the circuit was
    # already open and a new failure was recorded during half-open).
    state = cancel_timer(state, backend_name)

    # Schedule the half-open transition. Process.send_after/3 returns a timer
    # reference that can be cancelled with Process.cancel_timer/1.
    timer_ref = Process.send_after(self(), {:half_open, backend_name}, delay_ms)

    Logger.debug(
      "CircuitBreaker #{backend_name}: scheduled half_open in #{delay_ms}ms"
    )

    new_timers = Map.put(state.timers, backend_name, timer_ref)
    %{state | timers: new_timers}
  end

  # Cancel a pending half-open timer for a backend, if one exists.
  # Returns the updated state with the timer reference removed.
  @spec cancel_timer(map(), String.t()) :: map()
  defp cancel_timer(state, backend_name) do
    case Map.get(state.timers, backend_name) do
      nil ->
        state

      timer_ref ->
        Process.cancel_timer(timer_ref)
        new_timers = Map.delete(state.timers, backend_name)
        %{state | timers: new_timers}
    end
  end
end
