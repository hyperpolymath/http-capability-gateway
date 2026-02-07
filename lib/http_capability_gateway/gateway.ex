# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.Gateway do
  @moduledoc """
  HTTP Gateway implementing verb governance enforcement.

  Receives incoming HTTP requests, enforces policy-based verb governance,
  and forwards allowed requests to backend services.

  ## Request Flow

  1. Receive HTTP request (path, verb, headers)
  2. Extract trust level from headers (X-Trust-Level)
  3. Lookup enforcement rule via PolicyCompiler
  4. Evaluate: Does trust level satisfy exposure requirement?
  5. If allowed: Forward to backend via Proxy
  6. If denied: Return error (or stealth response)

  ## Trust Levels

  - `untrusted` - No authentication, anonymous access
  - `authenticated` - Valid authentication token present
  - `internal` - Request from internal service (mutual TLS, service token)

  ## Exposure Levels (from Policy)

  - `public` - Anyone can access (untrusted, authenticated, internal all allowed)
  - `authenticated` - Requires authentication (authenticated, internal allowed)
  - `internal` - Internal services only (internal allowed)

  ## Stealth Mode

  When trust level is insufficient, stealth profiles determine response:
  - Without stealth: Return 403 Forbidden with clear message
  - With stealth: Return configured status code (e.g., 404, 405) to hide capability
  """

  use Plug.Router
  require Logger

  alias HttpCapabilityGateway.PolicyCompiler
  alias HttpCapabilityGateway.Proxy

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  # Health check endpoint - doesn't require policy
  get "/health" do
    handle_health_check(conn)
  end

  # Readiness check endpoint - verifies policy is loaded
  get "/ready" do
    handle_readiness_check(conn)
  end

  # Prometheus metrics endpoint
  get "/metrics" do
    handle_metrics(conn)
  end

  # Catch-all route - enforce policy on all requests
  match _ do
    handle_request(conn)
  end

  @doc """
  Main request handler - enforces policy and forwards to backend.

  ## Parameters

    - `conn`: Plug.Conn struct with request details

  ## Process

    1. Extract trust level from X-Trust-Level header
    2. Lookup policy rule for path and verb
    3. Evaluate access decision
    4. Forward or deny request
  """
  def handle_request(conn) do
    start_time = System.monotonic_time()
    request_id = get_request_id(conn)

    Logger.metadata(request_id: request_id)

    # Extract request details
    path = conn.request_path
    verb = conn.method |> String.to_existing_atom()
    trust_level = extract_trust_level(conn)

    Logger.info("Processing request",
      path: path,
      verb: verb,
      trust_level: trust_level
    )

    # Get compiled policy table from application environment
    policy_table = Application.get_env(:http_capability_gateway, :policy_table)

    if is_nil(policy_table) do
      # Policy not loaded - return 503 Service Unavailable
      duration_us = System.monotonic_time() - start_time
      log_decision(request_id, path, verb, trust_level, :error, "Policy not loaded", duration_us)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{error: "Service configuration unavailable"}))
    else
      # Lookup policy rule
      case PolicyCompiler.lookup(policy_table, path, verb) do
        {:ok, rule} ->
          # Evaluate access decision
          case evaluate_access(trust_level, rule.exposure) do
            :allow ->
              # Forward to backend
              duration_us = System.monotonic_time() - start_time
              log_decision(request_id, path, verb, trust_level, :allow, rule, duration_us)

              Proxy.forward(conn, rule)

            :deny ->
              # Access denied - return error or stealth response
              duration_us = System.monotonic_time() - start_time
              log_decision(request_id, path, verb, trust_level, :deny, rule, duration_us)

              handle_denial(conn, rule, trust_level)
          end

        {:error, :no_match} ->
          # No policy rule matches - default deny
          duration_us = System.monotonic_time() - start_time
          log_decision(request_id, path, verb, trust_level, :no_match, nil, duration_us)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, Jason.encode!(%{error: "Resource not found"}))
      end
    end
  end

  # Extract trust level from X-Trust-Level header
  defp extract_trust_level(conn) do
    case get_req_header(conn, "x-trust-level") do
      [level | _] -> String.downcase(level)
      [] -> "untrusted"
    end
  end

  # Evaluate if trust level satisfies exposure requirement
  @spec evaluate_access(trust_level :: String.t(), exposure :: String.t()) :: :allow | :deny
  defp evaluate_access(trust_level, exposure) do
    case {trust_level, exposure} do
      # Public endpoints - anyone can access
      {_, "public"} -> :allow

      # Authenticated endpoints - authenticated or internal only
      {"authenticated", "authenticated"} -> :allow
      {"internal", "authenticated"} -> :allow

      # Internal endpoints - internal only
      {"internal", "internal"} -> :allow

      # All other combinations - deny
      _ -> :deny
    end
  end

  # Handle denied requests - apply stealth profile if configured
  defp handle_denial(conn, rule, trust_level) do
    stealth_profile = get_stealth_profile(rule.stealth_profile)

    {status_code, response_body} =
      case stealth_profile do
        nil ->
          # No stealth - return clear error
          {403, %{
            error: "Forbidden",
            message: "Insufficient trust level for this operation",
            required: rule.exposure,
            provided: trust_level
          }}

        profile when is_map(profile) ->
          # Apply stealth - return configured status for trust level
          code = get_stealth_code(profile, trust_level, rule.exposure)
          message = get_stealth_message(code)
          {code, %{error: message}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, Jason.encode!(response_body))
  end

  # Get stealth profile configuration from application environment
  defp get_stealth_profile(nil), do: nil

  defp get_stealth_profile(profile_name) do
    Application.get_env(:http_capability_gateway, :stealth_profiles, %{})
    |> Map.get(profile_name)
  end

  # Get stealth status code for trust level and exposure
  defp get_stealth_code(profile, trust_level, exposure) do
    # Try to get specific code for this exposure level, fallback to trust level
    profile[exposure] || profile[trust_level] || 404
  end

  # Get generic message for stealth status code
  defp get_stealth_message(404), do: "Not Found"
  defp get_stealth_message(405), do: "Method Not Allowed"
  defp get_stealth_message(400), do: "Bad Request"
  defp get_stealth_message(_), do: "Request could not be processed"

  # Extract or generate request ID
  defp get_request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [id | _] -> id
      [] -> generate_request_id()
    end
  end

  # Generate unique request ID
  defp generate_request_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  # Log access decision with structured data
  defp log_decision(request_id, path, verb, trust_level, decision, rule_or_reason, duration_us) do
    base_log = %{
      event: "access_decision",
      request_id: request_id,
      path: path,
      verb: verb,
      trust_level: trust_level,
      decision: decision,
      duration_us: duration_us
    }

    log_data =
      case decision do
        :allow ->
          Map.merge(base_log, %{
            exposure: rule_or_reason.exposure,
            narrative: rule_or_reason.narrative
          })

        :deny ->
          Map.merge(base_log, %{
            exposure: rule_or_reason.exposure,
            stealth_profile: rule_or_reason.stealth_profile
          })

        :error ->
          Map.put(base_log, :error, rule_or_reason)

        :no_match ->
          base_log
      end

    Logger.info("Access decision", log_data)

    # Emit telemetry event
    :telemetry.execute(
      [:http_capability_gateway, :access_decision],
      %{duration: duration_us},
      %{
        decision: decision,
        verb: verb,
        trust_level: trust_level
      }
    )
  end

  @doc """
  Health check endpoint - returns 200 OK if service is running.

  Does not check policy loading or backend connectivity - use /ready for that.
  """
  def handle_health_check(conn) do
    uptime_seconds = div(System.monotonic_time(:second) - get_start_time(), 1)

    response = %{
      status: "healthy",
      service: "http-capability-gateway",
      version: Application.spec(:http_capability_gateway, :vsn) |> to_string(),
      uptime_seconds: uptime_seconds
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  @doc """
  Readiness check endpoint - returns 200 OK if service is ready to handle traffic.

  Checks:
  - Policy is loaded
  - ETS tables exist
  """
  def handle_readiness_check(conn) do
    policy_table = Application.get_env(:http_capability_gateway, :policy_table)

    cond do
      is_nil(policy_table) ->
        # Policy not loaded
        response = %{
          status: "not_ready",
          reason: "Policy not loaded",
          service: "http-capability-gateway"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(response))

      :ets.whereis(policy_table) == :undefined ->
        # ETS table doesn't exist
        response = %{
          status: "not_ready",
          reason: "Policy table not found",
          service: "http-capability-gateway"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(response))

      true ->
        # Ready to serve traffic
        rule_count = :ets.info(policy_table, :size)

        response = %{
          status: "ready",
          service: "http-capability-gateway",
          policy_rules: rule_count
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))
    end
  end

  @doc """
  Prometheus metrics endpoint - exports metrics in Prometheus format.

  Metrics include:
  - Request counts by decision (allow/deny)
  - Request duration histograms
  - Policy rule counts
  """
  def handle_metrics(conn) do
    metrics = TelemetryMetricsPrometheus.Core.scrape()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  # Get application start time (monotonic time when app started)
  defp get_start_time do
    case :persistent_term.get({__MODULE__, :start_time}, nil) do
      nil ->
        start_time = System.monotonic_time(:second)
        :persistent_term.put({__MODULE__, :start_time}, start_time)
        start_time

      start_time ->
        start_time
    end
  end
end
