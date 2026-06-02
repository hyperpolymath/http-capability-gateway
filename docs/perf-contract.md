<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Performance Contract

> **Status: scaffold (Phase D-3).** This document names the SLOs the
> gateway will publish and the regression-alert gate will enforce. The
> concrete numbers are deliberately left as `TODO` — Phase D-4 of the
> single-lane HCG channel (standards#91) collects the baseline and fills
> them in. The CI gate is non-blocking until that point. Phase D-3 (this
> revision) is the last harness-shape change before D-4 collection: it
> adds the `trust-header rewrite`, `mTLS handshake`, and `mTLS amortised`
> scenarios so the baseline attributes header-rewrite cost, per-handshake
> cost, and per-request kept-alive cost independently of the proxy-200
> path.

Tracks: `Refs hyperpolymath/standards#99` (Phase D of `standards#91`).

## Scope of this contract

This contract covers in-gateway latency — the cost of the gateway's
own pipeline (trust resolution, policy lookup, rate limiter, circuit
breaker, header rewrite). The `exact route allow (proxy 200)` scenario
also includes the dial-and-read cost against an in-process loopback
backend (added in Phase D-2), since the production gateway always pays
that cost on an allow path; the loopback strips out real-network RTT and
real-backend processing time so what remains is the gateway-attributable
proxy overhead. The `mTLS handshake` scenario (added in Phase D-3)
covers per-handshake transport cost in isolation, and the
`mTLS amortised` scenario (added in the Phase D-3 follow-up) covers the
per-request cost when N=16 requests share one kept-alive TLS connection,
closing the bracket that `proxy 200` + `mTLS handshake` left loose. Real
production backend latency and real-network RTT remain out of scope.

The six named scenarios match the six Benchee scenarios in
`bench/gateway_latency.exs`:

| Scenario                                                  | What it measures                                                                  |
|-----------------------------------------------------------|-----------------------------------------------------------------------------------|
| `health endpoint`                                         | Cheapest path. No policy lookup, no proxy. Floor of any plug-pipeline overhead.   |
| `policy deny (405 fast-path)`                             | Verb-rejection path. Policy table hit, no proxy. Cost of the deny short-circuit.  |
| `exact route allow (proxy 200)`                           | Allow path that proxies to an in-process loopback backend returning 200. Captures the real dial-and-read cost the gateway pays in production. |
| `trust-header rewrite (Proxy.build_backend_headers)`      | Direct call to the `Proxy.__benchmark_build_backend_headers__/1` benchmark seam on a pre-built conn (`assigns[:trust_level] = :authenticated`, `assigns[:request_id]` set). Isolates the Phase A contract-header construction (X-Trust-Level / X-Request-ID / X-Forwarded-*) from policy lookup and network I/O. |
| `mTLS handshake (test CA)`                                | `:ssl.connect/4` against a raw `:ssl` acceptor + immediate close. Test CA chain is generated in-memory at bench startup via `:public_key.pkix_test_data/1` — the committed Phase B fixture ships only `*.crt` files (matching `*.key` is gitignored), so the chain is rebuilt with the same `verify_peer` + test-CA shape rather than reusing the on-disk material. Per-handshake cost (cert chain validation + key exchange) in isolation; no HTTP pipeline. Bounds the connection-spike SLO for Phase E rollout. |
| `mTLS amortised (test CA, N requests over kept-alive)`    | One `:ssl.connect/4` followed by N=16 tiny send/recv round-trips on the open connection, then `:ssl.close/1`. Uses a dedicated kept-alive acceptor (separate listener from the handshake-only scenario) with an echo loop, so the connection stays open across the N round-trips. Per-iteration cost is `(handshake + N * request) / N`, which approximates the per-request cost the Phase E rollout sees once the handshake is amortised across a kept-alive pool. Closes the bracket scenarios 3 + 5 left loose. |

## Published latency SLOs

Reported per scenario, per CI run:

- **p50** — median request latency
- **p95** — 95th-percentile latency (the SLO the regression gate watches)
- **p99** — tail latency (regression gate watches with a looser tolerance)

### Targets (placeholder — Phase D-4 will replace)

| Scenario                                                  | p50 target | p95 target | p99 target |
|-----------------------------------------------------------|------------|------------|------------|
| `health endpoint`                                         | TODO       | TODO       | TODO       |
| `policy deny (405 fast-path)`                             | TODO       | TODO       | TODO       |
| `exact route allow (proxy 200)`                           | TODO       | TODO       | TODO       |
| `trust-header rewrite (Proxy.build_backend_headers)`      | TODO       | TODO       | TODO       |
| `mTLS handshake (test CA)`                                | TODO       | TODO       | TODO       |
| `mTLS amortised (test CA, N requests over kept-alive)`    | TODO       | TODO       | TODO       |

Units: microseconds (µs). Hardware reference: `ubuntu-latest` GitHub
runners — the CI environment IS the published reference, deliberately
chosen because it is the environment every reviewer can reproduce
without local hardware variance. Phase D-4 (baseline collection) will
revisit whether a dedicated runner is needed once we see the spread.

## Regression-alert tolerance

The CI gate (`.github/workflows/perf-regression.yml`) fails a PR when
**any** of these conditions holds against the checked-in baseline:

- live `p50` > baseline `p50` × `tolerance.p50_max_ratio` (default 1.20)
- live `p95` > baseline `p95` × `tolerance.p95_max_ratio` (default 1.30)
- live `p99` > baseline `p99` × `tolerance.p99_max_ratio` (default 1.50)

Tolerances are looser as the percentile gets noisier — Phase D-4 will
tighten these once intra-run variance is characterised.

## Schema drift

The comparator iterates the **union** of scenario names from
`bench/results.json` and `bench/baseline.json`. Either direction of
schema drift fails the build in `active` mode:

- **`MISSING IN BASELINE`** — a scenario in `results.json` (the harness
  just emitted it) has no entry in `baseline.json`. A new scenario
  landed without a rebaseline; the gate has no anchor for it and
  cannot meaningfully report regression. Rebaseline before merging.
- **`MISSING IN RESULTS`** — a scenario in `baseline.json` is absent
  from `results.json` (the harness skipped or dropped it). Either the
  harness regressed silently, or a scenario was removed without
  rebaselining the file. The gate must not silently pass.

Both directions are surfaced inline in the markdown table (in the
`Status` column). In `scaffold-placeholder` mode they appear as
informational `scaffold (would fail: MISSING IN BASELINE)` /
`scaffold (would fail: MISSING IN RESULTS)` rows so a rebaseline PR
previews the eventual active-mode verdict before the gate is armed;
the build still passes. In `active` mode they appear as bare
`MISSING IN BASELINE` / `MISSING IN RESULTS` and exit the comparator
with status 1. Behaviour pivots on the single `_status` flag in
`bench/baseline.json` — no code change is needed to arm the schema
checks once the gate goes live.

## Baseline lifecycle

The baseline lives in `bench/baseline.json`. Its `_status` field gates
behaviour:

- `"scaffold-placeholder"` — gate reports numbers but never fails the
  build. This is the current state.
- `"active"` — gate fails the build on regression. Switching to this
  requires landing real numbers via a dedicated baseline-collection PR
  (Phase D-4), reviewed for noise/spread by the maintainer.

Updating the baseline is a deliberate act. Two paths:

### Automated (preferred — D-4 bootstrap)

Dispatch the **Perf Rebaseline** workflow
(`.github/workflows/perf-rebaseline.yml`, `workflow_dispatch` only).
It runs `bench/gateway_latency.exs` on the published reference target
(`ubuntu-latest`), pipes the result through `bench/rebaseline.exs`
to regenerate `bench/baseline.json` with real percentiles, and opens
a `perf: rebaseline (standards#99)` PR for review. `_status` stays
`scaffold-placeholder` in the generated PR — the maintainer flips it
to `active` (arming the gate) in the same PR or in a follow-up after
a confidence-building window.

### Manual (for local previews or operators without GHA access)

1. Open a PR titled `perf: rebaseline (standards#99)`.
2. Run `just rebaseline` locally on a CI-equivalent target (runs
   `bench/gateway_latency.exs` then `bench/rebaseline.exs`, which
   reads `bench/results.json` and writes a regenerated
   `bench/baseline.json`). Or run `just bench-collect` for the
   harness only and edit `bench/baseline.json` by hand.
3. Commit the regenerated `bench/baseline.json`.
4. Reviewer approves the new numbers (or rejects if the regression is
   real and unjustified). Never silently rebaseline in an unrelated PR.

Either path leaves `_status` as `scaffold-placeholder`. Flipping it to
`active` is a separate, deliberate decision (it may land in the same
PR or as a follow-up).

## Out of scope for Phase D-3

The scaffold deliberately does NOT yet include:

- Real baseline numbers and rebaselined tolerances (Phase D-4 — the
  `perf: rebaseline` ritual described above produces these on a
  CI-equivalent target and flips `bench/baseline.json` `_status` to
  `active`).
- Dashboard publication of historical numbers (Phase E — `standards#100`).

D-3 (this iteration) added three new scenarios to
`bench/gateway_latency.exs`:

- `trust-header rewrite (Proxy.build_backend_headers)` — direct call
  via the `Proxy.__benchmark_build_backend_headers__/1` benchmark seam
  (a `@doc false` hook over the private `build_backend_headers/1`).
  Isolates the Phase A contract-header construction cost.
- `mTLS handshake (test CA)` — raw `:ssl` acceptor + client connect
  using a test CA chain generated in-memory at bench startup via
  `:public_key.pkix_test_data/1`. The committed Phase B fixture in
  `test/fixtures/mtls` ships only the `*.crt` files (matching `*.key`
  is gitignored at the repo root), so the chain is rebuilt with the
  same `verify_peer` + test-CA shape rather than reusing the on-disk
  material. Each iteration is one fresh handshake closed immediately;
  isolates per-handshake cost from the proxy hot-path.
- `mTLS amortised (test CA, N requests over kept-alive)` — dedicated
  kept-alive acceptor (separate listener) running an echo loop. Each
  Benchee iteration opens one connection, does N=16 tiny send/recv
  round-trips on the held-open connection, and then closes. Per-iteration
  cost is `(handshake + N * request) / N`, which approximates the
  per-request cost in a kept-alive setting. This was previously deferred
  as out-of-scope and bracketed by `mTLS handshake` + `proxy 200`; the
  follow-up adds it as an explicit scenario so D-4 baseline collection
  captures it directly rather than via the bracket.

`bench/baseline.json` gains the three new scenario keys (all `TODO`,
`_status` remains `scaffold-placeholder`) and bumps `_schema_version`
to `0.3.0-scaffold` to signal the shape change. D-4 will land real
numbers across all six scenarios in a single dedicated
`perf: rebaseline` PR.

D-2 (the previous iteration) landed the in-process `Plug.Cowboy`
loopback backend in `bench/gateway_latency.exs` and renamed the
`exact route allow` scenario from `(proxy short-circuits)` (D-1:
dialled `:1`, refused) to `(proxy 200)`.

These are sequenced post-merge tasks under the single-lane HCG channel;
see `standards#91` for the order-of-operations and `standards#100` for
Phase E.
