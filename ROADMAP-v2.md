# http-capability-gateway v2.0 Roadmap — HISTORICAL / ASPIRATIONAL

> **⚠️ HISTORICAL DOCUMENT (2026-04-16):** This is an aspirational v2.0 vision
> written when the project was still in design phase. It is NOT on the current
> release path for v0.1.0 — the features listed here (web UI, plugins, multi-protocol
> full support, AI policy suggestions, etc.) are explicitly **out of MVP scope**.
>
> See `ROADMAP.adoc` and `docs/SUPPORTED-FEATURES.md` for the current scope and
> what is actually supported today.
>
> Do not treat any item in this document as a commitment or an imminent feature.
> It is preserved for reference and long-term direction only.

# Original Vision: The Gateway Everyone Wants

Transform http-capability-gateway from "good production gateway" to **"the obvious choice for API governance"** by making it:

1. **Bulletproof** - Never fails, always recovers
2. **Effortless** - 5-minute setup, beautiful UI, zero config defaults
3. **Powerful** - Handles any protocol, any scale, any use case
4. **Extensible** - Plugin ecosystem, community contributions
5. **Observable** - See everything, understand everything

---

## 🛡️ DEPENDABILITY (Make it Bulletproof)

### Priority 1: Resilience
- **Circuit Breakers** (#13)
  - Automatic backend failure detection
  - Exponential backoff with jitter
  - Self-healing (auto-recovery)
  - Per-backend circuit state
  - Metrics: circuit_breaker_state, failure_rate

- **Graceful Degradation**
  - Stale policy cache (continue with last good policy)
  - Backup policy file support
  - Read-only mode when policy invalid
  - Queue requests during brief outages

- **Policy Rollback**
  - Git-based policy versioning
  - Automatic rollback on error spike
  - Policy canary deployments (test on 1% traffic)
  - Diff visualization before applying

### Priority 2: High Availability
- **Zero-Downtime Updates** (#15)
  - Hot-reload policies without restart
  - Atomic ETS table swap
  - Watch policy file for changes
  - POST /admin/reload endpoint

- **Clustering Support**
  - Distributed policy cache (libcluster)
  - Consistent hashing for sticky sessions
  - Leader election for policy updates
  - Gossip protocol for policy sync

---

## 🔒 SECURITY (Make it Fort Knox)

### Priority 1: Protection
- **Rate Limiting** (#14)
  - Per trust level (untrusted: 10/min, authenticated: 100/min, internal: unlimited)
  - Token bucket algorithm
  - Distributed rate limiting (Redis)
  - Return 429 with Retry-After
  - Headers: X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset

- **Input Validation**
  - Request size limits (body, headers)
  - Path traversal protection
  - SQL injection detection
  - XSS filtering
  - CSRF protection

- **DDoS Protection**
  - Connection rate limiting
  - Slowloris protection
  - IP-based blocking
  - Geofencing support

### Priority 2: Compliance
- **Audit Logging**
  - Who changed what when
  - Policy change history
  - Failed access attempts
  - Compliance reports (SOC2, HIPAA)

- **Secrets Management**
  - HashiCorp Vault integration
  - AWS Secrets Manager
  - Environment variable encryption
  - Rotate credentials automatically

---

## ⚡ PERFORMANCE (Make it Blazing Fast)

### Priority 1: Speed
- **Caching Layer** (#17)
  - HTTP caching (Cache-Control, ETag, Last-Modified)
  - Cachex for in-memory cache
  - Redis for distributed cache
  - TTL per route in policy
  - Cache hit/miss metrics
  - Admin API for cache invalidation

- **Connection Pooling**
  - Reuse backend connections
  - Configurable pool size
  - Connection health checks
  - Automatic pool scaling

- **HTTP/2 Support**
  - Server push for related resources
  - Multiplexing
  - Header compression

### Priority 2: Optimization
- **Async Everything**
  - Async logging (no blocking)
  - Async metrics export
  - Background policy compilation

- **Response Streaming**
  - Stream large responses
  - Chunked transfer encoding
  - Server-sent events (SSE)

---

## 🚀 FUNCTIONALITY (Make it Powerful)

### Priority 1: Protocol Support (#22)
- **GraphQL**
  - Query/mutation name matching
  - Field-level permissions
  - Introspection control

- **WebSocket**
  - Long-lived connection policy checks
  - Message-level governance
  - Heartbeat support

- **gRPC**
  - Protobuf method matching
  - Service-level policies
  - Streaming support

### Priority 2: Advanced Features
- **Request/Response Transformation**
  - Modify headers (add, remove, replace)
  - Body transformation (JSON → JSON)
  - URL rewriting
  - Query parameter manipulation

- **Load Balancing**
  - Multiple backend support
  - Round-robin, least-connections, random
  - Health checks
  - Weighted routing

- **Multi-Tenancy**
  - Tenant isolation
  - Per-tenant policies
  - Tenant-specific backends
  - Usage tracking per tenant

---

## 🎨 EASY TO USE (Make it Effortless)

### Priority 1: Beautiful UI (#16)
- **Phoenix LiveView Dashboard**
  - Visual policy editor (drag-drop rules)
  - Live policy validation
  - Metrics charts (requests/sec, latency, errors)
  - Request logs viewer (real-time)
  - Policy diff/compare
  - Dark mode
  - Mobile responsive

- **Interactive Tutorial**
  - Onboarding wizard
  - Example policies gallery
  - Interactive playground
  - Video walkthroughs

### Priority 2: Developer Experience
- **Policy Testing Framework** (#19)
  - `assert_allows(policy, :GET, "/api/users", trust: "authenticated")`
  - `assert_denies(policy, :DELETE, "/api/admin")`
  - Property-based testing
  - Coverage reports
  - `mix policy.test` command

- **CLI Tool**
  - `hcg init` - scaffolding
  - `hcg validate policy.yaml` - validation
  - `hcg test policy.yaml` - testing
  - `hcg deploy` - deployment
  - `hcg analyze` - policy optimization suggestions

- **Policy Templates Library**
  - REST API gateway
  - Microservices mesh
  - Internal service gateway
  - Public API gateway
  - Multi-tenant SaaS
  - B2B API platform

---

## 🔌 EXTENSIBILITY (Make it Hackable)

### Priority 1: Plugin System (#21)
- **Behavior-Based Plugins**
  ```elixir
  defmodule MyAuthPlugin do
    @behaviour HttpCapabilityGateway.Plugin.Auth

    def authenticate(conn, config) do
      # Custom auth logic
    end
  end
  ```

- **Plugin Types**
  - `Auth` - Custom authentication
  - `RequestFilter` - Modify requests
  - `ResponseFilter` - Modify responses
  - `PolicyLoader` - Load from custom sources
  - `MetricsExporter` - Export to custom systems

- **Plugin Discovery**
  - Hex.pm package ecosystem
  - Auto-discovery via Mix config
  - Plugin marketplace on website

### Priority 2: Integrations
- **API Gateway Integration**
  - Kong plugin
  - Traefik middleware
  - Envoy filter
  - AWS API Gateway authorizer

- **Observability Integration**
  - Datadog APM
  - New Relic
  - Honeycomb
  - Elastic APM

---

## 📊 OBSERVABILITY (Make it Transparent)

### Priority 1: Visibility (#18)
- **Distributed Tracing**
  - OpenTelemetry integration
  - Jaeger/Zipkin export
  - Trace ID in logs
  - Trace context propagation
  - Span tags: verb, path, trust_level, decision

- **Real-Time Metrics Dashboard**
  - Requests per second (live graph)
  - Latency percentiles (p50, p95, p99)
  - Error rates by endpoint
  - Top endpoints by traffic
  - Top denied requests
  - Trust level distribution

### Priority 2: Insights
- **Policy Analytics**
  - Most-hit rules
  - Unused rules detection
  - Dead code in policies
  - Optimization suggestions

- **Cost Optimization**
  - Backend cost per endpoint
  - Expensive routes identification
  - Caching ROI calculation
  - Rate limit effectiveness

---

## 🎯 DEPLOYMENT (Make it Cloud-Native)

### Priority 1: Infrastructure as Code (#20)
- **Kubernetes**
  - Helm chart with sensible defaults
  - HPA (Horizontal Pod Autoscaler)
  - Ingress integration
  - ConfigMap for policies
  - Secret for TLS certs
  - ServiceMonitor for Prometheus

- **Terraform Modules**
  - AWS: ECS/Fargate deployment
  - GCP: Cloud Run / GKE
  - Azure: Container Instances / AKS
  - Complete networking setup
  - Load balancer configuration

### Priority 2: Developer Workflows
- **GitOps Integration**
  - ArgoCD application
  - FluxCD kustomization
  - Automatic policy sync from Git
  - PR-based policy reviews

- **CI/CD Templates**
  - GitHub Actions workflows
  - GitLab CI templates
  - Jenkins pipelines
  - Policy validation in CI

---

## 🌟 KILLER FEATURES (Make it Unique)

### The "Wow" Factors

1. **AI-Powered Policy Suggestions**
   - Analyze traffic patterns
   - Suggest optimal policies
   - Detect anomalies
   - Auto-generate policies from OpenAPI specs

2. **Time-Travel Debugging**
   - Replay requests from logs
   - Step through policy evaluation
   - "Why was this request denied?"
   - Visual policy execution trace

3. **Policy Simulation**
   - "What if" analysis
   - Test policy changes on historical traffic
   - Impact prediction before deployment
   - A/B test policies

4. **Community Policy Library**
   - Share policies on hub.hyperpolymath.org
   - Star/fork popular policies
   - Policy composition (import shared rules)
   - Security policy marketplace

5. **Zero-Config Mode**
   - Start with `hcg start`
   - Auto-generate policy from traffic
   - Learn mode (observe only)
   - Graduate to enforcement mode

6. **Visual Policy Builder**
   - Flowchart-style policy design
   - Drag-drop nodes for rules
   - Real-time validation
   - Export to YAML

---

## 📈 ADOPTION STRATEGY

### Make It Irresistible

1. **Quick Start Promise: "5 Minutes to Production"**
   ```bash
   curl -sSL https://get.hcg.dev | bash
   hcg init
   hcg start  # That's it!
   ```

2. **Free Tier with All Features**
   - No artificial limitations
   - Open source forever
   - Optional paid cloud hosting
   - Enterprise support available

3. **Viral Features**
   - Beautiful public dashboards (share your metrics)
   - Policy templates sharing
   - Success stories showcase
   - Badge: "Protected by HCG"

4. **Integration Everywhere**
   - Docker Hub official image
   - AWS/Azure/GCP marketplaces
   - Terraform registry
   - Helm artifact hub
   - VS Code extension

5. **Community Building**
   - Discord server
   - Monthly webinars
   - Blog with tutorials
   - YouTube channel
   - Twitter bot (gateway tips)

---

## 🎯 IMPLEMENTATION PRIORITY

### Phase 1: Dependability (v1.1.0) - 2 weeks
- Circuit breakers (#13)
- Hot-reload (#15)
- Graceful degradation

### Phase 2: Easy to Use (v1.2.0) - 3 weeks
- Web UI dashboard (#16)
- Policy testing framework (#19)
- CLI tool

### Phase 3: Performance (v1.3.0) - 2 weeks
- Caching layer (#17)
- Rate limiting (#14)
- Connection pooling

### Phase 4: Observability (v1.4.0) - 2 weeks
- Distributed tracing (#18)
- Real-time metrics dashboard
- Policy analytics

### Phase 5: Extensibility (v2.0.0) - 3 weeks
- Plugin system (#21)
- Protocol support (#22)
- Helm chart (#20)

---

## 💡 COMPETITIVE ADVANTAGES

### vs Kong
- ✅ Simpler policy language (DSL v1 vs Lua)
- ✅ Better stealth mode
- ✅ Native Elixir performance
- ✅ Built-in policy testing

### vs Traefik
- ✅ More fine-grained verb control
- ✅ Trust-level based governance
- ✅ Better observability out-of-box

### vs Envoy
- ✅ Much easier to configure
- ✅ Beautiful UI (Envoy has none)
- ✅ Policy-first design
- ✅ Smaller learning curve

### vs AWS API Gateway
- ✅ Self-hosted (no vendor lock-in)
- ✅ Open source
- ✅ No per-request pricing
- ✅ More flexible policies

---

## 🚀 Success Metrics

**Adoption:**
- 1,000 GitHub stars in 6 months
- 100 production deployments
- 10 community plugins

**Performance:**
- <5ms latency overhead
- 10,000+ req/sec on single instance
- 99.99% uptime in production

**Community:**
- 50 policy templates shared
- 100 Discord members
- 10 blog posts/tutorials

---

## 🎊 The Ultimate Goal

**"The Gateway Everyone Wants"**

When developers think "I need an API gateway," their first thought should be:
> "http-capability-gateway - duh! It's so easy, so powerful, and that UI is gorgeous!"

**Make it so good they can't resist.**
