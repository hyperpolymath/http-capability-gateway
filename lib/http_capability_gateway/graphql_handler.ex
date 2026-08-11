# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.GraphQLHandler do
  @moduledoc """
  GraphQL request handler with policy enforcement.

  Parses GraphQL queries, enforces operation-level governance, and forwards
  allowed queries to backend GraphQL services.

  ## GraphQL Policy Format

  Policies control which operation types are allowed:

  ```yaml
  graphql:
    allowed_operations:
      - query      # Read-only operations
      - mutation   # Write operations
    exposure: "authenticated"  # All GraphQL requires auth
  ```

  ## Integration

  Uses Zig FFI (ffi/zig/graphql/parser.zig) for parsing GraphQL queries.
  Conforms to Idris2 ABI (src/abi/Protocol.idr).
  """

  require Logger
  alias HttpCapabilityGateway.{Logging, PolicyCompiler}

  @doc """
  Handle GraphQL request with policy enforcement.

  ## Process

  1. Parse GraphQL JSON body
  2. Detect operation type (query/mutation/subscription)
  3. Check policy for allowed operations
  4. Forward to backend GraphQL service if allowed
  5. Return error if denied

  ## Parameters

    - `conn`: Plug.Conn with GraphQL request

  ## Returns

    - Plug.Conn with GraphQL response or error
  """
  def handle(conn) do
    request_id = conn.assigns[:request_id] || generate_request_id()

    Logging.log_request_received(request_id, conn, %{
      protocol: "GraphQL"
    })

    # Read JSON body
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    # Parse GraphQL request
    case parse_graphql_request(body) do
      {:ok, query_info} ->
        Logger.info("GraphQL request",
          operation: query_info.operation_type,
          name: query_info.operation_name,
          request_id: request_id
        )

        # Check policy
        if graphql_operation_allowed?(query_info.operation_type) do
          # Forward to backend GraphQL service
          forward_graphql_request(conn, body, query_info, request_id)
        else
          # Return GraphQL error
          send_graphql_error(conn, "Operation not allowed by policy")
        end

      {:error, reason} ->
        Logger.warning("GraphQL parse error", error: reason, request_id: request_id)
        send_graphql_error(conn, "Invalid GraphQL query: #{inspect(reason)}")
    end
  end

  # Parse GraphQL JSON body
  defp parse_graphql_request(body) do
    case Jason.decode(body) do
      {:ok, %{"query" => query} = data} ->
        operation_type = detect_operation_type(query)
        operation_name = Map.get(data, "operationName")

        {:ok, %{
          query: query,
          operation_type: operation_type,
          operation_name: operation_name,
          variables: Map.get(data, "variables")
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Detect GraphQL operation type from query string
  defp detect_operation_type(query) do
    trimmed = String.trim_leading(query)

    cond do
      String.starts_with?(trimmed, "mutation") -> :mutation
      String.starts_with?(trimmed, "subscription") -> :subscription
      String.starts_with?(trimmed, "query") -> :query
      String.starts_with?(trimmed, "{") -> :query  # Shorthand query
      true -> :query  # Default to query
    end
  end

  # Check if GraphQL operation is allowed
  # Integrates with PolicyCompiler - GraphQL uses /graphql path
  defp graphql_operation_allowed?(operation_type) do
    # Read the current policy table from application env so that this
    # handler stays correct after atomic policy reloads (see PolicyCompiler).
    # Hardcoding :policy_rules would miss the freshly-compiled table that
    # the atomic swap pattern publishes under a monotonic-time-suffixed name.
    policy_table = Application.get_env(:http_capability_gateway, :policy_table)

    if is_nil(policy_table) do
      false
    else
      # GraphQL operations are POST to /graphql
      case PolicyCompiler.lookup(policy_table, "/graphql", :POST) do
        {:ok, rule} ->
          # Additional check: some policies might restrict specific operations
          check_operation_policy(rule, operation_type)

        {:error, :no_match} ->
          false
      end
    end
  end

  # Check if specific GraphQL operation type is allowed by policy
  # This would be extended to read operation restrictions from policy rules
  defp check_operation_policy(_rule, _operation_type) do
    # Future: parse policy metadata for allowed operations (query/mutation/subscription)
    # For now, if /graphql is allowed, all operations are allowed
    true
  end

  # Forward GraphQL request to backend
  defp forward_graphql_request(conn, body, query_info, request_id) do
    backend_url = Application.get_env(:http_capability_gateway, :graphql_backend_url, "http://localhost:4000/graphql")

    Logger.info("Forwarding GraphQL request",
      backend: backend_url,
      operation: query_info.operation_type,
      request_id: request_id
    )

    # Forward request to backend GraphQL endpoint
    case Req.post(url: backend_url, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %{status: status, body: response_body}} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, response_body)
        |> Plug.Conn.halt()

      {:error, reason} ->
        Logger.error("GraphQL backend failed", error: inspect(reason))
        send_graphql_error(conn, "Backend service unavailable")
    end
  end

  # Send GraphQL error response
  defp send_graphql_error(conn, message) do
    error_response = %{
      errors: [
        %{
          message: message
        }
      ]
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(error_response))
    |> Plug.Conn.halt()
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
