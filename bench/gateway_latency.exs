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
# Phase D-2 (http-capability-gateway#14): adds an in-process Plug.Cowboy
# loopback backend that responds 200 cheaply, so the allow scenario
# measures the real end-to-end cost the gateway pays in production —
# header rewrite + Req-based proxy + response forwarding. This is the
# cost surface the Phase E rollout SLA (p99 latency at production
# endpoints) is measured against; without it the baseline numbers a
# Phase D-4 collection would produce are not comparable to production
# reality.
#
# Phase D-3 (this file): pulls two cost surfaces out of the proxy-200
# scenario into dedicated scenarios so D-4 baseline collection can
# attribute them independently:
#
#   • trust-header rewrite (Proxy.build_backend_headers) — the gateway's
#     contract-critical header surface (X-Trust-Level / X-Request-ID /
#     X-Forwarded-*) measured in isolation, with no policy lookup and no
#     network I/O. Phase A's "the trust class the backend sees is the
#     value the gateway resolved" invariant lives here, so if a change
#     ever inflates this cost, D-4 will catch it.
#
#   • mTLS handshake (test CA) — per-handshake cost on a raw :ssl
#     listener using the Phase B real-CA fixtures in test/fixtures/mtls.
#     Each iteration opens a fresh TLS connection with client-internal.crt
#     and immediately closes it; no policy lookup, no proxy. This is the
#     connection-spike cost the Phase E rollout has to budget for —
#     amortised cost across many requests is bounded by this number plus
#     the proxy-200 scenario, and isolating it lets us track CA chain /
#     curve / Cowboy-TLS-opt changes that would shift it independent of
#     the rest of the pipeline.
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
# ── Scenarios (Phase D-3 scope) ──────────────────────────────────────────────
#
#   1. health endpoint                            — fastest path, no policy, no proxy
#   2. policy deny (405 fast-path)                — unknown verb, policy table hit, no proxy
#   3. exact route allow (proxy 200)              — O(1) policy hit; proxies to the
#                                                   in-process loopback backend which
#                                                   responds 200 with a tiny JSON body
#   4. trust-header rewrite (Proxy.build_backend_headers)
#                                                 — D-3 — direct call to the proxy
#                                                   header-rewrite seam; isolates the
#                                                   Phase A contract-header construction
#                                                   from policy lookup and network I/O
#   5. mTLS handshake (test CA)                   — D-3 — :ssl.connect/4 with the Phase B
#                                                   client-internal cert against a raw
#                                                   :ssl acceptor; isolates per-handshake
#                                                   cost from the proxy hot-path
#   6. mTLS amortised (test CA, N requests over kept-alive)
#                                                 — D-3 follow-up — one :ssl.connect/4
#                                                   followed by N tiny send/recv round-trips
#                                                   on the open connection, then close.
#                                                   Approximates the per-request cost the
#                                                   Phase E rollout sees once the handshake
#                                                   is amortised across a kept-alive pool.
#                                                   Closes the bracket scenario 3 + scenario
#                                                   5 left loose.
#
# Each scenario is reported under p50 / p95 / p99 latency, matching the SLO
# names in docs/perf-contract.md. Throughput (req/s) is reported as a
# secondary signal; the SLO is latency, not throughput.
#
# ── What this harness still deliberately does NOT do ─────────────────────────
#
#   • Compare against a populated baseline.json (Phase D-4 collects baseline
#     numbers on a CI-equivalent target and flips `_status` to `active`)
#   • Run distributed (single-node only; estate concurrency-pool guard in #122)
# (Scenario 6 in D-3 closes the previously deferred amortised follow-up.)
#
# Those are sequenced post-D-3 tasks under the single-lane HCG channel
# (standards#91).

# `mix run` loads all deps onto the code path, including Benchee and
# Plug.Cowboy (both declared in mix.exs).
#
# Boot the OTP supervision tree so RateLimiter ETS, K9Contract, etc. are
# initialised — Gateway.call/2 depends on those processes existing.
{:ok, _} = Application.ensure_all_started(:http_capability_gateway)

# Phase D-3 scenario 5 uses :ssl directly (raw acceptor + client connect)
# without going through Plug.Cowboy's TLS startup, so the application
# needs to be started explicitly. It's part of OTP, no extra dep needed.
{:ok, _} = Application.ensure_all_started(:ssl)

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

alias HttpCapabilityGateway.Proxy

