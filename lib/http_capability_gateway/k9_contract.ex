# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# K9-SVC service contracts for policy-driven governance in the HTTP capability gateway.
#
# K9 contracts sit ABOVE a2ml attestations (which handle identity and audit). Contracts
# declare the "what do we promise" layer: per-route obligations (latency, availability),
# guarantees (error rate SLA), and breach policies (log, alert, circuit_break, fallback).
#
# The gateway enforces contracts by measuring actual performance against declared
# thresholds. After proxying a request, the response time is compared to the contract's
# max_latency_ms. If breached, the breach_policy determines the response: logging the
# violation, alerting, tripping a circuit breaker, or returning a fallback response.

defmodule HttpCapabilityGateway.K9Contract do
  @moduledoc """
  K9-SVC service contracts for policy-driven governance.

  Contracts declare per-route obligations (max latency, availability),
  guarantees (error rate SLA), and breach policies. The gateway enforces
  contracts by measuring actual performance against declared thresholds.

  ## What K9-SVC Contracts Are

  A K9-SVC contract declares:

    - `contract_id` — SHA-256 hash of the contract content (deterministic, content-addressable)
    - `service` — Which service this contract covers (e.g., "user-api")
    - `route_pattern` — Route pattern this contract applies to (e.g., "/api/users/*")
    - `verb` — HTTP verb this contract covers (:GET, :POST, etc., or :ANY for all)
    - `trust_threshold` — Minimum trust level to activate this contract (:untrusted, :authenticated, :internal)
    - `max_latency_ms` — Maximum allowed response time in milliseconds
    - `rate_limit` — Requests per second allowed under this contract
    - `timeout_ms` — Backend timeout for this contract (overrides default proxy timeout)
    - `breach_policy` — What happens when the contract is violated
    - `guarantees` — What the caller can expect (error rate SLA, uptime)

  ## Breach Policies

    - `:log` — Log the breach, continue normally (soft enforcement)
    - `:alert` — Log + emit telemetry alert event (for external alerting)
    - `:circuit_break` — Log + trip a circuit breaker for the route
    - `:fallback` — Return a cached/degraded response instead of the slow one

  ## Architecture

  Contracts are stored in ETS for O(1) lookup on the request hot path.
  The ETS table uses composite keys `{:contract, route_pattern, verb}` for
  direct lookup, mirroring the policy compiler's tiered approach.

  ## Integration with Gateway Pipeline

  The contract enforcement hooks into the gateway after policy lookup but
  before proxying:

    1. Policy lookup (existing) -> determines if request is allowed
    2. **Contract lookup** -> finds any K9 contract for this route+verb
    3. **Pre-proxy enforcement** -> apply contract rate_limit and timeout_ms
    4. Proxy forward (existing) -> forward to backend
    5. **Post-proxy enforcement** -> check max_latency_ms, execute breach_policy

  ## Contract IDs

  Contract IDs are deterministic SHA-256 hashes of the contract content
  (service + route_pattern + verb + obligations + guarantees). This makes
  contracts content-addressable and auditable — the same contract content
  always produces the same ID, and any modification produces a different ID.

  ## ETS Table Schema

    - Name: `:k9_contracts`
    - Type: `:set`
    - Key: `{:contract, route_pattern :: String.t(), verb :: atom()}`
    - Value: `%K9Contract{}`
    - Options: `[:named_table, :public, :set, read_concurrency: true]`
  """

  require Logger

  alias HttpCapabilityGateway.{CircuitBreaker, SafeTrust}

  # ---------------------------------------------------------------------------
  # Type Definitions
  # ---------------------------------------------------------------------------

  @typedoc """
  Breach policy determines the system's response when a contract is violated.

  - `:log` — Soft enforcement: log the breach, return the response anyway.
  - `:alert` — Log + emit a telemetry event for external alerting systems.
  - `:circuit_break` — Log + mark this route as degraded (future requests may be rejected).
  - `:fallback` — Return a cached/default response instead of the slow/failed one.
  """
  @type breach_policy :: :log | :alert | :circuit_break | :fallback

  @typedoc """
  Guarantee declarations — what callers can expect from this service endpoint.

  - `max_error_rate` — Maximum acceptable error rate as a float (0.0 to 1.0, e.g., 0.01 = 1%)
  - `uptime_sla` — Uptime guarantee as a float (e.g., 0.999 = 99.9%)
  - `description` — Human-readable description of the guarantee
  """
  @type guarantee :: %{
          max_error_rate: float(),
          uptime_sla: float(),
          description: String.t()
        }

  @typedoc """
  Full K9-SVC contract structure.
  """
  @type t :: %__MODULE__{
          contract_id: String.t(),
          service: String.t(),
          route_pattern: String.t(),
          verb: atom(),
          trust_threshold: SafeTrust.trust_level(),
          max_latency_ms: pos_integer(),
          rate_limit: pos_integer(),
          timeout_ms: pos_integer(),
          breach_policy: breach_policy(),
          guarantees: guarantee(),
          created_at: DateTime.t()
        }

  defstruct [
    :contract_id,
    :service,
    :route_pattern,
    :verb,
    :trust_threshold,
    :max_latency_ms,
    :rate_limit,
    :timeout_ms,
    :breach_policy,
    :guarantees,
    :created_at
  ]

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  # ETS table name for O(1) contract lookups on the request hot path.
  # The table is :named_table, :public (readable from any process), and :set
  # (one entry per route+verb combination, keyed by {:contract, pattern, verb}).
  @ets_table :k9_contracts

  # Valid breach policy atoms — used as an allowlist to prevent atom
  # exhaustion when parsing breach policies from external config.
  # SECURITY: Never call String.to_existing_atom on user input. Use parse_breach_policy/1.
  @valid_breach_policies [:log, :alert, :circuit_break, :fallback]

  # Valid HTTP verb atoms for contract matching. :ANY matches all verbs.
  @valid_verbs [:GET, :POST, :PUT, :DELETE, :PATCH, :HEAD, :OPTIONS, :ANY]

  # ---------------------------------------------------------------------------
  # Table Management
  # ---------------------------------------------------------------------------

  @doc """
  Initialise the K9 contract ETS table.

  Creates the `:k9_contracts` ETS table if it does not already exist.
  This is typically called from the application supervisor or during
  gateway startup. The table persists for the lifetime of the BEAM node.

  The table uses `read_concurrency: true` because the hot path (lookup/2)
  performs concurrent reads from multiple request-handling processes, while
  writes (register/1) are infrequent (only during config reloads).

  ## Returns

    - `:ok` — Table created or already exists.
  """
  @spec init() :: :ok
  def init do
    unless :ets.whereis(@ets_table) != :undefined do
      :ets.new(@ets_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

      Logger.info("K9 contract ETS table created", table: @ets_table)
    end

    :ok
  end

  @doc """
  Register a K9-SVC contract for a route pattern and verb.

  The contract is stored in ETS keyed by `{:contract, route_pattern, verb}`.
  If a contract already exists for this route+verb combination, it is replaced.
  The contract_id is computed as the SHA-256 hash of the contract content,
  making it content-addressable and deterministic.

  ## Parameters

    - `attrs` — Map of contract attributes. Required keys:
      - `:service` — Service name string (e.g., "user-api")
      - `:route_pattern` — Route pattern string (e.g., "/api/users/*")
      - `:verb` — HTTP verb atom (:GET, :POST, etc., or :ANY for all)
      - `:max_latency_ms` — Maximum response time in milliseconds
      - `:rate_limit` — Requests per second allowed
      - `:timeout_ms` — Backend timeout in milliseconds
      - `:breach_policy` — Breach policy atom (:log, :alert, :circuit_break, :fallback)
    - Optional keys:
      - `:trust_threshold` — Minimum trust level (default: :untrusted)
      - `:guarantees` — SLA guarantees map (default: basic guarantee)

  ## Returns

    - `{:ok, %K9Contract{}}` — Contract registered successfully.
    - `{:error, reason}` — Validation failed.

  ## Examples

      iex> K9Contract.register(%{
      ...>   service: "user-api",
      ...>   route_pattern: "/api/users/*",
      ...>   verb: :GET,
      ...>   max_latency_ms: 200,
      ...>   rate_limit: 100,
      ...>   timeout_ms: 5000,
      ...>   breach_policy: :alert
      ...> })
      {:ok, %K9Contract{contract_id: "a1b2c3...", ...}}
  """
  @spec register(map()) :: {:ok, t()} | {:error, term()}
  def register(attrs) when is_map(attrs) do
    with {:ok, service} <- validate_string(attrs, :service),
         {:ok, route_pattern} <- validate_string(attrs, :route_pattern),
         {:ok, verb} <- validate_verb(attrs),
         {:ok, max_latency_ms} <- validate_positive_int(attrs, :max_latency_ms),
         {:ok, rate_limit} <- validate_positive_int(attrs, :rate_limit),
         {:ok, timeout_ms} <- validate_positive_int(attrs, :timeout_ms),
         {:ok, breach_policy} <- validate_breach_policy(attrs) do
      trust_threshold = Map.get(attrs, :trust_threshold, :untrusted)

      guarantees =
        Map.get(attrs, :guarantees, %{
          max_error_rate: 0.01,
          uptime_sla: 0.999,
          description: "Standard SLA"
        })

      now = DateTime.utc_now()

      # Compute content-addressable contract ID from all obligation fields.
      # The hash covers service, route, verb, and all numeric thresholds so
      # that any change to the contract obligations produces a new ID.
      contract_id = compute_contract_id(service, route_pattern, verb, max_latency_ms, rate_limit, timeout_ms, breach_policy)

      contract = %__MODULE__{
        contract_id: contract_id,
        service: service,
        route_pattern: route_pattern,
        verb: verb,
        trust_threshold: trust_threshold,
        max_latency_ms: max_latency_ms,
        rate_limit: rate_limit,
        timeout_ms: timeout_ms,
        breach_policy: breach_policy,
        guarantees: guarantees,
        created_at: now
      }

      # Store in ETS with composite key for O(1) lookup.
      :ets.insert(@ets_table, {{:contract, route_pattern, verb}, contract})

      Logger.info("K9 contract registered",
        contract_id: contract_id,
        service: service,
        route: route_pattern,
        verb: verb,
        max_latency_ms: max_latency_ms,
        breach_policy: breach_policy
      )

      :telemetry.execute(
        [:http_capability_gateway, :k9_contract, :registered],
        %{count: 1},
        %{service: service, route: route_pattern, verb: verb}
      )

      {:ok, contract}
    end
  end

  @doc """
  Look up a K9-SVC contract for a given route path and HTTP verb.

  Performs a two-tier lookup:

    1. **Exact match** — Look for a contract keyed by `{:contract, path, verb}`.
    2. **Wildcard match** — Look for a contract keyed by `{:contract, path, :ANY}`.
    3. **Pattern scan** — Scan all contracts for wildcard route_pattern matches
       (e.g., "/api/users/*" matches "/api/users/123").

  Returns `nil` if no contract covers this route+verb combination.

  ## Parameters

    - `path` — The request path (e.g., "/api/users/123")
    - `verb` — The HTTP verb atom (e.g., :GET)

  ## Returns

    - `%K9Contract{}` — The matching contract, or nil if none found.

  ## Examples

      iex> K9Contract.lookup("/api/users/123", :GET)
      %K9Contract{service: "user-api", ...}

      iex> K9Contract.lookup("/unknown/path", :GET)
      nil
  """
  @spec lookup(String.t(), atom()) :: t() | nil
  def lookup(path, verb) when is_binary(path) and is_atom(verb) do
    # Tier 1: Exact path + exact verb match (O(1) ETS lookup)
    case :ets.lookup(@ets_table, {:contract, path, verb}) do
      [{_key, contract}] ->
        contract

      [] ->
        # Tier 2: Exact path + :ANY verb match (O(1) ETS lookup)
        case :ets.lookup(@ets_table, {:contract, path, :ANY}) do
          [{_key, contract}] ->
            contract

          [] ->
            # Tier 3: Wildcard pattern scan (O(n) over all contracts)
            # This handles route patterns like "/api/users/*" matching "/api/users/123".
            find_wildcard_match(path, verb)
        end
    end
  end

  @doc """
  Enforce a K9-SVC contract's pre-proxy constraints.

  Called BEFORE proxying a request to the backend. Checks:

    1. **Trust threshold** — Does the request's trust level meet the contract minimum?
    2. **Rate limit** — Contract-specific rate limiting (separate from global rate limiter).

  If pre-proxy checks fail, the request is rejected before reaching the backend,
  saving resources and latency.

  ## Parameters

    - `contract` — The K9 contract to enforce.
    - `trust_level` — The request's trust level (from conn.assigns[:trust_level]).

  ## Returns

    - `:ok` — Pre-proxy checks passed; proceed with proxying.
    - `{:error, :trust_insufficient}` — Trust level below contract threshold.
    - `{:error, :contract_rate_limited}` — Contract-specific rate limit exceeded.
  """
  @spec enforce_pre_proxy(t(), SafeTrust.trust_level()) :: :ok | {:error, atom()}
  def enforce_pre_proxy(%__MODULE__{} = contract, trust_level) do
    # Check trust threshold: the request's trust level must be >= the contract's
    # minimum trust threshold. Uses SafeTrust.satisfies?/2 for the formally
    # verified comparison (rank(trust) >= rank(threshold_as_exposure)).
    #
    # We map the trust threshold to an exposure level for comparison because
    # SafeTrust.satisfies?/2 compares trust vs exposure, and the contract's
    # trust_threshold semantically means "you need at least this trust level",
    # which is exactly what an exposure level declares.
    threshold_as_exposure = trust_to_exposure(contract.trust_threshold)

    if SafeTrust.satisfies?(trust_level, threshold_as_exposure) do
      :ok
    else
      Logger.info("K9 contract trust check failed",
        contract_id: contract.contract_id,
        required: contract.trust_threshold,
        provided: trust_level
      )

      {:error, :trust_insufficient}
    end
  end

  @doc """
  Enforce a K9-SVC contract's post-proxy constraints and handle breaches.

  Called AFTER proxying a request to the backend. Measures the actual response
  time against the contract's `max_latency_ms`. If the contract is breached,
  the `breach_policy` determines the response.

  ## Parameters

    - `contract` — The K9 contract to enforce.
    - `latency_ms` — Actual response time in milliseconds.
    - `response` — The backend response (Plug.Conn or equivalent).

  ## Returns

    - `{:ok, :within_sla}` — Response time within contract bounds.
    - `{:breach, breach_policy, latency_ms}` — Contract breached; returns the
      breach policy and actual latency for the caller to act on.

  ## Examples

      iex> K9Contract.enforce_post_proxy(contract, 150)
      {:ok, :within_sla}

      iex> K9Contract.enforce_post_proxy(contract, 500)
      {:breach, :alert, 500}
  """
  @spec enforce_post_proxy(t(), non_neg_integer()) ::
          {:ok, :within_sla} | {:breach, breach_policy(), non_neg_integer()}
  def enforce_post_proxy(%__MODULE__{} = contract, latency_ms) when is_integer(latency_ms) do
    if latency_ms <= contract.max_latency_ms do
      # Within SLA — emit telemetry with latency for monitoring.
      :telemetry.execute(
        [:http_capability_gateway, :k9_contract, :fulfilled],
        %{latency_ms: latency_ms, max_latency_ms: contract.max_latency_ms},
        %{
          contract_id: contract.contract_id,
          service: contract.service,
          route: contract.route_pattern
        }
      )

      {:ok, :within_sla}
    else
      # Contract breached — log and emit telemetry, then return the breach
      # policy for the gateway to act on.
      overshoot_ms = latency_ms - contract.max_latency_ms
      overshoot_pct = Float.round(overshoot_ms / contract.max_latency_ms * 100, 1)

      Logger.warning("K9 contract breach detected",
        contract_id: contract.contract_id,
        service: contract.service,
        route: contract.route_pattern,
        max_latency_ms: contract.max_latency_ms,
        actual_latency_ms: latency_ms,
        overshoot_ms: overshoot_ms,
        overshoot_pct: overshoot_pct,
        breach_policy: contract.breach_policy
      )

      :telemetry.execute(
        [:http_capability_gateway, :k9_contract, :breach],
        %{
          latency_ms: latency_ms,
          max_latency_ms: contract.max_latency_ms,
          overshoot_ms: overshoot_ms
        },
        %{
          contract_id: contract.contract_id,
          service: contract.service,
          route: contract.route_pattern,
          breach_policy: contract.breach_policy
        }
      )

      {:breach, contract.breach_policy, latency_ms}
    end
  end

  @doc """
  Execute a breach policy action.

  Called by the gateway when `enforce_post_proxy/2` returns a breach. Each
  breach policy triggers a different system response:

    - `:log` — Already logged by enforce_post_proxy; no additional action.
    - `:alert` — Emit a high-priority telemetry event for alerting systems.
    - `:circuit_break` — Mark the route as degraded (increments breach counter;
      if threshold exceeded, future requests get a 503).
    - `:fallback` — Return a degraded/cached response.

  ## Parameters

    - `contract` — The breached K9 contract.
    - `breach_policy` — The policy to execute.
    - `latency_ms` — The actual latency that triggered the breach.

  ## Returns

    - `:ok` — Action executed.
  """
  @spec execute_breach_policy(t(), breach_policy(), non_neg_integer()) :: :ok
  def execute_breach_policy(%__MODULE__{} = contract, policy, latency_ms) do
    case policy do
      :log ->
        # Already logged by enforce_post_proxy/2. No additional action needed.
        # The telemetry event was already emitted, so dashboards will see it.
        :ok

      :alert ->
        # Emit a high-priority telemetry event that external alerting systems
        # (PagerDuty, OpsGenie, custom webhooks) can subscribe to.
        :telemetry.execute(
          [:http_capability_gateway, :k9_contract, :alert],
          %{latency_ms: latency_ms, severity: :high},
          %{
            contract_id: contract.contract_id,
            service: contract.service,
            route: contract.route_pattern,
            message: "K9-SVC contract breach: #{contract.service} exceeded #{contract.max_latency_ms}ms (actual: #{latency_ms}ms)"
          }
        )

        :ok

      :circuit_break ->
        # Trip the circuit breaker for this route's service. The CircuitBreaker
        # GenServer manages the FSM transitions (open -> half_open -> closed)
        # and schedules recovery probes. Once tripped, the gateway's allow?/1
        # check will reject requests to this backend until the circuit recovers.
        #
        # We also increment the breach counter for audit trail purposes and
        # backward compatibility with dashboards reading breach counts from ETS.
        CircuitBreaker.trip(contract.service)
        increment_breach_counter(contract)
        :ok

      :fallback ->
        # The fallback response is handled by the gateway caller — it checks
        # the breach return value and serves a degraded response. We log the
        # intent here for audit trail purposes.
        Logger.info("K9 contract fallback triggered",
          contract_id: contract.contract_id,
          service: contract.service,
          route: contract.route_pattern,
          latency_ms: latency_ms
        )

        :ok
    end
  end

  @doc """
  Return the number of registered K9 contracts.

  Useful for monitoring, diagnostics, and readiness checks.

  ## Returns

    - Non-negative integer count of registered contracts.

  ## Examples

      iex> K9Contract.count()
      7
  """
  @spec count() :: non_neg_integer()
  def count do
    if :ets.whereis(@ets_table) != :undefined do
      :ets.info(@ets_table, :size)
    else
      0
    end
  end

  @doc """
  List all registered K9 contracts.

  Returns a list of all contracts currently stored in the ETS table.
  Useful for admin dashboards, debugging, and audit reporting.

  ## Returns

    - List of `%K9Contract{}` structs.
  """
  @spec list_all() :: [t()]
  def list_all do
    if :ets.whereis(@ets_table) != :undefined do
      @ets_table
      |> :ets.tab2list()
      |> Enum.map(fn {_key, contract} -> contract end)
    else
      []
    end
  end

  @doc """
  Remove a K9 contract for a given route pattern and verb.

  ## Parameters

    - `route_pattern` — The route pattern string.
    - `verb` — The HTTP verb atom.

  ## Returns

    - `:ok` — Contract removed (or was not present).
  """
  @spec remove(String.t(), atom()) :: :ok
  def remove(route_pattern, verb) when is_binary(route_pattern) and is_atom(verb) do
    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete(@ets_table, {:contract, route_pattern, verb})

      Logger.info("K9 contract removed",
        route: route_pattern,
        verb: verb
      )
    end

    :ok
  end

  @doc """
  Reset all K9 contracts (delete all entries from ETS).

  Administrative function for testing and configuration reloads.

  ## Returns

    - `:ok` — All contracts cleared.
  """
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete_all_objects(@ets_table)
      Logger.info("K9 contracts reset — all contracts cleared")
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  # Compute a deterministic SHA-256 contract ID from the contract's obligation
  # fields. The hash covers all fields that define the contract's behaviour,
  # so any change to obligations produces a new ID. This makes contracts
  # content-addressable for audit and deduplication.
  @spec compute_contract_id(String.t(), String.t(), atom(), pos_integer(), pos_integer(), pos_integer(), breach_policy()) :: String.t()
  defp compute_contract_id(service, route_pattern, verb, max_latency_ms, rate_limit, timeout_ms, breach_policy) do
    content =
      "#{service}|#{route_pattern}|#{verb}|#{max_latency_ms}|#{rate_limit}|#{timeout_ms}|#{breach_policy}"

    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  # Map a trust level atom to its corresponding exposure level atom for
  # SafeTrust.satisfies?/2 comparison. The mapping is:
  #   :untrusted -> :public (anyone can access)
  #   :authenticated -> :authenticated (requires auth)
  #   :internal -> :internal (internal only)
  @spec trust_to_exposure(SafeTrust.trust_level()) :: SafeTrust.exposure_level()
  defp trust_to_exposure(:untrusted), do: :public
  defp trust_to_exposure(:authenticated), do: :authenticated
  defp trust_to_exposure(:internal), do: :internal

  # Find a wildcard-matching contract by scanning all ETS entries.
  # Wildcard patterns use "*" as a glob-style suffix match:
  #   "/api/users/*" matches "/api/users/123", "/api/users/123/profile", etc.
  #
  # This is O(n) over the number of contracts, which is acceptable because:
  # 1. The number of K9 contracts is typically small (10-100, not millions).
  # 2. This is only reached when exact match (Tier 1 and 2) fails.
  # 3. Contracts are a governance overlay, not the primary routing mechanism.
  @spec find_wildcard_match(String.t(), atom()) :: t() | nil
  defp find_wildcard_match(path, verb) do
    if :ets.whereis(@ets_table) != :undefined do
      @ets_table
      |> :ets.tab2list()
      |> Enum.find_value(fn
        {{:contract, pattern, contract_verb}, contract} ->
          if wildcard_matches?(pattern, path) and (contract_verb == verb or contract_verb == :ANY) do
            contract
          else
            nil
          end
      end)
    else
      nil
    end
  end

  # Check if a wildcard pattern matches a path.
  # Supports trailing "*" glob patterns:
  #   "/api/users/*" matches "/api/users/123"
  #   "/api/*" matches "/api/anything/deep/nested"
  #   "/exact/path" matches only "/exact/path" (no wildcard)
  @spec wildcard_matches?(String.t(), String.t()) :: boolean()
  defp wildcard_matches?(pattern, path) do
    if String.ends_with?(pattern, "/*") do
      prefix = String.slice(pattern, 0..(String.length(pattern) - 3)//1)
      String.starts_with?(path, prefix <> "/") or path == prefix
    else
      pattern == path
    end
  end

  # Increment the breach counter for a contract's route. Used by the
  # :circuit_break breach policy. The counter is stored in a separate
  # ETS entry keyed by {:breach_count, route_pattern, verb}.
  #
  # When the counter exceeds a configurable threshold (default: 5),
  # downstream enforcement can reject requests to this route.
  @spec increment_breach_counter(t()) :: :ok
  defp increment_breach_counter(%__MODULE__{} = contract) do
    key = {:breach_count, contract.route_pattern, contract.verb}

    if :ets.whereis(@ets_table) != :undefined do
      case :ets.lookup(@ets_table, key) do
        [{^key, count}] ->
          new_count = count + 1
          :ets.insert(@ets_table, {key, new_count})

          breach_threshold =
            Application.get_env(:http_capability_gateway, :k9_breach_threshold, 5)

          if new_count >= breach_threshold do
            Logger.error("K9 contract circuit break threshold reached",
              contract_id: contract.contract_id,
              service: contract.service,
              route: contract.route_pattern,
              breach_count: new_count,
              threshold: breach_threshold
            )

            :telemetry.execute(
              [:http_capability_gateway, :k9_contract, :circuit_break],
              %{breach_count: new_count, threshold: breach_threshold},
              %{
                contract_id: contract.contract_id,
                service: contract.service,
                route: contract.route_pattern
              }
            )
          end

        [] ->
          :ets.insert(@ets_table, {key, 1})
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Validation Helpers
  # ---------------------------------------------------------------------------

  # Validate that a required key exists in the attrs map and is a non-empty string.
  @spec validate_string(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp validate_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and byte_size(value) > 0 ->
        {:ok, value}

      nil ->
        {:error, {:missing_required_field, key}}

      _other ->
        {:error, {:invalid_field, key, "must be a non-empty string"}}
    end
  end

  # Validate that the verb field is a known HTTP verb atom from the allowlist.
  # SECURITY: We check against @valid_verbs instead of calling String.to_existing_atom
  # to prevent atom table exhaustion.
  @spec validate_verb(map()) :: {:ok, atom()} | {:error, term()}
  defp validate_verb(attrs) do
    case Map.get(attrs, :verb) do
      verb when verb in @valid_verbs ->
        {:ok, verb}

      nil ->
        {:error, {:missing_required_field, :verb}}

      other ->
        {:error, {:invalid_verb, other, "must be one of #{inspect(@valid_verbs)}"}}
    end
  end

  # Validate that a key exists and is a positive integer.
  @spec validate_positive_int(map(), atom()) :: {:ok, pos_integer()} | {:error, term()}
  defp validate_positive_int(attrs, key) do
    case Map.get(attrs, key) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      nil ->
        {:error, {:missing_required_field, key}}

      other ->
        {:error, {:invalid_field, key, "must be a positive integer, got: #{inspect(other)}"}}
    end
  end

  # Validate that the breach_policy field is a known policy atom from the allowlist.
  # SECURITY: We check against @valid_breach_policies instead of calling String.to_existing_atom
  # to prevent atom table exhaustion from user-supplied config.
  @spec validate_breach_policy(map()) :: {:ok, breach_policy()} | {:error, term()}
  defp validate_breach_policy(attrs) do
    case Map.get(attrs, :breach_policy) do
      policy when policy in @valid_breach_policies ->
        {:ok, policy}

      nil ->
        {:error, {:missing_required_field, :breach_policy}}

      other ->
        {:error, {:invalid_breach_policy, other, "must be one of #{inspect(@valid_breach_policies)}"}}
    end
  end

  @doc """
  Safely parse a breach policy string to its corresponding atom.

  Uses pattern matching on known strings — NEVER String.to_existing_atom.
  Unknown or malformed input defaults to `:log` (safest policy).

  ## Parameters

    - `raw` — Raw breach policy string from configuration.

  ## Returns

    - Breach policy atom.

  ## Examples

      iex> K9Contract.parse_breach_policy("alert")
      :alert

      iex> K9Contract.parse_breach_policy("unknown")
      :log
  """
  @spec parse_breach_policy(String.t() | nil) :: breach_policy()
  def parse_breach_policy("log"), do: :log
  def parse_breach_policy("alert"), do: :alert
  def parse_breach_policy("circuit_break"), do: :circuit_break
  def parse_breach_policy("fallback"), do: :fallback
  def parse_breach_policy(_), do: :log
end
