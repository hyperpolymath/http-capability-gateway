# SPDX-License-Identifier: MPL-2.0
import Config

# HTTP Server configuration
config :http_capability_gateway,
  # HTTP port for gateway (default: 4000)
  port: String.to_integer(System.get_env("PORT") || "4000"),

  # Backend service URL (optional)
  backend_url: System.get_env("BACKEND_URL"),

  # Policy file path (DSL v1 YAML)
  policy_path: System.get_env("POLICY_PATH") || "config/policy.yaml",

  # Header used for trust level logging (optional)
  trust_level_header: System.get_env("TRUST_LEVEL_HEADER") || "x-trust-level",

  # Logging level default (can be overridden per-env)
  log_level: :info

# Logging configuration
config :logger, :console,
  format: {HttpCapabilityGateway.LogFormatter, :format},
  metadata: [:request_id, :service, :decision]

# Disable default logger formatting in favor of JSON
config :logger,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Telemetry configuration
# Metrics are defined in HttpCapabilityGateway.Application

# Import environment-specific config
import_config "#{config_env()}.exs"
