# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# bench/gateway_latency.exs — Phase D benchmark harness scaffold (standards#99)
#
# This file is the SKELETON for the Phase D published-latency contract. The
# real measurements (collection, baseline numbers, regression thresholds) are
# multi-session work and are deliberately NOT included here — see
# docs/perf-contract.md and bench/baseline.json for the placeholder constants
# and TODO markers that the follow-up sessions must replace.
#
# Run locally:
#
#     just bench
#
# or directly:
#
#     mix run bench/gateway_latency.exs
#
# CI invocation lives in .github/workflows/perf-regression.yml.
#
# ── Scenarios (Phase D scaffold scope) ───────────────────────────────────────
#
#   1. health endpoint   — fastest path, no policy lookup, no proxy
#   2. policy deny       — 405 fast-path (unknown verb, policy table hit, no proxy)
#   3. exact-route allow — O(1) policy hit; backend stubbed (no real network)
#
# Each scenario is reported under p50 / p95 / p99 latency, matching the SLO
# names in docs/perf-contract.md. Throughput (req/s) is reported as a
# secondary signal; the SLO is latency, not throughput.
#
# ── What this scaffold deliberately does NOT do ──────────────────────────────
#
#   • Talk to a real backend (Phase D-2 will add the loopback backend fixture)
#   • Exercise the mTLS handshake path (Phase D-3; reuses Phase B fixture)
#   • Capture the X-Trust-Level rewrite cost (Phase D-3)
#   • Compare against a populated baseline.json (Phase D-4 collects baseline)
#   • Run distributed (single-node only; estate concurrency-pool guard in #122)
#
# Those are all separate, sequenced post-merge tasks under the single-lane
# HCG channel (standards#91). This PR delivers the scaffold only.

# `mix run` loads all deps onto the code path, including Benchee
# (declared as :dev/:test dep in mix.exs).
#
# Boot the OTP supervision tree so RateLimiter ETS, K9Contract, etc. are
# initialised — Gateway.call/2 depends on those processes existing.
{:ok, _} = Application.ensure_all_started(:http_capability_gateway)

alias HttpCapabilityGateway.{Gateway, PolicyCompiler}

# ── Test fixture: a small, deterministic policy ──────────────────────────────
#
# Real Phase D-2 collection will use a fixture closer to the BoJ production
# policy shape. For the scaffold we just need a policy that exercises the
# three scenarios above.
policy = %{
  "dsl_version" => "1",
  "governance" => %{
    "global_verbs" => ["GET"],
    "routes" => [
      %{
        "path" => "/api/bench",
        "verbs" => ["GET"],
        # NB: backend URL is never dialled in scaffold mode; the deny/health
        # scenarios short-circuit before proxy. The allow scenario uses a
        # local loopback that intentionally refuses — the gateway returns
        # 502 quickly, which still captures the in-gateway cost we care about.
        # TODO(Phase D-2): wire a real loopback fixture (Bandit / cowboy_test).
        "backend" => "http://127.0.0.1:1",
        "exposure" => "public"
      }
    ]
  },
  "stealth" => %{"enabled" => false}
}

{:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
Application.put_env(:http_capability_gateway, :policy_table, table)
Application.put_env(:http_capability_gateway, :stealth_profiles, %{})

# Generous rate limits so the harness is not measuring 429s.
Application.put_env(:http_capability_gateway, :rate_limits, %{
  untrusted: {10_000_000, 10_000_000},
  authenticated: {10_000_000, 10_000_000},
  internal: :unlimited
})

# Use Plug.Test conn factory directly — the same shape benchmark_test.exs uses.
# This keeps the scaffold honest: we measure what the unit benchmarks measure,
# just with statistical-grade reporting (Benchee p50/p95/p99 vs raw avg).
require Plug.Test
import Plug.Test, only: [conn: 2]

# ── Benchee scenarios ────────────────────────────────────────────────────────

Benchee.run(
  %{
    "health endpoint" => fn ->
      conn(:get, "/health") |> Gateway.call([])
    end,
    "policy deny (405 fast-path)" => fn ->
      c = conn(:get, "/api/bench")
      %{c | method: "PROPFIND"} |> Gateway.call([])
    end,
    "exact route allow (proxy short-circuits)" => fn ->
      conn(:get, "/api/bench") |> Gateway.call([])
    end
  },
  # Phase D-1 (this scaffold): keep timings short so the workflow stays
  # under the 6-minute estate CI budget. Phase D-2 will widen warmup/time.
  warmup: 1,
  time: 2,
  memory_time: 0,
  percentiles: [50, 95, 99],
  # JSON output for the CI regression gate to diff against baseline.json.
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.JSON, file: "bench/results.json"}
  ],
  # Stable, reproducible names that match docs/perf-contract.md.
  print: [benchmarking: true, fast_warning: false, configuration: true]
)