# ── Trust-header rewrite seam fixture (Phase D-3, scenario 4) ───────────────
#
# Pre-build a conn that already has the assigns the Phase C trust-header
# rewrite reads (trust_level + request_id). The bench function then calls
# the Proxy benchmark hook directly so the measurement is the rewrite
# cost in isolation -- no policy lookup, no Gateway.call/2 pipeline, no
# network. This is the cost surface the Phase A contract invariant lives
# on: build_backend_headers/1 is what produces X-Trust-Level / X-Request-ID
# as the authoritative gateway-resolved values.
trust_header_conn =
  conn(:get, "/api/bench")
  |> Plug.Conn.put_req_header("authorization", "Bearer test-token")
  |> Plug.Conn.put_req_header("user-agent", "bench/d-3")
  |> Plug.Conn.put_req_header("accept", "application/json")
  |> Plug.Conn.assign(:trust_level, :authenticated)
  |> Plug.Conn.assign(:request_id, "bench-d3-rewrite")

# ── mTLS acceptor fixture (Phase D-3, scenario 5) ────────────────────────────
#
# Stand up a raw :ssl listener using a test CA chain generated in-memory
# via :public_key.pkix_test_data/1. Each Benchee iteration in scenario 5
# dials this listener with the matching client cert+key and immediately
# closes the connection, so what's measured is the per-handshake cost
# (verify_peer + cert chain validation against the test CA + key exchange
# + finished).
#
# Why in-memory and not test/fixtures/mtls/*.{crt,key}: the committed
# Phase B fixture (used by test/mtls_test.exs) only ships the .crt files
# — *.key is gitignored at the repo root. Reusing the committed *.crt
# files would require also committing the matching *.key files (or
# carving a fixture exception in .gitignore), which the estate security
# posture prefers we don't do for a bench fixture. The chain shape and
# verify_peer behaviour are identical; this scenario tests the same TLS
# transport guarantee, just with key material that never touches disk.
# If D-4 baseline collection shows the handshake cost is sensitive to
# RSA key size or cert chain length, a follow-up moves to a fixture
# shape closer to the production CA's parameters.
#
# Deliberately raw :ssl instead of Plug.Cowboy.https: this scenario must
# isolate the handshake from any HTTP-level pipeline, so we accept and
# discard at the TLS layer. The HTTP-over-TLS cost is bracketed by
# scenario 3 (proxy-200) + scenario 5 (handshake) for D-4 baseline.
#
# Port choice: 19_878 — one above the D-2 loopback (19_877) so the two
# fixtures can coexist when CI runs them back-to-back without socket
# reuse jitter.
# :public_key.pkix_test_data/1 returns a map with :server_config and
# :client_config keys, each already shaped as a property list ready to
# concat into :ssl.listen / :ssl.connect options. Empty cert-opts lists
# tell OTP to use the default RSA key parameters; if D-4 reveals the
# default size shifts handshake cost in a misleading direction we'll
# pin {rsa, Size, Exp} explicitly. Map keys here are Erlang atoms, so
# Elixir's %{atom: value} shorthand maps 1:1.
%{server_config: tls_listen_base, client_config: tls_client_base} =
  :public_key.pkix_test_data(%{
    server_chain: %{root: [], intermediates: [], peer: []},
    client_chain: %{root: [], intermediates: [], peer: []}
  })

tls_port = 19_878

tls_listen_opts =
  tls_listen_base ++
    [
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      reuseaddr: true,
      active: false
    ]

tls_client_opts =
  tls_client_base ++
    [
      verify: :verify_peer,
      # The synthesised peer cert has an arbitrary CN -- skip hostname
      # verify since we dial 127.0.0.1. Cert-chain trust is still
      # enforced via verify_peer against the in-memory CA the client
      # was given via :public_key.pkix_test_data.
      server_name_indication: :disable,
      active: false
    ]

# Acceptor loop: a tiny process that accepts handshakes and closes them.
# Spawned as part of fixture setup; lives for the duration of the bench
# run and is killed in the after clause.
{:ok, listen_socket} = :ssl.listen(tls_port, tls_listen_opts)

acceptor_pid =
  spawn_link(fn ->
    accept_loop = fn loop ->
      case :ssl.transport_accept(listen_socket, 5_000) do
        {:ok, transport_socket} ->
          # Drive the handshake to completion on the server side; the
          # cost the *client* sees is what scenario 5 measures, but the
          # server has to play its half or the client times out.
          case :ssl.handshake(transport_socket, 5_000) do
            {:ok, tls_socket} -> :ssl.close(tls_socket)
            {:error, _reason} -> :ok
          end

          loop.(loop)

        {:error, :timeout} ->
          loop.(loop)

        {:error, :closed} ->
          :ok
      end
    end

    accept_loop.(accept_loop)
  end)

