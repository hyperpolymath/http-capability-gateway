# http-capability-gateway - Implementation Roadmap

> NOTE (2026-03-30): This document is historical. The repository now contains a real Mix application, Elixir modules, and tests. Use `ROADMAP.adoc`, `TEST-NEEDS.md`, and `PROOF-NEEDS.md` as the current source of truth. The main gap is verification and scope control, not initial scaffolding.

**Created:** 2026-01-22
**Current Status:** 30% (Design Phase)
**Target:** MVP v0.1.0 (80-90%)
**Estimated Effort:** 40-60 hours

---

## Current State

### What Exists
- ✅ README with clear MVP scope
- ✅ Architecture design (Policy DSL → Elixir Gateway)
- ✅ Example policy.yaml structure
- ✅ Verb Governance Spec (DSL v1) defined
- ✅ Directory structure (contractiles/, docs/, config/)
- ✅ STATE.scm, ECOSYSTEM.scm files

### What's Missing
- ❌ No Elixir application (`mix.exs`)
- ❌ No source code (`lib/` directory empty/missing)
- ❌ No policy loader implementation
- ❌ No validator (schema validation)
- ❌ No compiler (DSL → enforcement rules)
- ❌ No HTTP gateway (Plug/Cowboy)
- ❌ No enforcement engine
- ❌ No tests

---

## Phase 1: Foundation (MVP) - 40-50 hours

### 1.1 Elixir Application Scaffold (2-3h)
**Priority:** CRITICAL
**Files to Create:**
```
http-capability-gateway/
├── mix.exs                           # Mix project config
├── lib/
│   └── http_capability_gateway/
│       ├── application.ex            # OTP application
│       └── gateway.ex                # Main supervisor
└── config/
    ├── config.exs                    # Base config
    ├── dev.exs                       # Dev environment
    ├── prod.exs                      # Production environment
    └── policy.yaml                   # ✓ Already exists
```

**Dependencies to Add:**
- `plug_cowboy` - HTTP server
- `jason` - JSON encoding/decoding
- `yaml_elixir` - YAML parser
- `telemetry` - Metrics/logging
- `ex_json_schema` - JSON Schema validation

**Tasks:**
- [ ] Create `mix.exs` with dependencies
- [ ] Generate OTP application structure
- [ ] Configure logger (structured JSON output)
- [ ] Set up Telemetry for observability

---

### 1.2 Policy Loader (4-6h)
**Priority:** CRITICAL
**Module:** `HttpCapabilityGateway.PolicyLoader`

**Implementation:**
```elixir
defmodule HttpCapabilityGateway.PolicyLoader do
  @moduledoc """
  Loads Verb Governance Spec (YAML) from disk.
  Parses YAML into Elixir map structure.
  """

  @spec load_policy(path :: String.t()) :: {:ok, map()} | {:error, term()}
  def load_policy(path) do
    # Read YAML file
    # Parse with YamlElixir
    # Return structured policy map
  end
end
```

**Schema to Parse:**
```yaml
service:
  name: string
  version: integer
  environment: string

verbs:
  GET:      {exposure: public | authenticated | internal}
  POST:     {exposure: public | authenticated | internal}
  PUT:      {exposure: public | authenticated | internal}
  DELETE:   {exposure: public | authenticated | internal}
  PATCH:    {exposure: public | authenticated | internal}
  HEAD:     {exposure: public | authenticated | internal}
  OPTIONS:  {exposure: public | authenticated | internal}

routes:
  - path: string (regex-capable)
    verbs: {verb-specific overrides with narrative}

stealth:
  profiles:
    limited:
      unauthenticated: 401 | 403 | 404 | 405
      untrusted: 401 | 403 | 404 | 405

narrative:
  purpose: string
```

**Tasks:**
- [ ] Implement YAML file reading
- [ ] Parse service metadata
- [ ] Parse verb exposure levels
- [ ] Parse route-specific overrides
- [ ] Parse stealth profiles
- [ ] Handle file errors gracefully

---

