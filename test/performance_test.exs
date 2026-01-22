# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PerformanceTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler}

  @moduletag :performance

  setup_all do
    # Compile a large policy for performance testing
    routes =
      for i <- 1..1000 do
        %{"path" => "/api/resource#{i}", "verbs" => ["GET", "POST"]}
      end

    policy = %{
      "dsl_version" => "1",
      "governance" => %{
        "global_verbs" => ["GET", "POST"],
        "routes" => routes
      }
    }

    PolicyCompiler.compile(policy)
    :ok
  end

  describe "policy compilation performance" do
    test "compiles large policy quickly (< 100ms)" do
      routes =
        for i <- 1..1000 do
          %{"path" => "/api/endpoint#{i}", "verbs" => ["GET", "POST", "PUT", "DELETE"]}
        end

      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => routes
        }
      }

      {time_us, :ok} = :timer.tc(fn -> PolicyCompiler.compile(policy) end)

      time_ms = time_us / 1000
      IO.puts("Policy compilation time (1000 routes): #{Float.round(time_ms, 2)}ms")

      assert time_ms < 100, "Policy compilation took #{time_ms}ms (expected < 100ms)"
    end

    test "compiles very large policy (5000 routes)" do
      routes =
        for i <- 1..5000 do
          %{"path" => "/api/item#{i}", "verbs" => ["GET", "POST"]}
        end

      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => routes
        }
      }

      {time_us, :ok} = :timer.tc(fn -> PolicyCompiler.compile(policy) end)

      time_ms = time_us / 1000
      IO.puts("Policy compilation time (5000 routes): #{Float.round(time_ms, 2)}ms")

      # Should still be reasonable (< 500ms)
      assert time_ms < 500
    end
  end

  describe "verb checking performance" do
    test "checks verbs quickly with large route table (< 1ms)" do
      # Compile done in setup_all (1000 routes)

      {time_us, _result} =
        :timer.tc(fn ->
          PolicyCompiler.is_verb_allowed?("/api/resource500", "GET")
        end)

      time_us_float = time_us * 1.0
      IO.puts("Verb check time: #{Float.round(time_us_float, 2)}µs")

      assert time_us < 1000, "Verb check took #{time_us}µs (expected < 1000µs)"
    end

    test "handles 1000 sequential verb checks efficiently" do
      {time_us, _results} =
        :timer.tc(fn ->
          for i <- 1..1000 do
            PolicyCompiler.is_verb_allowed?("/api/resource#{i}", "GET")
          end
        end)

      time_ms = time_us / 1000
      avg_us = time_us / 1000
      IO.puts("1000 verb checks: #{Float.round(time_ms, 2)}ms (avg #{Float.round(avg_us, 2)}µs/check)")

      # Should complete in < 100ms (< 100µs per check)
      assert time_ms < 100
    end

    test "handles concurrent verb checks efficiently" do
      {time_us, _results} =
        :timer.tc(fn ->
          tasks =
            for i <- 1..100 do
              Task.async(fn ->
                for j <- 1..10 do
                  PolicyCompiler.is_verb_allowed?("/api/resource#{j}", "GET")
                end
              end)
            end

          Task.await_many(tasks, 5000)
        end)

      time_ms = time_us / 1000
      IO.puts("1000 concurrent verb checks (100 tasks × 10): #{Float.round(time_ms, 2)}ms")

      # Concurrent checks should be fast due to ETS read concurrency
      assert time_ms < 200
    end
  end

  describe "gateway request handling performance" do
    test "handles sequential requests efficiently" do
      {time_us, _results} =
        :timer.tc(fn ->
          for i <- 1..100 do
            conn = conn(:get, "/api/resource#{rem(i, 1000)}")
            Gateway.call(conn, [])
          end
        end)

      time_ms = time_us / 1000
      avg_ms = time_ms / 100
      IO.puts("100 requests: #{Float.round(time_ms, 2)}ms (avg #{Float.round(avg_ms, 2)}ms/req)")

      # Should handle 100 requests in < 500ms (< 5ms per request)
      assert time_ms < 500
    end

    test "handles concurrent requests efficiently" do
      {time_us, _results} =
        :timer.tc(fn ->
          tasks =
            for i <- 1..50 do
              Task.async(fn ->
                conn = conn(:get, "/api/resource#{rem(i, 1000)}")
                Gateway.call(conn, [])
              end)
            end

          Task.await_many(tasks, 5000)
        end)

      time_ms = time_us / 1000
      IO.puts("50 concurrent requests: #{Float.round(time_ms, 2)}ms")

      # Concurrent requests should be fast
      assert time_ms < 200
    end

    test "handles high concurrency (100 concurrent requests)" do
      {time_us, _results} =
        :timer.tc(fn ->
          tasks =
            for i <- 1..100 do
              Task.async(fn ->
                conn = conn(:get, "/api/resource#{rem(i, 1000)}")
                Gateway.call(conn, [])
              end)
            end

          Task.await_many(tasks, 10000)
        end)

      time_ms = time_us / 1000
      IO.puts("100 concurrent requests: #{Float.round(time_ms, 2)}ms")

      # Should handle high concurrency
      assert time_ms < 500
    end
  end

  describe "memory usage" do
    test "policy compilation memory footprint is reasonable" do
      routes =
        for i <- 1..10000 do
          %{"path" => "/api/large#{i}", "verbs" => ["GET", "POST", "PUT", "DELETE"]}
        end

      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => routes
        }
      }

      mem_before = :erlang.memory(:total)
      PolicyCompiler.compile(policy)
      mem_after = :erlang.memory(:total)

      mem_diff_mb = (mem_after - mem_before) / (1024 * 1024)
      IO.puts("Memory usage for 10000 routes: #{Float.round(mem_diff_mb, 2)}MB")

      # Should use < 50MB for 10000 routes
      assert mem_diff_mb < 50
    end
  end

  describe "throughput benchmarks" do
    test "measures maximum throughput (requests/second)" do
      duration_ms = 1000  # Run for 1 second

      {_time_us, count} =
        :timer.tc(fn ->
          start_time = System.monotonic_time(:millisecond)
          count_requests(start_time, duration_ms, 0)
        end)

      rps = count
      IO.puts("Throughput: ~#{rps} requests/second")

      # Should handle > 1000 req/s (very conservative)
      assert rps > 1000
    end
  end

  # Helper function to count requests in a time period
  defp count_requests(start_time, duration_ms, count) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed < duration_ms do
      conn = conn(:get, "/api/resource1")
      Gateway.call(conn, [])
      count_requests(start_time, duration_ms, count + 1)
    else
      count
    end
  end
end
