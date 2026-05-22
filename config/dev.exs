# SPDX-License-Identifier: MPL-2.0
import Config

# Development-specific configuration

# Enable code reloading for development
config :http_capability_gateway,
  # Use local backend for testing
  backend_url: System.get_env("BACKEND_URL") || "http://localhost:8080",

  # Policy hot reload in development
  policy_hot_reload: true,

  # Use example policy from repo
  policy_path: System.get_env("POLICY_PATH") || "examples/policy-dev.yaml"

# Set log level to debug in development
config :logger,
  level: :debug,
  compile_time_purge_matching: [
    [level_lower_than: :debug]
  ]

# Enable helpful dev-mode warnings
config :phoenix, :plug_init_mode, :runtime