### 1.3 Policy Validator (6-8h)
**Priority:** CRITICAL
**Module:** `HttpCapabilityGateway.PolicyValidator`

**Implementation:**
```elixir
defmodule HttpCapabilityGateway.PolicyValidator do
  @moduledoc """
  Validates loaded policy against JSON Schema.
  Ensures all required fields present.
  Checks exposure levels are valid.
  Validates route paths are valid regexes.
  """

  @spec validate(policy :: map()) :: :ok | {:error, [validation_error()]}
  def validate(policy) do
    # Validate service metadata
    # Validate verb exposure levels
    # Validate route paths (regex compilation)
    # Validate stealth profile codes
    # Return aggregated errors
  end
end
```

**Validation Rules:**
- `service.name` - required, non-empty string
- `service.version` - required, positive integer
- `service.environment` - required, one of: dev, staging, prod
- `verbs.<METHOD>.exposure` - required, one of: public, authenticated, internal
- `routes[].path` - valid regex pattern
- `stealth.profiles.<profile>.<level>` - valid HTTP status code (401-599)

**Tasks:**
- [ ] Define JSON Schema for DSL v1
- [ ] Implement schema validation with ex_json_schema
- [ ] Validate regex patterns compile
- [ ] Validate exposure levels are recognized
- [ ] Validate stealth codes are valid HTTP codes
- [ ] Generate human-readable error messages

---

### 1.4 Policy Compiler (8-12h)
**Priority:** CRITICAL
**Module:** `HttpCapabilityGateway.PolicyCompiler`

**Implementation:**
```elixir
defmodule HttpCapabilityGateway.PolicyCompiler do
  @moduledoc """
  Compiles DSL policy into fast enforcement rules.
  Builds ETS table with compiled patterns for O(1) lookups.
  """

  defmodule CompiledRule do
    @moduledoc "Single enforcement rule"
    defstruct [
      :path_regex,         # Compiled Regex for route matching
      :verb,               # HTTP method atom (:get, :post, etc.)
      :exposure,           # :public | :authenticated | :internal
      :stealth_profile,    # :none | :limited (from policy)
      :narrative           # Optional explanation string
    ]
  end

  @spec compile(policy :: map()) :: {:ok, :ets.tid()} | {:error, term()}
  def compile(policy) do
    # Compile global verb rules
    # Compile route-specific overrides (take precedence)
    # Store in ETS table: {path_pattern, verb} => CompiledRule
    # Return ETS table reference
  end
end
```

**Compilation Strategy:**
1. Parse global verb rules (apply to all routes)
2. Parse route-specific overrides (highest precedence)
3. Compile regex patterns for efficient matching
4. Store in ETS table for fast concurrent lookups
5. Return ETS table reference for enforcement

**ETS Schema:**
```
Key:   {path_regex, verb_atom}
Value: %CompiledRule{...}
```

**Tasks:**
- [ ] Implement global verb rule compilation
- [ ] Implement route-specific override compilation
- [ ] Compile regex patterns with error handling
- [ ] Create ETS table with appropriate options (public, read_concurrency)
- [ ] Handle pattern conflicts (routes should override global)
- [ ] Benchmark lookup performance

---

### 1.5 HTTP Gateway (10-14h)
**Priority:** CRITICAL
**Module:** `HttpCapabilityGateway.Gateway`

**Implementation:**
```elixir
defmodule HttpCapabilityGateway.Gateway do
  @moduledoc """
  Plug-based HTTP gateway.
  Enforces compiled rules on incoming requests.
  Proxies allowed requests to backend.
  Logs all decisions.
  """

  use Plug.Router

  plug :match
  plug :dispatch

  # Match all methods and paths
  match _ do
    # Extract request metadata
    # Lookup enforcement rule
    # Make decision (allow/deny/stealth)
    # Log decision with provenance
    # Forward or reject
  end
end
```

