defmodule HttpCapabilityGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :http_capability_gateway,
      version: "0.1.0-dev",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Documentation
      name: "HTTP Capability Gateway",
      source_url: "https://github.com/hyperpolymath/http-capability-gateway",
      homepage_url: "https://github.com/hyperpolymath/http-capability-gateway",
      docs: [
        main: "readme",
        extras: ["README.md", "CONTRIBUTING.md", "SECURITY.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {HttpCapabilityGateway.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # HTTP Server
      {:plug_cowboy, "~> 2.7"},
      {:plug, "~> 1.15"},

      # JSON/YAML parsing
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},

      # JSON Schema validation
      {:ex_json_schema, "~> 0.10"},

      # HTTP client for backend proxy
      {:req, "~> 0.5"},

      # Observability
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:prometheus_telemetry, "~> 0.4"},

      # Testing
      {:stream_data, "~> 1.0", only: :test},

      # Benchmarking (Phase D — standards#99). Only loaded for the bench/*.exs
      # harness; not pulled into prod/test runtime. Benchee is the Elixir-native
      # statistical benchmark tool (p50/p95/p99, warmup, formatters). The
      # JSON formatter (benchee_json) feeds bench/compare.exs the structured
      # output it needs to diff against bench/baseline.json.
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false},
      {:benchee_json, "~> 1.0", only: [:dev, :test], runtime: false},

      # Documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
