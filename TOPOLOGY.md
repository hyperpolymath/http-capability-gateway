<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and component status -->
<!-- Last updated: 2026-04-16 -->

> **Note (2026-04-16):** The "completion percentage" model used in earlier
> versions of this document was misleading — components claimed as "100%"
> (e.g., mTLS) were verified-broken in review. This document now reports
> **implementation status** rather than topology percentages. For the
> authoritative "what works today" picture, see `docs/SUPPORTED-FEATURES.md`.
> For release gating, see `docs/RELEASE-CRITERIA.md`.

# http-capability-gateway — Project Topology

## System Architecture

```
                        ┌─────────────────────────────────────────┐
                        │              HTTP TRAFFIC               │
                        │        (GET, POST, DELETE, etc.)        │
                        └───────────────────┬─────────────────────┘
                                            │
                                            ▼
                        ┌─────────────────────────────────────────┐
                        │           GATEWAY CORE (ELIXIR)         │
                        │    (Governance Layer / Enforcement)     │
                        │                                         │
                        │  ┌─────────────────────────────────┐    │
                        │  │  Security Headers Plug           │    │
                        │  │  (OWASP: nosniff, DENY, etc.)   │    │
                        │  └─────────────────────────────────┘    │
                        └──────────┬───────────────────┬──────────┘
                                   │                   │
                                   ▼                   ▼
                        ┌───────────────────────┐  ┌────────────────────────────────┐
                        │ POLICY ENGINE         │  │ LOGGING & AUDIT                │
                        │ - Loader (DSL v1)     │  │ - Decision Context             │
                        │ - Validator           │  │ - Structured JSON Logs         │
                        │ - Compiler (Tiered)   │  │ - Narrative Metadata           │
                        │   T1: Exact O(1)      │  │ - Telemetry Events             │
                        │   T2: Regex O(r)      │  └──────────┬─────────────────────┘
                        │   T3: Global O(1)     │              │
                        └──────────┬────────────┘              │
                                   │                           │
                                   └────────────┬──────────────┘
                                                ▼
                        ┌─────────────────────────────────────────┐
                        │           UPSTREAM SERVICES             │
                        │      (Nginx, Apache, App Servers)       │
                        └─────────────────────────────────────────┘

                        ┌─────────────────────────────────────────┐
                        │          REPO INFRASTRUCTURE            │
                        │  Justfile / mix.exs .machine_readable/  │
                        │  Mustfile / Docker  0-AI-MANIFEST.a2ml  │
                        └─────────────────────────────────────────┘
```

## Component Status

Statuses below are backed by executed tests. See `docs/SUPPORTED-FEATURES.md`
for detailed caveats.

| Component | Status | Verified By |
|-----------|--------|-------------|
| **CORE GATEWAY** | | |
| Policy Loader (DSL v1) | Supported | `test/policy_loader_test.exs` |
| Validator | Supported | `test/policy_validator_test.exs` |
| Compiler (Tiered Lookup) | Supported | `test/policy_compiler_test.exs`, `test/benchmark_test.exs` |
| Enforcement Engine | Supported | `test/gateway_test.exs`, `test/e2e_test.exs` |
| Security Headers | Supported | `test/security_test.exs` |
| Atomic Policy Reload | Supported | `test/e2e_test.exs`, `test/concurrency_test.exs` |
| **INTERFACES & LOGS** | | |
| HTTP Proxy Layer | Supported | `test/e2e_test.exs` (502 on backend down) |
| Structured JSON Logs | Supported | Emitted by `log_decision/7`; no direct assertion |
| Stealth Profiles | Supported | `test/gateway_test.exs` stealth describe block |
| Prometheus Metrics | Supported | `GET /metrics` covered by e2e setup |
| **HEALTH & TRUST** | | |
| Health Check (`/health`) | Supported | `test/e2e_test.exs` |
| Readiness Check (`/ready`) | Supported | `test/e2e_test.exs` |
| Trust Header Extraction | Supported | `test/security_test.exs` |
| Trust Header Spoofing Protection | Supported | `test/security_test.exs` |
| mTLS Trust Extraction | Supported with caveats | Code uses `Record.extract` accessors; no integration test against a real CA yet |
| Rate Limiter (trust-scoped) | Supported | `test/concurrency_test.exs`, `test/benchmark_test.exs` |
| Circuit Breaker | Supported | `test/circuit_breaker_test.exs`, `test/concurrency_test.exs` |
| K9 Service Contracts | Supported | `test/k9_contract_test.exs` |
| **PROTOCOL HANDLERS** | | |
| HTTP/REST | Supported | Full test coverage |
| GraphQL | Stub only | `check_operation_policy/2` always returns true; do not use in production |
| gRPC | Stub only | `forward_grpc_request/5` returns hardcoded response; do not use in production |
| **REPO INFRASTRUCTURE** | | |
| Justfile Automation | Supported | N/A (developer tooling) |
| `.machine_readable/` | Supported | `STATE.a2ml` authoritative |
| Containerfile | Supported | Builds documented in `docs/DEPLOYMENT.md` |

## Key Dependencies

```
Policy Spec (DSL) ───► Validator ───► Compiler ───► Rule Table
                                                      │
                                                      ▼
HTTP Traffic ───────► Enforcement ───────────────► Forward / Block
```

## Update Protocol

This file is maintained by both humans and AI agents. When updating:

1. **Status changes**: A component moves to "Supported" only when it has at
   least one executed test. Do not claim completion based on code presence.
2. **Adding a component**: Add a new row with the test file that verifies it.
   If no test exists, mark as "Stub only" or "Not implemented".
3. **Architectural changes**: Update the ASCII diagram in the System Architecture section.
4. **Date**: Update the `Last updated` comment at the top of this file.
5. **No percentages**: Percentage-based completion claims are banned —
   they encouraged unjustified optimism (see 2026-04-16 correction note).

Progress bars use: `█` (filled) and `░` (empty), 10 characters wide.
Percentages: 0%, 10%, 20%, ... 100% (in 10% increments).
