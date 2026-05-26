<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Performance Contract

> **Status: scaffold (Phase D-2).** This document names the SLOs the
> gateway will publish and the regression-alert gate will enforce. The
> concrete numbers are deliberately left as `TODO` — Phase D-4 of the
> single-lane HCG channel (standards#91) collects the baseline and fills
> them in. The CI gate is non-blocking until that point. Phase D-2
> (loopback backend fixture) is the last harness-shape change before
> D-4 collection; further D-3 work adds the mTLS-handshake and trust-
> header rewrite scenarios but does not change the existing three.

Tracks: `Refs hyperpolymath/standards#99` (Phase D of `standards#91`).

## Scope of this contract

This contract covers in-gateway latency — the cost of the gateway's
own pipeline (trust resolution, policy lookup, rate limiter, circuit
breaker, header rewrite). The `exact route allow (proxy 200)` scenario
also includes the dial-and-read cost against an in-process loopback
backend (added in Phase D-2), since the production gateway always pays
that cost on an allow path; the loopback strips out real-network RTT and
real-backend processing time so what remains is the gateway-attributable
proxy overhead. Real production backend latency, real-network RTT, and
mTLS handshake amortisation are out of scope here; mTLS handshake cost
is tracked separately and lands in Phase D-3.

The three named scenarios match the three Benchee scenarios in
`bench/gateway_latency.exs`:

| Scenario                                  | What it measures                                                                  |
|-------------------------------------------|-----------------------------------------------------------------------------------|
| `health endpoint`                         | Cheapest path. No policy lookup, no proxy. Floor of any plug-pipeline overhead.   |
| `policy deny (405 fast-path)`             | Verb-rejection path. Policy table hit, no proxy. Cost of the deny short-circuit.  |
| `exact route allow (proxy 200)`           | Allow path that proxies to an in-process loopback backend returning 200. Captures the real dial-and-read cost the gateway pays in production. |

## Published latency SLOs

Reported per scenario, per CI run:

- **p50** — median request latency
- **p95** — 95th-percentile latency (the SLO the regression gate watches)
- **p99** — tail latency (regression gate watches with a looser tolerance)

### Targets (placeholder — Phase D-4 will replace)

| Scenario                                  | p50 target | p95 target | p99 target |
|-------------------------------------------|------------|------------|------------|
| `health endpoint`                         | TODO       | TODO       | TODO       |
| `policy deny (405 fast-path)`             | TODO       | TODO       | TODO       |
| `exact route allow (proxy 200)`           | TODO       | TODO       | TODO       |

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

## Baseline lifecycle

The baseline lives in `bench/baseline.json`. Its `_status` field gates
behaviour:

- `"scaffold-placeholder"` — gate reports numbers but never fails the
  build. This is the current state.
- `"active"` — gate fails the build on regression. Switching to this
  requires landing real numbers via a dedicated baseline-collection PR
  (Phase D-4), reviewed for noise/spread by the maintainer.

Updating the baseline is a deliberate act:

1. Open a PR titled `perf: rebaseline (standards#99)`.
2. Run `just bench-collect` locally on the CI-equivalent target.
3. Commit the regenerated `bench/baseline.json`.
4. Reviewer approves the new numbers (or rejects if the regression is
   real and unjustified). Never silently rebaseline in an unrelated PR.

## Out of scope for Phase D-2

The scaffold deliberately does NOT yet include:

- mTLS handshake amortisation (Phase D-3 — reuses the Phase B real-CA fixture).
- Trust-header rewrite cost on the `Proxy.build_backend_headers/1` path
  introduced in Phase C, as a dedicated scenario (Phase D-3 — the cost is
  currently folded into `exact route allow (proxy 200)`).
- Real baseline numbers and rebaselined tolerances (Phase D-4).
- Dashboard publication of historical numbers (Phase E — `standards#100`).

D-2 (this iteration) landed the in-process `Plug.Cowboy` loopback backend
in `bench/gateway_latency.exs` and renamed the `exact route allow`
scenario from `(proxy short-circuits)` (D-1: dialled `:1`, refused) to
`(proxy 200)`. `bench/baseline.json` carries the renamed scenario key;
the `_status` remains `scaffold-placeholder` because the rename does not
collect a real baseline — D-4 does.

These are sequenced post-merge tasks under the single-lane HCG channel;
see `standards#91` for the order-of-operations and `standards#100` for
Phase E.