# ── mTLS amortised acceptor fixture (Phase D-3, scenario 6) ──────────────────
#
# Second :ssl listener dedicated to the amortised scenario. Each accepted
# connection is held open and the server echoes back every frame the
# client sends; the connection terminates when the client closes its
# side. The amortised bench scenario opens ONE connection, does N
# send/recv round-trips, then closes, so this acceptor sees one
# handshake + N echo cycles + one close per Benchee iteration.
#
# Separate listener (port 19_879) instead of reusing 19_878: scenario 5's
# acceptor is shaped to close immediately after handshake, which would
# kill the kept-alive connection scenario 6 needs. Keeping the two
# fixtures independent also means D-4 can run them back-to-back without
# the scenario-5 acceptor's close-on-handshake racing scenario 6's
# send/recv loop.
#
# N (kept_alive_request_count below): chosen as 16 — a small bounded
# constant in the same order of magnitude as typical HTTP/1.1 keep-alive
# pool reuse counts before pool rotation, large enough that
# (handshake + N * request) / N visibly differs from the per-handshake
# cost in scenario 5 (so the bracket scenarios 5 + 3 left loose is
# visibly tightened), small enough that one iteration completes well
# within the Benchee per-iteration budget.
#
# Payload (kept_alive_payload below): a tiny 8-byte ASCII frame. The
# point is to measure per-request *connection* cost (round-trip on an
# established TLS session), not bulk-data throughput; the payload is
# kept deliberately small so socket-write timings don't dominate.
kept_alive_request_count = 16
kept_alive_payload = "bench-d3"

{:ok, kept_alive_listen_socket} = :ssl.listen(19_879, tls_listen_opts)

kept_alive_acceptor_pid =
  spawn_link(fn ->
    accept_loop = fn loop ->
      case :ssl.transport_accept(kept_alive_listen_socket, 5_000) do
        {:ok, transport_socket} ->
          case :ssl.handshake(transport_socket, 5_000) do
            {:ok, tls_socket} ->
              # Echo loop: read whatever the client sends, send it back,
              # continue until the client closes. The bench client does
              # exactly N send/recv pairs and then closes, so this loop
              # exits cleanly on {:error, :closed} once :ssl.close/1 has
              # been called on the client side.
              echo_loop = fn echo ->
                case :ssl.recv(tls_socket, byte_size(kept_alive_payload), 5_000) do
                  {:ok, data} ->
                    case :ssl.send(tls_socket, data) do
                      :ok -> echo.(echo)
                      {:error, _reason} -> :ssl.close(tls_socket)
                    end

                  {:error, :closed} ->
                    :ok

                  {:error, _reason} ->
                    :ssl.close(tls_socket)
                end
              end

              echo_loop.(echo_loop)

            {:error, _reason} ->
              :ok
          end

          loop.(loop)

        {:error, :timeout} ->
          loop.(loop)

        {:error, :closed} ->
          :ok
      end
    end

    accept_loop.(accept_loop)
  end)

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
      end,
      "trust-header rewrite (Proxy.build_backend_headers)" => fn ->
        Proxy.__benchmark_build_backend_headers__(trust_header_conn)
      end,
      "mTLS handshake (test CA)" => fn ->
        {:ok, sock} = :ssl.connect(~c"127.0.0.1", tls_port, tls_client_opts, 5_000)
        :ssl.close(sock)
      end,
      "mTLS amortised (test CA, N requests over kept-alive)" => fn ->
        # ONE handshake, then N tiny send/recv round-trips on the open
        # connection, then close. Per-iteration cost is
        # (handshake + N * request) / N which approximates the per-request
        # cost in a kept-alive setting. N is the module-level constant
        # `kept_alive_request_count` (see the amortised acceptor fixture
        # above for why 16 was chosen).
        {:ok, sock} = :ssl.connect(~c"127.0.0.1", 19_879, tls_client_opts, 5_000)

        Enum.each(1..kept_alive_request_count, fn _ ->
          :ok = :ssl.send(sock, kept_alive_payload)
          {:ok, _echoed} = :ssl.recv(sock, byte_size(kept_alive_payload), 5_000)
        end)

        :ssl.close(sock)
      end
    },
    # Phase D-1/D-2/D-3: keep timings short so the workflow stays under
    # the 6-minute estate CI budget. Phase D-4 may widen warmup/time
    # once the rebaseline ritual is in place.
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

  # Tear down the mTLS acceptor fixture (Phase D-3): closing the listen
  # socket causes the transport_accept loop to exit on :closed; the
  # linked acceptor process then terminates normally.
  Process.unlink(acceptor_pid)
  :ssl.close(listen_socket)
  Process.exit(acceptor_pid, :shutdown)

  # Same teardown shape for the amortised acceptor (Phase D-3 scenario 6).
  Process.unlink(kept_alive_acceptor_pid)
  :ssl.close(kept_alive_listen_socket)
  Process.exit(kept_alive_acceptor_pid, :shutdown)
end
