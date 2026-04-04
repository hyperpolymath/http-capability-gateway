# TEST-NEEDS.md — http-capability-gateway

## CRG Grade: C — ACHIEVED 2026-04-04

> Generated 2026-03-29 by punishing audit.

## Current State

| Category     | Count | Notes |
|-------------|-------|-------|
| Unit tests   | 7     | gateway, policy_compiler, policy_loader, policy_validator, policy_property, performance, http_capability_gateway |
| Integration  | 0     | Fuzz dir exists but is placeholder only |
| E2E          | 0     | No end-to-end tests |
| Benchmarks   | 0     | None |

**Source modules:** ~19 Elixir modules (gateway, circuit_breaker, proxy, rate_limiter, safe_trust, graphql_handler, grpc_handler, policy_*, minikaran, logging, etc.) + 2 Idris2 ABI + 4 Zig FFI.

## What's Missing

### P2P (Property-Based) Tests
- [ ] Policy compilation: fuzz arbitrary YAML policies through compiler
- [ ] Rate limiter: property tests for token bucket invariants
- [ ] Circuit breaker: state machine property tests (closed->open->half-open)
- [ ] GraphQL/gRPC handler: arbitrary request shape handling

### E2E Tests
- [ ] Full request lifecycle: client -> gateway -> upstream -> response
- [ ] Multi-protocol routing (HTTP, GraphQL, gRPC through single gateway)
- [ ] Policy hot-reload under load
- [ ] Health check / readiness probe validation

### Aspect Tests
- **Security:** Request sanitization, header injection, SSRF prevention, capability token validation — ZERO tests
- **Performance:** No load tests, no latency benchmarks, no throughput measurement
- **Concurrency:** No tests for concurrent connections, race conditions in rate limiter, circuit breaker under contention
- **Error handling:** No tests for upstream timeout, malformed requests, policy parse failures

### Build & Execution
- [ ] `mix test` runner verification
- [ ] Zig FFI integration test execution
- [ ] Container build + smoke test

### Benchmarks Needed
- [ ] Request routing latency (per-protocol)
- [ ] Policy evaluation overhead
- [ ] Rate limiter throughput
- [ ] Circuit breaker state transition cost

### Self-Tests
- [ ] Configuration validation on startup
- [ ] Policy schema self-check
- [ ] Capability token format verification

## Priority

**CRITICAL.** 19 modules with 7 unit tests = 37% coverage by file count. A security gateway with ZERO security tests is a contradiction. No benchmarks for a performance-sensitive proxy is unacceptable. No concurrency tests for a concurrent system is negligent.

## FAKE-FUZZ ALERT

- `tests/fuzz/placeholder.txt` is a scorecard placeholder inherited from rsr-template-repo — it does NOT provide real fuzz testing
- Replace with an actual fuzz harness (see rsr-template-repo/tests/fuzz/README.adoc) or remove the file
- Priority: P2 — creates false impression of fuzz coverage
