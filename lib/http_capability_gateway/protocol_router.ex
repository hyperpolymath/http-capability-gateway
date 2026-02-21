# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.ProtocolRouter do
  @moduledoc """
  Multi-protocol router supporting HTTP/REST, gRPC, and GraphQL.

  Routes requests based on detected protocol:
  - HTTP/REST: Standard HTTP verbs (GET, POST, etc.)
  - gRPC: HTTP/2 with application/grpc content-type
  - GraphQL: POST to /graphql endpoint with JSON body

  Protocol detection is automatic based on request characteristics.
  """

  require Logger
  alias HttpCapabilityGateway.{Gateway, GRPCHandler, GraphQLHandler}

  @doc """
  Detect protocol from request and route accordingly.

  ## Protocol Detection

  1. **GraphQL**: POST to /graphql path
  2. **gRPC**: HTTP/2 with content-type: application/grpc*
  3. **HTTP/REST**: Everything else

  ## Parameters

    - `conn`: Plug.Conn struct

  ## Returns

    - Plug.Conn with response from appropriate handler
  """
  def route(conn) do
    protocol = detect_protocol(conn)

    Logger.debug("Protocol detected",
      protocol: protocol,
      path: conn.request_path,
      content_type: get_content_type(conn)
    )

    case protocol do
      :graphql -> GraphQLHandler.handle(conn)
      :grpc -> GRPCHandler.handle(conn)
      :http -> Gateway.handle_request(conn)
    end
  end

  # Detect protocol from request characteristics
  defp detect_protocol(conn) do
    cond do
      # GraphQL: POST to /graphql
      conn.method == "POST" and conn.request_path == "/graphql" ->
        :graphql

      # gRPC: application/grpc content-type
      is_grpc_request?(conn) ->
        :grpc

      # Default: HTTP/REST
      true ->
        :http
    end
  end

  # Check if request is gRPC
  defp is_grpc_request?(conn) do
    content_type = get_content_type(conn)
    content_type && String.starts_with?(content_type, "application/grpc")
  end

  # Get content-type header
  defp get_content_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [type | _] -> type
      [] -> nil
    end
  end
end
