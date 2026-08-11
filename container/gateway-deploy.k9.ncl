K9!
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# container/gateway-deploy.k9.ncl
# http-capability-gateway — k9-svc deployment component (Hunt level)
#
# Phase E E1 deliverable for the BoJ tier-2 wiring channel
# (hyperpolymath/standards#91; Phase E = standards#100).
#
# The wider integration plan (boj-server `docs/integration/
# http-capability-gateway-plan.md` § Phase E, E1) prescribes this exact
# path. Until this file existed, the gateway-side §1.5 prereq in the
# rollout runbook (boj-server `docs/integration/hcg-tier2-rollout-runbook.md`)
# was an open checkbox; landing it flips that single prereq, and only
# that prereq — staging soak (§2), production split (§3) and the
# Trustfile flip (§6.4) remain owner-driven follow-ups gated on real
# infrastructure.
#
# Security Level: 'Hunt (requires cryptographic handshake for execution).
#
# WARNING: This component can execute shell commands when invoked
# through k9-svc. It declares intent only; the Hunt-handshake gate
# enforces authorisation at deploy time.
#
# Usage:
#   nickel typecheck container/gateway-deploy.k9.ncl
#   k9-svc validate container/gateway-deploy.k9.ncl
#   k9-svc deploy container/gateway-deploy.k9.ncl --env staging

# ─────────────────────────────────────────────────────────────────────
# Deployment configuration
# ─────────────────────────────────────────────────────────────────────
#
# Backend transport is sourced from the Phase A contract document
# (boj-server `docs/integration/http-capability-gateway-boj-contract.md`
# § 1, Transport): staging uses TCP loopback to BoJ on :7700,
# production uses a loopback Unix domain socket. The wire-form
# BACKEND_URL is composed from the `backend` block at deploy time —
# the contract document is the canonical source for the literal
# URL form (intentionally plain loopback per contract § 7: the
# mTLS boundary is client → gateway, the gateway → BoJ hop is
# loopback-isolated and does not require TLS).
#
# Trust source defaults to `"header"` per plan § E2 ("Trust level
# source: \"header\" initially, switched to \"mtls\" after Phase B
# cert rotation runbook is exercised"). The switch to `"mtls"` is a
# config flip, not a code change; it happens at the §2.4 rehearsal.
let deployment = {
  environments = {
    staging = {
      replicas = 1,
      memory = "512Mi",
      cpu = "250m",
      image_tag = "staging",
      # Phase A contract § 1: staging gateway → BoJ over TCP loopback
      # on :7700. Wire-form URL composed at deploy time; see contract.
      backend = {
        transport = "tcp_loopback",
        host = "127.0.0.1",
        port = 7700,
      },
      # Plan § E2: external port is gateway-owned, TLS for direct, or
      # 8080 when fronted by a Cloudflare Tunnel.
      port = 8443,
      trust_level_source = "header",
    },
    production = {
      replicas = 1,
      memory = "1Gi",
      cpu = "500m",
      image_tag = "latest",
      # Phase A contract § 1: production gateway → BoJ over a loopback
      # Unix domain socket; the back-side TCP port is not opened.
      backend = {
        transport = "unix_socket_loopback",
        socket_path = "/run/boj/gnosis.sock",
      },
      port = 8443,
      # Production trust source: Phase B mTLS (http-capability-gateway#10).
      # Flipped from `"header"` after the §2.4 staging cert-rotation
      # rehearsal completes per the rollout runbook.
      trust_level_source = "mtls",
    },
  },

  container = {
    # Image is built from the in-tree Containerfile (multi-stage
    # release build). Cerro-torre signing into a `.ctp` bundle is the
    # remaining § 1.5 prereq tracked on standards#100; the bundle name
    # is `http-capability-gateway` regardless of registry destination.
    image = "ghcr.io/hyperpolymath/http-capability-gateway",
    # Container listens on 4000 internally (Containerfile EXPOSE 4000);
    # the environment's `port` above is the externally bound port.
    internal_port = 4000,
    health_check = "/health",
    readiness_check = "/ready",
    metrics_path = "/metrics",
  },

  # Environment variables consumed by `config/runtime.exs`. Paths
  # marked `!OWNER:` in the rollout runbook § 1.3 are supplied at
  # deploy time, not committed here. `BACKEND_URL` is composed from
  # the per-environment `backend` block at deploy time per the wire
  # form in the Phase A contract § 1; it is not inlined here so the
  # canonical wire form lives in exactly one place (the contract).
  env = {
    POLICY_PATH = "/etc/http-capability-gateway/policy.yaml",
    BACKEND_URL = "<composed from environments[<env>].backend per contract § 1>",
    PORT = "<from environments[<env>].port>",
    TRUST_LEVEL_SOURCE = "<from environments[<env>].trust_level_source>",
    # mTLS material — owner-provided at deploy time per rollout
    # runbook § 1.3. The keys are declared here so a missing value
    # fails the deploy precheck rather than silently disabling mTLS.
    MTLS_CA_CERT_PATH = "<owner-provided>",
    GATEWAY_CERT_PATH = "<owner-provided>",
    GATEWAY_KEY_PATH = "<owner-provided>",
  },

  # Mounts: the policy YAML is delivered into the container read-only
  # per the policy-authoring workflow (boj-server `docs/integration/
  # http-capability-gateway-policy-authoring.md` § 3).
  mounts = [
    {
      name = "gateway-policy",
      source = "boj-server:config/gateway-policy-boj.yaml",
      target = "/etc/http-capability-gateway/policy.yaml",
      read_only = true,
    },
    {
      name = "mtls-material",
      source = "<owner-provided secret>",
      target = "/etc/http-capability-gateway/tls",
      read_only = true,
    },
  ],

  # Rolling strategy with max_unavailable = 0 preserves the
  # gateway's atomic policy-swap guarantee across replica churn:
  # a new replica with a new policy comes up before an old replica
  # is drained.
  strategy = {
    type = "rolling",
    max_surge = 1,
    max_unavailable = 0,
  },

  # Failure mode contract: the gateway↔BoJ seam declares
  # `failure_mode: "fail-closed (circuit breaker)"` in the BoJ
  # `Trustfile.a2ml [SEAMS]` entry. If the BoJ backend becomes
  # unreachable the gateway's circuit breaker trips and returns 503;
  # this deployment spec does not paper over that with a retry loop.
  failure_mode = "fail-closed",
} in

