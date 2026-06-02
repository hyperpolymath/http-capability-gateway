# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
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
  require Record

  alias HttpCapabilityGateway.CircuitBreaker
  alias HttpCapabilityGateway.K9Contract
  alias HttpCapabilityGateway.Minikaran
  alias HttpCapabilityGateway.PolicyCompiler
  alias HttpCapabilityGateway.Proxy
  alias HttpCapabilityGateway.RateLimiter
  alias HttpCapabilityGateway.SafeTrust
  alias HttpCapabilityGateway.VeriSimDB

  # Erlang OTPCertificate / OTPTBSCertificate record accessors.
  #
  # When :public_key.pkix_decode_cert/2 is called with :otp, it returns an
  # OTPCertificate record (which in Elixir is an erlang-record tuple). The
  # record definitions live in OTP's public_key application header file.
  # Record.extract pulls the CURRENT definitions at compile time, so the
  # field accessors stay correct across OTP versions even if the record
  # layout is extended.
  #
  # Defined as private (defrecordp) because they're an implementation detail
  # of extract_cert_subject/1 and should never leak outside this module.
  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  # Safe HTTP verb conversion with allowlist.
  #
  # String.to_existing_atom/1 crashes on unknown verbs (ArgumentError),
  # which is a DoS vector -- any client can crash the handler by sending
  # an exotic HTTP method like PROPFIND, MKCOL, REPORT, or any arbitrary
  # string. The BEAM atom table is finite (~1M atoms) and not garbage
  # collected, so String.to_existing_atom/1 is equally dangerous (atom exhaustion).
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
  # safely maps strings to atoms from a fixed set (no String.to_existing_atom).
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

  # Minikaran anomaly dashboard endpoint.
  #
  # Returns JSON with current anomalies, baseline summary, and operational
  # status. This endpoint is intended for monitoring dashboards and alerting
  # integrations, NOT for end-user consumption.
  #
  # Placed before the catch-all route so it is matched literally by Plug.Router.
  get "/api/v1/minikaran" do
    handle_minikaran_dashboard(conn)
  end

  # Catch-all route - enforce policy on all requests
  match _ do
    handle_request(conn)
  end

  # Safely converts an HTTP method string to its corresponding atom.
  #
  # Uses the @valid_methods allowlist to avoid the DoS vector inherent in
  # String.to_existing_atom/1 (which raises ArgumentError on unknown atoms)
  # and String.to_existing_atom/1 (which can exhaust the BEAM atom table).
  #
  # Returns the atom for known HTTP methods, or nil for unknown methods.
  # The caller (handle_request/1) uses this to short-circuit unknown methods
  # with a 405 response before any policy evaluation occurs.
  #
  # Parameters:
  #   - method: HTTP method string from conn.method (e.g., "GET", "PROPFIND")
  #
  # Returns:
  #   - Atom like :GET, :POST, etc. for valid methods
  #   - nil for unknown/unsupported methods
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
  atom table exhaustion from String.to_existing_atom/1, both of which are DoS vectors.
  """
  def handle_request(conn) do
    start_time = System.monotonic_time()
    request_id = get_request_id(conn)
    conn = Plug.Conn.assign(conn, :request_id, request_id)

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

        # Persist to the audit ledger so probes for unsupported verbs
        # (PROPFIND/MKCOL/REPORT/garbage) leave a forensic trail. This was
        # missing from the audit stream — the most security-relevant path
        # (unknown verb against an undeclared route) was the one not being
        # recorded. The verb string is passed as-is (no atom creation);
        # VeriSimDB stores it verbatim. The "policy_ref" carries a
        # discriminator so the audit reader can distinguish this case from
        # a legitimate deny.
        trust_level = Map.get(conn.assigns, :trust_level, :untrusted)
        VeriSimDB.audit_deny(path, conn.method, trust_level, "unknown_method:#{conn.method}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(405, Jason.encode!(%{error: "Method Not Allowed"}))
        |> halt()

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

                  # Async audit: persist allow decision to VeriSimDB (capgw:audit)
                  VeriSimDB.audit_allow(path, verb, trust_level, rule.backend, rule.name, duration_us)

                  # K9-SVC contract enforcement: check if a service contract exists
                  # for this route+verb. If so, enforce pre-proxy constraints (trust
                  # threshold, contract-specific rate limit) before forwarding. After
                  # proxying, check response latency against the contract's max_latency_ms.
                  enforce_with_contract(conn, rule, path, verb, trust_level)

                {:deny, _t, _e} ->
                  # Access denied -- apply stealth profile if configured, otherwise 403
                  duration_us = System.monotonic_time() - start_time
                  log_decision(request_id, path, verb, trust_level, :deny, rule, duration_us)

                  # Async audit: persist deny decision to VeriSimDB (capgw:audit)
                  VeriSimDB.audit_deny(path, verb, trust_level, rule.name)

                  handle_denial(conn, rule, trust_level)
              end

            {:error, :no_match} ->
              # No policy rule matches this path+verb combination -- default deny.
              duration_us = System.monotonic_time() - start_time
              log_decision(request_id, path, verb, trust_level, :no_match, nil, duration_us)

              # Persist to the audit ledger as well. The no-match path is
              # security-relevant (a probe for an undeclared route) and was
              # previously logged but not persisted. The "policy_ref"
              # discriminator lets the audit reader filter no-match denials
              # from explicit-rule denials.
              VeriSimDB.audit_deny(path, to_string(verb), trust_level, "no_match")

              stealth_profiles = Application.get_env(:http_capability_gateway, :stealth_profiles, %{})
              stealth_enabled? = stealth_profiles != %{}

              if stealth_enabled? do
                status = get_in(stealth_profiles, ["default", to_string(trust_level)]) || 404
                conn
                |> send_resp(status, "")
                |> halt()
              else
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(403, Jason.encode!(%{error: "Forbidden"}))
                |> halt()
              end
          end
        end
    end
  end

  # K9-SVC contract enforcement wrapper.
  #
  # If a K9 contract exists for this route+verb, enforce pre-proxy constraints
  # (trust threshold) and post-proxy constraints (latency SLA). If no contract
  # exists, forward directly to the backend (unchanged behaviour).
  #
  # The contract enforcement pipeline:
  #   1. Lookup contract for route+verb (O(1) ETS, with wildcard fallback)
  #   2. Pre-proxy: check trust threshold meets contract minimum
  #   3. Forward to backend via Proxy.forward/2 (with contract timeout_ms)
  #   4. Post-proxy: measure response latency against contract max_latency_ms
  #   5. If breached: execute breach policy (log, alert, circuit_break, fallback)
  defp enforce_with_contract(conn, rule, path, verb, trust_level) do
    # Circuit breaker check: reject requests to backends with open circuits
    # BEFORE doing any contract lookup or proxying. This prevents wasting
    # resources on requests that will fail anyway. The backend identifier
    # is the service name from the K9 contract, or "default" for uncontracted routes.
    backend_name =
      case K9Contract.lookup(path, verb) do
        nil -> "default"
        %K9Contract{service: service} -> service
      end

    if CircuitBreaker.allow?(backend_name) do
      enforce_with_contract_inner(conn, rule, path, verb, trust_level)
    else
      # Circuit is open — reject immediately with 503 to prevent hammering
      # the degraded backend. The circuit breaker will automatically probe
      # for recovery via the half-open state after a configured timeout.
      Logger.warning("Request rejected by circuit breaker",
        backend: backend_name,
        path: path,
        verb: verb
      )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{
        error: "Service Unavailable",
        message: "Circuit breaker open for backend '#{backend_name}'"
      }))
    end
  end

  # Inner contract enforcement, called after the circuit breaker check passes.
  # Separated to keep the circuit breaker guard clean and avoid deep nesting.
  defp enforce_with_contract_inner(conn, rule, path, verb, trust_level) do
    case K9Contract.lookup(path, verb) do
      nil ->
        # No K9 contract for this route — forward directly (existing behaviour).
        Proxy.forward(conn, rule)

      %K9Contract{} = contract ->
        # K9 contract found — enforce pre-proxy constraints.
        case K9Contract.enforce_pre_proxy(contract, trust_level) do
          :ok ->
            # Pre-proxy passed — forward with timing measurement.
            proxy_start = System.monotonic_time(:millisecond)
            result_conn = Proxy.forward(conn, rule)
            proxy_end = System.monotonic_time(:millisecond)
            latency_ms = proxy_end - proxy_start

            # Post-proxy: check latency against contract SLA.
            case K9Contract.enforce_post_proxy(contract, latency_ms) do
              {:ok, :within_sla} ->
                # Contract fulfilled — return the proxied response as-is.
                result_conn

              {:breach, breach_policy, actual_latency} ->
                # Contract breached — execute breach policy.
                K9Contract.execute_breach_policy(contract, breach_policy, actual_latency)

                case breach_policy do
                  :fallback ->
                    # Fallback: return a degraded response instead of the slow one.
                    conn
                    |> put_resp_content_type("application/json")
                    |> send_resp(503, Jason.encode!(%{
                      error: "Service Degraded",
                      message: "Response exceeded SLA (#{actual_latency}ms > #{contract.max_latency_ms}ms)",
                      contract_id: contract.contract_id
                    }))

                  _other ->
                    # For :log, :alert, :circuit_break — return the actual response.
                    # The breach has been recorded; the response is still valid data.
                    result_conn
                end
            end

          {:error, :trust_insufficient} ->
            # Trust level doesn't meet contract minimum — deny with 403.
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(403, Jason.encode!(%{
              error: "Contract Trust Insufficient",
              message: "K9-SVC contract requires #{contract.trust_threshold} trust level",
              contract_id: contract.contract_id
            }))

          {:error, :contract_rate_limited} ->
            # Contract-specific rate limit exceeded — deny with 429 and a
            # Retry-After hint of 1 second (the shortest meaningful window
            # for a per-second token bucket). The global RateLimiter runs
            # earlier in the pipeline; this catches contract-level capacity
            # limits that apply across all clients of a specific route.
            conn
            |> put_resp_header("retry-after", "1")
            |> put_resp_content_type("application/json")
            |> send_resp(429, Jason.encode!(%{
              error: "Too Many Requests",
              message: "K9-SVC contract rate limit exceeded",
              contract_id: contract.contract_id,
              rate_limit: contract.rate_limit
            }))
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

  # Extract subject fields from an X.509 certificate (DER-encoded).
  #
  # Uses :public_key.pkix_decode_cert/2 in :otp mode, which returns an
  # OTPCertificate record. The subject is nested inside the TBSCertificate:
  #
  #   #'OTPCertificate'{
  #     tbsCertificate: #'OTPTBSCertificate'{
  #       subject: {:rdnSequence, [...]}
  #     }
  #   }
  #
  # We use Record.extract accessors (defined at the top of this module) to
  # pull the subject field robustly, instead of a positional tuple match
  # that would break if OTP ever extends the record layout. This is the
  # production-grade replacement for the earlier approximation that matched
  # on {:Certificate, _, subject, _, _, _, _}.
  #
  # `@doc false` (public but internal): exposed so the mTLS test suite can
  # drive it with real test-CA DER without a live TLS socket. Not part of
  # the supported public API.
  @doc false
  def extract_cert_subject(cert_der) when is_binary(cert_der) do
    try do
      cert = :public_key.pkix_decode_cert(cert_der, :otp)

      # Use Record accessors for forward compatibility. If the returned
      # value is not an OTPCertificate record (e.g., some exotic cert
      # variant), the match fails and we report :invalid_cert.
      tbs = otp_certificate(cert, :tbsCertificate)
      subject = otp_tbs_certificate(tbs, :subject)

      subject_fields = extract_subject_fields(subject)
      {:ok, subject_fields}
    rescue
      e in [ArgumentError, MatchError, FunctionClauseError, CaseClauseError] ->
        # Certificate decoding can fail with these specific exceptions:
        #
        # - ArgumentError: malformed DER data passed to :public_key.pkix_decode_cert/2.
        #   This occurs when the binary is not valid ASN.1 DER encoding, is truncated,
        #   or contains invalid tag/length pairs.
        #
        # - MatchError: unexpected certificate structure after successful DER decoding.
        #   Raised when extract_subject_fields/1 receives something other than an
        #   `{:rdnSequence, _}` tuple (e.g., an unusual encoding variant).
        #
        # - FunctionClauseError: unsupported certificate version or algorithm.
        #   The :public_key module's internal functions may not have clauses for
        #   every possible certificate version (v1 certificates, for example,
        #   have a different structure than v3).
        #
        # - CaseClauseError: unexpected record shape from Record.extract accessors
        #   (e.g., a non-OTPCertificate value was returned).
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

  # Check whether the client certificate was actually verified by the
  # TLS transport -- NOT merely present.
  #
  # The mTLS listener is configured (Application.tls_socket_opts/0) with
  # `verify: :verify_peer` and `fail_if_no_peer_cert: true`. With that
  # configuration the TLS handshake itself rejects any peer that does not
  # present a certificate chaining to the configured CA. Chain validation
  # is therefore a transport-level guarantee: a request can only reach this
  # Plug pipeline over the HTTPS listener if its client certificate already
  # verified during the handshake.
  #
  # The previous implementation returned `true` whenever ANY certificate
  # was present. That is forgeable: a request arriving over the plaintext
  # HTTP listener could carry an attacker-supplied DER blob and be treated
  # as verified. We now fail closed unless ALL of the following hold:
  #
  #   1. the request arrived over TLS (`conn.scheme == :https`), so it came
  #      through the verify_peer listener and not the plaintext one;
  #   2. the adapter is the Cowboy adapter (the only adapter that can have
  #      performed the TLS peer verification);
  #   3. a non-empty peer certificate is present (redundant given
  #      verify_peer + fail_if_no_peer_cert, but checked explicitly as
  #      defence in depth and to reject empty/:undefined cert values).
  #
  # We deliberately do NOT reach into Cowboy's opaque request map to
  # re-derive the SSL session: chain validation already happened at the
  # handshake, Cowboy does not surface a post-handshake "verify result"
  # field, and depending on undocumented internal keys would be fragile
  # across Cowboy versions. The scheme + adapter + cert-presence triple is
  # the sound, stable signal.
  defp is_cert_verified(%Plug.Conn{scheme: :https, adapter: {Plug.Cowboy.Conn, _req}} = conn) do
    case get_peer_cert(conn) do
      {:ok, cert} when is_binary(cert) and byte_size(cert) > 0 -> true
      _ -> false
    end
  end

  defp is_cert_verified(_conn), do: false

  # Determine trust level from certificate attributes.
  #
  # `@doc false` (public but internal): exposed for the mTLS test suite so
  # the cert->trust mapping can be proven against real test-CA certs. Not
  # part of the supported public API.
  @doc false
  def determine_trust_level_from_cert(subject, verified) do
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
    |> halt()
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

  @doc """
  Minikaran anomaly dashboard endpoint.

  Returns a JSON object with three sections:

    - `status` -- operational status (learning/active) and uptime info
    - `anomalies` -- list of currently flagged anomalies with type labels
    - `baseline` -- learned baseline summary (null while in learning phase)

  This endpoint reads directly from Minikaran's ETS tables for O(1)
  response time, making it safe to poll frequently from monitoring systems.

  ## Response Shape

      {
        "status": {
          "status": "active",
          "windows_collected": 42,
          "min_windows_required": 5,
          "current_anomalies": 1,
          "uptime_sec": 2520
        },
        "anomalies": [
          {"type": "traffic_spike", "path": "/api/v1/users", "current": 150, "baseline": 42.3}
        ],
        "baseline": {
          "window_count": 41,
          "avg_requests_per_minute": 85.2,
          ...
        }
      }
  """
  def handle_minikaran_dashboard(conn) do
    # Fetch all three data sources in parallel (all are O(1) ETS reads
    # or fast GenServer calls).
    minikaran_status = Minikaran.status()
    current_anomalies = Minikaran.anomalies()
    current_baseline = Minikaran.baseline()

    # Format anomalies as JSON-friendly maps with explicit type labels.
    formatted_anomalies = Enum.map(current_anomalies, &format_anomaly_json/1)

    # Format baseline: convert atom keys to strings for JSON serialization.
    # Minikaran.baseline/0 returns nil during the learning phase.
    formatted_baseline =
      case current_baseline do
        nil -> nil
        baseline -> format_baseline_json(baseline)
      end

    response = %{
      status: minikaran_status,
      anomalies: formatted_anomalies,
      baseline: formatted_baseline
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  # Formats a Minikaran anomaly tuple into a JSON-serializable map.
  #
  # Each anomaly type has different fields, so we pattern-match and
  # produce a consistently shaped map with a :type discriminator.
  defp format_anomaly_json({:traffic_spike, path, current, baseline}) do
    %{type: "traffic_spike", path: path, current: current, baseline: baseline}
  end

  defp format_anomaly_json({:trust_shift, trust_level, current_pct, baseline_pct}) do
    %{
      type: "trust_shift",
      trust_level: Atom.to_string(trust_level),
      current_pct: current_pct,
      baseline_pct: baseline_pct
    }
  end

  defp format_anomaly_json({:latency_spike, percentile, current_ms, baseline_ms}) do
    %{
      type: "latency_spike",
      percentile: Atom.to_string(percentile),
      current_ms: current_ms,
      baseline_ms: baseline_ms
    }
  end

  defp format_anomaly_json({:path_novelty, new_paths, total_paths}) do
    %{type: "path_novelty", new_paths: new_paths, total_paths: total_paths}
  end

  defp format_anomaly_json({:error_spike, current_rate, baseline_rate}) do
    %{type: "error_spike", current_rate: current_rate, baseline_rate: baseline_rate}
  end

  # Formats the baseline summary map for JSON output.
  #
  # Converts atom keys in the trust_distribution sub-map to strings,
  # since JSON does not support atom keys.
  defp format_baseline_json(baseline) do
    trust_dist =
      Map.get(baseline, :trust_distribution, %{})
      |> Enum.into(%{}, fn {k, v} -> {Atom.to_string(k), v} end)

    %{
      window_count: baseline.window_count,
      avg_requests_per_minute: baseline.avg_requests_per_minute,
      trust_distribution: trust_dist,
      latency_p50_us: baseline.latency_p50_us,
      latency_p95_us: baseline.latency_p95_us,
      latency_p99_us: baseline.latency_p99_us,
      avg_error_rate: baseline.avg_error_rate,
      known_paths: baseline.known_paths,
      avg_unique_clients: baseline.avg_unique_clients
    }
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
