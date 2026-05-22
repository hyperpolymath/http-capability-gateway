<!-- SPDX-License-Identifier: MPL-2.0 -->

# Scoped Deployment Guide

**Recommendation status:** Required for v0.1.0 — do NOT front the entire
application surface with this gateway at v0.1.0.

## Why Scoped Deployment

The HTTP Capability Gateway at v0.1.0 is a **narrow verb-governance
prefilter**, not a general-purpose API gateway. The roadmap (`ROADMAP.adoc`
P2) explicitly says:

> Use the gateway in front of selected API routes first, not the whole
> application surface.

> Keep the runtime role constrained to prefiltering before origin-side
> enforcement.

The rationale is simple: the gateway has not yet been hardened for the
full range of protocols, trust sources, and failure modes that a
universal front-door must handle. Deploying it in front of a few
high-value API routes is **provable and reversible**. Deploying it in
front of your entire origin is neither.

## The Scoped-Deployment Pattern

```
                 Client
                    │
                    ▼
         ┌──────────────────────┐
         │ TLS-terminating      │   Existing edge (nginx / Caddy / Svalinn / CDN)
         │ reverse proxy        │
         └──────────┬───────────┘
                    │
            ┌───────┴─────────┐
            │                 │
 governed routes      everything else
 (e.g. /api/admin,    (static assets, public HTML, unmeasured APIs)
  /api/users,
  /api/billing)
            │                 │
            ▼                 ▼
 ┌──────────────────┐  ┌──────────────────┐
 │ http-capability- │  │ Origin service   │
 │ gateway          │──► directly           │
 │ (verb filter)    │  │                  │
 └──────────────────┘  └──────────────────┘
```

Traffic for **selected** routes is routed through the gateway first, where
verb governance, rate limiting, stealth responses, and circuit breaking
apply. All other traffic bypasses the gateway entirely.

## Choosing the Selected Routes

Good candidates for initial scoped deployment:

| Characteristic | Why it's a good fit |
|----------------|---------------------|
| Verb-sensitive | Some verbs should be `internal` only (e.g., `DELETE /api/users/:id`). |
| Rate-abusable | Login, signup, search — clear token-bucket value. |
| Low traffic volume (but high value) | Observable quickly; failures affect a small blast radius. |
| Already behind authentication | Trust levels can be supplied by your existing auth edge. |
| Non-streaming | The gateway does not yet support WebSocket or long-lived streaming. |

Poor candidates for initial deployment:

- Static asset delivery (no governance benefit, added latency)
- WebSocket / server-sent-events endpoints (not supported)
- GraphQL or gRPC endpoints (handlers are stubs — see `SUPPORTED-FEATURES.md`)
- Anything requiring TLS termination by this gateway
- Multi-backend load-balanced routes (the gateway has one backend per policy)

## Example: Putting the Gateway In Front of `/api/admin/*` Only

In your edge proxy (nginx example):

```nginx
# Governed routes → http-capability-gateway
location /api/admin/ {
    proxy_pass http://http-capability-gateway:4000;
    proxy_set_header X-Trust-Level $auth_level_from_auth_module;
    proxy_set_header X-Forwarded-For $remote_addr;
}

# Everything else → origin directly
location / {
    proxy_pass http://origin:8080;
}
```

Corresponding minimal gateway policy:

```yaml
dsl_version: "1"

governance:
  global_verbs: []
  routes:
    - path: "/api/admin/users"
      verbs: ["GET"]
      exposure: "authenticated"
      backend: "http://origin:8080"
    - path: "/api/admin/users/[0-9]+"
      verbs: ["GET", "PUT", "DELETE"]
      exposure: "internal"
      backend: "http://origin:8080"

stealth:
  enabled: true
  status_code: 404
```

The gateway covers three routes; everything else is served by the origin
directly and is unaffected by any gateway bug, regex ReDoS, or policy
reload error.

## Rollback Plan

Because only selected routes are governed, rolling back is a single config
change in your edge proxy:

```nginx
location /api/admin/ {
    # Skip gateway — route directly to origin.
    proxy_pass http://origin:8080;
}
```

No gateway code is in the request path, and no other routes are affected.
This is the key property that scoped deployment preserves.

## Migration Path to Broader Deployment

Once v0.1.0 has been running in production on a scoped set of routes for
long enough to gain confidence (think weeks, not hours), consider widening
the scope:

1. Add more routes to the policy, one group at a time.
2. Monitor `/metrics` for rate-limit hits, circuit breaker trips, and
   `access_decision` telemetry.
3. Only expand to protocols or trust sources that have moved out of the
   "stub only" / "caveats" rows of `docs/SUPPORTED-FEATURES.md`.
4. Revisit this document once the gateway is verified for broader scope;
   its recommendations WILL loosen over time as features graduate.

## When to NOT Use This Gateway at All

If your traffic is primarily:

- WebSocket or long-lived streaming
- gRPC or GraphQL (and you need real governance, not stubs)
- TLS-terminated by the gateway itself
- Multi-backend load balancing

...then this gateway is not the right tool for v0.1.0. Consider Envoy,
Kong, Traefik, or AWS API Gateway. This project is intentionally scoped
narrower than those, and forcing it into their role would reintroduce the
"97% production-ready" overclaim that release criteria now forbid.