**Request Flow:**
```
Incoming Request
    |
    v
Extract Metadata (method, path, auth, trust_level)
    |
    v
Lookup Enforcement Rule (ETS)
    |
    v
Apply Exposure Policy
    |
    v
Check Stealth Profile
    |
    v
Make Decision (allow | deny | stealth_response)
    |
    v
Log Decision (JSON)
    |
    v
Forward to Backend (if allowed) | Return Error
```

**Decision Logic:**
```elixir
def decide(request, rule) do
  case {request.trust_level, rule.exposure} do
    {_, :public}                     -> :allow
    {:authenticated, :authenticated} -> :allow
    {:internal, :internal}           -> :allow
    {:internal, :authenticated}      -> :allow
    {:authenticated, :public}        -> :allow
    _                                -> apply_stealth(request, rule)
  end
end
```

**Tasks:**
- [ ] Implement Plug.Router for HTTP gateway
- [ ] Extract request metadata (method, path, headers)
- [ ] Determine trust level (public/authenticated/internal)
- [ ] Lookup compiled rule from ETS
- [ ] Implement decision logic with exposure levels
- [ ] Implement stealth profile responses
- [ ] Forward allowed requests to backend (proxy)
- [ ] Structure JSON logs (see section 1.6)
- [ ] Handle backend errors gracefully

---

### 1.6 Structured Logging (4-6h)
**Priority:** HIGH
**Module:** `HttpCapabilityGateway.DecisionLogger`

**Log Format (JSON):**
```json
{
  "timestamp": "2026-01-22T20:30:00.123Z",
  "service": "ledger-api",
  "environment": "dev",
  "request": {
    "method": "DELETE",
    "path": "/accounts/42",
    "source_ip": "192.168.1.100",
    "trust_level": "public"
  },
  "rule": {
    "exposure": "internal",
    "narrative": "Account deletion requires internal trust."
  },
  "decision": "deny",
  "response": {
    "status": 404,
    "stealth_profile": "limited"
  },
  "duration_ms": 1.23
}
```

**Tasks:**
- [ ] Define log schema (above)
- [ ] Implement JSON encoder for decisions
- [ ] Integrate with Elixir Logger
- [ ] Add Telemetry metrics (decision counts, latency)
- [ ] Support log levels (info for allow, warn for deny)
- [ ] Ensure no sensitive data in logs

---

### 1.7 Configuration & Environment (2-3h)
**Priority:** MEDIUM
**Files:** `config/config.exs`, `config/dev.exs`, `config/prod.exs`

**Configuration Schema:**
```elixir
config :http_capability_gateway,
  # Policy
  policy_path: "config/policy.yaml",
  reload_on_change: false,  # Hot reload (Phase 2)

  # HTTP Gateway
  port: 8080,
  backend_url: "http://localhost:8081",
  timeout_ms: 5000,

  # Trust Detection
  trust_header: "X-Trust-Level",  # authenticated | internal
  auth_header: "Authorization",

  # Logging
  log_format: :json,
  log_level: :info

# Dev overrides
import_config "#{Mix.env()}.exs"
```

**Tasks:**
- [ ] Define config schema
- [ ] Implement env-specific overrides (dev/prod)
- [ ] Add config validation on startup
- [ ] Document all config options

---

### 1.8 Backend Proxy (4-6h)
**Priority:** HIGH
**Module:** `HttpCapabilityGateway.Proxy`

**Implementation:**
```elixir
defmodule HttpCapabilityGateway.Proxy do
  @moduledoc """
  Forwards allowed requests to backend service.
  Preserves headers, body, and method.
  Returns backend response to client.
  """

  @spec forward(conn :: Plug.Conn.t(), backend_url :: String.t()) :: Plug.Conn.t()
  def forward(conn, backend_url) do
    # Build backend request (method, path, headers, body)
    # Send HTTP request to backend
    # Stream response back to client
    # Handle errors (timeout, connection refused)
  end
end
```

**HTTP Client:** Use `Req` or `Finch` for backend requests

