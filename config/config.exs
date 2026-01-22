# SPDX-License-Identifier: PMPL-1.0-or-later
import Config

# HTTP Server configuration
config :http_capability_gateway,
  # HTTP port for gateway (default: 4000)
  port: String.to_integer(System.get_env("PORT") || "4000"),

  # Backend service URL (where allowed requests are forwarded)
  backend_url: System.get_env("BACKEND_URL") || "http://localhost:8080",

  # Policy file path (DSL v1 YAML)
  policy_path: System.get_env("POLICY_PATH") || "config/policy.yaml",

  # Enable/disable policy reload on file change (dev only)
  policy_hot_reload: false,

  # Trust level extraction
  # "header" - Extract from X-Trust-Level header
  # "mtls" - Extract from mTLS client certificate
  trust_level_source: System.get_env("TRUST_LEVEL_SOURCE") || "header",

  # Stealth mode profiles (loaded from policy, can be overridden)
  stealth_profiles: %{
    "limited" => %{
      "unauthenticated" => 405,
      "untrusted" => 404
    }
  }

# Logging configuration
config :logger, :console,
  format: {HttpCapabilityGateway.LogFormatter, :format},
  metadata: [:request_id, :service, :decision]

# Disable default logger formatting in favor of JSON
config :logger,
  backends: [:console],
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Telemetry configuration
# Metrics are defined in HttpCapabilityGateway.Application

# Import environment-specific config
import_config "#{config_env()}.exs"
