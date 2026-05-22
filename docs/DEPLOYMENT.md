<!-- SPDX-License-Identifier: MPL-2.0 -->

# Deployment Guide — HTTP Capability Gateway v0.1.0-dev

Practical guide for deploying the HTTP Capability Gateway to production environments.
Covers container-based deployment (Podman/Docker), bare-metal OTP releases, policy
file setup, health checks, monitoring, security configuration, and troubleshooting.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Container Deployment](#container-deployment)
3. [Bare-Metal Deployment](#bare-metal-deployment)
4. [Policy File Setup](#policy-file-setup)
5. [Health Checks](#health-checks)
6. [Monitoring](#monitoring)
7. [Security](#security)
8. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Runtime Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Elixir | 1.19+ | 1.19.4 |
| Erlang/OTP | 27+ | 28.2 |
| RAM | 256 MB | 1 GB+ |
| CPU | 1 core | 2+ cores |

**Or** a container runtime:

- **Podman** 4.0+ (preferred)
- **Docker** 24.0+
- **nerdctl** 1.0+

The Containerfile uses OCI format and is compatible with all three runtimes.

### Network Requirements

- Inbound access on the configured port (default: `4000`)
- Outbound HTTPS/HTTP access to backend services (for proxy)
- DNS resolution for backend service hostnames

---

## Container Deployment

### Building the Image

The repository includes a multi-stage `Containerfile` that produces a minimal
Alpine-based runtime image (~30 MB) with no build tools or source code.

```bash
# Build with Podman (preferred)
podman build -t http-capability-gateway:0.1.0-dev -f Containerfile .

# Build with Docker
docker build -t http-capability-gateway:0.1.0-dev -f Containerfile .
```

The builder stage uses `hexpm/elixir:1.19.4-erlang-28.2.2-alpine-3.22.1`.
The runtime stage uses `alpine:3.22.1` with only `libstdc++`, `ncurses-libs`,
and `openssl` installed. The application runs as a non-root `gateway` user.

### Running with Podman or Docker

```bash
# Run the gateway container
podman run -d \
  --name http-capability-gateway \
  -p 8080:4000 \
  -e POLICY_PATH=/app/config/policy.yaml \
  -e BACKEND_URL=http://backend:4000 \
  -e PORT=4000 \
  -v ./my-policy.yaml:/app/config/policy.yaml:ro \
  http-capability-gateway:0.1.0-dev

# Check logs
podman logs -f http-capability-gateway

# Stop and remove
podman stop http-capability-gateway
podman rm http-capability-gateway
```

### Running with podman-compose or docker-compose

The repository includes a `docker-compose.yml` that starts the gateway along
with an example httpbin backend for testing.

```bash
# Start all services (gateway + example backend)
podman-compose up --build -d

# Or with Docker Compose
docker-compose up --build -d

# View gateway logs
podman-compose logs -f gateway

# Test the gateway
curl http://localhost:8080/health
curl http://localhost:8080/ready
curl http://localhost:8080/metrics

# Stop all services
podman-compose down
```

The compose file maps host port `8080` to the gateway's internal port `4000`
and mounts a policy file from `./examples/policy-dev.yaml`.

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `POLICY_PATH` | Yes (prod) | `config/policy.yaml` | Path to the DSL v1 policy YAML file |
| `BACKEND_URL` | No | `nil` | URL of the backend service to proxy to |
| `PORT` | No | `4000` | HTTP listen port |
| `TRUST_LEVEL_HEADER` | No | `x-trust-level` | Header name for trust level extraction |
| `TRUST_LEVEL_SOURCE` | No | `header` | Trust extraction source: `header` or `mtls` |
| `LOG_LEVEL` | No | `info` | Logger level (`debug`, `info`, `warn`, `error`) |

### Volume Mounts

| Host Path | Container Path | Purpose |
|-----------|----------------|---------|
| Your policy file | `/app/config/policy.yaml` | DSL v1 governance policy |
| TLS certificates (optional) | `/app/certs/` | mTLS client CA and server certificates |

---

## Bare-Metal Deployment

### Mix Release Build

```bash
# Clone and enter the repository
cd /opt/http-capability-gateway

# Install dependencies (production only)
export MIX_ENV=prod
mix deps.get --only prod
mix compile

# Build OTP release
mix release

# The release is at:
#   _build/prod/rel/http_capability_gateway/
```

### Running the Release

```bash
# Start in foreground (useful for debugging)
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway start

# Start as background daemon
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway daemon

# Check if running
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway pid

# Stop the daemon
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway stop

# Remote console (attach to running node)
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway remote
```

### Systemd Service File

Create `/etc/systemd/system/http-capability-gateway.service`:

```ini
[Unit]
Description=HTTP Capability Gateway v0.1.0-dev
Documentation=https://github.com/hyperpolymath/http-capability-gateway
After=network.target

[Service]
Type=exec
User=gateway
Group=gateway
WorkingDirectory=/opt/http-capability-gateway

# Environment variables
Environment=POLICY_PATH=/etc/http-capability-gateway/policy.yaml
Environment=BACKEND_URL=http://backend.internal:4000
Environment=PORT=4000
Environment=TRUST_LEVEL_HEADER=x-trust-level
Environment=LOG_LEVEL=info

# Start the OTP release
ExecStart=/opt/http-capability-gateway/_build/prod/rel/http_capability_gateway/bin/http_capability_gateway start
ExecStop=/opt/http-capability-gateway/_build/prod/rel/http_capability_gateway/bin/http_capability_gateway stop

# Restart policy
Restart=on-failure
RestartSec=5s

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=http-capability-gateway

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/http-capability-gateway

[Install]
WantedBy=multi-user.target
```

Enable and start the service:

```bash
# Create the gateway user
sudo useradd --system --shell /usr/sbin/nologin gateway

# Set ownership
sudo chown -R gateway:gateway /opt/http-capability-gateway

# Install and start the service
sudo systemctl daemon-reload
sudo systemctl enable http-capability-gateway
sudo systemctl start http-capability-gateway

# Check status
sudo systemctl status http-capability-gateway
journalctl -u http-capability-gateway -f
```

### Configuration via Environment Variables

For bare-metal deployments, environment variables can be set through:

1. **Systemd `Environment=` directives** (shown above)
2. **Systemd `EnvironmentFile=`** pointing to a file:
   ```ini
   EnvironmentFile=/etc/http-capability-gateway/env
   ```
   With `/etc/http-capability-gateway/env` containing:
   ```bash
   POLICY_PATH=/etc/http-capability-gateway/policy.yaml
   BACKEND_URL=http://backend.internal:4000
   PORT=4000
   ```
3. **Shell exports** when running interactively

---

## Policy File Setup

### Where to Put Policy Files

| Deployment | Recommended Location |
|------------|---------------------|
| Container | `/app/config/policy.yaml` (volume mount) |
| Bare-metal | `/etc/http-capability-gateway/policy.yaml` |
| Development | `config/policy.yaml` (in-repo) |

### DSL v1 Format Overview

Policy files use YAML with the DSL v1 schema. A minimal policy:

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET
    - POST
  routes:
    - path: "/api/v1/users/[0-9]+"
      verbs: [GET, PUT, DELETE]
    - path: "/health"
      verbs: [GET]
stealth:
  enabled: true
  status_code: 404
```

For the complete DSL v1 reference, including regex routes, stealth mode options,
and validation rules, see [POLICY-DSL.md](POLICY-DSL.md).

### Hot Reload via SIGHUP

Policy files are loaded at startup. To reload the policy without restarting
the gateway, send a SIGHUP signal to the BEAM process:

```bash
# Find the OS process ID (not the Erlang PID)
kill -HUP $(pidof beam.smp)
```

The gateway uses an **atomic dual-table swap** for zero-downtime reloads:

1. A new pair of ETS tables (main + regex) is compiled from the updated policy
2. If compilation succeeds, both table references are swapped atomically
3. The old tables are deleted after the swap
4. If compilation fails, the old tables remain active (no service disruption)

This guarantees that in-flight requests are never served from a partially
loaded policy.

---

## Health Checks

### Liveness: `GET /health`

Returns `200 OK` if the BEAM process is running. Does **not** check policy
loading or backend connectivity. Use this for container liveness probes.

```bash
curl -s http://localhost:4000/health | jq .
```

```json
{
  "status": "healthy",
  "service": "http-capability-gateway",
  "version": "0.1.0-dev",
  "uptime_seconds": 3600
}
```

### Readiness: `GET /ready`

Returns `200 OK` only if the policy is loaded and ETS tables are operational.
Returns `503 Service Unavailable` if the gateway is not ready to serve traffic.
Use this for container readiness probes and load balancer health checks.

```bash
curl -s http://localhost:4000/ready | jq .
```

```json
{
  "status": "ready",
  "service": "http-capability-gateway",
  "policy_rules": 12,
  "main_table_rules": 10,
  "regex_table_rules": 2,
  "rate_limiter_buckets": 42
}
```

The readiness response includes:

- `policy_rules`: Total compiled rules (main + regex tables)
- `main_table_rules`: Exact-match (O(1)) and global rules
- `regex_table_rules`: Regex pattern routes (O(r) scan)
- `rate_limiter_buckets`: Active client rate limiter entries

### Container Health Check Configuration

The Containerfile includes a built-in health check:

```
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3
  CMD wget --no-verbose --tries=1 --spider http://localhost:4000/health || exit 1
```

For Kubernetes, configure liveness and readiness probes separately:

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 4000
  initialDelaySeconds: 10
  periodSeconds: 30
readinessProbe:
  httpGet:
    path: /ready
    port: 4000
  initialDelaySeconds: 5
  periodSeconds: 10
```

---

## Monitoring

### Prometheus `/metrics` Endpoint

The gateway exposes Prometheus-format metrics at `GET /metrics`:

```bash
curl -s http://localhost:4000/metrics
```

#### Key Metrics to Watch

| Metric | Type | Description |
|--------|------|-------------|
| `http_capability_gateway_request_completed_count` | Counter | Total requests processed |
| `http_capability_gateway_request_completed_duration` | Distribution | Request duration (microseconds) |
| `http_capability_gateway_access_decision_count` | Counter | Decisions by type (`allow`/`deny`), verb, trust level |
| `http_capability_gateway_backend_forward_count` | Counter | Requests forwarded to backend |
| `http_capability_gateway_backend_response_duration` | Distribution | Backend response latency (microseconds) |
| `http_capability_gateway_error_count` | Counter | Errors by type |
| `http_capability_gateway_minikaran_anomaly_count` | Counter | Anomalies detected by type |

#### Prometheus Scrape Configuration

```yaml
scrape_configs:
  - job_name: 'http-capability-gateway'
    scrape_interval: 15s
    static_configs:
      - targets: ['gateway:4000']
    metrics_path: /metrics
```

### Minikaran Anomaly Dashboard: `GET /api/v1/minikaran`

The built-in Minikaran traffic anomaly detector provides a JSON dashboard
for monitoring unusual traffic patterns:

```bash
curl -s http://localhost:4000/api/v1/minikaran | jq .
```

```json
{
  "status": {
    "status": "active",
    "windows_collected": 42,
    "min_windows_required": 5,
    "current_anomalies": 1,
    "uptime_sec": 2520
  },
  "anomalies": [
    {
      "type": "traffic_spike",
      "path": "/api/v1/users",
      "current": 150,
      "baseline": 42.3
    }
  ],
  "baseline": {
    "window_count": 41,
    "avg_requests_per_minute": 85.2,
    "trust_distribution": {
      "untrusted": 0.6,
      "authenticated": 0.35,
      "internal": 0.05
    },
    "latency_p50_us": 1200,
    "latency_p95_us": 8500,
    "latency_p99_us": 25000,
    "avg_error_rate": 0.02,
    "known_paths": 45,
    "avg_unique_clients": 120
  }
}
```

**Anomaly types detected:**

| Type | Description |
|------|-------------|
| `traffic_spike` | Request volume z-score exceeds threshold for a path |
| `trust_shift` | Trust level distribution deviates from learned baseline |
| `latency_spike` | p95 latency exceeds baseline by significant margin |
| `path_novelty` | Unusual number of never-before-seen request paths |
| `error_spike` | Error rate exceeds learned baseline |

Minikaran requires **5+ baseline windows** (1 minute each) before anomaly
detection activates. During the learning phase, `status` will be `"learning"`.

### Log Monitoring

The gateway emits structured JSON logs suitable for ingestion by ELK,
Splunk, DataDog, or CloudWatch:

```json
{
  "timestamp": "2026-02-28T12:00:00.000Z",
  "level": "info",
  "message": "access_decision",
  "request_id": "a1b2c3d4e5f6",
  "path": "/api/v1/users/123",
  "verb": "GET",
  "trust_level": "authenticated",
  "decision": "allow",
  "duration_us": 45
}
```

---

## Security

### mTLS Setup

The gateway supports mTLS-based trust level extraction. To enable:

1. **Set `TRUST_LEVEL_SOURCE=mtls`** in your environment configuration.

2. **Configure Cowboy for TLS** in `config/prod.exs`:
   ```elixir
   config :http_capability_gateway,
     scheme: :https,
     certfile: "/app/certs/server.pem",
     keyfile: "/app/certs/server-key.pem",
     cacertfile: "/app/certs/ca.pem",
     verify: :verify_peer,
     fail_if_no_peer_cert: false
   ```

3. **Trust level mapping from certificates:**
   - `internal` -- Verified certificate with OU = "Internal Services"
   - `authenticated` -- Any verified certificate from a trusted CA
   - `untrusted` -- No certificate or verification failed

### Trust Levels and How They Work

The gateway uses a formally verified trust hierarchy
(from `proven/SafeTrust.idr`):

```
untrusted (rank 0) < authenticated (rank 1) < internal (rank 2)
```

Access decisions compare trust rank against exposure rank:

| Trust Level | Can Access Public | Can Access Authenticated | Can Access Internal |
|-------------|-------------------|-------------------------|---------------------|
| `untrusted` | Yes | No | No |
| `authenticated` | Yes | Yes | No |
| `internal` | Yes | Yes | Yes |

The monotonicity property guarantees that upgrading trust never revokes
previously granted access.

### Trust Header Spoofing Protection

By default, the gateway strips the `X-Trust-Level` header from requests
that do not originate from a trusted proxy IP. This prevents external
clients from spoofing elevated trust levels.

Configure trusted proxy IPs:

```elixir
config :http_capability_gateway,
  strip_trust_header: true,
  trusted_proxies: ["127.0.0.1", "::1", "10.0.0.1"]
```

### Rate Limiter Configuration

The token bucket rate limiter enforces per-client, per-trust-level limits:

| Trust Level | Default Rate | Default Burst |
|-------------|-------------|---------------|
| `untrusted` | 10 req/s | 10 |
| `authenticated` | 100 req/s | 100 |
| `internal` | Unlimited | Unlimited |

Override defaults in configuration:

```elixir
config :http_capability_gateway, :rate_limits, %{
  untrusted: {20, 20},        # {rate_per_sec, burst_capacity}
  authenticated: {200, 200},
  internal: :unlimited
}
```

When a client exceeds their rate limit, the gateway returns:

- **Status**: `429 Too Many Requests`
- **Header**: `Retry-After: <seconds>`
- **Body**: JSON with retry timing

Client identification uses `X-Forwarded-For` first entry (if present) or
the direct peer IP, combined with the trust level.

### OWASP Security Headers

All responses include hardened security headers:

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Cache-Control: no-store, no-cache, must-revalidate`
- `Connection: close`

---

## Troubleshooting

### Gateway Fails to Start

**Symptom**: Service exits immediately or loops in `Restart`.

**Common causes:**

1. **Missing `POLICY_PATH`**: In production, `POLICY_PATH` is required.
   ```bash
   # Check the variable is set
   echo $POLICY_PATH
   ls -la $POLICY_PATH
   ```

2. **Invalid policy file**: The gateway validates the policy at startup and
   refuses to start if validation fails.
   ```bash
   # Validate policy manually
   mix run -e 'HttpCapabilityGateway.PolicyValidator.validate_file("policy.yaml")'
   ```

3. **Port already in use**:
   ```bash
   ss -tlnp | grep 4000
   ```

4. **Check logs**:
   ```bash
   journalctl -u http-capability-gateway -n 50 --no-pager
   # Or for containers:
   podman logs http-capability-gateway
   ```

### All Requests Return 404 (Stealth Mode)

**Symptom**: Legitimate requests get `404 Not Found`.

**Causes:**

- The HTTP verb is not in `global_verbs` or the route's `verbs` list
- The request path does not match any route regex pattern
- Stealth mode is enabled, masking the actual `403` as `404`

**Debug steps:**

1. Check if the verb is allowed for the path in your policy file
2. Test path matching: regex patterns must match the full path
3. Temporarily disable stealth (`stealth.enabled: false`) to see real 403s
4. Verify with the readiness endpoint that rules are loaded:
   ```bash
   curl -s http://localhost:4000/ready | jq .policy_rules
   ```

### 429 Too Many Requests

**Symptom**: Clients receiving rate limit errors.

**Causes:**

- Client exceeding per-trust-level rate limit
- Multiple clients behind the same proxy IP sharing a bucket

**Solutions:**

- Check the `Retry-After` header for when the client can retry
- Increase rate limits in configuration for the affected trust level
- Ensure `X-Forwarded-For` is set correctly by upstream proxies so
  clients behind a shared IP get separate buckets

### 503 Circuit Breaker Open

**Symptom**: Requests return `503 Service Unavailable` with "Circuit breaker open".

**Cause**: The backend has exceeded the breach threshold configured in K9-SVC
contracts, causing the circuit breaker to open.

**Resolution:**

- Check backend health: the circuit breaker will automatically probe with
  half-open requests after the configured timeout
- Check Minikaran dashboard for latency spikes: `GET /api/v1/minikaran`
- If the backend is healthy, the circuit breaker will recover automatically

### 503 Service Configuration Unavailable

**Symptom**: All requests return `503` with "Service configuration unavailable".

**Cause**: The policy table is nil, meaning policy compilation failed or the
gateway is still starting up.

**Resolution:**

- Check startup logs for policy validation errors
- Verify the policy file syntax and content
- Ensure `POLICY_PATH` points to a valid DSL v1 YAML file

### Backend Connection Errors

**Symptom**: Allowed requests fail during proxying.

**Debug steps:**

```bash
# Test backend connectivity from the gateway host
curl -v $BACKEND_URL/health

# Check DNS resolution
nslookup backend.internal

# Check gateway logs for proxy errors
journalctl -u http-capability-gateway | grep -i proxy
```

### High Memory Usage

**Symptom**: Gateway process consuming excessive memory.

**Possible causes:**

1. Very large policy file (10,000+ routes) expanding ETS tables
2. Large number of unique client IPs filling rate limiter buckets
3. Minikaran sliding window accumulating observations

**Mitigation:**

```bash
# Check ETS table sizes via remote console
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway remote
> :ets.info(:rate_limiter_buckets, :size)
> :ets.info(:minikaran_observations, :size)

# Reset rate limiter buckets if needed
> HttpCapabilityGateway.RateLimiter.reset()
```

---

## Support

- **Issues**: <https://github.com/hyperpolymath/http-capability-gateway/issues>
- **Discussions**: <https://github.com/hyperpolymath/http-capability-gateway/discussions>
