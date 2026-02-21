# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.GRPCHandler do
  @moduledoc """
  gRPC request handler with policy enforcement.

  Parses gRPC requests (HTTP/2 frames), enforces verb governance on
  service/method calls, and forwards allowed requests to backend gRPC services.

  ## gRPC Policy Format

  Policies map gRPC service.method to exposure levels:

  ```yaml
  grpc_methods:
    - service: "grpc.health.v1.Health"
      method: "Check"
      exposure: "public"
    - service: "myapp.UserService"
      method: "GetUser"
      exposure: "authenticated"
  ```

  ## Integration

  Uses Zig FFI (ffi/zig/grpc/parser.zig) for parsing HTTP/2 gRPC frames.
  Conforms to Idris2 ABI (src/abi/Protocol.idr).
  """

  require Logger
  alias HttpCapabilityGateway.{Logging, PolicyCompiler}

  @doc """
  Handle gRPC request with policy enforcement.

  ## Process

  1. Parse gRPC frame (HTTP/2 DATA with 5-byte header)
  2. Extract service/method from :path pseudo-header
  3. Check policy for allowed methods
  4. Forward to backend gRPC service if allowed
  5. Return gRPC error code if denied

  ## Parameters

    - `conn`: Plug.Conn with gRPC request

  ## Returns

    - Plug.Conn with gRPC response or error
  """
  def handle(conn) do
    request_id = conn.assigns[:request_id] || generate_request_id()

    Logging.log_request_received(request_id, conn, %{
      protocol: "gRPC"
    })

    # Read request body (gRPC frame)
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    # Parse gRPC request via Zig FFI
    # TODO: Call parse_grpc_request from Zig
    # For now, return stub response

    service = extract_service_from_path(conn.request_path)
    method = extract_method_from_path(conn.request_path)

    Logger.info("gRPC request",
      service: service,
      method: method,
      request_id: request_id
    )

    # Check policy (stub - would integrate with PolicyCompiler)
    if grpc_method_allowed?(service, method) do
      # Forward to backend gRPC service
      forward_grpc_request(conn, service, method, body, request_id)
    else
      # Return gRPC PERMISSION_DENIED error
      send_grpc_error(conn, :permission_denied, "Method not allowed by policy")
    end
  end

  # Extract service from gRPC path (/Service/Method)
  defp extract_service_from_path(path) do
    case String.split(path, "/", trim: true) do
      [service, _method] -> service
      _ -> "unknown"
    end
  end

  # Extract method from gRPC path
  defp extract_method_from_path(path) do
    case String.split(path, "/", trim: true) do
      [_service, method] -> method
      _ -> "unknown"
    end
  end

  # Check if gRPC method is allowed
  # Integrates with PolicyCompiler to enforce gRPC-specific policies
  defp grpc_method_allowed?(service, method) do
    # Build gRPC path in format /Service/Method
    path = "/#{service}/#{method}"

    # Check against policy rules
    # gRPC methods are treated as POST requests in the policy
    case PolicyCompiler.lookup(:policy_rules, path, :POST) do
      {:ok, _rule} -> true
      {:error, :no_match} -> false
    end
  end

  # Forward gRPC request to backend
  defp forward_grpc_request(conn, service, method, _body, request_id) do
    backend_url = Application.get_env(:http_capability_gateway, :grpc_backend_url, "http://localhost:50051")

    Logger.info("Forwarding gRPC request",
      backend: backend_url,
      service: service,
      method: method,
      request_id: request_id
    )

    # TODO: Implement gRPC client forwarding
    # For now, return success stub
    send_grpc_response(conn, 0, "gRPC forwarding not yet implemented")
  end

  # Send gRPC error response
  defp send_grpc_error(conn, error_code, message) do
    grpc_status = case error_code do
      :permission_denied -> 7
      :unauthenticated -> 16
      :unavailable -> 14
      _ -> 2  # UNKNOWN
    end

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/grpc")
    |> Plug.Conn.put_resp_header("grpc-status", to_string(grpc_status))
    |> Plug.Conn.put_resp_header("grpc-message", message)
    |> Plug.Conn.send_resp(200, "")  # gRPC errors use HTTP 200
    |> Plug.Conn.halt()
  end

  # Send gRPC success response
  defp send_grpc_response(conn, _status, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/grpc")
    |> Plug.Conn.put_resp_header("grpc-status", "0")
    |> Plug.Conn.send_resp(200, body)
    |> Plug.Conn.halt()
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
