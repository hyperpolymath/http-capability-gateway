# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.Application do
  @moduledoc """
  OTP Application for HTTP Capability Gateway.

  Loads policy on startup, starts the HTTP server, and initialises the
  Minikaran traffic anomaly detector with its telemetry handlers.

  ## Supervision Tree

      HttpCapabilityGateway.Supervisor (one_for_one)
      ├── TelemetryMetricsPrometheus.Core  -- Prometheus metrics exporter
      ├── HttpCapabilityGateway.CircuitBreaker -- Backend circuit breaker FSM
      ├── HttpCapabilityGateway.Minikaran  -- Traffic shape anomaly detector
      └── Plug.Cowboy (Gateway)            -- HTTP server

  CircuitBreaker and Minikaran are started BEFORE the HTTP server so that
  ETS tables and telemetry handlers are ready before the first request
  arrives. This guarantees no observations are lost during startup.
  """

  use Application
  require Logger

  alias HttpCapabilityGateway.{PolicyLoader, PolicyValidator, PolicyCompiler, Logging}
  alias HttpCapabilityGateway.{CircuitBreaker, Minikaran}

  @impl true
  def start(_type, _args) do
    # Load and compile policy before starting HTTP server
    case load_and_compile_policy() do
      {:ok, policy_table} ->
        # Store policy table in application environment
        Application.put_env(:http_capability_gateway, :policy_table, policy_table)

        # Start HTTP server and other children
        port = Application.get_env(:http_capability_gateway, :port, 4000)

        children = [
          # Prometheus metrics exporter
          {TelemetryMetricsPrometheus.Core, metrics: telemetry_metrics()},

          # Circuit breaker FSM -- started BEFORE Minikaran and the HTTP
          # server so its ETS table (:gateway_circuit_breaker) exists before
          # the first request arrives. The gateway calls allow?/1 on every
          # request, so the table must be available from startup.
          {CircuitBreaker, []},

          # Minikaran traffic anomaly detector -- started BEFORE the HTTP
          # server so its telemetry handlers are attached before the first
          # request arrives. This ensures zero observation loss at startup.
          {Minikaran, name: Minikaran},

          # HTTP server with our Gateway router
          {Plug.Cowboy, scheme: :http, plug: HttpCapabilityGateway.Gateway, options: [port: port]}
        ]

        opts = [strategy: :one_for_one, name: HttpCapabilityGateway.Supervisor]

        Logger.info("Starting HTTP Capability Gateway", port: port)

        # Attach Minikaran telemetry handlers after supervision tree starts.
        # We use a callback to ensure handlers are attached only after
        # the Minikaran GenServer is alive and ready to receive casts.
        result = Supervisor.start_link(children, opts)

        case result do
          {:ok, _pid} ->
            Minikaran.TelemetryHandler.attach()
            result

          error ->
            error
        end

      {:error, reason} ->
        Logger.error("Failed to load policy, cannot start gateway", error: reason)
        {:error, {:policy_load_failed, reason}}
    end
  end

  # Load policy from file, validate, and compile
  defp load_and_compile_policy do
    policy_path = Application.get_env(:http_capability_gateway, :policy_path)

    # Skip policy loading if path is nil (useful for testing)
    if is_nil(policy_path) do
      Logger.info("Skipping policy load (policy_path is nil)")
      {:ok, :ets.new(:policy_rules, [:set, :public, :named_table])}
    else
      Logger.info("Loading policy", path: policy_path)

      with {:ok, policy} <- PolicyLoader.load_from_file(policy_path),
         :ok <- PolicyValidator.validate(policy),
         {:ok, table} <- PolicyCompiler.compile(policy) do
        # Configure stealth from DSL v1 policy
        configure_stealth(policy)

        # Log policy stats
        stats = PolicyCompiler.stats(table)
        service_name = get_in(policy, ["service", "name"]) || "unknown"

        Logging.log_policy_load(policy_path, :ok, %{
          service: service_name,
          total_rules: stats.total_rules,
          global_rules: stats.global_rules,
          route_rules: stats.route_rules,
          verbs: Enum.map(stats.verbs, &to_string/1)
        })

        Logger.info("Policy compilation complete",
          service: service_name,
          rules: stats.total_rules
        )

        {:ok, table}
      else
        {:error, _reason} = error ->
          Logging.log_policy_load(policy_path, error, %{})
          error
      end
    end
  end

  # Define telemetry metrics
  defp telemetry_metrics do
    [
      # Request metrics
      Telemetry.Metrics.last_value("http_capability_gateway.request.received.count"),
      Telemetry.Metrics.counter("http_capability_gateway.request.completed.count"),
      Telemetry.Metrics.distribution("http_capability_gateway.request.completed.duration",
        unit: {:native, :microsecond},
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 30_000]]
      ),

      # Policy lookup metrics
      Telemetry.Metrics.distribution("http_capability_gateway.policy.lookup.duration",
        unit: {:native, :microsecond},
        reporter_options: [buckets: [10, 50, 100, 500, 1_000]]
      ),

      # Access decision metrics
      Telemetry.Metrics.counter("http_capability_gateway.access.decision.count",
        tags: [:decision, :verb, :trust_level]
      ),

      # Backend metrics
      Telemetry.Metrics.counter("http_capability_gateway.backend.forward.count"),
      Telemetry.Metrics.distribution("http_capability_gateway.backend.response.duration",
        unit: {:native, :microsecond},
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 30_000, 60_000]]
      ),

      # Error metrics
      Telemetry.Metrics.counter("http_capability_gateway.error.count", tags: [:error_type]),

      # Minikaran anomaly metrics -- counts anomalies by type for Prometheus
      # dashboards and alerting. Each anomaly detection cycle emits one event
      # per detected anomaly with a :type tag.
      Telemetry.Metrics.counter("http_capability_gateway.minikaran.anomaly.count",
        tags: [:type]
      )
    ]
  end

  # Configure stealth profiles from DSL v1 policy
  defp configure_stealth(policy) do
    case get_in(policy, ["stealth", "enabled"]) do
      true ->
        status_code = get_in(policy, ["stealth", "status_code"]) || 404
        # Store stealth profile for Gateway to use
        stealth_profiles = %{
          "default" => %{
            "unauthenticated" => status_code,
            "authenticated" => status_code,
            "untrusted" => status_code
          }
        }
        Application.put_env(:http_capability_gateway, :stealth_profiles, stealth_profiles)
        Logger.info("Stealth mode enabled", status_code: status_code)

      _ ->
        Application.put_env(:http_capability_gateway, :stealth_profiles, %{})
        Logger.info("Stealth mode disabled")
    end
  end
end
