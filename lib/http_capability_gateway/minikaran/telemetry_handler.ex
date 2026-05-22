# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.Minikaran.TelemetryHandler do
  @moduledoc """
  Telemetry handler that feeds traffic observations into Minikaran.

  Hooks into existing telemetry events emitted by the gateway's request
  pipeline and translates them into Minikaran observation records. All
  calls to `Minikaran.record/1` are asynchronous (GenServer.cast) so
  this handler never blocks the request path.

  ## Events Handled

    - `[:http_capability_gateway, :access_decision]` -- emitted by
      Gateway.log_decision/7 after every access decision. Captures the
      request path, trust level, verb, and decision duration.

    - `[:http_capability_gateway, :request, :completed]` -- emitted by
      Logging.log_request_completed/4 after the full request lifecycle
      including backend proxying. Captures the final status code and
      total latency.

    - `[:http_capability_gateway, :rate_limit, :exceeded]` -- emitted by
      RateLimiter.call/2 when a client exceeds their rate limit bucket.
      Records this as a 429 response for error tracking.

  ## Attachment

  Call `attach/0` during application startup (typically in
  `Application.start/2`) AFTER the Minikaran GenServer is started.
  The handler is idempotent -- calling attach/0 multiple times is safe
  because `:telemetry.attach/4` replaces handlers with the same ID.

  ## Design Notes

  We use a dedicated handler module (rather than anonymous functions)
  because:

    1. Named modules survive hot code reloads (anonymous funs reference
       a specific module version and detach on upgrade).
    2. The handler function is a single dispatch point, making it easy
       to add new events or transform data.
    3. Testing is straightforward -- call the handler function directly.
  """

  require Logger

  alias HttpCapabilityGateway.Minikaran

  # Handler IDs for telemetry attachment. Must be unique across the
  # application. We use a consistent prefix for easy identification
  # in :telemetry.list_handlers/1 output.
  @access_decision_handler_id "minikaran-access-decision"
  @request_completed_handler_id "minikaran-request-completed"
  @rate_limit_handler_id "minikaran-rate-limit-exceeded"

  @doc """
  Attaches all Minikaran telemetry handlers.

  This function is idempotent -- safe to call multiple times. Each call
  detaches any existing handler with the same ID before re-attaching,
  which is the standard pattern for telemetry handler management.

  ## Events Attached

    - `[:http_capability_gateway, :access_decision]`
    - `[:http_capability_gateway, :request, :completed]`
    - `[:http_capability_gateway, :rate_limit, :exceeded]`

  ## Examples

      # In Application.start/2:
      HttpCapabilityGateway.Minikaran.TelemetryHandler.attach()
  """
  @spec attach() :: :ok
  def attach do
    # Detach any existing handlers first (idempotent re-attachment).
    detach()

    :telemetry.attach(
      @access_decision_handler_id,
      [:http_capability_gateway, :access_decision],
      &handle_event/4,
      %{}
    )

    :telemetry.attach(
      @request_completed_handler_id,
      [:http_capability_gateway, :request, :completed],
      &handle_event/4,
      %{}
    )

    :telemetry.attach(
      @rate_limit_handler_id,
      [:http_capability_gateway, :rate_limit, :exceeded],
      &handle_event/4,
      %{}
    )

    Logger.info("Minikaran telemetry handlers attached",
      handlers: [
        @access_decision_handler_id,
        @request_completed_handler_id,
        @rate_limit_handler_id
      ]
    )

    :ok
  end

  @doc """
  Detaches all Minikaran telemetry handlers.

  Safe to call even if handlers are not currently attached (telemetry
  silently ignores detach requests for non-existent handler IDs).

  ## Examples

      HttpCapabilityGateway.Minikaran.TelemetryHandler.detach()
  """
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@access_decision_handler_id)
    :telemetry.detach(@request_completed_handler_id)
    :telemetry.detach(@rate_limit_handler_id)
    :ok
  end

  @doc """
  Telemetry event handler callback.

  Dispatches on the event name to extract relevant fields and forward
  them to `Minikaran.record/1` as an observation map.

  ## Parameters

    - `event` -- telemetry event name (list of atoms)
    - `measurements` -- numeric measurements map
    - `metadata` -- event context map
    - `_config` -- handler configuration (unused)

  This function is called synchronously within the telemetry dispatch
  pipeline, so it must be fast. The actual work (recording the
  observation) is delegated to the Minikaran GenServer via cast.
  """
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(
        [:http_capability_gateway, :access_decision],
        measurements,
        metadata,
        _config
      ) do
    # Extract fields from the access decision telemetry event.
    #
    # The gateway emits this in Gateway.log_decision/7 with:
    #   measurements: %{duration: duration_us}
    #   metadata: %{decision: atom, verb: atom, trust_level: atom}
    #
    # We need the path from the metadata, but the gateway's telemetry
    # event does not include it. We reconstruct what we can:
    # the path is not available here, so we use the verb as a proxy
    # for path-level tracking. The request_completed event has the
    # status code for error tracking.
    trust_level = Map.get(metadata, :trust_level, :untrusted)
    duration = Map.get(measurements, :duration, 0)
    decision = Map.get(metadata, :decision, :unknown)
    verb = Map.get(metadata, :verb, :GET)

    # Map the decision to a pseudo-status for error tracking.
    # :deny and :no_match map to 403/404 which are client errors.
    status =
      case decision do
        :allow -> 200
        :deny -> 403
        :no_match -> 404
        :error -> 500
        _ -> 0
      end

    observation = %{
      path: "/#{verb}",
      trust_level: trust_level,
      latency_us: duration,
      status: status,
      client_ip: Map.get(metadata, :client, "unknown"),
      timestamp: System.system_time(:second)
    }

    Minikaran.record(observation)
    :ok
  end

  def handle_event(
        [:http_capability_gateway, :request, :completed],
        measurements,
        metadata,
        _config
      ) do
    # Extract fields from the request completed telemetry event.
    #
    # Emitted by Logging.log_request_completed/4 with:
    #   measurements: %{count: 1, duration: total_duration_us}
    #   metadata: %{status: http_status_code}
    status = Map.get(metadata, :status, 0)
    duration = Map.get(measurements, :duration, 0)

    # The request completed event does not carry path or trust level,
    # but it has the authoritative status code and total latency.
    # We record it with a generic path marker so the latency samples
    # and error counts are captured in the window bucket.
    observation = %{
      path: "/_completed",
      trust_level: Map.get(metadata, :trust_level, :unknown),
      latency_us: duration,
      status: status,
      client_ip: Map.get(metadata, :client, "unknown"),
      timestamp: System.system_time(:second)
    }

    Minikaran.record(observation)
    :ok
  end

  def handle_event(
        [:http_capability_gateway, :rate_limit, :exceeded],
        _measurements,
        metadata,
        _config
      ) do
    # Rate limit exceeded events indicate a 429 response.
    # These are always error responses and contribute to the error rate.
    trust_level = Map.get(metadata, :trust_level, :untrusted)
    client = Map.get(metadata, :client, "unknown")

    observation = %{
      path: "/_rate_limited",
      trust_level: trust_level,
      latency_us: 0,
      status: 429,
      client_ip: client,
      timestamp: System.system_time(:second)
    }

    Minikaran.record(observation)
    :ok
  end

  # Catch-all for unexpected events (defensive programming).
  # Telemetry should never route unknown events here, but if handler
  # configuration changes, this prevents a crash.
  def handle_event(event, _measurements, _metadata, _config) do
    Logger.debug("Minikaran telemetry handler received unexpected event",
      event: inspect(event)
    )

    :ok
  end
end
