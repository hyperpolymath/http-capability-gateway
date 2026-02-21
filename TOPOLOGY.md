<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-02-19 -->

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
                        └──────────┬───────────────────┬──────────┘
                                   │                   │
                                   ▼                   ▼
                        ┌───────────────────────┐  ┌────────────────────────────────┐
                        │ POLICY ENGINE         │  │ LOGGING & AUDIT                │
                        │ - Loader (DSL v1)     │  │ - Decision Context             │
                        │ - Validator           │  │ - Structured JSON Logs         │
                        │ - Compiler            │  │ - Narrative Metadata           │
                        └──────────┬────────────┘  └──────────┬─────────────────────┘
                                   │                          │
                                   └────────────┬─────────────┘
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
  Compiler                          ██████████ 100%    Rule compilation active
  Enforcement Engine                ██████████ 100%    Verb gating verified

INTERFACES & LOGS
  HTTP Proxy Layer                  ████████░░  80%    Scaling logic refining
  Structured JSON Logs              ██████████ 100%    Audit-grade logs stable
  Stealth Profiles                  ██████░░░░  60%    Limited profile active

REPO INFRASTRUCTURE
  Justfile Automation               ██████████ 100%    Standard build/run tasks
  .machine_readable/                ██████████ 100%    STATE.adoc tracking
  Docker Compose                    ██████████ 100%    Full stack deployment

─────────────────────────────────────────────────────────────────────────────
OVERALL:                            █████████░  ~90%   MVP stable and functional
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