**Tasks:**
- [ ] Implement HTTP client for backend forwarding
- [ ] Preserve all headers from original request
- [ ] Forward request body (streaming for large payloads)
- [ ] Stream response back to client
- [ ] Handle backend timeouts
- [ ] Handle backend connection errors
- [ ] Add retry logic (optional)

---

## Phase 2: Testing & Quality (12-16h)

### 2.1 Unit Tests (6-8h)
**Test Coverage:**
- PolicyLoader - YAML parsing, error handling
- PolicyValidator - All validation rules, error messages
- PolicyCompiler - Rule compilation, ETS lookups, regex matching
- Gateway - Decision logic for all exposure/trust combinations
- Proxy - Forwarding, error handling

**Tools:** ExUnit, Mox (for HTTP backend mocking)

**Tasks:**
- [ ] Test policy loader with valid/invalid YAML
- [ ] Test validator with valid/invalid policies
- [ ] Test compiler regex matching
- [ ] Test gateway decision logic (all paths)
- [ ] Test stealth profile responses
- [ ] Test proxy forwarding and error handling
- [ ] Achieve 80%+ code coverage

---

### 2.2 Integration Tests (4-6h)
**Test Scenarios:**
1. Full flow: Load policy → Validate → Compile → Enforce
2. Allowed request forwarded to backend
3. Denied request returns correct stealth code
4. Route-specific override takes precedence
5. Backend timeout handling
6. Invalid policy rejection on startup

**Tasks:**
- [ ] Set up test backend (simple Plug app)
- [ ] Test end-to-end request flows
- [ ] Test policy loading from file
- [ ] Test enforcement with real HTTP requests
- [ ] Test log output (structured JSON)

---

### 2.3 Property Testing (Optional, 2-4h)
**Library:** StreamData

**Properties to Test:**
- Any valid policy compiles without error
- Compiled rules match expected exposure
- Decision logic is deterministic
- Stealth responses never leak internal info

---

## Phase 3: Documentation (4-6h)

### 3.1 API Documentation (2-3h)
**Tasks:**
- [ ] Add @moduledoc to all modules
- [ ] Add @doc to all public functions
- [ ] Add @spec for all function signatures
- [ ] Generate ExDoc documentation
- [ ] Deploy docs to GitHub Pages

---

### 3.2 User Guide (2-3h)
**Sections:**
- Quick Start (5 minutes)
- Policy DSL Reference
- Configuration Options
- Deployment Guide (systemd, Docker, K8s)
- Troubleshooting

**Tasks:**
- [ ] Write quick start guide
- [ ] Document DSL syntax with examples
- [ ] Document all config options
- [ ] Add deployment examples
- [ ] Add troubleshooting section

---

## Phase 4: Production Readiness (8-12h)

### 4.1 Performance Optimization (4-6h)
**Targets:**
- < 1ms decision latency (p50)
- < 5ms decision latency (p99)
- > 10,000 req/s throughput (single node)

**Tasks:**
- [ ] Benchmark ETS lookup performance
- [ ] Benchmark regex matching
- [ ] Optimize hot paths
- [ ] Add telemetry for latency tracking
- [ ] Load test with wrk/k6

---

### 4.2 Observability (2-3h)
**Tasks:**
- [ ] Add Prometheus metrics exporter
- [ ] Add health check endpoint (`/health`)
- [ ] Add readiness check endpoint (`/ready`)
- [ ] Add metrics endpoint (`/metrics`)
- [ ] Document metrics schema

**Metrics to Export:**
- `http_capability_gateway_decisions_total{decision, verb, exposure}` (counter)
- `http_capability_gateway_decision_duration_seconds` (histogram)
- `http_capability_gateway_backend_requests_total{status}` (counter)

---

### 4.3 Containerization (2-3h)
**Tasks:**
- [ ] Create Dockerfile (multi-stage build)
- [ ] Create docker-compose.yml for local dev
- [ ] Create Kubernetes manifests (Deployment, Service, ConfigMap)
- [ ] Document container deployment

---

## Definition of Done (MVP v0.1.0)

