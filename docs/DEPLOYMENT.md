# Deployment Guide

Complete guide for deploying HTTP Capability Gateway to production environments.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Environment Setup](#environment-setup)
3. [Configuration](#configuration)
4. [Deployment Methods](#deployment-methods)
5. [Monitoring](#monitoring)
6. [Troubleshooting](#troubleshooting)
7. [Production Checklist](#production-checklist)

## Prerequisites

### System Requirements

- **Elixir**: 1.19+
- **Erlang/OTP**: 27+
- **OS**: Linux (recommended), macOS, or Windows
- **RAM**: Minimum 512MB, recommended 2GB+
- **CPU**: 2+ cores recommended for production

### Network Requirements

- Outbound HTTPS access (for backend proxy)
- Inbound access on configured port (default: 8080)
- DNS resolution for backend services

### Dependencies

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y build-essential git curl

# Install Elixir + Erlang via asdf (recommended)
git clone https://github.com/asdf-vm/asdf.git ~/.asdf
echo '. $HOME/.asdf/asdf.sh' >> ~/.bashrc
source ~/.bashrc

asdf plugin add erlang
asdf plugin add elixir

asdf install erlang 27.0
asdf install elixir 1.19.0-otp-27

asdf global erlang 27.0
asdf global elixir 1.19.0-otp-27
```

## Environment Setup

### Production Environment Variables

Create `/etc/environment.d/http-capability-gateway.conf`:

```bash
# Policy Configuration
POLICY_FILE=/opt/http-capability-gateway/config/policy.yaml

# Backend Configuration
BACKEND_URL=https://backend.internal:8443

# Network Configuration
PORT=8080
BIND_ADDRESS=0.0.0.0

# Trust Level Configuration
TRUST_LEVEL_HEADER=x-trust-level

# Logging
LOG_LEVEL=info
LOG_FORMAT=json

# Observability
ENABLE_TELEMETRY=true
TELEMETRY_PORT=9568
```

### Directory Structure

```bash
sudo mkdir -p /opt/http-capability-gateway
sudo mkdir -p /var/log/http-capability-gateway
sudo mkdir -p /etc/http-capability-gateway

# Set ownership
sudo chown -R app-user:app-user /opt/http-capability-gateway
sudo chown -R app-user:app-user /var/log/http-capability-gateway
```

## Configuration

### Policy Configuration

Create `/etc/http-capability-gateway/policy.yaml`:

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET
    - POST
  routes:
    - path: "/api/v1/admin"
      verbs: [GET]
    - path: "/api/v1/users/[0-9]+"
      verbs: [GET, PUT, DELETE]
    - path: "/api/v1/posts"
      verbs: [GET, POST]
    - path: "/api/v1/health"
      verbs: [GET]
    - path: "/api/v1/metrics"
      verbs: [GET]
stealth:
  enabled: true
  status_code: 404
```

### Elixir Release Configuration

Edit `config/prod.exs`:

```elixir
import Config

config :http_capability_gateway,
  policy_file: System.get_env("POLICY_FILE") || "/etc/http-capability-gateway/policy.yaml",
  backend_url: System.fetch_env!("BACKEND_URL"),
  port: String.to_integer(System.get_env("PORT", "8080")),
  bind_address: System.get_env("BIND_ADDRESS", "0.0.0.0"),
  trust_level_header: System.get_env("TRUST_LEVEL_HEADER", "x-trust-level"),
  log_level: String.to_atom(System.get_env("LOG_LEVEL", "info"))

config :logger,
  level: :info,
  backends: [:console],
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

config :logger, :console,
  format: {HttpCapabilityGateway.LogFormatter, :format},
  metadata: [:request_id, :trust_level]
```

## Deployment Methods

### Method 1: Elixir Release (Recommended)

#### Build Release

```bash
cd /opt/http-capability-gateway

# Set environment
export MIX_ENV=prod

# Get dependencies
mix deps.get --only prod

# Compile
mix compile

# Build release
mix release

# Release will be in _build/prod/rel/http_capability_gateway/
```

#### Run Release

```bash
# Start in foreground
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway start

# Start as daemon
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway daemon

# Check status
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway pid

# Stop
_build/prod/rel/http_capability_gateway/bin/http_capability_gateway stop
```

#### Systemd Service

Create `/etc/systemd/system/http-capability-gateway.service`:

```ini
[Unit]
Description=HTTP Capability Gateway
After=network.target

[Service]
Type=forking
User=app-user
Group=app-user
WorkingDirectory=/opt/http-capability-gateway
EnvironmentFile=/etc/environment.d/http-capability-gateway.conf
ExecStart=/opt/http-capability-gateway/_build/prod/rel/http_capability_gateway/bin/http_capability_gateway daemon
ExecStop=/opt/http-capability-gateway/_build/prod/rel/http_capability_gateway/bin/http_capability_gateway stop
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/http-capability-gateway

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable http-capability-gateway
sudo systemctl start http-capability-gateway
sudo systemctl status http-capability-gateway
```

### Method 2: Docker Container

#### Dockerfile

```dockerfile
# SPDX-License-Identifier: PMPL-1.0-or-later
FROM elixir:1.19-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache build-base git

# Copy dependency files
COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force

# Install dependencies
ENV MIX_ENV=prod
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application files
COPY lib ./lib
COPY config ./config
COPY priv ./priv

# Build release
RUN mix release

# Runtime stage
FROM alpine:3.19

RUN apk add --no-cache openssl ncurses-libs libstdc++

WORKDIR /app

# Create non-root user
RUN addgroup -g 1000 app && \
    adduser -D -u 1000 -G app app

# Copy release from builder
COPY --from=builder --chown=app:app /app/_build/prod/rel/http_capability_gateway ./

# Switch to non-root user
USER app

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Start command
CMD ["bin/http_capability_gateway", "start"]
```

#### Build and Run

```bash
# Build image
docker build -t http-capability-gateway:0.1.0 .

# Run container
docker run -d \
  --name http-capability-gateway \
  -p 8080:8080 \
  -e POLICY_FILE=/app/config/policy.yaml \
  -e BACKEND_URL=https://backend:8443 \
  -v /etc/http-capability-gateway/policy.yaml:/app/config/policy.yaml:ro \
  http-capability-gateway:0.1.0

# Check logs
docker logs -f http-capability-gateway

# Stop
docker stop http-capability-gateway
```

#### Docker Compose

```yaml
# docker-compose.yml
version: '3.8'

services:
  gateway:
    image: http-capability-gateway:0.1.0
    build: .
    ports:
      - "8080:8080"
    environment:
      POLICY_FILE: /app/config/policy.yaml
      BACKEND_URL: http://backend:4000
      PORT: 8080
      LOG_LEVEL: info
    volumes:
      - ./priv/config/policy.prod.yaml:/app/config/policy.yaml:ro
      - gateway-logs:/var/log/http-capability-gateway
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--spider", "http://localhost:8080/health"]
      interval: 30s
      timeout: 3s
      retries: 3

volumes:
  gateway-logs:
```

Start with Docker Compose:

```bash
docker-compose up -d
docker-compose logs -f gateway
```

### Method 3: Kubernetes Deployment

#### Deployment Manifest

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: http-capability-gateway
  labels:
    app: http-capability-gateway
spec:
  replicas: 3
  selector:
    matchLabels:
      app: http-capability-gateway
  template:
    metadata:
      labels:
        app: http-capability-gateway
    spec:
      containers:
      - name: gateway
        image: http-capability-gateway:0.1.0
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: POLICY_FILE
          value: /config/policy.yaml
        - name: BACKEND_URL
          valueFrom:
            configMapKeyRef:
              name: gateway-config
              key: backend_url
        - name: PORT
          value: "8080"
        - name: LOG_LEVEL
          value: info
        volumeMounts:
        - name: policy
          mountPath: /config
          readOnly: true
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: policy
        configMap:
          name: gateway-policy
---
apiVersion: v1
kind: Service
metadata:
  name: http-capability-gateway
spec:
  selector:
    app: http-capability-gateway
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
  type: LoadBalancer
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-policy
data:
  policy.yaml: |
    dsl_version: "1"
    governance:
      global_verbs:
        - GET
        - POST
      routes:
        - path: "/api/admin"
          verbs: [GET]
    stealth:
      enabled: true
      status_code: 404
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-config
data:
  backend_url: "http://backend-service:8080"
```

Deploy to Kubernetes:

```bash
kubectl apply -f k8s/deployment.yaml
kubectl get pods -l app=http-capability-gateway
kubectl logs -f deployment/http-capability-gateway
```

## Monitoring

### Health Checks

```bash
# HTTP health check
curl http://localhost:8080/health
# Expected: 200 OK

# Check logs for errors
journalctl -u http-capability-gateway -f

# Docker logs
docker logs -f http-capability-gateway
```

### Telemetry Metrics

The gateway emits telemetry events for:
- Request handling (count, duration)
- Verb enforcement (allowed/denied)
- Backend proxy (latency, errors)

Integrate with Prometheus, DataDog, or other observability platforms.

### Log Monitoring

Structured JSON logs can be ingested by:
- **ELK Stack** (Elasticsearch, Logstash, Kibana)
- **Splunk**
- **DataDog**
- **CloudWatch Logs** (AWS)

Example log entry:

```json
{
  "timestamp": "2026-01-22T23:00:00.000Z",
  "level": "info",
  "message": "request_handled",
  "request_id": "req-abc123",
  "method": "GET",
  "path": "/api/users/123",
  "verb_allowed": true,
  "response_status": 200,
  "duration_ms": 45
}
```

## Troubleshooting

### Gateway Won't Start

**Symptom**: Gateway fails to start

**Possible Causes**:
1. Policy file not found or invalid
2. Backend URL not configured
3. Port already in use

**Solutions**:

```bash
# Check policy file exists
ls -la $POLICY_FILE

# Validate policy
mix run -e "HttpCapabilityGateway.PolicyValidator.validate_file(System.fetch_env!(\"POLICY_FILE\"))"

# Check port availability
sudo netstat -tlnp | grep 8080

# Check logs
journalctl -u http-capability-gateway -n 50
```

### Requests Getting 404 (Stealth Mode)

**Symptom**: All requests return 404

**Possible Causes**:
1. Verb not in global_verbs or route config
2. Path not matching route regex

**Solutions**:

```bash
# Check compiled policy
iex -S mix
> HttpCapabilityGateway.PolicyCompiler.get_global_verbs()
> HttpCapabilityGateway.PolicyCompiler.is_verb_allowed?("/api/users", "GET")

# Check logs for verb_allowed=false
journalctl -u http-capability-gateway | grep '"verb_allowed":false'
```

### Backend Connection Issues

**Symptom**: Gateway returns errors for proxied requests

**Possible Causes**:
1. Backend URL misconfigured
2. Network connectivity issues
3. Backend not responding

**Solutions**:

```bash
# Test backend connectivity from gateway host
curl -v $BACKEND_URL/health

# Check DNS resolution
nslookup backend.internal

# Check gateway logs
journalctl -u http-capability-gateway | grep proxy_error
```

### High Memory Usage

**Symptom**: Gateway using excessive memory

**Possible Causes**:
1. Very large policy (10,000+ routes)
2. Memory leak

**Solutions**:

```bash
# Check policy size
wc -l $POLICY_FILE

# Monitor Erlang VM memory
iex -S mix
> :erlang.memory()

# Restart gateway to clear memory
sudo systemctl restart http-capability-gateway
```

## Production Checklist

### Pre-Deployment

- [ ] Policy file validated
- [ ] Backend URL configured and tested
- [ ] Stealth mode configured appropriately
- [ ] Log level set to `info` or `warn`
- [ ] Environment variables configured
- [ ] TLS/SSL certificates in place (if terminating TLS)
- [ ] Firewall rules configured
- [ ] Resource limits set (systemd, Docker, K8s)

### Post-Deployment

- [ ] Health check endpoint responding
- [ ] Test requests succeed for allowed verbs
- [ ] Test requests fail (stealth) for denied verbs
- [ ] Logs are being collected
- [ ] Metrics are being collected
- [ ] Alerts configured for errors
- [ ] Backup of policy file

### Security

- [ ] Run as non-root user
- [ ] SELinux/AppArmor enabled (if applicable)
- [ ] Secrets not in environment variables (use secrets management)
- [ ] Network segmentation (gateway ↔ backend only)
- [ ] Rate limiting configured (future feature)
- [ ] mTLS for backend connections (future feature)

### Performance

- [ ] Load testing completed
- [ ] Latency acceptable (< 50ms p99)
- [ ] Throughput meets requirements
- [ ] Resource usage within limits
- [ ] Horizontal scaling tested (K8s)

## Updates and Rollbacks

### Rolling Update (Kubernetes)

```bash
# Update image
kubectl set image deployment/http-capability-gateway gateway=http-capability-gateway:0.2.0

# Check rollout status
kubectl rollout status deployment/http-capability-gateway

# Rollback if needed
kubectl rollout undo deployment/http-capability-gateway
```

### Blue-Green Deployment

1. Deploy new version alongside old
2. Test new version with subset of traffic
3. Switch traffic to new version
4. Monitor for issues
5. Decommission old version or rollback

## Support

For deployment issues:
- **GitHub Issues**: https://github.com/hyperpolymath/http-capability-gateway/issues
- **Discussions**: https://github.com/hyperpolymath/http-capability-gateway/discussions
