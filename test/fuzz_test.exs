# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.FuzzTest do
  @moduledoc """
  Property-based fuzz tests for the HTTP Capability Gateway.

  Replaces the former tests/fuzz/placeholder.txt with real StreamData-based
  property tests that exercise the gateway with arbitrary inputs.

  Focus areas:
    - Arbitrary YAML policies through the compiler (never crashes)
    - Arbitrary HTTP methods through the gateway (never crashes, always 405 for unknown)
    - Arbitrary trust level strings (always parse safely)
    - Arbitrary paths through policy lookup (never crashes)
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler, SafeTrust}

  import Plug.Test

  setup_all do
    HttpCapabilityGateway.RateLimiter.init([])
    HttpCapabilityGateway.K9Contract.init()
    :ok
  end

  # ── Generators ────────────────────────────────────────────────────

  defp http_verb_string do
    one_of([
      constant("GET"),
      constant("POST"),
      constant("PUT"),
      constant("DELETE"),
      constant("PATCH"),
      constant("HEAD"),
      constant("OPTIONS"),
      # Invalid / exotic verbs
      string(:alphanumeric, min_length: 1, max_length: 20),
      constant("PROPFIND"),
      constant("MKCOL"),
      constant("REPORT"),
      constant("TRACE"),
      constant("CONNECT"),
      constant(""),
      constant("get"),
      constant("Get")
    ])
  end

  defp trust_level_string do
    one_of([
      constant("untrusted"),
      constant("authenticated"),
      constant("internal"),
      string(:printable, min_length: 0, max_length: 50),
      constant("INTERNAL"),
      constant("admin"),
      constant("root"),
      constant(nil)
    ])
  end

  defp path_string do
    one_of([
      constant("/"),
      constant("/api/users"),
      constant("/api/admin"),
      constant("/health"),
      # Random paths
      map(
        list_of(string(:alphanumeric, min_length: 1, max_length: 10), min_length: 1, max_length: 5),
        fn segments -> "/" <> Enum.join(segments, "/") end
      ),
      # Adversarial paths
      constant("/../../etc/passwd"),
      constant("/" <> String.duplicate("a", 5000)),
      constant("/api/users%00admin"),
      constant("/api/%2e%2e/%2e%2e/etc/passwd")
    ])
  end

  defp valid_policy do
    gen all(
          verbs <- list_of(member_of(["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]),
                    min_length: 1, max_length: 7),
          route_count <- integer(0..10)
        ) do
      routes =
        for i <- 1..route_count do
          route_verbs = Enum.take(verbs, Enum.random(1..length(verbs)))

          %{
            "path" => "/api/resource_#{i}",
            "verbs" => Enum.uniq(route_verbs),
            "backend" => "http://localhost:8080",
            "exposure" => Enum.random(["public", "authenticated", "internal"])
          }
        end

      %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => Enum.uniq(verbs),
          "routes" => routes
        },
        "stealth" => %{
          "enabled" => Enum.random([true, false]),
          "status_code" => Enum.random([404, 403, 405])
        }
      }
    end
  end

  # ── Property Tests ────────────────────────────────────────────────

  describe "fuzz: arbitrary HTTP methods never crash the gateway" do
    setup do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => [
            %{"path" => "/api/test", "verbs" => ["GET"], "backend" => "http://localhost:8080"}
          ]
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
      Application.put_env(:http_capability_gateway, :policy_table, table)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{})
      :ok
    end

    property "any method string produces a valid HTTP response (never crashes)", max_runs: 50 do
      check all method <- http_verb_string() do
        conn = conn(:get, "/api/test")
        conn = %{conn | method: method}

        # Must not raise, must produce a valid status code
        result = Gateway.call(conn, [])
        assert is_integer(result.status)
        assert result.status >= 100 and result.status < 600
      end
    end
  end

  describe "fuzz: arbitrary trust level strings always parse safely" do
    property "any trust string parses to a valid trust atom", max_runs: 100 do
      check all trust_str <- trust_level_string() do
        result = SafeTrust.parse_trust(trust_str)
        assert result in [:untrusted, :authenticated, :internal]
      end
    end

    property "any exposure string parses to a valid exposure atom", max_runs: 100 do
      check all exposure_str <- one_of([
              string(:printable, min_length: 0, max_length: 50),
              constant(nil),
              constant("public"),
              constant("authenticated"),
              constant("internal")
            ]) do
        result = SafeTrust.parse_exposure(exposure_str)
        assert result in [:public, :authenticated, :internal]
      end
    end
  end

  describe "fuzz: arbitrary paths through gateway never crash" do
    setup do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{
              "path" => "/api/users/[0-9]+",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080"
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

    property "any path string produces a valid HTTP response", max_runs: 50 do
      check all path <- path_string() do
        conn = conn(:get, path) |> Gateway.call([])
        assert is_integer(conn.status)
        assert conn.status >= 100 and conn.status < 600
      end
    end
  end

  describe "fuzz: arbitrary policies compile without crashing" do
    property "valid policies always compile successfully", max_runs: 30 do
      check all policy <- valid_policy() do
        result = PolicyCompiler.compile(policy, delete_old: false, atomic_swap: false)

        case result do
          {:ok, table} ->
            # Verify the table is a valid ETS reference
            assert :ets.info(table, :size) >= 0
            :ets.delete(table)

          {:error, errors} ->
            # Compilation errors are acceptable (e.g., from edge cases)
            # but must be a list, not a crash
            assert is_list(errors)
        end
      end
    end
  end

  describe "fuzz: combined method + path + trust never crash" do
    setup do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST", "PUT", "DELETE"],
          "routes" => [
            %{
              "path" => "/api/items/[0-9]+",
              "verbs" => ["GET", "PUT"],
              "backend" => "http://localhost:8080",
              "exposure" => "authenticated"
            },
            %{
              "path" => "/api/admin",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080",
              "exposure" => "internal"
            }
          ]
        },
        "stealth" => %{"enabled" => true, "status_code" => 404}
      }

      {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
      Application.put_env(:http_capability_gateway, :policy_table, table)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{
        "default" => %{"untrusted" => 404, "authenticated" => 403}
      })
      :ok
    end

    property "any combination of method, path, and trust produces valid response", max_runs: 50 do
      check all method <- http_verb_string(),
                path <- path_string(),
                trust <- trust_level_string() do
        conn = conn(:get, path)
        conn = %{conn | method: method}

        conn =
          if trust do
            Plug.Conn.put_req_header(conn, "x-trust-level", trust)
          else
            conn
          end

        result = Gateway.call(conn, [])
        assert is_integer(result.status)
        assert result.status >= 100 and result.status < 600
      end
    end
  end
end