A feature is considered complete when:
- ✅ Code implemented and compiles
- ✅ Unit tests written and passing
- ✅ Integration tests passing
- ✅ Documentation updated (API docs + user guide)
- ✅ Benchmarked (meets performance targets)
- ✅ Reviewed (at least 1 reviewer)

**MVP Completion Criteria:**
- ✅ Policy loaded from YAML
- ✅ Policy validated against schema
- ✅ Policy compiled to ETS rules
- ✅ HTTP gateway enforces rules
- ✅ Decisions logged as JSON
- ✅ Allowed requests forwarded to backend
- ✅ Denied requests return stealth codes
- ✅ Tests passing (80%+ coverage)
- ✅ Documentation complete
- ✅ Performance targets met

---

## Effort Estimate Summary

| Phase | Description | Hours |
|-------|-------------|-------|
| 1. Foundation (MVP) | Elixir app, loader, validator, compiler, gateway, proxy | 40-50 |
| 2. Testing & Quality | Unit tests, integration tests | 12-16 |
| 3. Documentation | API docs, user guide | 4-6 |
| 4. Production Readiness | Performance, observability, containers | 8-12 |
| **TOTAL** | **MVP v0.1.0 (80-90% complete)** | **64-84 hours** |

**Revised Estimate (Focused MVP):** 40-60 hours
**Priority:** Complete Phase 1 (Foundation) first → 40-50 hours

---

## Dependencies

**External:**
- Elixir 1.15+ with OTP 26+
- Backend service to proxy to (e.g., WordPress, API)

**Internal (lcb-website stack):**
- indieweb2-bastion - Consent portal (provides trust levels via header)
- svalinn - Edge gateway (sits in front of capability gateway)
- WordPress - Backend service

**Integration Points:**
- Receives requests from Svalinn
- Reads `X-Trust-Level` header from indieweb2-bastion
- Forwards allowed requests to WordPress/backend

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Policy DSL too complex | Medium | High | Keep v1 minimal, defer complex features |
| ETS performance issues | Low | High | Benchmark early, optimize compiler |
| Backend proxy errors | Medium | Medium | Comprehensive error handling, retries |
| Regex DoS attacks | Medium | High | Validate patterns at compile time, set limits |
| Integration with indieweb2-bastion | High | Medium | Define header contract early, test integration |

---

## Next Steps (Immediate)

1. **Create Elixir scaffold** (2-3h)
   - `mix new http_capability_gateway --sup`
   - Add dependencies to `mix.exs`
   - Set up directory structure

2. **Implement PolicyLoader** (4-6h)
   - Read and parse `config/policy.yaml`
   - Return structured policy map

3. **Implement PolicyValidator** (6-8h)
   - Define JSON Schema for DSL v1
   - Validate policy against schema
   - Test with valid/invalid policies

4. **Implement PolicyCompiler** (8-12h)
   - Compile policy to ETS rules
   - Benchmark lookup performance

5. **Implement Gateway + Proxy** (14-20h)
   - HTTP gateway with Plug
   - Decision logic
   - Backend forwarding
   - Structured logging

**Target:** MVP v0.1.0 in 40-50 hours of focused work

---

## Questions for Stakeholder

1. **Backend URL:** What's the WordPress backend URL? (default: `http://localhost:8081`)
2. **Trust Header:** What header does indieweb2-bastion set? (assumed: `X-Trust-Level`)
3. **Port:** What port should the gateway listen on? (default: 8080)
4. **Stealth Profiles:** Are the example stealth codes (404, 405) correct?
5. **Narrative:** Should narrative be logged or just for documentation?

---

## Conclusion

**http-capability-gateway** is currently at **30% completion** (design phase). Implementing the MVP will require **40-60 hours** of focused Elixir development. The architecture is well-defined, and the scope is minimal and achievable. The primary blocker is the **lack of implementation** - all the design work is complete, but no code exists yet.

**Recommendation:** Prioritize this after completing Cerro Torre (95% → 100%) and before WordPress integration, as it's a **critical frontend component** for the hardened stack.
