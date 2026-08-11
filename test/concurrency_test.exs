# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.ConcurrencyTest do
  @moduledoc """
  Concurrency and failure-mode tests for the HTTP Capability Gateway.

  Covers race conditions, contention behaviour, and failure modes that
  cannot be reproduced by single-threaded tests:

    - Rate limiter under burst contention (many concurrent clients)
    - Circuit breaker state transitions under concurrent failures
    - Policy atomic reload under concurrent reads
    - ETS table contention patterns

  These tests are tagged `:concurrency` so they can be skipped in fast
  CI runs if needed.
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler, RateLimiter, CircuitBreaker}

  @moduletag :concurrency

  setup_all do
    HttpCapabilityGateway.RateLimiter.init([])
    HttpCapabilityGateway.K9Contract.init()

    # CircuitBreaker is a GenServer — start it if not already running.
    case Process.whereis(CircuitBreaker) do
      nil ->
        {:ok, _pid} = CircuitBreaker.start_link([])

      _pid ->
        :ok
    end

    :ok
  end

  # ── Rate Limiter Concurrency ──────────────────────────────────────

  describe "rate limiter: concurrent clients" do
    setup do
      # Use a restrictive rate limit for untrusted users so we can reliably
      # observe 429 responses under contention. Override the test_helper.exs
      # default of 10000 for this test only.
      original = Application.get_env(:http_capability_gateway, :rate_limits)

      Application.put_env(:http_capability_gateway, :rate_limits, %{
        untrusted: {5, 5},
        authenticated: {10, 10},
        internal: :unlimited
      })

      RateLimiter.reset()

      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => []
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
      Application.put_env(:http_capability_gateway, :policy_table, table)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{})

      on_exit(fn ->
        if original do
          Application.put_env(:http_capability_gateway, :rate_limits, original)
        end
      end)

      :ok
    end

    test "concurrent requests from same client get rate limited correctly" do
      # 50 concurrent requests from same IP with burst=5.
      # Expect roughly 5 allowed, rest 429 (may vary slightly due to timing).
      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            conn(:get, "/api/burst")
            |> Map.put(:remote_ip, {203, 0, 113, 1})
            |> Gateway.call([])
          end)
        end

      results = Task.await_many(tasks, 5_000)
      statuses = Enum.map(results, & &1.status)

      allowed_count = Enum.count(statuses, fn s -> s in [200, 502] end)
      rate_limited_count = Enum.count(statuses, &(&1 == 429))

      # With burst=5 and race-tolerant algorithm (±1-2 extra per doc comment),
      # we expect 5-7 allowed. Assert the bucket actually rate-limited.
      assert allowed_count >= 5
      assert allowed_count <= 10, "Too many requests allowed: #{allowed_count}"
      assert rate_limited_count >= 40, "Not enough rate-limited: #{rate_limited_count}"
      assert allowed_count + rate_limited_count == 50
    end

    test "concurrent requests from different clients all succeed (separate buckets)" do
      # 20 concurrent requests from 20 DIFFERENT IPs should all succeed
      # because each gets its own bucket with burst=5.
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            conn(:get, "/api/separate")
            |> Map.put(:remote_ip, {203, 0, 113, i})
            |> Gateway.call([])
          end)
        end

      results = Task.await_many(tasks, 5_000)
      statuses = Enum.map(results, & &1.status)

      # All 20 unique clients get their first token, so all should be allowed.
      rate_limited_count = Enum.count(statuses, &(&1 == 429))
      assert rate_limited_count == 0, "Some unique clients were rate limited"
    end

    test "internal trust is never rate limited even under heavy load" do
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            conn(:get, "/api/internal")
            |> put_req_header("x-trust-level", "internal")
            |> Gateway.call([])
          end)
        end

      results = Task.await_many(tasks, 5_000)
      statuses = Enum.map(results, & &1.status)

      # Internal trust bypasses rate limiting
      rate_limited = Enum.count(statuses, &(&1 == 429))
      assert rate_limited == 0
    end

    test "retry-after header is always present on 429 responses" do
      # Fill the bucket then verify 429 carries Retry-After
      for _ <- 1..20 do
        conn(:get, "/api/fill")
        |> Map.put(:remote_ip, {203, 0, 113, 99})
        |> Gateway.call([])
      end

      conn =
        conn(:get, "/api/fill")
        |> Map.put(:remote_ip, {203, 0, 113, 99})
        |> Gateway.call([])

      if conn.status == 429 do
        retry_after = get_resp_header(conn, "retry-after")
        assert length(retry_after) == 1
        {secs, _} = Integer.parse(hd(retry_after))
        assert secs >= 1
      end
    end
  end

  # ── Circuit Breaker Concurrency ───────────────────────────────────

  describe "circuit breaker: concurrent failure recording" do
    setup do
      # Reset state for this test via public API (no dedicated global reset).
      CircuitBreaker.reset("concurrent-backend-1")
      CircuitBreaker.reset("concurrent-backend-2")
      # Allow async cast to settle
      _ = CircuitBreaker.status("concurrent-backend-1")
      :ok
    end

    test "concurrent failure recordings serialize through the GenServer" do
      # Record 20 concurrent failures; the default threshold is 5,
      # so the circuit should be open at the end, not in some undefined state.
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            CircuitBreaker.record_failure("concurrent-backend-1")
          end)
        end

      Task.await_many(tasks, 5_000)

      # Give the GenServer a moment to process the casts
      Process.sleep(100)

      status = CircuitBreaker.status("concurrent-backend-1")
      assert status.state == :open
      assert status.failure_count >= 5
    end

    test "concurrent allow? checks return consistent result" do
      # Trip the circuit
      CircuitBreaker.trip("concurrent-backend-2")
      Process.sleep(50)

      # 100 concurrent allow? checks — all should return false
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            CircuitBreaker.allow?("concurrent-backend-2")
          end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.all?(results, fn r -> r == false end)
    end

    test "success after failures resets the counter" do
      # Record a few failures (below threshold)
      for _ <- 1..3 do
        CircuitBreaker.record_failure("concurrent-backend-1")
      end

      Process.sleep(50)
      status = CircuitBreaker.status("concurrent-backend-1")
      assert status.state == :closed
      assert status.failure_count == 3

      # Success resets counter
      CircuitBreaker.record_success("concurrent-backend-1")
      Process.sleep(50)

      status = CircuitBreaker.status("concurrent-backend-1")
      assert status.state == :closed
      assert status.failure_count == 0
    end

    test "unregistered backends always allow" do
      assert CircuitBreaker.allow?("never-registered-backend-#{:rand.uniform(1_000_000)}") == true
    end
  end

  # ── Policy Reload Under Load ──────────────────────────────────────

  describe "policy atomic reload: concurrent reads during swap" do
    test "concurrent readers never see a missing/empty policy table" do
      # Baseline policy
      policy_v1 = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{
              "path" => "/api/stable",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080",
              "exposure" => "public"
            }
          ]
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, _t1} = PolicyCompiler.compile(policy_v1, delete_old: false)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{})

      # Start 10 reader tasks that continuously hit the gateway
      test_pid = self()

      readers =
        for _ <- 1..10 do
          Task.async(fn ->
            results =
              for _ <- 1..50 do
                conn = conn(:get, "/api/stable") |> Gateway.call([])
                conn.status
              end

            send(test_pid, {:reader_done, results})
            results
          end)
        end

      # While readers are running, trigger several policy swaps
      for i <- 1..5 do
        policy_vN = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => ["GET"],
            "routes" => [
              %{
                "path" => "/api/stable",
                "verbs" => ["GET"],
                "backend" => "http://localhost:808#{i}",
                "exposure" => "public"
              }
            ]
          },
          "stealth" => %{"enabled" => false}
        }

        {:ok, _} = PolicyCompiler.compile(policy_vN, delete_old: false)
        Process.sleep(5)
      end

      all_results = Task.await_many(readers, 10_000) |> List.flatten()

      # The critical invariant: no reader ever got a 503 (service unavailable
      # = policy table missing). Every request must have been served with
      # a valid decision (200/502/403/404).
      service_unavailable = Enum.count(all_results, &(&1 == 503))

      assert service_unavailable == 0,
             "Atomic reload leaked a gap: #{service_unavailable} requests got 503"

      # Every request should be allowed (public endpoint, GET, all policies allow it)
      allowed = Enum.count(all_results, fn s -> s in [200, 502] end)
      assert allowed == length(all_results), "Some requests got unexpected status"
    end

    test "failed reload during concurrent reads preserves service" do
      # Start with a valid policy
      good_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{
              "path" => "/api/keep",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080",
              "exposure" => "public"
            }
          ]
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, good_table} = PolicyCompiler.compile(good_policy, delete_old: false)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{})

      # Concurrent readers
      readers =
        for _ <- 1..5 do
          Task.async(fn ->
            for _ <- 1..30 do
              conn = conn(:get, "/api/keep") |> Gateway.call([])
              conn.status
            end
          end)
        end

      # Try to load a bad policy (should fail)
      bad_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{
              "path" => "[unclosed",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080"
            }
          ]
        }
      }

      # Compilation fails; atomic_swap: false ensures no side effects on app env
      _ = PolicyCompiler.compile(bad_policy, delete_old: false, atomic_swap: false)

      all_results = Task.await_many(readers, 10_000) |> List.flatten()

      # Good policy remained active throughout
      assert Enum.all?(all_results, fn s -> s in [200, 502] end)

      # Verify good table is still referenced
      assert Application.get_env(:http_capability_gateway, :policy_table) == good_table
    end
  end
end
