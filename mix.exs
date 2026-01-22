defmodule HttpCapabilityGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :http_capability_gateway,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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

      # Testing
      {:stream_data, "~> 1.0", only: :test}
    ]
  end
end
