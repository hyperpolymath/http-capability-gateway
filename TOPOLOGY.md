<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-02-28 -->

# http-capability-gateway — Project Topology

## System Architecture

```
                        ┌─────────────────────────────────────────┐
                        │              HTTP TRAFFIC               │
                        │        (GET, POST, DELETE, etc.)        │
                        └───────────────────┬─────────────────────┘
                                            │
                                            ▼
                        ┌─────────────────────────────────────────┐
                        │           GATEWAY CORE (ELIXIR)         │
                        │    (Governance Layer / Enforcement)     │
                        │                                         │
                        │  ┌─────────────────────────────────┐    │
                        │  │  Security Headers Plug           │    │
                        │  │  (OWASP: nosniff, DENY, etc.)   │    │
                        │  └─────────────────────────────────┘    │
                        └──────────┬───────────────────┬──────────┘
                                   │                   │
                                   ▼                   ▼
                        ┌───────────────────────┐  ┌────────────────────────────────┐
                        │ POLICY ENGINE         │  │ LOGGING & AUDIT                │
                        │ - Loader (DSL v1)     │  │ - Decision Context             │
                        │ - Validator           │  │ - Structured JSON Logs         │
                        │ - Compiler (Tiered)   │  │ - Narrative Metadata           │
                        │   T1: Exact O(1)      │  │ - Telemetry Events             │
                        │   T2: Regex O(r)      │  └──────────┬─────────────────────┘
                        │   T3: Global O(1)     │              │
                        └──────────┬────────────┘              │
                                   │                           │
                                   └────────────┬──────────────┘
                                                ▼
                        ┌─────────────────────────────────────────┐
                        │           UPSTREAM SERVICES             │
                        │      (Nginx, Apache, App Servers)       │
                        └─────────────────────────────────────────┘

                        ┌─────────────────────────────────────────┐
                        │          REPO INFRASTRUCTURE            │
                        │  Justfile / mix.exs .machine_readable/  │
                        │  Mustfile / Docker  0-AI-MANIFEST.a2ml  │
                        └─────────────────────────────────────────┘
```

## Completion Dashboard

```
COMPONENT                          STATUS              NOTES
─────────────────────────────────  ──────────────────  ─────────────────────────────────
CORE GATEWAY
  Policy Loader (DSL v1)            ██████████ 100%    YAML spec parsing stable
  Validator                         ██████████ 100%    Schema validation verified
  Compiler (Tiered Lookup)          ██████████ 100%    O(1) exact + O(r) regex + O(1) global
  Enforcement Engine                ██████████ 100%    Verb gating verified
  Security Headers                  ██████████ 100%    OWASP hardened (nosniff, DENY, etc.)

INTERFACES & LOGS
  HTTP Proxy Layer                  ████████░░  80%    Scaling logic refining
  Structured JSON Logs              ██████████ 100%    Audit-grade logs stable
  Stealth Profiles                  ██████░░░░  60%    Limited profile active
  Prometheus Metrics                ██████████ 100%    Telemetry export active

HEALTH & TRUST
  Health Check (/health)            ██████████ 100%    Uptime, version, status
  Readiness Check (/ready)          ██████████ 100%    Policy + ETS validation
  mTLS Trust Extraction             ██████████ 100%    Certificate-based trust levels
  Trust Header Extraction           ██████████ 100%    X-Trust-Level header support

REPO INFRASTRUCTURE
  Justfile Automation               ██████████ 100%    Standard build/run tasks
  .machine_readable/                ██████████ 100%    STATE.scm tracking
  Containerfile                     ██████████ 100%    Chainguard-based deployment

─────────────────────────────────────────────────────────────────────────────
OVERALL:                            █████████░  ~97%   Production-ready, optimised
```

## Key Dependencies

```
Policy Spec (DSL) ───► Validator ───► Compiler ───► Rule Table
                                                      │
                                                      ▼
HTTP Traffic ───────► Enforcement ───────────────► Forward / Block
```

## Update Protocol

This file is maintained by both humans and AI agents. When updating:

1. **After completing a component**: Change its bar and percentage
2. **After adding a component**: Add a new row in the appropriate section
3. **After architectural changes**: Update the ASCII diagram
4. **Date**: Update the `Last updated` comment at the top of this file

Progress bars use: `█` (filled) and `░` (empty), 10 characters wide.
Percentages: 0%, 10%, 20%, ... 100% (in 10% increments).
