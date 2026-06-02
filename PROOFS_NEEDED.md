# PROOF-NEEDS.md — http-capability-gateway

## Current State

- **src/abi/*.idr**: YES — `Protocol.idr`, `Types.idr`, `MTLSPolicy.idr` (obligation stub)
- **Dangerous patterns**: 0 (`believe_me` reference in Protocol.idr is documentation only)
- **LOC**: ~9,500
- **ABI layer**: Idris2 definitions present

## What Needs Proving

| Component | What | Why |
|-----------|------|-----|
| Capability token validation | Token issuance/revocation correctness | Security-critical: malformed tokens bypass access control |
| Protocol state machine | Session state transitions are total | Prevent stuck/invalid protocol states |
| Permission composition | Capability intersection/union laws | Ensure composed permissions don't escalate |
| ABI type safety | FFI boundary type marshalling correctness | Prevent memory corruption at language boundary |
| mTLS trust policy | An unverified client cert is never mapped to a privileged trust class (`classify CertUnverified _ = Untrusted`) | Security core of Phase B mTLS-as-primary-path: forged/unverified certs must be indistinguishable from anonymous |

### mTLS trust policy (Phase B / standards#97)

- **Claim stated:** `src/abi/MTLSPolicy.idr` — `unverifiedNeverPrivileged`.
- **Status:** PENDING (scheduled for Phase C/D — standards#98/#99). The
  obligation is recorded as a `0`-multiplicity hole; not yet discharged and
  intentionally excluded from `gateway.ipkg modules` so it does not gate the
  build before discharge.
- **Mirrors:** the runtime decision in
  `Gateway.determine_trust_level_from_cert/2` and the listener fail-closed
  contract in `HttpCapabilityGateway.Application`.

## Recommended Prover

**Idris2** — ABI layer already in Idris2; extend existing `Protocol.idr` and `Types.idr` with dependent type proofs for capability correctness.

## Priority

**MEDIUM** — Has working ABI layer with clean Idris2 code. Main gap is proving capability composition and protocol state transitions.

## Open contract surfaces (2026-06-02 self-audit, #31)

The audit issue #31 (priority 3) calls out two integration gaps that are
not yet code but want to be tracked as proof obligations:

- **chimichanga capability attenuation**: when the `capability` field
  (PR #33) acquires a partial-order lattice via `hyperpolymath/chimichanga`,
  the attenuation predicate `client_capability ≤ rule.capability` becomes
  a new proof obligation alongside the existing trust-total-order proof in
  `proven/SafeTrust.idr`. See `docs/CAPABILITY-INTEGRATION.md` §2.
- **groove-protocol service discovery**: resolving a backend URL via
  service discovery does NOT itself need a proof, but the *fallback
  contract* ("on resolution failure, return 503 — NEVER fall back to a
  static URL") wants a mechanised statement so future refactors do not
  introduce a silent trust-downgrade. See
  `docs/CAPABILITY-INTEGRATION.md` §3.

### Echo-types audit (2026-06-02)

Per estate convention (`feedback_proofs_must_check_and_cross_doc_echo_types.md`),
echo-types was audited. **Status: record-as-not-relevant** for the current
scaffold. Re-check this entry when chimichanga attenuation lands: the
lattice may introduce an L3 obligation at that point.
