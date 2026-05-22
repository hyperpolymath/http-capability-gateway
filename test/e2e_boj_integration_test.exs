# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.E2EBojIntegrationTest do
  @moduledoc """
  Phase C (`hyperpolymath/standards#98`) -- end-to-end verification of the
  gateway ↔ BoJ unified-zig-api gnosis-handler seam.

  These tests drive the full Plug pipeline (security headers → strip
  untrusted headers → extract trust → rate-limit → policy lookup →
  SafeTrust → proxy) and assert the contract that BoJ's gnosis handler
  observes on the wire. A real backend listening on TCP localhost stands
  in for the gnosis handler (the staging transport choice per the Phase A
  contract); it captures every forwarded request into an ETS table so
  each test can read back exactly what BoJ would have received.

  Contract under test: `docs/integration/http-capability-gateway-boj-contract.md`
  in the boj-server repo (ADR 0004). The seam invariants asserted here:

    * `X-Trust-Level` is the gateway-resolved trust class, NOT what the
      client supplied. The backend trusts it as authoritative because the
      gateway has already stripped any client-supplied value (from
      untrusted sources) and re-set it from the compiled trust value.
    * `X-Request-ID` is the gateway's resolved request id (auto-generated
      if absent) so backend logs join cleanly to gateway access logs.
    * `X-Gateway: http-capability-gateway` and the `X-Forwarded-*` tags
      are set per the Phase A contract.
    * Denied requests (verb not in policy, trust < exposure, default
      unmatched path) never reach the backend.

  The live mTLS handshake (`verify: :verify_peer`) is a transport-level
  guarantee proven separately by Phase B (`test/mtls_test.exs`). These
  tests run over the plaintext Plug pipeline with trust supplied via the
  trusted-proxy header path, which is the development mode the same
  invariant must hold for.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler}

  @backend_port 19_876
  @backend_url "http://localhost:#{@backend_port}"
  @capture_table :e2e_boj_seam_capture

  # Stand-in for BoJ's unified Zig API gnosis handler. Captures every
  # request it receives -- method, path, headers, body -- into an ETS
  # table so the test assertions can read back what BoJ would have seen.
  defmodule MockBoj do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    match _ do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      :ets.insert(
        :e2e_boj_seam_capture,
        {:erlang.unique_integer([:monotonic]),
         %{
           method: conn.method,
           path: conn.request_path,
           headers: Map.new(conn.req_headers),
           body: body
         }}
      )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true, gnosis_received: conn.request_path}))
    end
  end

  setup_all do
    # The ETS capture table is owned by a long-lived process so it
    # outlives any single test process. Tests reset it between runs
    # in the per-test `setup` block.
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ets.new(@capture_table, [
      :ordered_set,
      :public,
      :named_table,
      {:heir, owner, :no_state}
    ])

    {:ok, _pid} = Plug.Cowboy.http(MockBoj, [], port: @backend_port)

    HttpCapabilityGateway.RateLimiter.init([])
    HttpCapabilityGateway.K9Contract.init()

    Application.put_env(:http_capability_gateway, :backend_url, @backend_url)

    on_exit(fn ->
      Plug.Cowboy.shutdown(MockBoj.HTTP)
      send(owner, :stop)
    end)

    :ok
  end

  setup do
    :ets.delete_all_objects(@capture_table)

    policy = %{
      "dsl_version" => "1",
      "service" => %{"name" => "phase-c-seam-test"},
      "governance" => %{
        # GET only as the global verb so verb-not-declared (e.g. PUT) is
        # naturally a default-deny case below.
        "global_verbs" => ["GET"],
        "routes" => [
          %{
            "path" => "/health",
            "verbs" => ["GET"],
            "exposure" => "public",
            "narrative" => "Health probe; always public."
          },
          %{
            "path" => "/cartridges",
            "verbs" => ["GET", "POST"],
            "exposure" => "authenticated",
            "narrative" => "Cartridge discovery requires authentication."
          },
          %{
            "path" => "/admin",
            "verbs" => ["GET", "DELETE"],
            "exposure" => "internal",
            "narrative" => "Admin surface restricted to internal trust."
          }
        ]
      },
      "stealth" => %{"enabled" => true, "status_code" => 404}
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

    {:ok, table: table}
  end

  defp captured do
    @capture_table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {ord, _} -> ord end)
    |> Enum.map(fn {_, req} -> req end)
  end

  # ── Phase C / C1: case-by-case seam matrix ────────────────────────

  describe "public rule, untrusted client" do
    test "request reaches BoJ with the gateway-resolved trust forwarded" do
      conn =
        conn(:get, "/health")
        |> Gateway.call([])

      assert conn.status == 200
      assert [req] = captured()
      assert req.method == "GET"
      assert req.path == "/health"
      assert req.headers["x-trust-level"] == "untrusted"
      assert req.headers["x-gateway"] == "http-capability-gateway"
      assert is_binary(req.headers["x-forwarded-for"])
      assert is_binary(req.headers["x-forwarded-proto"])
      assert is_binary(req.headers["x-forwarded-host"])
      assert is_binary(req.headers["x-request-id"]) and req.headers["x-request-id"] != ""
    end
  end

  describe "authenticated rule, trusted-proxy header path" do
    test "X-Trust-Level: authenticated is honoured and forwarded onward" do
      # Plug.Test conns default to remote_ip {127, 0, 0, 1}, which sits in
      # :trusted_proxies, so the supplied header survives strip_untrusted_headers/2
      # and the gateway resolves trust as :authenticated.
      conn =
        conn(:get, "/cartridges")
        |> put_req_header("x-trust-level", "authenticated")
        |> Gateway.call([])

      assert conn.status == 200
      assert [req] = captured()
      # The gateway forwards its OWN resolved value (here :authenticated)
      # regardless of what the client wrote -- they happen to agree
      # because the source IP was trusted.
      assert req.headers["x-trust-level"] == "authenticated"
    end

    test "an internal trust on a trusted source is forwarded as internal" do
      conn =
        conn(:get, "/admin")
        |> put_req_header("x-trust-level", "internal")
        |> Gateway.call([])

      assert conn.status == 200
      assert [req] = captured()
      assert req.headers["x-trust-level"] == "internal"
    end
  end

  describe "authenticated rule, untrusted client" do
    test "request is denied with the stealth response and never forwarded" do
      conn = conn(:get, "/cartridges") |> Gateway.call([])

      # untrusted < authenticated -> deny. Stealth profile maps untrusted -> 404.
      assert conn.status == 404
      assert captured() == []
    end
  end

  describe "internal rule, non-internal client" do
    test "authenticated client on an internal route is denied without forwarding" do
      conn =
        conn(:delete, "/admin")
        |> put_req_header("x-trust-level", "authenticated")
        |> Gateway.call([])

      # authenticated < internal -> deny. Stealth profile maps authenticated -> 403.
      assert conn.status in [403, 404]
      assert captured() == []
    end
  end

  describe "verb not declared for the path" do
    test "PUT to /cartridges (verbs are [GET,POST]) is denied without forwarding" do
      conn =
        conn(:put, "/cartridges")
        |> put_req_header("x-trust-level", "authenticated")
        |> Gateway.call([])

      assert conn.status in [403, 404]
      assert captured() == []
    end
  end

  describe "path not in policy" do
    test "non-global verb on an undeclared path is denied without forwarding" do
      conn =
        conn(:delete, "/totally/undeclared/path")
        |> put_req_header("x-trust-level", "internal")
        |> Gateway.call([])

      # No global DELETE, no /totally/undeclared rule -> default-deny.
      assert conn.status in [403, 404]
      assert captured() == []
    end
  end

  # ── Phase C / C1: request-id propagation ─────────────────────────

  describe "request-id propagation across the seam" do
    test "a client-supplied X-Request-ID flows through to BoJ" do
      conn =
        conn(:get, "/health")
        |> put_req_header("x-request-id", "boj-seam-trace-001")
        |> Gateway.call([])

      assert conn.status == 200
      assert [req] = captured()
      assert req.headers["x-request-id"] == "boj-seam-trace-001"
    end

    test "an absent X-Request-ID is auto-generated and still forwarded" do
      conn = conn(:get, "/health") |> Gateway.call([])

      assert conn.status == 200
      assert [req] = captured()
      # `get_request_id/1` in the gateway emits a 32-char lowercase hex id
      # when none is supplied; the seam test asserts the contract on the
      # observable wire, not on the implementation, so we check shape.
      assert is_binary(req.headers["x-request-id"])
      assert byte_size(req.headers["x-request-id"]) > 0
      assert req.headers["x-request-id"] == conn.assigns[:request_id]
    end
  end

  # ── Phase C / C1: gateway is authoritative for X-Trust-Level ─────

  describe "trust header forgery resistance" do
    test "an untrusted client cannot smuggle X-Trust-Level: internal through to BoJ" do
      # Plug.Test conns default to 127.0.0.1, which is in :trusted_proxies.
      # Tighten the allowlist for this test so the test conn looks
      # 'untrusted' from the gateway's perspective and any supplied
      # X-Trust-Level is stripped before extract_trust resolves it.
      Application.put_env(:http_capability_gateway, :trusted_proxies, ["10.255.255.255"])

      try do
        conn =
          conn(:get, "/health")
          |> put_req_header("x-trust-level", "internal")
          |> Gateway.call([])

        assert conn.status == 200
        assert [req] = captured()
        # The smuggled "internal" was stripped; the gateway resolved trust
        # from the (now empty) header path and forwarded the authoritative
        # "untrusted" value on the BoJ-bound request.
        assert req.headers["x-trust-level"] == "untrusted"
      after
        Application.put_env(:http_capability_gateway, :trusted_proxies, ["127.0.0.1", "::1"])
      end
    end
  end
end
