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
      ├── HttpCapabilityGateway.VeriSimDB  -- Async audit log persistence (capgw:audit)
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
  alias HttpCapabilityGateway.{CircuitBreaker, Minikaran, VeriSimDB}

  @impl true
  def start(_type, _args) do
    # Load and compile policy before starting HTTP server
    case load_and_compile_policy() do
      {:ok, policy_table} ->
        # Store policy table in application environment
        Application.put_env(:http_capability_gateway, :policy_table, policy_table)

        # Start HTTP server and other children
        port = Application.get_env(:http_capability_gateway, :port, 4000)

        # Build the listener child specs. When trust_level_source is "mtls",
        # a valid TLS listener is mandatory; http_listeners/1 returns
        # {:error, reason} and the application refuses to start (fail-closed)
        # rather than silently falling back to the forgeable header path.
        with {:ok, listeners} <- http_listeners(port) do
          children =
            [
              # Prometheus metrics exporter
              {TelemetryMetricsPrometheus.Core, metrics: telemetry_metrics()},

              # VeriSimDB async audit log client -- started early so that the
              # ETS buffer table (:capgw_verisimdb_buffer) exists before the
              # first request arrives. Writes are fire-and-forget casts.
              {VeriSimDB, []},

              # Circuit breaker FSM -- started BEFORE Minikaran and the HTTP
              # server so its ETS table (:gateway_circuit_breaker) exists before
              # the first request arrives. The gateway calls allow?/1 on every
              # request, so the table must be available from startup.
              {CircuitBreaker, []},

              # Minikaran traffic anomaly detector -- started BEFORE the HTTP
              # server so its telemetry handlers are attached before the first
              # request arrives. This ensures zero observation loss at startup.
              {Minikaran, name: Minikaran}
            ] ++ listeners

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
        else
          {:error, reason} ->
            Logger.error(
              "mTLS listener configuration invalid; refusing to start (fail-closed)",
              error: inspect(reason)
            )

            {:error, {:listener_config_invalid, reason}}
        end

      {:error, reason} ->
        Logger.error("Failed to load policy, cannot start gateway", error: reason)
        {:error, {:policy_load_failed, reason}}
    end
  end

  # Build the HTTP/HTTPS listener child specs.
  #
  # The plaintext HTTP listener is always started: it serves the development
  # header-trust path and unauthenticated public routes. The mTLS HTTPS
  # listener is started in addition whenever TLS material is configured.
  #
  # Trust-level-source contract (the Phase B security invariant):
  #
  #   * "header" (default) -- HTTP listener only. Header trust is for
  #     development and for public routes behind a trusted edge.
  #
  #   * "mtls" -- the HTTPS listener with `verify: :verify_peer` and
  #     `fail_if_no_peer_cert: true` is MANDATORY. If the TLS material is
  #     missing or unreadable we return {:error, _} so the application
  #     refuses to start. We never silently downgrade an mTLS deployment to
  #     the forgeable header path.
  defp http_listeners(port) do
    http = {Plug.Cowboy, scheme: :http, plug: HttpCapabilityGateway.Gateway, options: [port: port]}

    trust_source = Application.get_env(:http_capability_gateway, :trust_level_source, "header")

    case tls_socket_opts() do
      {:ok, tls_opts} ->
        tls_port = Application.get_env(:http_capability_gateway, :tls_port, 4443)

        https =
          {Plug.Cowboy,
           scheme: :https,
           plug: HttpCapabilityGateway.Gateway,
           options: [port: tls_port] ++ tls_opts}

        Logger.info("mTLS listener enabled", tls_port: tls_port, verify: :verify_peer)
        {:ok, [http, https]}

      :no_tls when trust_source == "mtls" ->
        {:error,
         "trust_level_source is \"mtls\" but TLS material is not configured. " <>
           "Set MTLS_CA_CERT_PATH, GATEWAY_CERT_PATH and GATEWAY_KEY_PATH."}

      :no_tls ->
        {:ok, [http]}

      {:error, _reason} = err when trust_source == "mtls" ->
        err

      {:error, reason} ->
        Logger.warning(
          "TLS material configured but unreadable; starting HTTP listener only",
          error: inspect(reason)
        )

        {:ok, [http]}
    end
  end

  # Resolve the Cowboy TLS socket options from the environment.
  #
  # Returns:
  #   * {:ok, opts}      -- all three paths set and the files exist
  #   * :no_tls          -- no TLS material configured at all
  #   * {:error, reason} -- partially configured or files missing
  #
  # `verify: :verify_peer` + `fail_if_no_peer_cert: true` makes the TLS
  # handshake itself reject any client that does not present a certificate
  # chaining to `cacertfile`. A request that reaches the Plug pipeline over
  # this listener has therefore already had its client certificate chain
  # verified by the transport (see Gateway.is_cert_verified/1).
  defp tls_socket_opts do
    ca = Application.get_env(:http_capability_gateway, :mtls_ca_cert_path)
    cert = Application.get_env(:http_capability_gateway, :gateway_cert_path)
    key = Application.get_env(:http_capability_gateway, :gateway_key_path)

    cond do
      is_nil(ca) and is_nil(cert) and is_nil(key) ->
        :no_tls

      is_nil(ca) or is_nil(cert) or is_nil(key) ->
        {:error,
         "incomplete TLS configuration: MTLS_CA_CERT_PATH, GATEWAY_CERT_PATH " <>
           "and GATEWAY_KEY_PATH must all be set together"}

      true ->
        missing = Enum.reject([ca, cert, key], &File.exists?/1)

        if missing == [] do
          {:ok,
           [
             cacertfile: ca,
             certfile: cert,
             keyfile: key,
             verify: :verify_peer,
             fail_if_no_peer_cert: true
           ]}
        else
          {:error, "TLS files not found: #{Enum.join(missing, ", ")}"}
        end
    end
  end

  # Load policy from file or BoJ catalog, validate, and compile.
  # Resolution order:
  #   1. BOJ_CARTRIDGES_ROOT env var  — catalog mode (auto-policy from cartridge.json)
  #   2. :boj_cartridges_root config  — catalog mode
  #   3. :policy_path config          — static YAML file
  #   4. nil                          — skip (test mode)
  defp load_and_compile_policy do
    catalog_root =
      System.get_env("BOJ_CARTRIDGES_ROOT") ||
        Application.get_env(:http_capability_gateway, :boj_cartridges_root)

    policy_path = Application.get_env(:http_capability_gateway, :policy_path)

    cond do
      is_binary(catalog_root) ->
        Logger.info("Catalog mode: building policy from BoJ cartridges", root: catalog_root)
        compile_from_loader(fn -> PolicyLoader.load_from_boj_catalog(catalog_root) end, catalog_root)

      is_binary(policy_path) ->
        Logger.info("Static mode: loading policy from file", path: policy_path)
        compile_from_loader(fn -> PolicyLoader.load_from_file(policy_path) end, policy_path)

      true ->
        Logger.info("Skipping policy load (no policy_path or BOJ_CARTRIDGES_ROOT configured)")
        {:ok, :ets.new(:policy_rules, [:set, :public, :named_table])}
    end
  end

  defp compile_from_loader(loader_fn, source) do
    with {:ok, policy} <- loader_fn.(),
         :ok <- PolicyValidator.validate(policy),
         {:ok, table} <- PolicyCompiler.compile(policy) do
      configure_stealth(policy)

      stats = PolicyCompiler.stats(table)
      service_name = get_in(policy, ["service", "name"]) || "unknown"

      Logging.log_policy_load(source, :ok, %{
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
        Logging.log_policy_load(source, error, %{})
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
