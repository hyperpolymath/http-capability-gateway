# PROOF-NEEDS.md — http-capability-gateway

## Current State

- **src/abi/*.idr**: YES — `Protocol.idr`, `Types.idr`
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

## Recommended Prover

**Idris2** — ABI layer already in Idris2; extend existing `Protocol.idr` and `Types.idr` with dependent type proofs for capability correctness.

## Priority

**MEDIUM** — Has working ABI layer with clean Idris2 code. Main gap is proving capability composition and protocol state transitions.
