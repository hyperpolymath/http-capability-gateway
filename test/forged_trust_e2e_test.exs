# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.ForgedTrustE2ETest do
  @moduledoc """
  End-to-end regression net for the "plaintext listener + forged
  X-Trust-Level header" attack class (audit issue #31, priority 5).

  The existing test/security_test.exs strip-untrusted-headers describe
  block asserts on `conn.assigns[:trust_level]` -- correct but partial.
  This file closes the loop by asserting on the actual *response* the
  forged client receives when it targets a route whose exposure is
  `:internal`. The result must be 403 (or stealth status), NEVER an
  upstream-proxied 200/502.
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

  setup do
    # A policy with an `internal`-exposure route. A correctly trusted
    # caller (loopback proxy passing the trust header) reaches the
    # backend; a forged-header caller from any other IP must be denied.
    policy = %{
      "dsl_version" => "1",
      "governance" => %{
        "global_verbs" => ["GET"],
        "routes" => [
          %{
            "path" => "/internal/secret",
            "verbs" => ["GET"],
            "exposure" => "internal",
            "backend" => "http://localhost:8080"
          }
        ]
      }
    }

    {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
    Application.put_env(:http_capability_gateway, :policy_table, table)
    Application.put_env(:http_capability_gateway, :stealth_profiles, %{})
    # Belt + braces: ensure strip is enabled and only loopback is trusted.
    Application.put_env(:http_capability_gateway, :strip_trust_header, true)
    Application.put_env(:http_capability_gateway, :trusted_proxies, ["127.0.0.1", "::1"])
    :ok
  end

  describe "plaintext listener + forged X-Trust-Level against :internal route" do
    test "denies a forged 'internal' from a non-loopback IP" do
      # Forge the trust header AND pretend to be 10.x.x.x (i.e. NOT a
      # trusted upstream proxy). The strip plug must remove the header
      # before extract_trust runs; the gateway must then default to
      # :untrusted and deny on the :internal route.
      conn =
        conn(:get, "/internal/secret")
        |> put_req_header("x-trust-level", "internal")
        |> Map.put(:remote_ip, {10, 0, 0, 99})
        |> Gateway.call([])

      # The response itself must be a denial, not a proxied 200/502.
      # Without the strip plug, this would be a 200 (or 502 because the
      # backend is down) — i.e. a successful privilege escalation.
      assert conn.status == 403, "forged trust must NOT reach :internal route"
      assert conn.halted

      # Defence-in-depth: also assert on the resolved trust level.
      assert conn.assigns[:trust_level] == :untrusted
    end

    test "denies forged 'authenticated' against :internal (rank insufficient)" do
      conn =
        conn(:get, "/internal/secret")
        |> put_req_header("x-trust-level", "authenticated")
        |> Map.put(:remote_ip, {203, 0, 113, 7})
        |> Gateway.call([])

      assert conn.status == 403
      assert conn.assigns[:trust_level] == :untrusted
    end

    test "preserves real internal trust from loopback (control case)" do
      # Loopback is in the trusted_proxies default; this case must NOT
      # be affected by the strip plug, so the gateway sees :internal
      # and allows the request to reach the (down) backend, yielding a
      # 502 Bad Gateway (NOT 403).
      conn =
        conn(:get, "/internal/secret")
        |> put_req_header("x-trust-level", "internal")
        # conn/3 from Plug.Test defaults remote_ip to {127, 0, 0, 1}
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :internal
      # Backend is not running in tests, so the proxy returns 502.
      # Crucially, NOT 403 -- the policy decision allowed the request.
      assert conn.status in [200, 502]
    end

    test "denies forged garbage trust value against :internal route" do
      # Even with a "trusted" remote IP, garbage values must parse to
      # :untrusted (SafeTrust.parse_trust fail-safe).
      conn =
        conn(:get, "/internal/secret")
        |> put_req_header("x-trust-level", "ADMIN_OVERRIDE")
        |> Gateway.call([])

      assert conn.assigns[:trust_level] == :untrusted
      assert conn.status == 403
    end
  end
end
