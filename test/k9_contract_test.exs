# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.K9ContractTest do
  @moduledoc """
  Unit tests for K9-SVC service contracts.

  Covers:
    - Contract registration & validation
    - Tiered lookup (exact verb, :ANY verb, wildcard pattern)
    - Pre-proxy trust threshold enforcement
    - Pre-proxy contract rate-limit enforcement
    - Post-proxy latency SLA checks
    - Breach policy execution (log, alert, circuit_break, fallback)
    - parse_breach_policy safety
    - count/list_all/remove/reset lifecycle
  """

  use ExUnit.Case, async: false

  alias HttpCapabilityGateway.{K9Contract, CircuitBreaker}

  setup_all do
    K9Contract.init()

    case Process.whereis(CircuitBreaker) do
      nil -> {:ok, _} = CircuitBreaker.start_link([])
      _pid -> :ok
    end

    :ok
  end

  setup do
    K9Contract.reset()
    :ok
  end

  # ── Registration ──────────────────────────────────────────────────

  describe "register/1" do
    test "registers a contract with valid attrs" do
      attrs = %{
        service: "user-api",
        route_pattern: "/api/users/*",
        verb: :GET,
        max_latency_ms: 200,
        rate_limit: 100,
        timeout_ms: 5_000,
        breach_policy: :alert
      }

      assert {:ok, contract} = K9Contract.register(attrs)
      assert contract.service == "user-api"
      assert contract.route_pattern == "/api/users/*"
      assert contract.verb == :GET
      assert contract.trust_threshold == :untrusted
      assert is_binary(contract.contract_id)
      assert byte_size(contract.contract_id) == 64
    end

    test "contract_id is deterministic for identical content" do
      attrs = %{
        service: "a",
        route_pattern: "/x",
        verb: :GET,
        max_latency_ms: 100,
        rate_limit: 10,
        timeout_ms: 1000,
        breach_policy: :log
      }

      {:ok, c1} = K9Contract.register(attrs)
      # Re-register same content
      {:ok, c2} = K9Contract.register(attrs)

      assert c1.contract_id == c2.contract_id
    end

    test "contract_id changes when any obligation changes" do
      base = %{
        service: "a",
        route_pattern: "/x",
        verb: :GET,
        max_latency_ms: 100,
        rate_limit: 10,
        timeout_ms: 1000,
        breach_policy: :log
      }

      {:ok, c1} = K9Contract.register(base)
      {:ok, c2} = K9Contract.register(%{base | max_latency_ms: 200})

      refute c1.contract_id == c2.contract_id
    end

    test "rejects missing service field" do
      attrs = %{
        route_pattern: "/x",
        verb: :GET,
        max_latency_ms: 100,
        rate_limit: 10,
        timeout_ms: 1000,
        breach_policy: :log
      }

      assert {:error, {:missing_required_field, :service}} = K9Contract.register(attrs)
    end

    test "rejects non-positive max_latency_ms" do
      attrs = %{
        service: "a",
        route_pattern: "/x",
        verb: :GET,
        max_latency_ms: 0,
        rate_limit: 10,
        timeout_ms: 1000,
        breach_policy: :log
      }

      assert {:error, {:invalid_field, :max_latency_ms, _}} = K9Contract.register(attrs)
    end

    test "rejects invalid verb atom" do
      attrs = %{
        service: "a",
        route_pattern: "/x",
        verb: :PROPFIND,
        max_latency_ms: 100,
        rate_limit: 10,
        timeout_ms: 1000,
        breach_policy: :log
      }

      assert {:error, {:invalid_verb, :PROPFIND, _}} = K9Contract.register(attrs)
    end

    test "rejects invalid breach_policy atom" do
      attrs = %{
        service: "a",
        route_pattern: "/x",
        verb: :GET,
        max_latency_ms: 100,
        rate_limit: 10,
        timeout_ms: 1000,
        breach_policy: :panic
      }

      assert {:error, {:invalid_breach_policy, :panic, _}} = K9Contract.register(attrs)
    end

    test "accepts :ANY verb" do
      attrs = %{
        service: "a",
        route_pattern: "/x",
        verb: :ANY,
        max_latency_ms: 100,
        rate_limit: 10,
        timeout_ms: 1000,
        breach_policy: :log
      }

      assert {:ok, contract} = K9Contract.register(attrs)
      assert contract.verb == :ANY
    end
  end

  # ── Lookup ────────────────────────────────────────────────────────

  describe "lookup/2" do
    test "returns nil for unknown route" do
      assert K9Contract.lookup("/nowhere", :GET) == nil
    end

    test "tier 1: exact path + verb match" do
      {:ok, _} = K9Contract.register(%{
        service: "a", route_pattern: "/exact/path", verb: :GET,
        max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })

      assert %K9Contract{service: "a"} = K9Contract.lookup("/exact/path", :GET)
    end

    test "tier 1: does not match other verbs" do
      {:ok, _} = K9Contract.register(%{
        service: "a", route_pattern: "/only-get", verb: :GET,
        max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })

      assert K9Contract.lookup("/only-get", :POST) == nil
    end

    test "tier 2: :ANY verb matches any method" do
      {:ok, _} = K9Contract.register(%{
        service: "a", route_pattern: "/any-verb", verb: :ANY,
        max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })

      assert %K9Contract{} = K9Contract.lookup("/any-verb", :GET)
      assert %K9Contract{} = K9Contract.lookup("/any-verb", :POST)
      assert %K9Contract{} = K9Contract.lookup("/any-verb", :DELETE)
    end

    test "tier 3: wildcard pattern matches subpaths" do
      {:ok, _} = K9Contract.register(%{
        service: "a", route_pattern: "/api/users/*", verb: :GET,
        max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })

      assert %K9Contract{} = K9Contract.lookup("/api/users/123", :GET)
      assert %K9Contract{} = K9Contract.lookup("/api/users/123/profile", :GET)
    end

    test "exact match takes precedence over :ANY" do
      {:ok, _} = K9Contract.register(%{
        service: "specific", route_pattern: "/dual", verb: :GET,
        max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })
      {:ok, _} = K9Contract.register(%{
        service: "generic", route_pattern: "/dual", verb: :ANY,
        max_latency_ms: 500, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })

      assert %K9Contract{service: "specific"} = K9Contract.lookup("/dual", :GET)
      assert %K9Contract{service: "generic"} = K9Contract.lookup("/dual", :POST)
    end
  end

  # ── Pre-Proxy Enforcement ─────────────────────────────────────────

  describe "enforce_pre_proxy/2: trust threshold" do
    setup do
      {:ok, contract} = K9Contract.register(%{
        service: "auth-svc",
        route_pattern: "/private/*",
        verb: :GET,
        trust_threshold: :authenticated,
        max_latency_ms: 100,
        rate_limit: 100_000,
        timeout_ms: 1000,
        breach_policy: :log
      })

      {:ok, contract: contract}
    end

    test "allows authenticated trust", %{contract: contract} do
      assert K9Contract.enforce_pre_proxy(contract, :authenticated) == :ok
    end

    test "allows internal trust (higher rank)", %{contract: contract} do
      assert K9Contract.enforce_pre_proxy(contract, :internal) == :ok
    end

    test "denies untrusted trust", %{contract: contract} do
      assert {:error, :trust_insufficient} =
               K9Contract.enforce_pre_proxy(contract, :untrusted)
    end
  end

  describe "enforce_pre_proxy/2: rate limit" do
    test "allows requests within rate limit" do
      {:ok, contract} = K9Contract.register(%{
        service: "rl-svc",
        route_pattern: "/rate/limited",
        verb: :GET,
        max_latency_ms: 100,
        rate_limit: 5,
        timeout_ms: 1000,
        breach_policy: :log
      })

      # First 5 requests should pass (burst == rate_limit capacity)
      results = for _ <- 1..5, do: K9Contract.enforce_pre_proxy(contract, :untrusted)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "denies requests beyond rate limit" do
      {:ok, contract} = K9Contract.register(%{
        service: "rl-svc",
        route_pattern: "/rate/strict",
        verb: :GET,
        max_latency_ms: 100,
        rate_limit: 3,
        timeout_ms: 1000,
        breach_policy: :log
      })

      # Exhaust the bucket
      for _ <- 1..3, do: K9Contract.enforce_pre_proxy(contract, :untrusted)

      # Next request should be rate-limited
      assert {:error, :contract_rate_limited} =
               K9Contract.enforce_pre_proxy(contract, :untrusted)
    end

    test "trust check runs before rate check" do
      {:ok, contract} = K9Contract.register(%{
        service: "rl-svc",
        route_pattern: "/priority",
        verb: :GET,
        trust_threshold: :internal,
        max_latency_ms: 100,
        rate_limit: 1,
        timeout_ms: 1000,
        breach_policy: :log
      })

      # Even though bucket is full, trust_insufficient should be returned
      # first for untrusted calls.
      assert {:error, :trust_insufficient} =
               K9Contract.enforce_pre_proxy(contract, :untrusted)
    end
  end

  # ── Post-Proxy Enforcement ────────────────────────────────────────

  describe "enforce_post_proxy/2" do
    setup do
      {:ok, contract} = K9Contract.register(%{
        service: "sla-svc",
        route_pattern: "/sla/check",
        verb: :GET,
        max_latency_ms: 200,
        rate_limit: 100,
        timeout_ms: 1000,
        breach_policy: :alert
      })

      {:ok, contract: contract}
    end

    test "within SLA", %{contract: contract} do
      assert K9Contract.enforce_post_proxy(contract, 50) == {:ok, :within_sla}
      assert K9Contract.enforce_post_proxy(contract, 200) == {:ok, :within_sla}
    end

    test "breach when latency exceeds max", %{contract: contract} do
      assert {:breach, :alert, 500} = K9Contract.enforce_post_proxy(contract, 500)
    end

    test "breach returns the contract's configured policy", %{contract: contract} do
      assert {:breach, :alert, _} = K9Contract.enforce_post_proxy(contract, 1000)
    end
  end

  # ── Breach Policy Execution ───────────────────────────────────────

  describe "execute_breach_policy/3" do
    setup do
      {:ok, contract} = K9Contract.register(%{
        service: "breach-svc",
        route_pattern: "/breach/me",
        verb: :GET,
        max_latency_ms: 100,
        rate_limit: 100,
        timeout_ms: 1000,
        breach_policy: :circuit_break
      })

      CircuitBreaker.reset("breach-svc")
      _ = CircuitBreaker.status("breach-svc")
      {:ok, contract: contract}
    end

    test ":log is a no-op that doesn't crash", %{contract: contract} do
      assert :ok = K9Contract.execute_breach_policy(contract, :log, 500)
    end

    test ":alert emits telemetry", %{contract: contract} do
      test_pid = self()
      handler_id = "test-alert-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:http_capability_gateway, :k9_contract, :alert],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:alert_event, measurements, metadata})
        end,
        nil
      )

      assert :ok = K9Contract.execute_breach_policy(contract, :alert, 500)
      assert_receive {:alert_event, %{latency_ms: 500}, _meta}, 500

      :telemetry.detach(handler_id)
    end

    test ":circuit_break trips the circuit breaker", %{contract: contract} do
      assert :ok = K9Contract.execute_breach_policy(contract, :circuit_break, 500)

      # Allow GenServer cast to settle
      Process.sleep(100)

      assert CircuitBreaker.allow?("breach-svc") == false
    end

    test ":fallback is logged but doesn't raise", %{contract: contract} do
      assert :ok = K9Contract.execute_breach_policy(contract, :fallback, 500)
    end
  end

  # ── Safe String Parsing ───────────────────────────────────────────

  describe "parse_breach_policy/1" do
    test "parses known policy strings" do
      assert K9Contract.parse_breach_policy("log") == :log
      assert K9Contract.parse_breach_policy("alert") == :alert
      assert K9Contract.parse_breach_policy("circuit_break") == :circuit_break
      assert K9Contract.parse_breach_policy("fallback") == :fallback
    end

    test "defaults unknown strings to :log (safest)" do
      assert K9Contract.parse_breach_policy("nuke") == :log
      assert K9Contract.parse_breach_policy("") == :log
      assert K9Contract.parse_breach_policy(nil) == :log
      assert K9Contract.parse_breach_policy("LOG") == :log
    end
  end

  # ── Lifecycle ─────────────────────────────────────────────────────

  describe "count/0, list_all/0, remove/2, reset/0" do
    test "count reflects registered contracts only" do
      assert K9Contract.count() == 0

      {:ok, _} = K9Contract.register(%{
        service: "a", route_pattern: "/1", verb: :GET,
        max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })
      {:ok, _} = K9Contract.register(%{
        service: "b", route_pattern: "/2", verb: :POST,
        max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })

      assert K9Contract.count() == 2
    end

    test "count does NOT include rate-limit buckets or breach counters" do
      {:ok, contract} = K9Contract.register(%{
        service: "bucket-leak-test", route_pattern: "/bucket", verb: :GET,
        max_latency_ms: 100, rate_limit: 5, timeout_ms: 1000, breach_policy: :circuit_break
      })

      # Create rate-limit bucket entries via enforce_pre_proxy
      for _ <- 1..3, do: K9Contract.enforce_pre_proxy(contract, :untrusted)

      # Create breach-counter entry via :circuit_break breach policy
      K9Contract.execute_breach_policy(contract, :circuit_break, 500)

      # count/0 should still report only the 1 registered contract
      assert K9Contract.count() == 1
    end

    test "list_all returns only contract structs (no buckets or counters)" do
      {:ok, contract} = K9Contract.register(%{
        service: "list-all-test", route_pattern: "/list", verb: :GET,
        max_latency_ms: 100, rate_limit: 5, timeout_ms: 1000, breach_policy: :circuit_break
      })

      K9Contract.enforce_pre_proxy(contract, :untrusted)
      K9Contract.execute_breach_policy(contract, :circuit_break, 500)

      entries = K9Contract.list_all()
      assert length(entries) == 1
      assert %K9Contract{service: "list-all-test"} = hd(entries)
    end

    test "remove deletes a specific contract" do
      {:ok, _} = K9Contract.register(%{
        service: "a", route_pattern: "/keep", verb: :GET,
        max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })
      {:ok, _} = K9Contract.register(%{
        service: "b", route_pattern: "/gone", verb: :GET,
        max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
      })

      assert K9Contract.count() == 2
      assert :ok = K9Contract.remove("/gone", :GET)
      assert K9Contract.count() == 1
      assert K9Contract.lookup("/gone", :GET) == nil
      assert %K9Contract{} = K9Contract.lookup("/keep", :GET)
    end

    test "reset clears all contracts" do
      for i <- 1..5 do
        {:ok, _} = K9Contract.register(%{
          service: "svc#{i}", route_pattern: "/route#{i}", verb: :GET,
          max_latency_ms: 100, rate_limit: 10, timeout_ms: 1000, breach_policy: :log
        })
      end

      assert K9Contract.count() == 5
      assert :ok = K9Contract.reset()
      assert K9Contract.count() == 0
      assert K9Contract.list_all() == []
    end
  end

  # ── Wildcard Safety With Mixed Table Entries ──────────────────────

  describe "wildcard lookup with mixed ETS entries" do
    test "lookup does not crash when rate-limit buckets exist" do
      # Register a wildcard contract and exercise its rate limiter so
      # {:contract_bucket, ...} entries exist in the table. Then a
      # subsequent lookup that falls through to wildcard scanning must
      # not FunctionClauseError on the non-contract entries.
      {:ok, contract} = K9Contract.register(%{
        service: "mixed", route_pattern: "/mixed/*", verb: :GET,
        max_latency_ms: 100, rate_limit: 5, timeout_ms: 1000, breach_policy: :log
      })

      # Create a bucket entry
      K9Contract.enforce_pre_proxy(contract, :untrusted)

      # Wildcard lookup must not crash
      result = K9Contract.lookup("/mixed/deep/path", :GET)
      assert %K9Contract{service: "mixed"} = result
    end
  end
end
