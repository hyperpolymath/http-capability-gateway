# SPDX-License-Identifier: PMPL-1.0-or-later
import Config

# Runtime configuration for production releases
# These values are read from environment variables at runtime, not compile time
if config_env() == :prod do
  config :http_capability_gateway,
    policy_path: System.fetch_env!("POLICY_PATH"),
    backend_url: System.get_env("BACKEND_URL"),
    port: String.to_integer(System.get_env("PORT") || "4000"),
    trust_level_header: System.get_env("TRUST_LEVEL_HEADER") || "x-trust-level",
    trust_level_source: System.get_env("TRUST_LEVEL_SOURCE") || "header"
end
