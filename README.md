# HTTP Capability Gateway

**A high-performance Elixir HTTP gateway with declarative verb governance and stealth mode.**

image:https://img.shields.io/badge/License-PMPL--1.0-blue.svg[License: PMPL-1.0,link="https://github.com/hyperpolymath/palimpsest-license"]
![Elixir 1.19+](https://img.shields.io/badge/Elixir-1.19+-purple.svg)
![OTP 27+](https://img.shields.io/badge/OTP-27+-red.svg)

## Overview

HTTP Capability Gateway enforces fine-grained HTTP verb restrictions at the gateway level using a declarative policy language. It provides:

- **Declarative Verb Governance**: Define allowed HTTP verbs globally and per-route
- **Stealth Mode**: Return configurable status codes (404, 403, etc.) for unauthorized requests
- **Fast Policy Enforcement**: O(1) verb lookups via ETS, handles >1000 req/s
- **Trust Level Integration**: Extract trust levels from mTLS certificates or headers
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

1. **Create a policy file** (`priv/config/policy.yaml`):

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
  policy_file: "priv/config/policy.dev.yaml",
  backend_url: "http://localhost:4000",
  port: 8080
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
curl http://localhost:8080/api/public
# Returns: proxied response from backend

# Denied: DELETE not in global verbs
curl -X DELETE http://localhost:8080/api/public
# Returns: 404 (stealth mode)

# Allowed: PUT on specific route
curl -X PUT http://localhost:8080/api/users/123
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
# Policy file path (default: priv/config/policy.dev.yaml)
export POLICY_FILE=/path/to/policy.yaml

# Backend URL (required)
export BACKEND_URL=http://backend:4000

# Gateway port (default: 8080)
export PORT=8080

# Trust level header name (default: x-trust-level)
export TRUST_LEVEL_HEADER=x-trust-level
```

### Elixir Config

**`config/config.exs`** (shared config):

```elixir
import Config

config :http_capability_gateway,
  backend_url: System.get_env("BACKEND_URL", "http://localhost:4000"),
  port: String.to_integer(System.get_env("PORT", "8080")),
  trust_level_header: System.get_env("TRUST_LEVEL_HEADER", "x-trust-level")
```

**`config/dev.exs`** (development):

```elixir
import Config

config :http_capability_gateway,
  policy_file: "priv/config/policy.dev.yaml",
  log_level: :debug
```

**`config/prod.exs`** (production):

```elixir
import Config

config :http_capability_gateway,
  policy_file: System.get_env("POLICY_FILE"),
  log_level: :info
```

## Trust Levels

Extract trust levels from mTLS certificates or HTTP headers:

```elixir
# From header (current implementation)
curl -H "X-Trust-Level: high" http://localhost:8080/api/admin
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

Benchmarks (M1 MacBook Pro, 2023):

| Metric | Value |
|--------|-------|
| Policy compilation (1000 routes) | <100ms |
| Verb check latency | <1ms |
| Throughput (sequential) | >1000 req/s |
| Throughput (50 concurrent) | >2000 req/s |
| Memory usage (10000 routes) | <50MB |

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

Test coverage: **76+ tests** across 6 test files:
- Unit tests (policy pipeline)
- Integration tests (gateway)
- Property-based tests (StreamData)
- Performance tests (benchmarks)

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
├── test/                         # Test suite (76+ tests)
├── priv/config/                  # Example policies
├── config/                       # Elixir config files
└── docs/                         # API documentation
```

## Roadmap

- [x] Phase 1: Foundation (90%)
  - [x] Policy pipeline (loader, validator, compiler)
  - [x] HTTP gateway with verb enforcement
  - [x] Backend proxy
  - [x] Structured logging
- [x] Phase 2: Testing (95%)
  - [x] Unit tests (45 tests)
  - [x] Integration tests (31 tests)
  - [x] Property-based tests (7 properties)
  - [x] Performance tests
- [ ] Phase 3: Documentation (in progress)
  - [x] README with quickstart
  - [ ] API documentation
  - [ ] Deployment guide
  - [ ] Policy DSL reference
- [ ] Phase 4: Production (pending)
  - [ ] Docker container
  - [ ] Health checks endpoint
  - [ ] Prometheus metrics export
  - [ ] mTLS trust level extraction

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
