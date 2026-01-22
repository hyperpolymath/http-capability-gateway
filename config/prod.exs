# SPDX-License-Identifier: PMPL-1.0-or-later
import Config

# Production-specific configuration

# Require environment variables in production
config :http_capability_gateway,
  # Backend URL MUST be set in production
  backend_url: System.fetch_env!("BACKEND_URL"),

  # Policy path MUST be set in production
  policy_path: System.fetch_env!("POLICY_PATH"),

  # Disable hot reload in production
  policy_hot_reload: false,

  # Use mTLS for trust level extraction in production
  trust_level_source: System.get_env("TRUST_LEVEL_SOURCE") || "mtls"

# Production logging at info level
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Error reporting configuration (add Sentry, Rollbar, etc. here)
# config :sentry,
#   dsn: System.fetch_env!("SENTRY_DSN"),
#   environment_name: :prod,
#   enable_source_code_context: true,
#   root_source_code_paths: [File.cwd!()]
