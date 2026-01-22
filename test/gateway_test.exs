# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.GatewayTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler}

  setup do
    # Clean up ETS tables
    try do
      :ets.delete(:gateway_rules)
      :ets.delete(:stealth_config)
    catch
      :error, :badarg -> :ok
    end

    # Compile default policy
    policy = %{
      "dsl_version" => "1",
      "governance" => %{
        "global_verbs" => ["GET", "POST"],
        "routes" => [
          %{"path" => "/api/admin", "verbs" => ["GET"]},
          %{"path" => "/api/users/[0-9]+", "verbs" => ["GET", "PUT", "DELETE"]},
          %{"path" => "/health", "verbs" => ["GET"]}
        ]
      },
      "stealth" => %{
        "enabled" => true,
        "status_code" => 404
      }
    }

    PolicyCompiler.compile(policy)
    :ok
  end

  describe "HTTP verb enforcement" do
    test "allows global verbs on unspecified routes" do
      conn = conn(:get, "/api/public")
      conn = Gateway.call(conn, [])

      # Should pass through (not get 404/403)
      refute conn.status == 404
      refute conn.status == 403
    end

    test "denies non-global verbs on unspecified routes (stealth)" do
      conn = conn(:delete, "/api/public")
      conn = Gateway.call(conn, [])

      assert conn.status == 404
      assert conn.halted
    end

    test "allows route-specific verbs" do
      conn = conn(:get, "/api/admin")
      conn = Gateway.call(conn, [])

      refute conn.status == 404
      refute conn.status == 403
    end

    test "denies verbs not allowed for route" do
      conn = conn(:post, "/api/admin")
      conn = Gateway.call(conn, [])

      assert conn.status == 404
      assert conn.halted
    end

    test "handles regex route matching" do
      # Should match /api/users/[0-9]+
      conn = conn(:put, "/api/users/123")
      conn = Gateway.call(conn, [])

      refute conn.status == 404

      # Should not match (non-numeric ID)
      conn = conn(:put, "/api/users/abc")
      conn = Gateway.call(conn, [])

      assert conn.status == 404
    end

    test "allows DELETE on specific routes" do
      conn = conn(:delete, "/api/users/456")
      conn = Gateway.call(conn, [])

      refute conn.status == 404
      refute conn.status == 403
    end
  end

  describe "HTTP methods" do
    test "handles GET requests" do
      conn = conn(:get, "/health")
      conn = Gateway.call(conn, [])

      refute conn.status == 404
    end

    test "handles POST requests" do
      conn = conn(:post, "/api/public")
      conn = Gateway.call(conn, [])

      refute conn.status == 404
    end

    test "handles PUT requests" do
      conn = conn(:put, "/api/users/789")
      conn = Gateway.call(conn, [])

      refute conn.status == 404
    end

    test "handles DELETE requests" do
      conn = conn(:delete, "/api/users/321")
      conn = Gateway.call(conn, [])

      refute conn.status == 404
    end

    test "handles HEAD requests" do
      # HEAD not in global verbs, should be denied
      conn = conn(:head, "/api/public")
      conn = Gateway.call(conn, [])

      assert conn.status == 404
    end

    test "handles OPTIONS requests" do
      # OPTIONS not in global verbs, should be denied
      conn = conn(:options, "/api/public")
      conn = Gateway.call(conn, [])

      assert conn.status == 404
    end
  end

  describe "stealth mode" do
    test "returns configured stealth status code" do
      conn = conn(:delete, "/api/forbidden")
      conn = Gateway.call(conn, [])

      assert conn.status == 404  # Stealth status code
    end

    test "halts connection on forbidden request" do
      conn = conn(:patch, "/api/admin")
      conn = Gateway.call(conn, [])

      assert conn.halted
    end

    test "returns empty body in stealth mode" do
      conn = conn(:delete, "/api/forbidden")
      conn = Gateway.call(conn, [])

      assert conn.resp_body == ""
    end
  end

  describe "stealth disabled" do
    setup do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"]
        },
        "stealth" => %{
          "enabled" => false,
          "status_code" => 403
        }
      }

      PolicyCompiler.compile(policy)
      :ok
    end

    test "returns 403 when stealth disabled" do
      conn = conn(:delete, "/api/forbidden")
      conn = Gateway.call(conn, [])

      assert conn.status == 403
    end
  end

  describe "request ID tracking" do
    test "preserves existing request ID" do
      conn = conn(:get, "/health")
      |> put_req_header("x-request-id", "test-123")

      conn = Gateway.call(conn, [])

      assert get_req_header(conn, "x-request-id") == ["test-123"]
    end

    test "generates request ID if missing" do
      conn = conn(:get, "/health")
      conn = Gateway.call(conn, [])

      # Should have a request ID header or assign
      assert is_binary(conn.assigns[:request_id]) or
             length(get_req_header(conn, "x-request-id")) > 0
    end
  end

  describe "trust level evaluation" do
    test "extracts trust level from header" do
      conn = conn(:get, "/api/admin")
      |> put_req_header("x-trust-level", "high")

      conn = Gateway.call(conn, [])

      # Trust level should be evaluated
      assert conn.assigns[:trust_level] == "high" or
             conn.assigns[:trust_level] == :high
    end

    test "defaults to low trust when header missing" do
      conn = conn(:get, "/api/public")
      conn = Gateway.call(conn, [])

      # Should default to low trust
      assert conn.assigns[:trust_level] in ["low", :low, nil]
    end

    test "handles invalid trust level gracefully" do
      conn = conn(:get, "/api/public")
      |> put_req_header("x-trust-level", "invalid")

      conn = Gateway.call(conn, [])

      # Should not crash, should default or handle gracefully
      assert is_map(conn.assigns)
    end
  end

  describe "path matching edge cases" do
    test "handles paths with trailing slashes" do
      conn = conn(:get, "/health/")
      conn = Gateway.call(conn, [])

      # Should match /health
      refute conn.status == 404
    end

    test "handles paths with query parameters" do
      conn = conn(:get, "/api/public?foo=bar")
      conn = Gateway.call(conn, [])

      refute conn.status == 404
    end

    test "handles paths with fragments" do
      conn = conn(:get, "/api/public#section")
      conn = Gateway.call(conn, [])

      refute conn.status == 404
    end

    test "handles root path" do
      conn = conn(:get, "/")
      conn = Gateway.call(conn, [])

      # Should match global verbs (GET allowed)
      refute conn.status == 404
    end

    test "handles nested paths" do
      conn = conn(:get, "/api/v1/users/123/posts")
      conn = Gateway.call(conn, [])

      # Should use global verbs (GET allowed)
      refute conn.status == 404
    end
  end

  describe "case sensitivity" do
    test "verb matching is case-sensitive" do
      conn = conn(:get, "/health")
      conn = Gateway.call(conn, [])

      refute conn.status == 404

      # Lowercase verb should not match
      conn = %Plug.Conn{conn(:get, "/health") | method: "get"}
      conn = Gateway.call(conn, [])

      assert conn.status == 404
    end
  end

  describe "concurrent requests" do
    test "handles multiple concurrent requests" do
      # Simulate 10 concurrent requests
      tasks = for i <- 1..10 do
        Task.async(fn ->
          conn = conn(:get, "/api/public")
          conn = Gateway.call(conn, [])
          {i, conn.status}
        end)
      end

      results = Task.await_many(tasks, 5000)

      # All requests should succeed (not get 404)
      assert Enum.all?(results, fn {_i, status} -> status != 404 end)
    end
  end
end
