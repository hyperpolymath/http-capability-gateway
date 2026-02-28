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
  alias HttpCapabilityGateway.RateLimiter
  alias HttpCapabilityGateway.SafeTrust

  # Safe HTTP verb conversion with allowlist.
  #
  # String.to_existing_atom/1 crashes on unknown verbs (ArgumentError),
  # which is a DoS vector -- any client can crash the handler by sending
  # an exotic HTTP method like PROPFIND, MKCOL, REPORT, or any arbitrary
  # string. The BEAM atom table is finite (~1M atoms) and not garbage
  # collected, so String.to_atom/1 is equally dangerous (atom exhaustion).
  #
  # Instead, we maintain an explicit allowlist of the seven standard HTTP
  # methods supported by this gateway. Any method not in this map is
  # rejected early with 405 Method Not Allowed, without touching the
  # atom table or reaching policy evaluation.
  #
  # This map is used by safe_verb/1 which is called at the top of
  # handle_request/1 before any policy lookup occurs.
  @valid_methods %{
    "GET" => :GET,
    "POST" => :POST,
    "PUT" => :PUT,
    "DELETE" => :DELETE,
    "PATCH" => :PATCH,
    "HEAD" => :HEAD,
    "OPTIONS" => :OPTIONS
  }

  plug(Plug.Logger)
  plug(:security_headers)
  plug(:strip_untrusted_headers)
  plug(:extract_trust)
  plug(RateLimiter)
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

  # Strip trust level header from external requests to prevent spoofing.
  #
  # SECURITY: If the gateway is exposed directly to the internet (not behind
  # a trusted load balancer or reverse proxy), any client can forge the
  # X-Trust-Level header with a value like "internal" and bypass all verb
  # governance. This is a privilege escalation vector that would allow
  # anonymous clients to access internal-only endpoints.
  #
  # This plug removes the trust level header unless the request originates
  # from a trusted upstream proxy (identified by IP address). The result is
  # that direct clients always get trust_level="untrusted" regardless of
  # what headers they send, while legitimate proxy-injected headers are
  # preserved.
  #
  # Configuration (in config/runtime.exs or config/config.exs):
  #
  #   # Enable/disable header stripping (default: true for defense-in-depth)
  #   config :http_capability_gateway, :strip_trust_header, true
  #
  #   # IP addresses of trusted upstream proxies that are allowed to set
  #   # the trust level header. Only exact IP matches are supported.
  #   # Default: loopback only (127.0.0.1, ::1)
  #   config :http_capability_gateway, :trusted_proxies, ["127.0.0.1", "::1", "10.0.0.1"]
  #
  # When strip_trust_header is false, no stripping occurs (useful for
  # development environments where the gateway is accessed directly).
  #
  # Note: This uses conn.remote_ip which is set by the HTTP server (Cowboy).
  # If you need to trust X-Forwarded-For headers from a CDN in front of
  # your load balancer, configure Plug.Conn's remote_ip separately
  # (e.g., via RemoteIp plug or Cowboy's proxy_header option).
  defp strip_untrusted_headers(conn, _opts) do
    if Application.get_env(:http_capability_gateway, :strip_trust_header, true) do
      # Fetch the list of trusted proxy IPs from configuration.
      # Default to loopback addresses only -- the most restrictive setting.
      trusted_proxies =
        Application.get_env(:http_capability_gateway, :trusted_proxies, ["127.0.0.1", "::1"])

      # Convert the BEAM tuple IP address to a string for comparison.
      # conn.remote_ip is an Erlang inet address tuple like {127, 0, 0, 1}
      # or {0, 0, 0, 0, 0, 0, 0, 1} for IPv6.
      remote_ip = conn.remote_ip |> :inet.ntoa() |> to_string()

      if remote_ip in trusted_proxies do
        # Request comes from a trusted proxy -- preserve the trust level header.
        # The proxy is responsible for setting it correctly based on mTLS,
        # authentication tokens, or other upstream verification.
        conn
      else
        # Request comes from an untrusted source -- strip the trust level header
        # to prevent spoofing. The downstream extract_trust_level/1 function
        # will default to "untrusted" when the header is absent.
        trust_header =
          Application.get_env(:http_capability_gateway, :trust_level_header, "x-trust-level")

        Logger.debug("Stripped trust level header from untrusted source",
          remote_ip: remote_ip,
          header: trust_header
        )

        delete_req_header(conn, trust_header)
      end
    else
      # Header stripping disabled -- pass through unchanged.
      # Only use this in development/testing environments.
      conn
    end
  end

  # Extract trust level from headers/mTLS and store in conn.assigns.
  #
  # This plug runs BEFORE the RateLimiter plug in the pipeline so that
  # rate limiting decisions can be based on the authenticated trust level.
  # The trust level is parsed through SafeTrust.parse_trust/1 which
  # safely maps strings to atoms from a fixed set (no String.to_atom).
  #
  # The trust level is stored in conn.assigns[:trust_level] and reused
  # by both the rate limiter and the request handler, avoiding duplicate
  # extraction work.
  defp extract_trust(conn, _opts) do
    trust_level_str = extract_trust_level(conn)
    trust_level = SafeTrust.parse_trust(trust_level_str)
    Plug.Conn.assign(conn, :trust_level, trust_level)
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
  Safely converts an HTTP method string to its corresponding atom.

  Uses the @valid_methods allowlist to avoid the DoS vector inherent in
  String.to_existing_atom/1 (which raises ArgumentError on unknown atoms)
  and String.to_atom/1 (which can exhaust the BEAM atom table).

  Returns the atom for known HTTP methods, or nil for unknown methods.
  The caller (handle_request/1) uses this to short-circuit unknown methods
  with a 405 response before any policy evaluation occurs.

  ## Parameters

    - `method`: HTTP method string from conn.method (e.g., "GET", "PROPFIND")

  ## Returns

    - Atom like :GET, :POST, etc. for valid methods
    - nil for unknown/unsupported methods

  ## Examples

      iex> safe_verb("GET")
      :GET

      iex> safe_verb("PROPFIND")
      nil
  """
  defp safe_verb(method) do
    Map.get(@valid_methods, method)
  end

  @doc """
  Main request handler - enforces policy and forwards to backend.

  ## Parameters

    - `conn`: Plug.Conn struct with request details

  ## Process

    1. Convert HTTP method to atom via safe allowlist (reject unknown methods)
    2. Extract trust level from X-Trust-Level header
    3. Lookup policy rule for path and verb
    4. Evaluate access decision
    5. Forward or deny request

  ## Security

  Unknown HTTP methods (PROPFIND, MKCOL, REPORT, arbitrary strings) are
  rejected with 405 Method Not Allowed before reaching policy evaluation.
  This prevents ArgumentError crashes from String.to_existing_atom/1 and
  atom table exhaustion from String.to_atom/1, both of which are DoS vectors.
  """
  def handle_request(conn) do
    start_time = System.monotonic_time()
    request_id = get_request_id(conn)

    Logger.metadata(request_id: request_id)

    path = conn.request_path

    case safe_verb(conn.method) do
      nil ->
        # Unknown HTTP method -- reject without crashing.
        #
        # This is the critical security fix: instead of calling
        # String.to_existing_atom(conn.method) which raises ArgumentError
        # on unknown verbs (crashing the request handler and potentially
        # the supervision tree under load), we return 405 immediately.
        #
        # This also prevents atom table exhaustion if an attacker sends
        # thousands of unique method strings and we were using to_atom/1.
        Logger.warning("Rejected unknown HTTP method",
          method: conn.method,
          path: path,
          remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string()
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(405, Jason.encode!(%{error: "Method Not Allowed"}))

      verb ->
        # Valid HTTP method -- proceed with policy evaluation.
        #
        # Trust level was already extracted and parsed by the :extract_trust
        # plug earlier in the pipeline (stored in conn.assigns[:trust_level]).
        # This avoids duplicate header parsing and ensures the rate limiter
        # and request handler see the same trust level.
        trust_level = Map.get(conn.assigns, :trust_level, :untrusted)

        Logger.info("Processing request",
          path: path,
          verb: verb,
          trust_level: trust_level
        )

        # Get compiled policy table from application environment.
        # This reference is set by PolicyCompiler.compile/2 and updated
        # atomically during policy reloads (see Fix 3: atomic swap pattern).
        policy_table = Application.get_env(:http_capability_gateway, :policy_table)

        if is_nil(policy_table) do
          # Policy not loaded - return 503 Service Unavailable.
          # This occurs during startup before the first policy compilation
          # completes, or if policy loading failed entirely.
          duration_us = System.monotonic_time() - start_time
          log_decision(request_id, path, verb, trust_level, :error, "Policy not loaded", duration_us)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(503, Jason.encode!(%{error: "Service configuration unavailable"}))
        else
          # Lookup policy rule using tiered strategy:
          # Tier 1: O(1) exact literal path match
          # Tier 2: O(r) regex route pattern scan (dedicated regex table)
          # Tier 3: O(1) global verb rule fallback
          case PolicyCompiler.lookup(policy_table, path, verb) do
            {:ok, rule} ->
              # Evaluate access decision using SafeTrust.evaluate/2.
              # This replaces the ad-hoc evaluate_access/2 function with the
              # formally verified trust hierarchy from proven/SafeTrust.idr.
              # SafeTrust.evaluate/2 returns {:allow, t, e} or {:deny, t, e}
              # providing a structured audit trail for every decision.
              exposure = SafeTrust.parse_exposure(rule.exposure)

              case SafeTrust.evaluate(trust_level, exposure) do
                {:allow, _t, _e} ->
                  # Forward to backend -- trust level satisfies exposure requirement
                  duration_us = System.monotonic_time() - start_time
                  log_decision(request_id, path, verb, trust_level, :allow, rule, duration_us)

                  Proxy.forward(conn, rule)

                {:deny, _t, _e} ->
                  # Access denied -- apply stealth profile if configured, otherwise 403
                  duration_us = System.monotonic_time() - start_time
                  log_decision(request_id, path, verb, trust_level, :deny, rule, duration_us)

                  handle_denial(conn, rule, trust_level)
              end

            {:error, :no_match} ->
              # No policy rule matches this path+verb combination -- default deny.
              # Returns 404 to avoid leaking information about which paths exist.
              duration_us = System.monotonic_time() - start_time
              log_decision(request_id, path, verb, trust_level, :no_match, nil, duration_us)

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(404, Jason.encode!(%{error: "Resource not found"}))
          end
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

      # Extract subject from the decoded certificate.
      #
      # IMPORTANT: This pattern match is a simplified approximation.
      # When :public_key.pkix_decode_cert/2 is called with :otp, it returns
      # an OTPCertificate record, NOT a raw {:Certificate, ...} tuple.
      # The OTP certificate structure nests the subject inside:
      #
      #   #'OTPCertificate'{
      #     tbsCertificate: #'OTPTBSCertificate'{
      #       subject: {rdnSequence, [...]}
      #     }
      #   }
      #
      # For production use, this should be updated to use Erlang record
      # accessors or the :public_key module's helper functions to extract
      # the subject reliably across all certificate versions and formats.
      #
      # The current pattern may work for certificates decoded with :plain
      # (the second argument to pkix_decode_cert), but :otp mode returns
      # a different structure. Consider using:
      #   cert_otp = :public_key.pkix_decode_cert(cert_der, :otp)
      #   tbs = elem(cert_otp, 1)  # OTPTBSCertificate
      #   subject = elem(tbs, 5)   # subject field
      #
      # TODO: Replace with proper OTP record access for production mTLS.
      case cert do
        {:Certificate, _, subject, _, _, _, _} ->
          subject_fields = extract_subject_fields(subject)
          {:ok, subject_fields}

        _ ->
          {:error, :invalid_cert}
      end
    rescue
      e in [ArgumentError, MatchError, FunctionClauseError] ->
        # Certificate decoding can fail with these specific exceptions:
        #
        # - ArgumentError: malformed DER data passed to :public_key.pkix_decode_cert/2.
        #   This occurs when the binary is not valid ASN.1 DER encoding, is truncated,
        #   or contains invalid tag/length pairs.
        #
        # - MatchError: unexpected certificate structure after successful DER decoding.
        #   This can happen when the certificate uses extensions or encoding variants
        #   that don't match the expected OTP record structure.
        #
        # - FunctionClauseError: unsupported certificate version or algorithm.
        #   The :public_key module's internal functions may not have clauses for
        #   every possible certificate version (v1 certificates, for example,
        #   have a different structure than v3).
        #
        # We log the exception for debugging but return a clean error tuple
        # rather than crashing the request handler. The caller (extract_trust_level_from_cert/1)
        # treats this as "untrusted" -- a safe default.
        #
        # Note: We intentionally do NOT catch all exceptions (bare rescue) because
        # unexpected errors (e.g., ErlangError, SystemLimitError) indicate bugs
        # that should propagate to the supervisor for visibility and crash reporting.
        Logger.warning("Certificate decode failed", error: inspect(e))
        {:error, :decode_failed}
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

  # NOTE: The previous ad-hoc evaluate_access/2 function has been removed.
  # All access decisions now go through SafeTrust.evaluate/2 which implements
  # the formally verified trust hierarchy from proven/SafeTrust.idr.
  # The access decision is: rank(trust) >= rank(exposure), where ranks are
  # untrusted=0, authenticated=1, internal=2 for trust, and
  # public=0, authenticated=1, internal=2 for exposure.
  # See HttpCapabilityGateway.SafeTrust for the single source of truth.

  # Handle denied requests - apply stealth profile if configured.
  #
  # trust_level is now a SafeTrust atom (:untrusted, :authenticated, :internal).
  # We convert to string for stealth profile map lookups and JSON responses,
  # since stealth profiles use string keys matching the DSL v1 format.
  defp handle_denial(conn, rule, trust_level) do
    stealth_profile = get_stealth_profile(rule.stealth_profile)
    trust_str = Atom.to_string(trust_level)

    {status_code, response_body} =
      case stealth_profile do
        nil ->
          # No stealth - return clear error with trust/exposure atoms as strings
          {403, %{
            error: "Forbidden",
            message: "Insufficient trust level for this operation",
            required: rule.exposure,
            provided: trust_str
          }}

        profile when is_map(profile) ->
          # Apply stealth - return configured status for trust level.
          # Stealth profile keys are strings matching DSL v1 format.
          code = get_stealth_code(profile, trust_str, rule.exposure)
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
        # Ready to serve traffic.
        # Report rule counts from both main and regex tables.
        regex_table = Application.get_env(:http_capability_gateway, :policy_regex_table)

        main_count = :ets.info(policy_table, :size)

        regex_count =
          if regex_table && :ets.whereis(regex_table) != :undefined,
            do: :ets.info(regex_table, :size),
            else: 0

        rate_limiter_buckets = RateLimiter.bucket_count()

        response = %{
          status: "ready",
          service: "http-capability-gateway",
          policy_rules: main_count + regex_count,
          main_table_rules: main_count,
          regex_table_rules: regex_count,
          rate_limiter_buckets: rate_limiter_buckets
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
