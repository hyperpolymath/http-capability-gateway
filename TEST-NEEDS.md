# TEST-NEEDS.md — http-capability-gateway

## CRG Grade: C — ACHIEVED 2026-04-04

> Generated 2026-03-29 by punishing audit. Superseded 2026-04-16 by the
> P0/P1/P2 test work documented below.

## Current State (updated 2026-04-16)

| Category     | Count | Notes |
|-------------|-------|-------|
| Unit tests   | 9     | gateway, policy_compiler, policy_loader, policy_validator, policy_property, performance, http_capability_gateway, **circuit_breaker**, **k9_contract** |
| Security     | 1     | security_test.exs: sanitization, headers, SSRF, capability tokens (30+ tests) |
| E2E          | 1     | e2e_test.exs: full lifecycle, policy hot-reload, upstream proxy, health probes (20+ tests) |
| Concurrency  | 1     | concurrency_test.exs: rate limiter contention, circuit breaker serialization, atomic reload under load |
| Fuzz         | 1     | fuzz_test.exs: property-based fuzzing with StreamData (6 properties) |
| Benchmarks   | 2     | performance_test.exs (existing) + benchmark_test.exs (rate limiter / circuit breaker / route lookup) |

**Source modules:** ~19 Elixir modules + 2 Idris2 ABI + 2 Zig FFI parsers.

## Coverage Summary

### ✅ Covered

- **P2P (Property-Based) Tests**
  - Policy compilation: arbitrary YAML through compiler (`test/fuzz_test.exs`)
  - Circuit breaker: state machine transitions (`test/circuit_breaker_test.exs`)
  - Rate limiter: token bucket under contention (`test/concurrency_test.exs`)

- **E2E Tests**
  - Full request lifecycle (`test/e2e_test.exs`)
  - Policy hot-reload under load (`test/concurrency_test.exs`)
  - Health check / readiness probe validation (`test/e2e_test.exs`)

- **Aspect Tests**
  - **Security:** Request sanitization, header injection, SSRF prevention, capability token validation (`test/security_test.exs`)
  - **Concurrency:** Rate limiter and circuit breaker under contention (`test/concurrency_test.exs`)
  - **Performance:** Rate limiter, circuit breaker, route lookup benchmarks (`test/benchmark_test.exs`)

- **Benchmarks**
  - Rate limiter throughput (`test/benchmark_test.exs`)
  - Circuit breaker state transition cost (`test/benchmark_test.exs`)
  - Exact vs regex vs global-fallback route lookup (`test/benchmark_test.exs`)
  - Policy evaluation overhead (`test/performance_test.exs`)
  - Full plug pipeline throughput (`test/benchmark_test.exs`)

### ⚠️ Still Missing

- **Multi-protocol routing tests** — GraphQL/gRPC handlers are stubs per `docs/SUPPORTED-FEATURES.md`, so this is out of MVP scope rather than "missing".
- **Zig FFI integration test execution** — requires zig toolchain; covered by separate FFI build step.
- **Container build smoke test** — performed in CI, not in `mix test`.
- **Error handling: upstream timeout** — Req receive_timeout covered implicitly; no dedicated test.
- **Real-CA mTLS integration test** — code uses `Record.extract` accessors but no live cert in test fixtures.
- **Self-tests for config validation on startup** — Application.start refuses without policy, but no dedicated assertion.

## Priority

Originally **CRITICAL** when only 7 unit tests covered 19 modules.
Now: the release gate in `docs/RELEASE-CRITERIA.md` maps every MVP claim
to a concrete test file. Remaining items are clearly marked above and
are not release blockers for v0.1.0.

## FUZZ STATUS

- `tests/fuzz/placeholder.txt` has been removed (was a scorecard placeholder, not real fuzzing).
- Real property-based fuzz tests added in `test/fuzz_test.exs` using StreamData.
- Covers: arbitrary HTTP methods, trust strings, paths, policies, and combined input fuzzing.
