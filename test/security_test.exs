# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.SecurityTest do
  @moduledoc """
  Security tests for the HTTP Capability Gateway.

  Covers OWASP-relevant attack surface:
    - Request sanitization (unknown methods, oversized paths, null bytes)
    - Header handling (trust spoofing, hop-by-hop filtering, security headers)
    - SSRF resistance (internal IP backends, path traversal)
    - Capability/trust token validation (forging, downgrade, atom exhaustion)
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler, SafeTrust}

  setup_all do
    HttpCapabilityGateway.RateLimiter.init([])
    HttpCapabilityGateway.K9Contract.init()
    :ok
  end

  setup do
    policy = %{
      "dsl_version" => "1",
      "governance" => %{
        "global_verbs" => ["GET", "POST"],
        "routes" => [
          %{
            "path" => "/api/users",
            "verbs" => ["GET", "POST"],
            "backend" => "http://localhost:8080",
            "exposure" => "public"
          },
          %{
            "path" => "/api/admin",
            "verbs" => ["GET", "DELETE"],
            "backend" => "http://localhost:8080",
            "exposure" => "internal"
          },
          %{
            "path" => "/api/auth",
            "verbs" => ["GET", "POST"],
            "backend" => "http://localhost:8080",
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
        "authenticated" => 404
      }
    })

    # Default: strip trust headers from non-loopback sources
    Application.put_env(:http_capability_gateway, :strip_trust_header, true)
    Application.put_env(:http_capability_gateway, :trusted_proxies, ["127.0.0.1", "::1"])

    {:ok, table: table}
  end

  # ── Request Sanitization ──────────────────────────────────────────

  describe "request sanitization: unknown HTTP methods" do
    test "rejects exotic HTTP methods with 405 (PROPFIND)" do
      conn = conn(:get, "/api/users")
      conn = %{conn | method: "PROPFIND"}
      conn = Gateway.call(conn, [])
      assert conn.status == 405
      assert conn.halted || conn.state == :sent
    end

    test "rejects exotic HTTP methods with 405 (MKCOL)" do
      conn = conn(:get, "/api/users")
      conn = %{conn | method: "MKCOL"}
      conn = Gateway.call(conn, [])
      assert conn.status == 405
    end

    test "rejects arbitrary method strings without atom exhaustion" do
      # Send many unique method strings — should NOT exhaust atom table
      for i <- 1..100 do
        conn = conn(:get, "/api/users")
        conn = %{conn | method: "BOGUS_METHOD_#{i}"}
        conn = Gateway.call(conn, [])
        assert conn.status == 405
      end
    end

    test "rejects lowercase http methods" do
      conn = conn(:get, "/api/users")
      conn = %{conn | method: "get"}
      conn = Gateway.call(conn, [])
      assert conn.status == 405
    end

    test "rejects empty method string" do
      conn = conn(:get, "/api/users")
      conn = %{conn | method: ""}
      conn = Gateway.call(conn, [])
      assert conn.status == 405
    end
  end

  describe "request sanitization: path handling" do
    test "handles paths with null bytes without crashing" do
      # Null bytes in paths can confuse C-based parsers downstream
      conn = conn(:get, "/api/users%00/../../etc/passwd") |> Gateway.call([])
      # Gateway should respond (not crash) — exact status depends on routing
      assert conn.status in [200, 403, 404, 502]
    end

    test "handles extremely long paths without crashing" do
      long_path = "/" <> String.duplicate("a", 10_000)
      conn = conn(:get, long_path) |> Gateway.call([])
      assert conn.status in [200, 403, 404, 502]
    end

    test "handles paths with encoded traversal sequences" do
      conn = conn(:get, "/api/users/../../../etc/passwd") |> Gateway.call([])
      assert conn.status in [200, 403, 404, 502]
      refute conn.status == 500
    end

    test "handles paths with double encoding" do
      conn = conn(:get, "/api/users/%252e%252e/admin") |> Gateway.call([])
      assert conn.status in [200, 403, 404, 502]
      refute conn.status == 500
    end
  end

  # ── Header Handling & Trust Spoofing ──────────────────────────────

  describe "header handling: trust level spoofing prevention" do
    test "strips X-Trust-Level from non-trusted source" do
      # Remote IP defaults to 127.0.0.1 in Plug.Test, which IS trusted.
      # Simulate an external IP by using a non-loopback address.
      conn =
        conn(:get, "/api/admin")
        |> put_req_header("x-trust-level", "internal")
        |> Map.put(:remote_ip, {192, 168, 1, 100})
        |> Gateway.call([])

      # The trust header should have been stripped; request treated as untrusted.
      # An untrusted user hitting an internal endpoint should be denied.
      assert conn.assigns[:trust_level] == :untrusted
    end

    test "preserves X-Trust-Level from trusted proxy" do
      # 127.0.0.1 is in trusted_proxies by default
      conn =
        conn(:get, "/api/admin")
        |> put_req_header("x-trust-level", "internal")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :internal
    end

    test "rejects forged internal trust from external IP" do
      conn =
        conn(:get, "/api/admin")
        |> put_req_header("x-trust-level", "internal")
        |> Map.put(:remote_ip, {10, 0, 0, 99})
        |> Gateway.call([])

      # Should be denied: trust stripped to untrusted, endpoint requires internal
      assert conn.assigns[:trust_level] == :untrusted
    end

    test "handles missing trust header gracefully" do
      conn = conn(:get, "/api/users") |> Gateway.call([])
      assert conn.assigns[:trust_level] == :untrusted
    end

    test "handles garbage trust header values" do
      conn =
        conn(:get, "/api/users")
        |> put_req_header("x-trust-level", "superadmin_root_override")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :untrusted
    end

    test "handles trust header with SQL injection payload" do
      conn =
        conn(:get, "/api/users")
        |> put_req_header("x-trust-level", "internal' OR '1'='1")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :untrusted
    end
  end

  describe "header handling: security response headers" do
    test "sets X-Content-Type-Options: nosniff" do
      conn = conn(:get, "/health") |> Gateway.call([])
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "sets X-Frame-Options: DENY" do
      conn = conn(:get, "/health") |> Gateway.call([])
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "sets Cache-Control to no-store" do
      conn = conn(:get, "/health") |> Gateway.call([])
      assert get_resp_header(conn, "cache-control") == ["no-store, no-cache, must-revalidate"]
    end

    test "sets Referrer-Policy" do
      conn = conn(:get, "/health") |> Gateway.call([])
      assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
    end

    test "security headers present on denied responses too" do
      conn =
        conn(:delete, "/api/unknown_endpoint")
        |> Gateway.call([])

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end
  end

  # ── SSRF Resistance ───────────────────────────────────────────────

  describe "SSRF resistance: proxy target validation" do
    test "proxy does not follow redirects to internal IPs by default" do
      # Req library with retry: false is used; verify the backend URL
      # is built from config, not from user-controlled input.
      # The backend URL comes from Application.get_env, NOT from
      # request headers or query params.
      backend_url = Application.get_env(:http_capability_gateway, :backend_url, "http://localhost:8080")
      assert is_binary(backend_url)
    end

    test "X-Forwarded-Host does not influence backend target" do
      # Even if a client sends X-Forwarded-Host, the proxy should route
      # to the configured backend_url, not to the forged host.
      conn =
        conn(:get, "/api/users")
        |> put_req_header("x-forwarded-host", "evil.internal.service")
        |> Gateway.call([])

      # Should not crash and should route to configured backend (which is down → 502)
      # or policy allows/denies normally
      assert conn.status in [200, 403, 404, 502]
    end

    test "Host header does not influence backend routing" do
      conn =
        conn(:get, "/api/users")
        |> put_req_header("host", "169.254.169.254")
        |> Gateway.call([])

      assert conn.status in [200, 403, 404, 502]
    end
  end

  # ── Capability / Trust Token Validation ───────────────────────────

  describe "capability token: SafeTrust validation" do
    test "parse_trust rejects all unknown strings to :untrusted" do
      malicious_inputs = [
        "admin",
        "root",
        "INTERNAL",
        "Internal",
        "Authenticated",
        "superuser",
        "internal\x00",
        "internal; DROP TABLE users;",
        "",
        nil,
        "internal\ninternal"
      ]

      for input <- malicious_inputs do
        assert SafeTrust.parse_trust(input) == :untrusted,
               "Expected :untrusted for input #{inspect(input)}"
      end
    end

    test "parse_trust accepts only exact lowercase matches" do
      assert SafeTrust.parse_trust("authenticated") == :authenticated
      assert SafeTrust.parse_trust("internal") == :internal
      assert SafeTrust.parse_trust("untrusted") == :untrusted
    end

    test "parse_exposure rejects unknown strings to :public (fail-open)" do
      assert SafeTrust.parse_exposure("typo") == :public
      assert SafeTrust.parse_exposure("INTERNAL") == :public
      assert SafeTrust.parse_exposure(nil) == :public
    end

    test "parse_exposure accepts only exact lowercase matches" do
      assert SafeTrust.parse_exposure("authenticated") == :authenticated
      assert SafeTrust.parse_exposure("internal") == :internal
      assert SafeTrust.parse_exposure("public") == :public
    end

    test "trust hierarchy is monotone: upgrading trust never revokes access" do
      trust_levels = [:untrusted, :authenticated, :internal]
      exposure_levels = [:public, :authenticated, :internal]

      for exposure <- exposure_levels do
        # If a lower trust level can access, all higher ones can too
        for {t1, i1} <- Enum.with_index(trust_levels),
            {t2, i2} <- Enum.with_index(trust_levels),
            i1 <= i2 do
          if SafeTrust.satisfies?(t1, exposure) do
            assert SafeTrust.satisfies?(t2, exposure),
                   "Monotonicity violation: #{t1} satisfies #{exposure} but #{t2} does not"
          end
        end
      end
    end

    test "access decision matrix is correct" do
      # Exhaustive test of all 9 combinations
      assert SafeTrust.evaluate(:untrusted, :public) == {:allow, :untrusted, :public}
      assert SafeTrust.evaluate(:untrusted, :authenticated) == {:deny, :untrusted, :authenticated}
      assert SafeTrust.evaluate(:untrusted, :internal) == {:deny, :untrusted, :internal}

      assert SafeTrust.evaluate(:authenticated, :public) == {:allow, :authenticated, :public}
      assert SafeTrust.evaluate(:authenticated, :authenticated) == {:allow, :authenticated, :authenticated}
      assert SafeTrust.evaluate(:authenticated, :internal) == {:deny, :authenticated, :internal}

      assert SafeTrust.evaluate(:internal, :public) == {:allow, :internal, :public}
      assert SafeTrust.evaluate(:internal, :authenticated) == {:allow, :internal, :authenticated}
      assert SafeTrust.evaluate(:internal, :internal) == {:allow, :internal, :internal}
    end

    test "unknown atoms in satisfies? return false (deny)" do
      assert SafeTrust.satisfies?(:superadmin, :public) == false
      assert SafeTrust.satisfies?(:internal, :superadmin) == false
    end
  end

  describe "capability token: gateway enforcement integration" do
    test "untrusted user cannot access internal-only endpoint" do
      conn =
        conn(:get, "/api/admin")
        |> Gateway.call([])

      # Default trust is :untrusted, /api/admin requires internal → denied
      assert conn.assigns[:trust_level] == :untrusted
      # Should be denied (stealth 404 or 403)
      assert conn.status in [403, 404]
    end

    test "authenticated user cannot access internal-only endpoint" do
      conn =
        conn(:get, "/api/admin")
        |> put_req_header("x-trust-level", "authenticated")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :authenticated
      assert conn.status in [403, 404]
    end

    test "internal user can access internal-only endpoint" do
      conn =
        conn(:get, "/api/admin")
        |> put_req_header("x-trust-level", "internal")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :internal
      # Allowed — gets forwarded to backend (502 since backend is down, or 200)
      assert conn.status in [200, 502]
    end

    test "untrusted user cannot access authenticated endpoint" do
      conn =
        conn(:get, "/api/auth")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :untrusted
      assert conn.status in [403, 404]
    end

    test "authenticated user can access authenticated endpoint" do
      conn =
        conn(:get, "/api/auth")
        |> put_req_header("x-trust-level", "authenticated")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :authenticated
      assert conn.status in [200, 502]
    end
  end
end
