# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# bench/gateway_latency.exs — Phase D benchmark harness (standards#99)
#
# Phase D-1 (standards#99 scaffold, http-capability-gateway#12) wired the
# Benchee-driven gateway pipeline measurement and the JSON output the
# perf-regression CI gate diffs against bench/baseline.json. The "exact
# route allow" scenario in D-1 dialled `http://127.0.0.1:1` (refused
# immediately) so the timing only captured the in-gateway cost up to the
# proxy dial, not the dial-and-read cost.
#
# Phase D-2 (this file): adds an in-process Plug.Cowboy loopback backend
# that responds 200 cheaply, so the allow scenario measures the real
# end-to-end cost the gateway pays in production — header rewrite +
# Req-based proxy + response forwarding. This is the cost surface the
# Phase E rollout SLA (p99 latency at production endpoints) is measured
# against; without it the baseline numbers a Phase D-4 collection would
# produce are not comparable to production reality.
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
# ── Scenarios (Phase D-2 scope) ──────────────────────────────────────────────
#
#   1. health endpoint                 — fastest path, no policy lookup, no proxy
#   2. policy deny (405 fast-path)     — unknown verb, policy table hit, no proxy
#   3. exact route allow (proxy 200)   — O(1) policy hit; proxies to the
#                                        in-process loopback backend which
#                                        responds 200 with a tiny JSON body
#
# Each scenario is reported under p50 / p95 / p99 latency, matching the SLO
# names in docs/perf-contract.md. Throughput (req/s) is reported as a
# secondary signal; the SLO is latency, not throughput.
#
# ── What this harness still deliberately does NOT do ─────────────────────────
#
#   • Exercise the mTLS handshake path (Phase D-3; reuses Phase B fixture)
#   • Capture the X-Trust-Level rewrite cost as a dedicated scenario
#     (Phase D-3 — the cost is currently folded into the proxy-200 scenario)
#   • Compare against a populated baseline.json (Phase D-4 collects baseline)
#   • Run distributed (single-node only; estate concurrency-pool guard in #122)
#
# Those are sequenced post-D-2 tasks under the single-lane HCG channel
# (standards#91).

# `mix run` loads all deps onto the code path, including Benchee and
# Plug.Cowboy (both declared in mix.exs).
#
# Boot the OTP supervision tree so RateLimiter ETS, K9Contract, etc. are
# initialised — Gateway.call/2 depends on those processes existing.
{:ok, _} = Application.ensure_all_started(:http_capability_gateway)

alias HttpCapabilityGateway.{Gateway, PolicyCompiler}

# ── Loopback backend fixture (Phase D-2) ────────────────────────────────────
#
# In-process Plug.Cowboy listener on a fixed loopback port. Mirrors the
# pattern in test/e2e_boj_integration_test.exs (MockBoj) so the bench and
# the seam test share the same backend shape. The body is intentionally
# tiny: real BoJ responses are larger, but the bench is measuring the
# gateway's overhead, not the backend's response cost. A larger body
# would add noise from socket-write timings that aren't gateway-attributable.
#
# Port choice: 19_877 — one above the E2E test's 19_876 so the two can
# coexist if a future runner ever interleaves them. The CI runner is
# clean per job; conflict is not expected.
defmodule HttpCapabilityGateway.Bench.LoopbackBackend do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, ~s({"ok":true}))
  end
end

backend_port = 19_877
backend_url = "http://127.0.0.1:#{backend_port}"

{:ok, _backend_pid} =
  Plug.Cowboy.http(HttpCapabilityGateway.Bench.LoopbackBackend, [], port: backend_port)

# ── Test fixture: a small, deterministic policy ──────────────────────────────
#
# Real Phase D-4 collection will use a fixture closer to the BoJ production
# policy shape (covering all routes in config/gateway-policy-boj-example.yaml
# in the boj-server repo). For D-1/D-2 we just need a policy that exercises
# the three scenarios above.
policy = %{
  "dsl_version" => "1",
  "governance" => %{
    "global_verbs" => ["GET"],
    "routes" => [
      %{
        "path" => "/api/bench",
        "verbs" => ["GET"],
        "backend" => backend_url,
        "exposure" => "public"
      }
    ]
  },
  "stealth" => %{"enabled" => false}
}

{:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
Application.put_env(:http_capability_gateway, :policy_table, table)
Application.put_env(:http_capability_gateway, :stealth_profiles, %{})
Application.put_env(:http_capability_gateway, :backend_url, backend_url)

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

try do
  Benchee.run(
    %{
      "health endpoint" => fn ->
        conn(:get, "/health") |> Gateway.call([])
      end,
      "policy deny (405 fast-path)" => fn ->
        c = conn(:get, "/api/bench")
        %{c | method: "PROPFIND"} |> Gateway.call([])
      end,
      "exact route allow (proxy 200)" => fn ->
        conn(:get, "/api/bench") |> Gateway.call([])
      end
    },
    # Phase D-1/D-2: keep timings short so the workflow stays under the
    # 6-minute estate CI budget. Phase D-4 may widen warmup/time once the
    # rebaseline ritual is in place.
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
after
  # Stop the loopback backend so the script exits cleanly. Plug.Cowboy
  # registers the listener under the plug module's name by default.
  _ = Plug.Cowboy.shutdown(HttpCapabilityGateway.Bench.LoopbackBackend.HTTP)
end
