# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.E2ETest do
  @moduledoc """
  End-to-end tests for the HTTP Capability Gateway.

  Tests the full request lifecycle from raw HTTP through policy enforcement
  to backend proxying, including policy hot-reload and error handling.

  These tests exercise the real plug pipeline (security headers, trust
  extraction, rate limiting, routing, policy lookup, and proxy forwarding)
  as an integrated whole.
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler}

  setup_all do
    HttpCapabilityGateway.RateLimiter.init([])
    HttpCapabilityGateway.K9Contract.init()
    :ok
  end

  # ── Full Request Lifecycle ────────────────────────────────────────

  describe "full request lifecycle: load → compile → enforce → proxy" do
    setup do
      policy = %{
        "dsl_version" => "1",
        "service" => %{"name" => "e2e-test-service", "version" => 1},
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{
              "path" => "/api/public",
              "verbs" => ["GET", "POST"],
              "backend" => "http://localhost:19876",
              "exposure" => "public"
            },
            %{
              "path" => "/api/private",
              "verbs" => ["GET", "POST"],
              "backend" => "http://localhost:19876",
              "exposure" => "authenticated"
            },
            %{
              "path" => "/api/internal",
              "verbs" => ["GET", "DELETE"],
              "backend" => "http://localhost:19876",
              "exposure" => "internal"
            },
            %{
              "path" => "/api/items/[0-9]+",
              "verbs" => ["GET", "PUT", "DELETE"],
              "backend" => "http://localhost:19876",
              "exposure" => "authenticated"
            }
          ]
        },
        "stealth" => %{
          "enabled" => true,
          "status_code" => 404
        }
      }

      {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
      Application.put_env(:http_capability_gateway, :policy_table, table)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{
        "default" => %{
          "untrusted" => 404,
          "authenticated" => 403
        }
      })
      Application.put_env(:http_capability_gateway, :strip_trust_header, true)
      Application.put_env(:http_capability_gateway, :trusted_proxies, ["127.0.0.1", "::1"])

      {:ok, table: table, policy: policy}
    end

    test "public GET: untrusted user gets through to backend (or 502)" do
      conn =
        conn(:get, "/api/public")
        |> Gateway.call([])

      # Public endpoint, GET is allowed, trust is untrusted but exposure is public → allow.
      # Backend is down → 502. If something intercepted, allowed status.
      assert conn.status in [200, 502]
      assert conn.assigns[:trust_level] == :untrusted
      assert is_binary(conn.assigns[:request_id])
    end

    test "authenticated GET to private: with auth header passes" do
      conn =
        conn(:get, "/api/private")
        |> put_req_header("x-trust-level", "authenticated")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :authenticated
      assert conn.status in [200, 502]
    end

    test "unauthenticated GET to private: denied with stealth" do
      conn =
        conn(:get, "/api/private")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :untrusted
      # Stealth profile maps "untrusted" → 404
      assert conn.status == 404
    end

    test "internal DELETE to internal endpoint: with internal trust passes" do
      conn =
        conn(:delete, "/api/internal")
        |> put_req_header("x-trust-level", "internal")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :internal
      assert conn.status in [200, 502]
    end

    test "authenticated DELETE to internal endpoint: denied" do
      conn =
        conn(:delete, "/api/internal")
        |> put_req_header("x-trust-level", "authenticated")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :authenticated
      # Stealth profile maps "authenticated" → 403
      assert conn.status in [403, 404]
    end

    test "regex route: authenticated PUT to /api/items/42" do
      conn =
        conn(:put, "/api/items/42")
        |> put_req_header("x-trust-level", "authenticated")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :authenticated
      assert conn.status in [200, 502]
    end

    test "regex route: untrusted GET to /api/items/99 denied" do
      conn =
        conn(:get, "/api/items/99")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :untrusted
      # Requires authenticated, user is untrusted → denied
      assert conn.status in [403, 404]
    end

    test "unknown verb on known route: 405 before policy evaluation" do
      conn = conn(:get, "/api/public")
      conn = %{conn | method: "TRACE"}
      conn = Gateway.call(conn, [])
      assert conn.status == 405
    end

    test "unknown path with global verb: uses global rule" do
      conn =
        conn(:get, "/completely/unknown/path")
        |> Gateway.call([])

      # Global verb GET is defined as public exposure → allowed
      assert conn.status in [200, 502]
    end

    test "unknown path with non-global verb: denied" do
      conn =
        conn(:delete, "/completely/unknown/path")
        |> Gateway.call([])

      # DELETE is not a global verb → no match → denied with stealth
      assert conn.status in [403, 404]
    end
  end

  # ── Policy Hot Reload ─────────────────────────────────────────────

  describe "policy hot-reload: atomic swap under load" do
    test "recompiling policy atomically swaps to new rules" do
      # Start with policy that allows GET only
      policy_v1 = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => []
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, _table_v1} = PolicyCompiler.compile(policy_v1, delete_old: false)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{})

      # Verify POST is denied under v1
      conn = conn(:post, "/api/test") |> Gateway.call([])
      assert conn.status == 403

      # Hot-reload to policy v2 that allows POST
      policy_v2 = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => []
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, _table_v2} = PolicyCompiler.compile(policy_v2, delete_old: false)

      # Verify POST is now allowed under v2
      conn = conn(:post, "/api/test") |> Gateway.call([])
      assert conn.status in [200, 502]
    end

    test "failed recompilation preserves last good policy" do
      # Load a good policy first
      good_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{
              "path" => "/api/ok",
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

      # Try to compile a policy with an invalid regex
      bad_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{
              "path" => "[invalid(regex",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080"
            }
          ]
        },
        "stealth" => %{"enabled" => false}
      }

      # Compilation should fail
      result = PolicyCompiler.compile(bad_policy, delete_old: false, atomic_swap: false)
      assert {:error, _errors} = result

      # Good policy should still be active
      current_table = Application.get_env(:http_capability_gateway, :policy_table)
      assert current_table == good_table

      # Requests should still work against the good policy
      conn = conn(:get, "/api/ok") |> Gateway.call([])
      assert conn.status in [200, 502]
    end

    test "policy swap adds new routes" do
      # v1: only /api/alpha
      policy_v1 = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => [],
          "routes" => [
            %{
              "path" => "/api/alpha",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080",
              "exposure" => "public"
            }
          ]
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, _} = PolicyCompiler.compile(policy_v1, delete_old: false)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{})

      # /api/beta should be denied
      conn = conn(:get, "/api/beta") |> Gateway.call([])
      assert conn.status == 403

      # v2: add /api/beta
      policy_v2 = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => [],
          "routes" => [
            %{
              "path" => "/api/alpha",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080",
              "exposure" => "public"
            },
            %{
              "path" => "/api/beta",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080",
              "exposure" => "public"
            }
          ]
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, _} = PolicyCompiler.compile(policy_v2, delete_old: false)

      # /api/beta should now be allowed
      conn = conn(:get, "/api/beta") |> Gateway.call([])
      assert conn.status in [200, 502]
    end

    test "policy swap removes routes" do
      # v1: both /api/alpha and /api/beta
      policy_v1 = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => [],
          "routes" => [
            %{
              "path" => "/api/alpha",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080",
              "exposure" => "public"
            },
            %{
              "path" => "/api/beta",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080",
              "exposure" => "public"
            }
          ]
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, _} = PolicyCompiler.compile(policy_v1, delete_old: false)
      Application.put_env(:http_capability_gateway, :stealth_profiles, %{})

      # Both should work
      conn = conn(:get, "/api/beta") |> Gateway.call([])
      assert conn.status in [200, 502]

      # v2: remove /api/beta
      policy_v2 = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => [],
          "routes" => [
            %{
              "path" => "/api/alpha",
              "verbs" => ["GET"],
              "backend" => "http://localhost:8080",
              "exposure" => "public"
            }
          ]
        },
        "stealth" => %{"enabled" => false}
      }

      {:ok, _} = PolicyCompiler.compile(policy_v2, delete_old: false)

      # /api/beta should now be denied
      conn = conn(:get, "/api/beta") |> Gateway.call([])
      assert conn.status == 403
    end
  end

  # ── Upstream Proxy Behavior ───────────────────────────────────────

  describe "upstream proxy: backend unavailable" do
    setup do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => [
            %{
              "path" => "/api/test",
              "verbs" => ["GET", "POST"],
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
      {:ok, table: table}
    end

    test "returns 502 when backend is unreachable" do
      conn =
        conn(:get, "/api/test")
        |> Gateway.call([])

      # Policy allows the request, but backend at port 19999 is not running
      assert conn.status == 502

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Bad Gateway"
    end

    test "returns 502 for POST with body when backend is down" do
      conn =
        conn(:post, "/api/test", Jason.encode!(%{key: "value"}))
        |> put_req_header("content-type", "application/json")
        |> Gateway.call([])

      assert conn.status == 502
    end
  end

  describe "upstream proxy: no policy loaded" do
    test "returns 503 when policy table is nil" do
      # Temporarily remove policy
      old_table = Application.get_env(:http_capability_gateway, :policy_table)
      Application.put_env(:http_capability_gateway, :policy_table, nil)

      conn = conn(:get, "/api/anything") |> Gateway.call([])
      assert conn.status == 503

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Service configuration unavailable"

      # Restore
      Application.put_env(:http_capability_gateway, :policy_table, old_table)
    end
  end

  # ── Health & Readiness Probes ─────────────────────────────────────

  describe "health and readiness endpoints" do
    setup do
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
      {:ok, table: table}
    end

    test "GET /health returns 200 with service info" do
      conn = conn(:get, "/health") |> Gateway.call([])
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "healthy"
      assert body["service"] == "http-capability-gateway"
      assert is_integer(body["uptime_seconds"])
    end

    test "GET /ready returns 200 when policy loaded" do
      conn = conn(:get, "/ready") |> Gateway.call([])
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ready"
      assert is_integer(body["policy_rules"])
    end

    test "GET /ready returns 503 when policy not loaded" do
      old_table = Application.get_env(:http_capability_gateway, :policy_table)
      Application.put_env(:http_capability_gateway, :policy_table, nil)

      conn = conn(:get, "/ready") |> Gateway.call([])
      assert conn.status == 503

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "not_ready"

      Application.put_env(:http_capability_gateway, :policy_table, old_table)
    end
  end

  # ── Request ID Propagation ────────────────────────────────────────

  describe "request ID propagation across lifecycle" do
    setup do
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
      {:ok, table: table}
    end

    test "provided request ID is preserved through the full pipeline" do
      conn =
        conn(:get, "/api/whatever")
        |> put_req_header("x-request-id", "e2e-trace-12345")
        |> Gateway.call([])

      assert conn.assigns[:request_id] == "e2e-trace-12345"
    end

    test "auto-generated request ID is a 32-char hex string" do
      conn = conn(:get, "/api/whatever") |> Gateway.call([])
      request_id = conn.assigns[:request_id]
      assert is_binary(request_id)
      assert byte_size(request_id) == 32
      assert Regex.match?(~r/^[0-9a-f]{32}$/, request_id)
    end
  end
end
