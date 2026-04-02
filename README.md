# HTTP Capability Gateway

**An Elixir HTTP gateway for declarative verb governance, route policy enforcement, and selective prefiltering.**

image:https://img.shields.io/badge/License-PMPL--1.0-blue.svg[License: PMPL-1.0,link="https://github.com/hyperpolymath/palimpsest-license"]
![Elixir 1.19+](https://img.shields.io/badge/Elixir-1.19+-purple.svg)
![OTP 27+](https://img.shields.io/badge/OTP-27+-red.svg)

## Current Status

This repository contains a real Elixir gateway implementation, but it should currently be treated as a narrow, in-progress API governance layer rather than a fully proven front door for an entire site.

- The core policy pipeline exists: loader, validator, compiler, gateway, proxy, telemetry.
- The main remaining gaps are security depth, end-to-end verification, and benchmark evidence.
- Read `ROADMAP.adoc`, `TEST-NEEDS.md`, and `PROOF-NEEDS.md` together when judging readiness.

HTTP Capability Gateway enforces fine-grained HTTP verb restrictions at the gateway level using a declarative policy language. It provides:

- **Declarative Verb Governance**: Define allowed HTTP verbs globally and per-route
- **Stealth Mode**: Return configurable status codes (404, 403, etc.) for unauthorized requests
- **Fast Policy Enforcement Architecture**: ETS-backed lookups and compiled policy rules; benchmark evidence still needs to be formalized
- **Trust Level Integration**: Current implementation is header-based, with mTLS-oriented direction documented but not the primary proved path yet
- **Comprehensive Logging**: Structured JSON logs with telemetry metrics
- **Backend Proxy**: Transparent proxying to backend services with header preservation

## Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/hyperpolymath/http-capability-gateway.git
cd http-capability-gateway

# Install dependencies
mix deps.get

# Compile
mix compile
```

### Basic Usage

1. **Create a policy file** (`config/policy.yaml`):

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET
    - POST
  routes:
    - path: "/api/admin"
      verbs: [GET]
    - path: "/api/users/[0-9]+"
      verbs: [GET, PUT, DELETE]
stealth:
  enabled: true
  status_code: 404
```

2. **Configure backend** (`config/dev.exs`):

```elixir
config :http_capability_gateway,
  policy_path: "examples/policy-dev.yaml",
  backend_url: "http://localhost:4000",
  port: 4000
```

3. **Start the gateway**:

```bash
mix run --no-halt

# Or with interactive shell
iex -S mix
```

4. **Test requests**:

```bash
# Allowed: GET on global route
curl http://localhost:4000/api/public
# Returns: proxied response from backend

# Denied: DELETE not in global verbs
curl -X DELETE http://localhost:4000/api/public
# Returns: 404 (stealth mode)

# Allowed: PUT on specific route
curl -X PUT http://localhost:4000/api/users/123
# Returns: proxied response from backend
```

## Policy Language (DSL v1)

### Structure

```yaml
dsl_version: "1"  # Required: policy format version

governance:
  # Global verbs: allowed on all routes unless overridden
  global_verbs:
    - GET
    - POST

  # Route-specific rules (optional)
  routes:
    - path: "/api/admin"
      verbs: [GET]  # Only GET allowed, overrides global
    - path: "/api/users/[0-9]+"  # Regex patterns supported
      verbs: [GET, PUT, DELETE]

stealth:  # Optional stealth mode configuration
  enabled: true
  status_code: 404  # Status code for denied requests
```

### Supported HTTP Verbs

- `GET`, `POST`, `PUT`, `DELETE`
- `PATCH`, `HEAD`, `OPTIONS`

### Path Matching

- **Literal paths**: `/api/users`
- **Regex patterns**: `/api/users/[0-9]+` (numeric user IDs)
- **Wildcard patterns**: `/api/posts/.+` (any post path)

### Stealth Mode

When a request is denied:
- **Stealth enabled**: Returns configured status code (e.g., 404) with empty body
- **Stealth disabled**: Returns 403 Forbidden

Valid stealth status codes: `200`, `301`, `302`, `403`, `404`, `410`, `500`, `503`

## Configuration

### Environment Variables

```bash
# Policy file path (default: config/policy.yaml)
export POLICY_PATH=/path/to/policy.yaml

# Backend URL (required)
export BACKEND_URL=http://backend:4000

# Gateway port (default: 4000)
export PORT=4000

# Trust level header name (default: x-trust-level)
export TRUST_LEVEL_HEADER=x-trust-level
```

### Elixir Config

**`config/config.exs`** (shared config):

```elixir
import Config

config :http_capability_gateway,
  backend_url: System.get_env("BACKEND_URL", "http://localhost:4000"),
  port: String.to_integer(System.get_env("PORT", "4000")),
  trust_level_header: System.get_env("TRUST_LEVEL_HEADER", "x-trust-level")
```

**`config/dev.exs`** (development):

```elixir
import Config

config :http_capability_gateway,
  policy_path: "examples/policy-dev.yaml",
  log_level: :debug
```

**`config/prod.exs`** (production):

```elixir
import Config

config :http_capability_gateway,
  policy_path: System.get_env("POLICY_PATH"),
  log_level: :info
```

## Trust Levels

Extract trust levels from mTLS certificates or HTTP headers:

```elixir
# From header (current implementation)
curl -H "X-Trust-Level: high" http://localhost:4000/api/admin
```

Trust levels can be used for:
- Audit logging
- Fine-grained access control (future feature)
- Rate limiting (future feature)

## Logging

Structured JSON logs with telemetry:

```json
{
  "timestamp": "2026-01-22T23:00:00.000Z",
  "level": "info",
  "message": "request_handled",
  "request_id": "req-abc123",
  "method": "GET",
  "path": "/api/users/123",
  "trust_level": "high",
  "verb_allowed": true,
  "stealth_triggered": false,
  "response_status": 200,
  "duration_ms": 45
}
```

## Performance

Performance-oriented design is present, but the benchmark story is not yet strong enough to advertise hard numbers as release evidence.

- ETS-backed rule lookup is implemented.
- A performance test file exists.
- Benchmarking and concurrency validation are still tracked as open work in `ROADMAP.adoc` and `TEST-NEEDS.md`.

## Testing

```bash
# Run all tests
mix test

# Run specific test file
mix test test/policy_loader_test.exs

# Run property-based tests only
mix test --only property

# Run performance tests
mix test --only performance

# Run with coverage
mix test --cover
```

Current tests cover the policy pipeline and some gateway behavior, but the repo still needs materially stronger evidence in the following areas:

- security tests for token validation, request sanitization, and SSRF resistance
- end-to-end request lifecycle tests
- concurrency and reload testing
- formal benchmark runs

Do not treat the current suite as sufficient proof for whole-site gateway deployment.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    HTTP Capability Gateway                   │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐│
│  │  Policy  │──▶│  Policy  │──▶│  Policy  │──▶│   ETS    ││
│  │  Loader  │   │Validator │   │ Compiler │   │  Rules   ││
│  └──────────┘   └──────────┘   └──────────┘   └──────────┘│
│                                                       ▲       │
│                                                       │       │
│  ┌──────────┐                                        │       │
│  │   HTTP   │────────────────────────────────────────┘       │
│  │ Gateway  │                                                │
│  │ (Plug)   │                                                │
│  └────┬─────┘                                                │
│       │                                                      │
│       │ if allowed                                           │
│       ▼                                                      │
│  ┌──────────┐                                                │
│  │ Backend  │───▶ http://backend:4000                       │
│  │  Proxy   │                                                │
│  │  (Req)   │                                                │
│  └──────────┘                                                │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## Project Structure

```
http-capability-gateway/
├── lib/
│   └── http_capability_gateway/
│       ├── application.ex        # OTP application
│       ├── gateway.ex            # HTTP gateway (Plug.Router)
│       ├── proxy.ex              # Backend proxy (Req)
│       ├── policy_loader.ex      # YAML policy loading
│       ├── policy_validator.ex   # DSL v1 validation
│       ├── policy_compiler.ex    # ETS compilation
│       ├── logging.ex            # Structured logging
│       └── log_formatter.ex      # JSON log formatter
├── test/                         # Current automated tests
├── config/                       # Elixir config files and default policy
├── examples/                     # Example policies
└── docs/                         # API documentation
```

## Roadmap

Use `ROADMAP.adoc` as the current roadmap.

The short version is:

- core policy pipeline exists
- tests exist but are not yet strong enough for broad production claims
- the recommended near-term role is route-scoped API prefiltering, not full-site gateway responsibility
- benchmark, E2E, and security-hardening work remain open

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new features
4. Ensure `mix test` passes
5. Submit a pull request

## License

This project is licensed under the **PMPL-1.0-or-later** (Polyform Maintainer Private License).

See [LICENSE](LICENSE) for details.

## Credits

**Author**: Jonathan D.A. Jewell
**Email**: jonathan@hyperpolymath.org
**Repository**: https://github.com/hyperpolymath/http-capability-gateway

Built with ❤️ in Elixir by the hyperpolymath team.

## Support

- **Issues**: https://github.com/hyperpolymath/http-capability-gateway/issues
- **Discussions**: https://github.com/hyperpolymath/http-capability-gateway/discussions
- **Security**: See [SECURITY.md](SECURITY.md) for reporting security vulnerabilities


## Architecture

See [TOPOLOGY.md](TOPOLOGY.md) for a visual architecture map and completion dashboard.
