# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.PerformanceTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler}

  @moduletag :performance

  setup_all do
    # Initialize RateLimiter ETS table
    HttpCapabilityGateway.RateLimiter.init([])
    HttpCapabilityGateway.K9Contract.init()

    # Compile a large policy for performance testing
    routes =
      for i <- 1..1000 do
        %{"path" => "/api/resource#{i}", "verbs" => ["GET", "POST"], "backend" => "http://localhost:8080"}
      end

    policy = %{
      "dsl_version" => "1",
      "governance" => %{
        "global_verbs" => ["GET", "POST"],
        "routes" => routes
      }
    }

    {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
    # Set the policy table for Gateway lookups
    Application.put_env(:http_capability_gateway, :policy_table, table)
    {:ok, table: table}
  end

  describe "policy compilation performance" do
    test "compiles large policy quickly (< 100ms)" do
      routes =
        for i <- 1..1000 do
          %{"path" => "/api/endpoint#{i}", "verbs" => ["GET", "POST", "PUT", "DELETE"], "backend" => "http://localhost:8080"}
        end

      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => routes
        }
      }

      {time_us, {:ok, table}} = :timer.tc(fn -> PolicyCompiler.compile(policy, atomic_swap: false) end)
      
      # Ensure table is clean for memory tests if needed
      :ets.delete(table)

      time_ms = time_us / 1000
      IO.puts("Policy compilation time (1000 routes): #{Float.round(time_ms, 2)}ms")

      assert time_ms < 100, "Policy compilation took #{time_ms}ms (expected < 100ms)"
    end
  end

  describe "verb checking performance" do
    test "checks verbs quickly with large route table (< 1ms)", %{table: table} do
      {time_us, _result} =
        :timer.tc(fn ->
          PolicyCompiler.lookup(table, "/api/resource500", :GET)
        end)

      time_us_float = time_us * 1.0
      IO.puts("Verb check time: #{Float.round(time_us_float, 2)}µs")

      assert time_us < 1000, "Verb check took #{time_us}µs (expected < 1000µs)"
    end

    test "handles 1000 sequential verb checks efficiently", %{table: table} do
      {time_us, _results} =
        :timer.tc(fn ->
          for i <- 1..1000 do
            PolicyCompiler.lookup(table, "/api/resource#{i}", :GET)
          end
        end)

      time_ms = time_us / 1000
      avg_us = time_us / 1000
      IO.puts("1000 verb checks: #{Float.round(time_ms, 2)}ms (avg #{Float.round(avg_us, 2)}µs/check)")

      assert time_ms < 100
    end

    test "handles concurrent verb checks efficiently", %{table: table} do
      {time_us, _results} =
        :timer.tc(fn ->
          tasks =
            for _i <- 1..100 do
              Task.async(fn ->
                for j <- 1..10 do
                  PolicyCompiler.lookup(table, "/api/resource#{j}", :GET)
                end
              end)
            end

          Task.await_many(tasks, 5000)
        end)

      time_ms = time_us / 1000
      IO.puts("1000 concurrent verb checks: #{Float.round(time_ms, 2)}ms")
      assert time_ms < 200
    end
  end

  describe "gateway request handling performance" do
    test "handles sequential requests efficiently", %{table: table} do
      # Refresh the app env to point to the correct table
      Application.put_env(:http_capability_gateway, :policy_table, table)

      {time_us, _results} =
        :timer.tc(fn ->
          for i <- 1..50 do
            conn(:get, "/api/resource#{i}") |> Gateway.call([])
          end
        end)

      time_ms = time_us / 1000
      IO.puts("50 requests: #{Float.round(time_ms, 2)}ms")
      assert time_ms < 500
    end

    test "handles high concurrency (100 concurrent requests)", %{table: table} do
      Application.put_env(:http_capability_gateway, :policy_table, table)

      {time_us, _results} =
        :timer.tc(fn ->
          tasks =
            for i <- 1..100 do
              Task.async(fn ->
                conn(:get, "/api/resource#{i}") |> Gateway.call([])
              end)
            end

          Task.await_many(tasks, 5000)
        end)

      time_ms = time_us / 1000
      IO.puts("100 concurrent requests: #{Float.round(time_ms, 2)}ms")
      assert time_ms < 1000
    end
  end

  describe "throughput benchmarks" do
    test "measures maximum throughput (requests/second)", %{table: table} do
      Application.put_env(:http_capability_gateway, :policy_table, table)
      duration_ms = 1000
      {time_us, count} = :timer.tc(fn -> count_requests(duration_ms, table, 0) end)

      rps = count / (time_us / 1_000_000)
      IO.puts("Throughput: #{rps |> round()} requests/second")

      assert rps > 500
    end

    defp count_requests(duration_ms, table, count) do
      start_time = System.monotonic_time(:millisecond)
      do_count_requests(start_time, duration_ms, table, count)
    end

    defp do_count_requests(start_time, duration_ms, table, count) do
      now = System.monotonic_time(:millisecond)

      if now - start_time < duration_ms do
        conn(:get, "/api/resource1") |> Gateway.call([])
        do_count_requests(start_time, duration_ms, table, count + 1)
      else
        count
      end
    end
  end

  describe "memory usage" do
    test "measures memory overhead per route" do
      for size <- [100, 1000, 10000] do
        routes =
          for i <- 1..size do
            %{"path" => "/api/large#{i}", "verbs" => ["GET", "POST", "PUT", "DELETE"], "backend" => "http://localhost:8080"}
          end

        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => ["GET"],
            "routes" => routes
          }
        }

        {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
        
        # Approximate memory usage from ETS
        info = :ets.info(table)
        mem_words = info[:memory]
        mem_kb = (mem_words * :erlang.system_info(:wordsize)) / 1024
        
        IO.puts("Memory usage for #{size} routes: #{Float.round(mem_kb / 1024, 2)}MB")
        
        # Cleanup
        :ets.delete(table)
      end
    end
  end
end
