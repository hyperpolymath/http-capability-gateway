<!-- SPDX-License-Identifier: MPL-2.0 -->

# Supported Features — HTTP Capability Gateway

**Version:** 0.1.0-dev
**Last updated:** 2026-04-16
**Status:** MVP verification phase (CRG grade C)

This document is the single authoritative reference for what the gateway
actually supports today. If it is not in the **Supported** list below, it
is either a stub, planned work, or out of scope — do not rely on it in
production.

See `ROADMAP.adoc` for the formal MVP scope definition with test mappings,
and `MULTI-PROTOCOL.md` for protocol-specific details (note that document
describes a broader vision; the table here reflects actual runtime behaviour).

---

## Protocols

| Protocol | Status | Notes |
|----------|--------|-------|
| **HTTP/1.1** | Supported | Full verb governance, proxy forwarding, stealth mode. This is the MVP scope. |
| **HTTP/2** | Supported (via Cowboy) | Inherited from Plug.Cowboy adapter. Not exercised by gateway-specific tests. |
| **HTTPS / TLS** | Not supported | No TLS termination inside the gateway. Run behind a TLS-terminating proxy (nginx, Caddy, Svalinn, etc.). |
| **mTLS (client certs)** | Partial | `extract_trust_level_from_cert/1` now uses proper `Record.extract`-based OTPCertificate accessors (OTP-version-robust) and extracts the subject's CN/O/OU fields. Not yet validated against real CA certificates in an integration test — exercise in staging before relying on it for trust decisions. |
| **GraphQL** | Stub only | `GraphQLHandler` parses JSON bodies and does naive prefix-based operation detection. `check_operation_policy/2` always returns true. Operation-level governance is not implemented. |
| **gRPC** | Stub only | `GRPCHandler` extracts service/method from path but `forward_grpc_request/5` returns a hardcoded response — no actual gRPC forwarding. |
| **WebSocket** | Not supported | No implementation. |

## Trust Sources

| Source | Status | Notes |
|--------|--------|-------|
| **`X-Trust-Level` header** | Supported | The canonical trust source. Values: `untrusted`, `authenticated`, `internal`. Anything else is parsed as `:untrusted` (see `SafeTrust.parse_trust/1`). |
| **Header stripping for untrusted sources** | Supported | `strip_untrusted_headers/2` removes `X-Trust-Level` from any request whose `remote_ip` is not in `:trusted_proxies`. Default trusted proxies: `["127.0.0.1", "::1"]`. **Operator action required**: configure `:trusted_proxies` for your deployment before exposing the gateway. |
| **mTLS certificate OU** | Supported with caveats | Subject extraction uses stable `Record.extract` accessors. An OU of "Internal Services" maps to `:internal`; any other verified cert maps to `:authenticated`. Test against your CA's cert format before production use — OU field name conventions vary. |
| **Authorization header (JWT/Bearer)** | Not parsed | The gateway does not parse or validate tokens. The upstream that sets `X-Trust-Level` is expected to do this (e.g., indieweb2-bastion in the hyperpolymath stack). |
| **IP allowlist** | Not supported | The gateway does not block by IP. Rely on upstream L4/L7 filtering. |

## Policy Enforcement

| Feature | Status | Notes |
|---------|--------|-------|
| **YAML policy loading** | Supported | `PolicyLoader.load_from_file/1` reads DSL v1 files. |
| **Policy validation** | Supported | `PolicyValidator.validate/1` rejects malformed policies before compilation. |
| **Policy compilation to ETS** | Supported | Dual-table layout: main (exact + global) and regex. |
| **Exact path matching** | Supported | O(1) via ETS `{:exact, path, verb}` keys. |
| **Regex path matching** | Supported | O(r) scan of dedicated regex table. |
| **Global verb rules** | Supported | Fallback when no route matches. |
| **Atomic policy hot-reload** | Supported | Recompiling creates new tables and swaps app env references atomically. See `test/e2e_test.exs` hot-reload tests. |
| **Per-route exposure overrides** | Supported | Route `exposure` field overrides global behaviour. |
| **Stealth mode (configurable status codes)** | Supported | Default 404 hides denied endpoints. |
| **Default-deny on no match** | Supported | Returns 403 (or stealth code) when no rule matches. |

## Runtime Features

| Feature | Status | Notes |
|---------|--------|-------|
| **Rate limiting (token bucket)** | Supported | Per-(IP, trust) buckets. Defaults: `untrusted` 10 req/s, `authenticated` 100 req/s, `internal` unlimited. `X-Forwarded-For` is trusted for client IP — require a trusted reverse proxy to prevent spoofing. |
| **Circuit breaker** | Supported | Three-state FSM (closed/open/half_open) per backend. 5 failures to trip, 30s before half-open probe (configurable). |
| **K9 service contracts** | Partial | Trust threshold enforcement works. `rate_limit` field on contracts is declared but NOT enforced. |
| **Structured JSON logs** | Supported | Every access decision logged with request_id, path, verb, trust_level, decision. |
| **Telemetry events** | Supported | All major events emit `[:http_capability_gateway, ...]` telemetry. |
| **Health probe** | Supported | `GET /health` returns 200 with uptime. |
| **Readiness probe** | Supported | `GET /ready` returns 200 iff policy is loaded. |
| **Prometheus metrics** | Supported | `GET /metrics` via `TelemetryMetricsPrometheus.Core.scrape/0`. |
| **Anomaly detection (Minikaran)** | Supported | `GET /api/v1/minikaran` returns current anomalies. |
| **Audit log (VeriSimDB)** | Supported | Allow/deny decisions persisted asynchronously. |

## Out of MVP Scope

The following are explicitly **not** in the v0.1.0 MVP:

- Multi-backend load balancing
- TLS termination
- Response caching
- Request/response body transformation
- Dynamic trust scoring / ML-based trust
- Web UI / admin dashboard
- Plugin system (auth, filters, custom loaders)
- Distributed cluster coordination
- Kubernetes operator
- Helm chart

See `ROADMAP-v2.md` for these items; they are **aspirational** and not
on the release path for v0.1.0.

---

## Operator Quick Checklist

Before exposing the gateway to the public internet:

1. **Configure `:trusted_proxies`** — add the IP addresses of your upstream
   TLS-terminating proxies. Without this, direct clients can forge
   `X-Trust-Level: internal` and bypass all governance.
2. **Test mTLS trust extraction against your CA's cert format** — the code
   uses `Record.extract`-based OTPCertificate accessors that are stable
   across OTP versions, but OU field conventions vary between CAs and
   there is no integration test yet against real client certificates.
3. **Do NOT route GraphQL or gRPC traffic through this gateway** —
   handlers are stubs. HTTP/REST only.
4. **Set realistic `:rate_limits`** for your traffic. The test defaults
   are set very high for test predictability.
5. **Provide a valid policy file at startup** — the application refuses
   to start without one (fail-closed).
6. **Put a TLS-terminating proxy in front** — the gateway does not do TLS.
7. **Monitor the `/metrics` endpoint** — especially
   `http_capability_gateway_circuit_breaker_*` and rate-limit counters.
