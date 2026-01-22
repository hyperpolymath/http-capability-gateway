# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.Proxy do
  @moduledoc """
  HTTP Proxy for forwarding allowed requests to backend services.

  Forwards requests that pass policy enforcement to configured backend URLs.
  Handles request transformation, response streaming, and error handling.

  ## Features

  - Method preservation (GET, POST, PUT, DELETE, etc.)
  - Header forwarding (with filtering)
  - Request body streaming
  - Response body streaming
  - Timeout handling
  - Connection pooling (via Req)

  ## Configuration

  Backend URL is configured in application environment:

      config :http_capability_gateway,
        backend_url: "http://localhost:8080"

  ## Headers

  - Forwards most headers from client to backend
  - Filters out hop-by-hop headers (Connection, Keep-Alive, etc.)
  - Adds X-Forwarded-* headers for provenance
  - Preserves Authorization headers
  """

  require Logger

  @hop_by_hop_headers [
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade"
  ]

  @doc """
  Forwards an allowed request to the backend service.

  ## Parameters

    - `conn`: Plug.Conn struct with original request
    - `rule`: CompiledRule that allowed this request

  ## Returns

    - Updated Plug.Conn with backend response
  """
  def forward(conn, rule) do
    backend_url = get_backend_url()
    target_url = build_target_url(backend_url, conn.request_path, conn.query_string)

    Logger.info("Forwarding request",
      target: target_url,
      method: conn.method,
      rule_exposure: rule.exposure
    )

    # Read request body if present
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    # Build headers for backend request
    headers = build_backend_headers(conn)

    # Make backend request using Req
    case make_backend_request(conn.method, target_url, headers, body) do
      {:ok, response} ->
        # Forward backend response to client
        send_backend_response(conn, response)

      {:error, reason} ->
        # Backend request failed
        Logger.error("Backend request failed", error: inspect(reason))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(502, Jason.encode!(%{
          error: "Bad Gateway",
          message: "Backend service unavailable"
        }))
    end
  end

  # Get backend URL from configuration
  defp get_backend_url do
    Application.get_env(:http_capability_gateway, :backend_url, "http://localhost:8080")
  end

  # Build full target URL with path and query string
  defp build_target_url(base_url, path, query_string) do
    base_url = String.trim_trailing(base_url, "/")

    if query_string == "" do
      "#{base_url}#{path}"
    else
      "#{base_url}#{path}?#{query_string}"
    end
  end

  # Build headers for backend request
  defp build_backend_headers(conn) do
    conn.req_headers
    |> filter_hop_by_hop_headers()
    |> add_forwarded_headers(conn)
    |> Enum.into(%{})
  end

  # Filter out hop-by-hop headers that shouldn't be forwarded
  defp filter_hop_by_hop_headers(headers) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(name) in @hop_by_hop_headers
    end)
  end

  # Add X-Forwarded-* headers for request provenance
  defp add_forwarded_headers(headers, conn) do
    remote_ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    headers ++
      [
        {"x-forwarded-for", remote_ip},
        {"x-forwarded-proto", conn.scheme |> to_string()},
        {"x-forwarded-host", conn.host},
        {"x-gateway", "http-capability-gateway"}
      ]
  end

  # Make HTTP request to backend using Req
  defp make_backend_request(method, url, headers, body) do
    method_atom = method |> String.downcase() |> String.to_atom()

    options = [
      method: method_atom,
      url: url,
      headers: headers,
      body: body,
      receive_timeout: 30_000,  # 30 second timeout
      retry: false  # Don't retry - let caller handle failures
    ]

    case Req.request(options) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Send backend response to client
  defp send_backend_response(conn, backend_response) do
    # Set response status
    conn = Plug.Conn.put_status(conn, backend_response.status)

    # Forward response headers (filter hop-by-hop)
    conn =
      Enum.reduce(backend_response.headers, conn, fn {name, value}, acc ->
        if String.downcase(name) not in @hop_by_hop_headers do
          Plug.Conn.put_resp_header(acc, String.downcase(name), value)
        else
          acc
        end
      end)

    # Send response body
    Plug.Conn.send_resp(conn, conn.status, backend_response.body)
  end

  @doc """
  Health check for backend service.

  ## Parameters

    - `opts`: Optional keyword list
      - `:url` - Override backend URL for health check
      - `:timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

    - `:ok` - Backend is healthy
    - `{:error, reason}` - Backend is unhealthy
  """
  def health_check(opts \\ []) do
    url = Keyword.get(opts, :url) || get_backend_url()
    timeout = Keyword.get(opts, :timeout, 5_000)

    case Req.get(url: "#{url}/health", receive_timeout: timeout) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, "Unhealthy status: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
