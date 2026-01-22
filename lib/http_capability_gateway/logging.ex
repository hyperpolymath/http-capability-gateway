# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.Logging do
  @moduledoc """
  Structured logging and observability for HTTP capability gateway.

  Provides comprehensive audit trails for policy enforcement decisions,
  request processing, and system health. All logs are emitted in JSON format
  with consistent structure for easy parsing and analysis.

  ## Log Events

  - `gateway.request.received` - Request enters gateway
  - `gateway.policy.lookup` - Policy rule lookup
  - `gateway.access.decision` - Allow/deny decision with reasoning
  - `gateway.backend.forward` - Request forwarded to backend
  - `gateway.backend.response` - Backend response received
  - `gateway.request.completed` - Request processing finished
  - `gateway.error` - Error during processing

  ## Log Fields

  All log events include:
  - `timestamp` - ISO 8601 timestamp
  - `event` - Event type
  - `request_id` - Unique request identifier
  - `duration_us` - Processing duration in microseconds (where applicable)

  ## Telemetry Integration

  Emits telemetry events for:
  - Request duration histograms
  - Decision type counters (allow/deny/no_match)
  - Backend response times
  - Error rates
  """

  require Logger

  @doc """
  Log request received event.

  ## Parameters

    - `request_id` - Unique request identifier
    - `conn` - Plug.Conn struct with request details
    - `metadata` - Optional additional metadata map
  """
  def log_request_received(request_id, conn, metadata \\ %{}) do
    log_data = %{
      event: "gateway.request.received",
      request_id: request_id,
      method: conn.method,
      path: conn.request_path,
      query_string: conn.query_string,
      remote_ip: format_ip(conn.remote_ip),
      user_agent: get_header(conn, "user-agent"),
      trust_level: get_header(conn, "x-trust-level") || "untrusted"
    }
    |> Map.merge(metadata)

    Logger.info("Request received", log_data)

    :telemetry.execute(
      [:http_capability_gateway, :request, :received],
      %{count: 1},
      log_data
    )
  end

  @doc """
  Log policy lookup event.

  ## Parameters

    - `request_id` - Unique request identifier
    - `path` - Request path
    - `verb` - HTTP verb atom
    - `result` - Lookup result: {:ok, rule} or {:error, :no_match}
    - `duration_us` - Lookup duration in microseconds
  """
  def log_policy_lookup(request_id, path, verb, result, duration_us) do
    log_data = %{
      event: "gateway.policy.lookup",
      request_id: request_id,
      path: path,
      verb: verb,
      duration_us: duration_us
    }

    log_data =
      case result do
        {:ok, rule} ->
          Map.merge(log_data, %{
            match: "found",
            exposure: rule.exposure,
            stealth_profile: rule.stealth_profile,
            pattern: rule.path_pattern
          })

        {:error, :no_match} ->
          Map.put(log_data, :match, "not_found")
      end

    Logger.info("Policy lookup", log_data)

    :telemetry.execute(
      [:http_capability_gateway, :policy, :lookup],
      %{duration: duration_us},
      %{match: elem(result, 0)}
    )
  end

  @doc """
  Log access decision event.

  ## Parameters

    - `request_id` - Unique request identifier
    - `decision` - Decision atom: :allow, :deny, :no_match, :error
    - `metadata` - Map with decision context:
      - `path` - Request path
      - `verb` - HTTP verb
      - `trust_level` - Client trust level
      - `exposure` - Required exposure (if rule found)
      - `reason` - Denial/error reason (if applicable)
      - `duration_us` - Decision duration
  """
  def log_access_decision(request_id, decision, metadata) do
    log_data =
      %{
        event: "gateway.access.decision",
        request_id: request_id,
        decision: decision
      }
      |> Map.merge(metadata)

    # Log at appropriate level
    case decision do
      :allow ->
        Logger.info("Access allowed", log_data)

      :deny ->
        Logger.warning("Access denied", log_data)

      :no_match ->
        Logger.warning("No policy match", log_data)

      :error ->
        Logger.error("Decision error", log_data)
    end

    # Emit telemetry
    :telemetry.execute(
      [:http_capability_gateway, :access, :decision],
      %{
        count: 1,
        duration: Map.get(metadata, :duration_us, 0)
      },
      %{
        decision: decision,
        verb: Map.get(metadata, :verb),
        trust_level: Map.get(metadata, :trust_level)
      }
    )
  end

  @doc """
  Log backend forward event.

  ## Parameters

    - `request_id` - Unique request identifier
    - `backend_url` - Full backend URL
    - `method` - HTTP method
    - `metadata` - Optional additional metadata
  """
  def log_backend_forward(request_id, backend_url, method, metadata \\ %{}) do
    log_data =
      %{
        event: "gateway.backend.forward",
        request_id: request_id,
        backend_url: backend_url,
        method: method
      }
      |> Map.merge(metadata)

    Logger.info("Forwarding to backend", log_data)

    :telemetry.execute(
      [:http_capability_gateway, :backend, :forward],
      %{count: 1},
      %{method: method}
    )
  end

  @doc """
  Log backend response event.

  ## Parameters

    - `request_id` - Unique request identifier
    - `status` - HTTP status code
    - `duration_us` - Backend response time in microseconds
    - `metadata` - Optional additional metadata
  """
  def log_backend_response(request_id, status, duration_us, metadata \\ %{}) do
    log_data =
      %{
        event: "gateway.backend.response",
        request_id: request_id,
        status: status,
        duration_us: duration_us
      }
      |> Map.merge(metadata)

    Logger.info("Backend response", log_data)

    :telemetry.execute(
      [:http_capability_gateway, :backend, :response],
      %{
        count: 1,
        duration: duration_us
      },
      %{status: status}
    )
  end

  @doc """
  Log request completed event.

  ## Parameters

    - `request_id` - Unique request identifier
    - `status` - Final HTTP status code sent to client
    - `total_duration_us` - Total request processing time
    - `metadata` - Optional additional metadata with phase timings
  """
  def log_request_completed(request_id, status, total_duration_us, metadata \\ %{}) do
    log_data =
      %{
        event: "gateway.request.completed",
        request_id: request_id,
        status: status,
        total_duration_us: total_duration_us
      }
      |> Map.merge(metadata)

    Logger.info("Request completed", log_data)

    :telemetry.execute(
      [:http_capability_gateway, :request, :completed],
      %{
        count: 1,
        duration: total_duration_us
      },
      %{status: status}
    )
  end

  @doc """
  Log error event.

  ## Parameters

    - `request_id` - Unique request identifier
    - `error_type` - Error classification atom
    - `error` - Error term or message
    - `metadata` - Optional additional context
  """
  def log_error(request_id, error_type, error, metadata \\ %{}) do
    log_data =
      %{
        event: "gateway.error",
        request_id: request_id,
        error_type: error_type,
        error: inspect(error)
      }
      |> Map.merge(metadata)

    Logger.error("Gateway error", log_data)

    :telemetry.execute(
      [:http_capability_gateway, :error],
      %{count: 1},
      %{error_type: error_type}
    )
  end

  @doc """
  Log policy load event.

  ## Parameters

    - `policy_path` - Path to policy file
    - `result` - Load result: :ok or {:error, reason}
    - `metadata` - Optional metadata (service name, rules count, etc.)
  """
  def log_policy_load(policy_path, result, metadata \\ %{}) do
    log_data =
      %{
        event: "gateway.policy.load",
        policy_path: policy_path,
        result: elem(result, 0)
      }
      |> Map.merge(metadata)

    case result do
      :ok ->
        Logger.info("Policy loaded successfully", log_data)

      {:error, reason} ->
        Logger.error("Policy load failed", Map.put(log_data, :reason, inspect(reason)))
    end

    :telemetry.execute(
      [:http_capability_gateway, :policy, :load],
      %{count: 1},
      %{result: elem(result, 0)}
    )
  end

  @doc """
  Log health check event.

  ## Parameters

    - `component` - Component being checked (e.g., "backend", "policy")
    - `status` - Health status: :healthy or :unhealthy
    - `metadata` - Optional check details
  """
  def log_health_check(component, status, metadata \\ %{}) do
    log_data =
      %{
        event: "gateway.health.check",
        component: component,
        status: status
      }
      |> Map.merge(metadata)

    case status do
      :healthy ->
        Logger.info("Health check passed", log_data)

      :unhealthy ->
        Logger.warning("Health check failed", log_data)
    end

    :telemetry.execute(
      [:http_capability_gateway, :health, :check],
      %{count: 1},
      %{component: component, status: status}
    )
  end

  # Helper: Format IP address tuple to string
  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip({a, b, c, d, e, f, g, h}) do
    "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  end

  defp format_ip(other), do: inspect(other)

  # Helper: Get header value from conn
  defp get_header(conn, header_name) do
    case Plug.Conn.get_req_header(conn, header_name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
