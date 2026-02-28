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
  plug(:security_headers)
  plug(:match)
  plug(:dispatch)

  # Security headers applied to ALL responses (including health/metrics).
  #
  # These headers harden the gateway against common web attacks:
  # - X-Content-Type-Options: prevent MIME-type sniffing
  # - X-Frame-Options: prevent clickjacking
  # - Referrer-Policy: limit referrer leakage
  # - Cache-Control: prevent caching of policy decisions
  # - X-Request-ID: propagate request tracing
  #
  # Inspired by aerie's security header implementation (2026-02-28)
  # and OWASP Secure Headers Project recommendations.
  defp security_headers(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate")
    |> put_resp_header("connection", "close")
  end

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

  # Extract trust level from X-Trust-Level header or mTLS certificate
  defp extract_trust_level(conn) do
    trust_level_source = Application.get_env(:http_capability_gateway, :trust_level_source, "header")

    case trust_level_source do
      "mtls" ->
        # Extract from mTLS client certificate
        extract_trust_level_from_cert(conn)

      "header" ->
        # Extract from header (default)
        extract_trust_level_from_header(conn)

      _ ->
        # Fallback to header
        extract_trust_level_from_header(conn)
    end
  end

  # Extract trust level from X-Trust-Level header
  defp extract_trust_level_from_header(conn) do
    header_name = Application.get_env(:http_capability_gateway, :trust_level_header, "x-trust-level")

    case get_req_header(conn, header_name) do
      [level | _] -> String.downcase(level)
      [] -> "untrusted"
    end
  end

  # Extract trust level from mTLS client certificate
  # Checks for:
  # 1. Client certificate presence
  # 2. Certificate subject fields (O, OU)
  # 3. Certificate verification status
  defp extract_trust_level_from_cert(conn) do
    with {:ok, peer_cert} <- get_peer_cert(conn),
         {:ok, subject} <- extract_cert_subject(peer_cert),
         verified <- is_cert_verified(conn) do
      # Determine trust level from certificate attributes
      determine_trust_level_from_cert(subject, verified)
    else
      _ ->
        # No certificate or invalid - untrusted
        "untrusted"
    end
  end

  # Get peer certificate from connection
  # Note: Requires Cowboy to be configured with TLS and verify: :verify_peer
  defp get_peer_cert(conn) do
    case conn.adapter do
      {Plug.Cowboy.Conn, req} ->
        # Extract peer certificate from Cowboy request
        case :cowboy_req.cert(req) do
          :undefined -> {:error, :no_cert}
          cert when is_binary(cert) -> {:ok, cert}
        end

      _ ->
        {:error, :not_supported}
    end
  end

  # Extract subject fields from X.509 certificate
  defp extract_cert_subject(cert_der) when is_binary(cert_der) do
    try do
      # Decode DER-encoded certificate
      cert = :public_key.pkix_decode_cert(cert_der, :otp)

      # Extract subject from certificate
      case cert do
        {:Certificate, _, subject, _, _, _, _} ->
          subject_fields = extract_subject_fields(subject)
          {:ok, subject_fields}

        _ ->
          {:error, :invalid_cert}
      end
    rescue
      _ -> {:error, :decode_failed}
    end
  end

  # Extract subject fields into a map
  defp extract_subject_fields({:rdnSequence, rdn_sequence}) do
    Enum.reduce(rdn_sequence, %{}, fn rdn_set, acc ->
      Enum.reduce(rdn_set, acc, fn
        {:AttributeTypeAndValue, {2, 5, 4, 10}, {:utf8String, value}}, acc ->
          # O = Organization
          Map.put(acc, :organization, to_string(value))

        {:AttributeTypeAndValue, {2, 5, 4, 11}, {:utf8String, value}}, acc ->
          # OU = Organizational Unit
          Map.put(acc, :organizational_unit, to_string(value))

        {:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, value}}, acc ->
          # CN = Common Name
          Map.put(acc, :common_name, to_string(value))

        _, acc ->
          acc
      end)
    end)
  end

  # Check if certificate was verified
  defp is_cert_verified(conn) do
    # In a real implementation, check if certificate passed verification
    # For now, assume verified if certificate is present
    case get_peer_cert(conn) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # Determine trust level from certificate attributes
  defp determine_trust_level_from_cert(subject, verified) do
    cond do
      # Internal services: verified cert from internal CA with specific OU
      verified and Map.get(subject, :organizational_unit) == "Internal Services" ->
        "internal"

      # Authenticated: verified cert from trusted CA
      verified ->
        "authenticated"

      # Untrusted: certificate present but not verified
      true ->
        "untrusted"
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
