# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
import Config

# Production-specific configuration

# Policy file path (required)
config :http_capability_gateway,
  policy_path: System.fetch_env!("POLICY_PATH"),

  # Backend URL (optional)
  backend_url: System.get_env("BACKEND_URL"),

  # Server port
  port: String.to_integer(System.get_env("PORT") || "4000"),

  # Trust level header
  trust_level_header: System.get_env("TRUST_LEVEL_HEADER") || "x-trust-level"

# Set log level to info in production
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]
