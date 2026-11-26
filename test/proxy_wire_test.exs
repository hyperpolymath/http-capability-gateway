# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.ProxyWireBackend do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)

    send(
      opts[:owner],
      {:wire_request, conn.request_path, conn.query_string, conn.req_headers, body}
    )

    case conn.request_path do
      "/redirect" ->
        conn |> put_resp_header("location", "/redirected") |> send_resp(302, "move")

      "/unavailable" ->
        send_resp(conn, 503, "not retried")

      _ ->
        conn = put_resp_content_type(conn, "application/json")

        conn = %{
          conn
          | resp_headers: [{"set-cookie", "a=1"}, {"set-cookie", "b=2"} | conn.resp_headers]
        }

        send_resp(conn, 200, body)
    end
  end
end

defmodule HttpCapabilityGateway.ProxyWireTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias HttpCapabilityGateway.Plugins.{WebhookHardener, XmlRpcShield}
  alias HttpCapabilityGateway.Proxy

  setup do
    ref = make_ref()

    {:ok, _} =
      Plug.Cowboy.http(HttpCapabilityGateway.ProxyWireBackend, [owner: self()], port: 0, ref: ref)

    previous =
      for key <- [:backend_url, :max_request_body_bytes, :request_plugins],
          do: {key, Application.get_env(:http_capability_gateway, key)}

    Application.put_env(
      :http_capability_gateway,
      :backend_url,
      "http://127.0.0.1:#{:ranch.get_port(ref)}"
    )

    Application.put_env(:http_capability_gateway, :max_request_body_bytes, 1024)

    Application.put_env(:http_capability_gateway, :request_plugins, %{
      {"POST", "/webhook"} => [{WebhookHardener, %{}}],
      {"POST", "/xmlrpc.php"} => [{XmlRpcShield, %{}}]
    })

    on_exit(fn ->
      Plug.Cowboy.shutdown(ref)

      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:http_capability_gateway, key),
          else: Application.put_env(:http_capability_gateway, key, value)
      end
    end)

    :ok
  end

  test "real upstream preserves query, JSON bytes, repeated cookies and resolved headers" do
    body = Jason.encode!("λ and \"quotes\"")

    response =
      conn(:post, "/echo?x=a%2Fb&n=2", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-trust-level", "internal")
      |> put_req_header("x-request-id", "forged")
      |> assign(:trust_level, :untrusted)
      |> assign(:request_id, "resolved-test-id")
      |> Proxy.forward(%{exposure: "public"})

    assert response.status == 200
    assert response.resp_body == body
    assert Enum.sort(get_resp_header(response, "set-cookie")) == ["a=1", "b=2"]
    assert_receive {:wire_request, "/echo", "x=a%2Fb&n=2", headers, ^body}
    assert {"x-trust-level", "untrusted"} in headers
    assert {"x-request-id", "resolved-test-id"} in headers
    refute {"x-trust-level", "internal"} in headers
  end

  test "redirect is returned rather than followed outside the policy decision" do
    response = conn(:get, "/redirect") |> Proxy.forward(%{exposure: "public"})
    assert response.status == 302
    assert get_resp_header(response, "location") == ["/redirected"]
    assert_receive {:wire_request, "/redirect", _, _, _}
    refute_receive {:wire_request, _, _, _, _}
  end

  test "upstream 503 is preserved without retrying the operation" do
    response = conn(:post, "/unavailable", "operation") |> Proxy.forward(%{exposure: "public"})
    assert response.status == 503
    assert response.resp_body == "not retried"
    assert_receive {:wire_request, "/unavailable", _, _, "operation"}
    refute_receive {:wire_request, _, _, _, _}
  end

  test "body beyond configured bound never reaches upstream" do
    response =
      conn(:post, "/xmlrpc.php", String.duplicate("x", 1025))
      |> Proxy.forward(%{exposure: "public"})

    assert response.status == 413
    refute_receive {:wire_request, _, _, _, _}
  end

  test "denies a blocked target in a raw JSON webhook" do
    response =
      conn(:post, "/webhook", Jason.encode!(%{target: "http://127.0.0.1"}))
      |> put_req_header("content-type", "application/json")
      |> Proxy.forward(%{exposure: "public"})

    assert response.status == 403
    assert Jason.decode!(response.resp_body)["reason"] == "target_ip_blocked"
    refute_receive {:wire_request, _, _, _, _}
  end

  test "denies an unauthorized XML-RPC method" do
    response =
      conn(:post, "/xmlrpc.php", "<methodCall><methodName>other</methodName></methodCall>")
      |> put_req_header("content-type", "text/xml")
      |> Proxy.forward(%{exposure: "public"})

    assert response.status == 403
    assert Jason.decode!(response.resp_body)["reason"] == "rpc_method_unauthorized"
    refute_receive {:wire_request, _, _, _, _}
  end

  test "denies an XML-RPC request with an empty body" do
    response =
      conn(:post, "/xmlrpc.php")
      |> put_req_header("content-type", "text/xml")
      |> Proxy.forward(%{exposure: "public"})

    assert response.status == 403
    assert Jason.decode!(response.resp_body)["reason"] == "rpc_method_missing"
    refute_receive {:wire_request, _, _, _, _}
  end

  test "forwards the original XML bytes after inspection" do
    body = "<methodCall>\n  <methodName>pingback.ping</methodName>\n</methodCall>"

    response =
      conn(:post, "/xmlrpc.php", body)
      |> put_req_header("content-type", "text/xml")
      |> Proxy.forward(%{exposure: "public"})

    assert response.status == 200
    assert_receive {:wire_request, "/xmlrpc.php", "", _, ^body}
  end
end