# ─────────────────────────────────────────────────────────────────────
# Deployment scripts (executed at Hunt level)
# ─────────────────────────────────────────────────────────────────────
#
# Shell-level recipes. The substantive logic lives in `Justfile`
# (`just container-build`, `just container-up`) so these scripts are
# thin orchestration. The pre-deploy script enforces that the policy
# file mounted into the container loads + validates cleanly before
# any traffic shift — the same `PolicyLoader.load_policy/1` +
# `PolicyValidator.validate/1` pair the gateway runs at startup, so a
# malformed policy never reaches a running container.
let scripts = {
  pre_deploy = m%"
#!/bin/sh
set -eu
echo "K9: Pre-deployment validation for http-capability-gateway..."
just container-verify
just policy-validate "${POLICY_FILE:-config/policy.yaml}"
echo "K9: Validation passed."
"%,

  deploy = m%"
#!/bin/sh
set -eu
ENV="${1:-staging}"
echo "K9: Deploying http-capability-gateway to $ENV environment..."
just container-build
just container-up
echo "K9: Deployment to $ENV complete."
"%,

  rollback = m%"
#!/bin/sh
set -eu
echo "K9: Rolling back http-capability-gateway deployment..."
just container-down
echo "K9: Rollback complete (immediate-bypass)."
echo "K9: See boj-server docs/integration/hcg-tier2-rollout-runbook.md § 5"
echo "K9: for the full rollback procedure (immediate vs permanent)."
"%,
} in

# ─────────────────────────────────────────────────────────────────────
# Top-level k9-svc component
# ─────────────────────────────────────────────────────────────────────
#
# `pedigree` is inlined at the top level so the canonical
# hyperpolymath/k9-validate-action regex finds
#   pedigree = { … metadata = { name = …, version = … } … }
# without traversing `let` bindings — same shape as the boj-server
# reference (`container/deploy.k9.ncl`).
{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "deployment-component",
    # L1: Snout — identity
    metadata = {
      name = "http-capability-gateway-deploy",
      version = "0.1.0",
      breed = "application/vnd.k9+nickel",
      magic_number = "K9!",
      description = "http-capability-gateway tier-2 deployment component (Hunt level)",
    },
    # L2: Scent — target environment
    target = {
      os = 'Linux,
      is_edge = false,
      requires_podman = true,
      min_memory_mb = 512,
    },
    # L3: Leash — security
    security = {
      leash = 'Hunt,
      trust_level = 'Hunt,
      allow_network = true,
      allow_filesystem_write = true,
      allow_subprocess = true,
      # Real Ed25519 signature is added at bundle-signing time
      # (cerro-torre `.ctp` step, rollout runbook § 1.5).
      signature = "PLACEHOLDER-SIGNATURE-REQUIRED-FOR-HUNT",
    },
    # L4: Gut — self-validation
    validation = {
      checksum = "sha256:placeholder",
      pedigree_version = "1.0.0",
      hunt_authorized = false,
    },
    # L5: Muscle — deployment recipes
    recipes = {
      install = "just container-build",
      validate = "just container-verify",
      deploy = "just container-up",
      migrate = "just container-build && just container-up",
    },
  },

  deployment = deployment,
  scripts = scripts,

  required_level = 'Hunt,

  warning = m%"
WARNING: This is a Hunt-level component.

It can execute shell commands and modify your system.
Before running, ensure you have:

1. Reviewed the deployment scripts above.
2. Verified the signature (added at cerro-torre `.ctp` signing).
3. Explicitly authorised Hunt-level execution.

Run with:
  k9-svc authorize container/gateway-deploy.k9.ncl &&
  k9-svc deploy container/gateway-deploy.k9.ncl

The rollback procedure is in boj-server docs/integration/
hcg-tier2-rollout-runbook.md § 5; the script in this file only
covers the immediate-bypass step.
"%,
}
