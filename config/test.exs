# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
import Config

# Test-specific configuration

# Use in-memory policy for testing (no file I/O)
config :http_capability_gateway,
  # Use a test backend that doesn't actually exist
  backend_url: "http://localhost:9999",

  # Use test policy file (nil to skip loading during app start for unit tests)
  policy_path: nil,

  # Disable policy hot reload in tests
  policy_hot_reload: false

# Set log level to warning in tests (reduce noise)
config :logger,
  level: :warning,
  compile_time_purge_matching: [
    [level_lower_than: :warning]
  ]

# Disable logger output during tests (can be overridden per-test)
config :logger, :console,
  format: "$message\n",
  level: :warning
