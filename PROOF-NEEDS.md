# SPDX-License-Identifier: CC-BY-SA-4.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

# Proof Needs (echo-types audit)

This file records cross-repo proof obligations relevant to this repository,
including an explicit echo-types audit per estate convention
(`feedback_proofs_must_check_and_cross_doc_echo_types.md`).

## Echo-types

**Status: record-as-not-relevant (2026-06-02).**

`hyperpolymath/echo-types` was audited for relevant existing proofs that
this repository should reuse or extend. Findings:

- The trust hierarchy already has a mechanised proof in
  `proven/SafeTrust.idr` (referenced from `lib/http_capability_gateway/safe_trust.ex`).
- No L3 (echo) obligation is in scope for the gateway: the gateway does not
  participate in any echo protocol; it terminates inbound HTTP and forwards
  to a single backend.
- The new `EgressPolicy` module's decision function is a pure first-order
  predicate (host + verb membership in an allowlist). It does not interact
  with echo types.

**Action:** none. Re-check this entry when egress acquires a
chimichanga-attenuation seam (#84-3 follow-up); attenuation may bring an
L3 obligation into scope at that point.

## SafeTrust monotonicity

Already mechanised in `proven/SafeTrust.idr` (Idris2). The Elixir
implementation in `lib/http_capability_gateway/safe_trust.ex` mirrors the
specification one-to-one. No new proof debt added by this PR.

## EgressPolicy

The egress policy decision function `EgressPolicy.decide/3` is small enough
to mechanise (membership in a list of host+verb pairs). Filing as proof
debt for a future PR; not blocking egress scaffold landing.
