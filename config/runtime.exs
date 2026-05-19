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
    trust_level_source: System.get_env("TRUST_LEVEL_SOURCE") || "header",

    # mTLS listener (Phase B). When TRUST_LEVEL_SOURCE=mtls these three paths
    # MUST all be set and readable or the application refuses to start
    # (fail-closed -- see HttpCapabilityGateway.Application.http_listeners/1).
    tls_port: String.to_integer(System.get_env("GATEWAY_TLS_PORT") || "4443"),
    mtls_ca_cert_path: System.get_env("MTLS_CA_CERT_PATH"),
    gateway_cert_path: System.get_env("GATEWAY_CERT_PATH"),
    gateway_key_path: System.get_env("GATEWAY_KEY_PATH")
end
