# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.Application do
  @moduledoc """
  OTP Application for HTTP Capability Gateway.

  Loads policy on startup and starts HTTP server.
  """

  use Application
  require Logger

  alias HttpCapabilityGateway.{PolicyLoader, PolicyValidator, PolicyCompiler, Logging}

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
          # Telemetry supervisor
          {Telemetry.Metrics, metrics: telemetry_metrics()},

          # HTTP server with our Gateway router
          {Plug.Cowboy, scheme: :http, plug: HttpCapabilityGateway.Gateway, options: [port: port]}
        ]

        opts = [strategy: :one_for_one, name: HttpCapabilityGateway.Supervisor]

        Logger.info("Starting HTTP Capability Gateway", port: port)

        Supervisor.start_link(children, opts)

      {:error, reason} ->
        Logger.error("Failed to load policy, cannot start gateway", error: reason)
        {:error, {:policy_load_failed, reason}}
    end
  end

  # Load policy from file, validate, and compile
  defp load_and_compile_policy do
    policy_path = Application.get_env(:http_capability_gateway, :policy_path)

    Logger.info("Loading policy", path: policy_path)

    with {:ok, policy} <- PolicyLoader.load_policy(policy_path),
         :ok <- PolicyValidator.validate(policy),
         {:ok, table} <- PolicyCompiler.compile(policy) do
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
      Telemetry.Metrics.counter("http_capability_gateway.error.count", tags: [:error_type])
    ]
  end
end
