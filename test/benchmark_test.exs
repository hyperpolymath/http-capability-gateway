# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.BenchmarkTest do
  @moduledoc """
  Benchmarks for the HTTP Capability Gateway.

  Complements test/performance_test.exs with benchmarks focused on the
  components that were previously unmeasured:

    - Rate limiter per-request overhead
    - Rate limiter throughput
    - Circuit breaker state transition cost
    - Regex vs exact route lookup latency comparison
    - Full plug pipeline cost breakdown

  Tagged `:benchmark` so they run only when explicitly requested:

      mix test --only benchmark

  These are not pass/fail performance regressions — they print numbers
  for human review. We set generous upper bounds only as smoke tests.
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler, RateLimiter, CircuitBreaker}

  @moduletag :benchmark

  setup_all do
    RateLimiter.init([])
    HttpCapabilityGateway.K9Contract.init()

    case Process.whereis(CircuitBreaker) do
      nil ->
        {:ok, _pid} = CircuitBreaker.start_link([])

      _pid ->
        :ok
    end

    :ok
  end

  # ── Rate Limiter ──────────────────────────────────────────────────

  describe "benchmark: rate limiter overhead" do
    setup do
      RateLimiter.reset()

      Application.put_env(:http_capability_gateway, :rate_limits, %{
        untrusted: {100_000, 100_000},
        authenticated: {1_000_000, 1_000_000},
        internal: :unlimited
      })

      :ok
    end

    test "rate limiter check-and-consume latency (per request)" do
      conn = conn(:get, "/whatever") |> Plug.Conn.assign(:trust_level, :untrusted)

      # Warm up (first call creates bucket)
      _ = RateLimiter.call(conn, [])

      iterations = 10_000

      {time_us, _} =
        :timer.tc(fn ->
          for _ <- 1..iterations do
            RateLimiter.call(conn, [])
          end
        end)

      avg_us = time_us / iterations
      IO.puts("Rate limiter per-call: #{Float.round(avg_us, 3)}µs (over #{iterations} calls)")

      # Sanity: average should be < 100µs even on slow machines
      assert avg_us < 100
    end

    test "rate limiter scales across unique clients" do
      iterations = 5_000

      {time_us, _} =
        :timer.tc(fn ->
          for i <- 1..iterations do
            conn(:get, "/any")
            |> Plug.Conn.assign(:trust_level, :untrusted)
            |> Map.put(:remote_ip, {198, 51, 100, rem(i, 256)})
            |> RateLimiter.call([])
          end
        end)

      avg_us = time_us / iterations
      rps = 1_000_000 / avg_us
      IO.puts("Rate limiter throughput (varied IPs): #{round(rps)} req/s (avg #{Float.round(avg_us, 3)}µs)")

      # Bucket count bounded by distinct clients seen
      assert RateLimiter.bucket_count() >= 100
    end

    test "rate limiter short-circuits for internal trust" do
      # Internal trust path skips the ETS read entirely.
      conn = conn(:get, "/x") |> Plug.Conn.assign(:trust_level, :internal)

      iterations = 50_000

      {time_us, _} =
        :timer.tc(fn ->
          for _ <- 1..iterations do
            RateLimiter.call(conn, [])
          end
        end)

      avg_us = time_us / iterations
      IO.puts("Rate limiter (internal trust, short-circuit): #{Float.round(avg_us, 3)}µs")

      # Should be substantially faster than the untrusted path since it
      # avoids ETS reads entirely.
      assert avg_us < 10
    end
  end

  # ── Circuit Breaker ───────────────────────────────────────────────

  describe "benchmark: circuit breaker overhead" do
    test "allow? hot-path latency (ETS read only)" do
      # Register a backend by recording a success
      CircuitBreaker.record_success("bench-backend")
      Process.sleep(20)

      iterations = 100_000

      {time_us, _} =
        :timer.tc(fn ->
          for _ <- 1..iterations do
            CircuitBreaker.allow?("bench-backend")
          end
        end)

      avg_us = time_us / iterations
      IO.puts("CircuitBreaker.allow? per-call: #{Float.round(avg_us * 1000, 1)}ns")

      # Should be well under 10µs — just an ETS lookup + atom comparison
      assert avg_us < 10
    end

    test "allow? on unregistered backends" do
      iterations = 50_000

      {time_us, _} =
        :timer.tc(fn ->
          for i <- 1..iterations do
            CircuitBreaker.allow?("never-registered-#{rem(i, 1000)}")
          end
        end)

      avg_us = time_us / iterations
      IO.puts("CircuitBreaker.allow? (unregistered): #{Float.round(avg_us * 1000, 1)}ns")

      # Unregistered backends are treated as closed; should be similarly fast.
      assert avg_us < 20
    end

    test "state transition cost (record_failure to trip open)" do
      backend = "transition-bench-#{:rand.uniform(1_000_000)}"

      # Measure the time to trip the circuit with 5 failures (default threshold)
      {time_us, _} =
        :timer.tc(fn ->
          for _ <- 1..5 do
            CircuitBreaker.record_failure(backend)
          end

          # Wait for GenServer to process casts
          _ = CircuitBreaker.status(backend)
        end)

      IO.puts("CircuitBreaker trip transition (5 failures): #{Float.round(time_us / 1000, 2)}ms")

      # Give the GenServer a moment for the threshold-crossing trip
      Process.sleep(50)
      status = CircuitBreaker.status(backend)
      assert status.state == :open
    end
  end

  # ── Routing: Exact vs Regex ───────────────────────────────────────

  describe "benchmark: exact vs regex route lookup" do
    setup do
      # 100 exact routes and 100 regex routes in the same policy
      exact_routes =
        for i <- 1..100 do
          %{
            "path" => "/api/exact#{i}",
            "verbs" => ["GET"],
            "backend" => "http://localhost:8080",
            "exposure" => "public"
          }
        end

      regex_routes =
        for i <- 1..100 do
          %{
            "path" => "/api/regex#{i}/[0-9]+",
            "verbs" => ["GET"],
            "backend" => "http://localhost:8080",
            "exposure" => "public"
          }
        end

      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => exact_routes ++ regex_routes
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
      Application.put_env(:http_capability_gateway, :policy_table, table)
      {:ok, table: table}
    end

    test "exact route lookup is O(1) regardless of table size", %{table: table} do
      iterations = 50_000

      # Hit different exact routes so we're not just caching one entry
      {time_us, _} =
        :timer.tc(fn ->
          for i <- 1..iterations do
            path = "/api/exact#{rem(i, 100) + 1}"
            PolicyCompiler.lookup(table, path, :GET)
          end
        end)

      avg_us = time_us / iterations
      IO.puts("Exact route lookup: #{Float.round(avg_us, 2)}µs/lookup")

      # O(1) lookup should be comfortably under 5µs
      assert avg_us < 10
    end

    test "regex route lookup cost with 100 regex routes", %{table: table} do
      iterations = 5_000

      # These paths require scanning regex routes
      {time_us, _} =
        :timer.tc(fn ->
          for i <- 1..iterations do
            path = "/api/regex#{rem(i, 100) + 1}/42"
            PolicyCompiler.lookup(table, path, :GET)
          end
        end)

      avg_us = time_us / iterations
      IO.puts("Regex route lookup (100 regex routes): #{Float.round(avg_us, 2)}µs/lookup")

      # O(r) scan — slower than exact but should stay reasonable
      assert avg_us < 1000
    end

    test "global fallback lookup (no route match)", %{table: table} do
      iterations = 10_000

      {time_us, _} =
        :timer.tc(fn ->
          for i <- 1..iterations do
            PolicyCompiler.lookup(table, "/totally/unknown/path/#{i}", :GET)
          end
        end)

      avg_us = time_us / iterations
      IO.puts("Global fallback lookup: #{Float.round(avg_us, 2)}µs/lookup")

      # Must scan regex routes first, then fall through to global
      assert avg_us < 2000
    end
  end

  # ── Full Pipeline Throughput ──────────────────────────────────────

  describe "benchmark: full plug pipeline" do
    setup do
      # High rate limits to avoid 429 interference
      Application.put_env(:http_capability_gateway, :rate_limits, %{
        untrusted: {1_000_000, 1_000_000},
        authenticated: {1_000_000, 1_000_000},
        internal: :unlimited
      })

      RateLimiter.reset()

      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{
              "path" => "/api/bench",
              "verbs" => ["GET"],
              "backend" => "http://localhost:19999",
              "exposure" => "public"
            }
          ]
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
      Application.put_env(:http_capability_gateway, :policy_table, table)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{})

      :ok
    end

    test "policy-denied requests (unknown verb, 405) throughput" do
      iterations = 2_000

      {time_us, _} =
        :timer.tc(fn ->
          for _ <- 1..iterations do
            conn = conn(:get, "/api/bench")
            conn = %{conn | method: "PROPFIND"}
            Gateway.call(conn, [])
          end
        end)

      rps = iterations / (time_us / 1_000_000)
      avg_us = time_us / iterations
      IO.puts("405 fast-path: #{round(rps)} req/s (#{Float.round(avg_us, 2)}µs/req)")

      assert rps > 1_000
    end

    test "health endpoint throughput (no policy lookup)" do
      iterations = 2_000

      {time_us, _} =
        :timer.tc(fn ->
          for _ <- 1..iterations do
            conn(:get, "/health") |> Gateway.call([])
          end
        end)

      rps = iterations / (time_us / 1_000_000)
      avg_us = time_us / iterations
      IO.puts("Health endpoint: #{round(rps)} req/s (#{Float.round(avg_us, 2)}µs/req)")

      # Health check should be one of the fastest paths (no policy, no proxy).
      assert rps > 1_000
    end
  end
end
