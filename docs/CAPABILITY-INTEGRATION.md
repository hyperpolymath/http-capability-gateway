<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# Capability + Service-Discovery Integration

This document describes the **contract surfaces** by which
`http-capability-gateway` connects (or, in v0.x, *will connect*) to:

- the estate capability model (`hyperpolymath/chimichanga` capability
  attenuation, `hyperpolymath/boj-server` cartridges), and
- service discovery (`hyperpolymath/groove-protocol`).

It is intentionally written as a *contract* rather than a feature list:
this PR adds documentation only. The implementation is filed as proof debt
in `PROOFS_NEEDED.md` and tracked in the linked audit issues.

## 1. Existing surface: BoJ cartridges

`PolicyLoader.load_from_boj_catalog/1` already builds a Verb Governance Spec
from a directory of `cartridge.json` manifests. The mapping is:

| Cartridge field      | DSL v1 field              | Notes                                               |
|----------------------|---------------------------|-----------------------------------------------------|
| `name`               | route `name`              | One `invoke` route per cartridge                    |
| `auth_method`        | route `exposure`          | `none` → `public`, others → `authenticated`         |
| `description`        | route `narrative`         | Carried through for audit                           |
| (nothing yet)        | route `capability`        | **OPEN**: bind cartridge capability label           |

The third row is the gap this document calls out: cartridges declare
capability vocabularies but those vocabularies do not yet flow onto
compiled rules. PR #33 (`audit/policy-schema-capability`) adds the schema
field; the cartridge loader needs a follow-up to populate it.

## 2. Chimichanga capability attenuation (proposed surface)

`hyperpolymath/chimichanga` defines a capability-attenuation lattice: a
holder of capability `C` can derive a strictly weaker capability `C'`
without consulting the issuer. The gateway is the right place to enforce
attenuation at the request boundary.

### Proposed contract

Each compiled rule carries:

- `capability :: String.t() | nil` (PR #33 lands this)
- `attenuated_from :: [String.t()] | nil` (NOT YET) — the set of broader
  capabilities from which the rule's capability is derivable.

The gateway then enforces:

```
allow iff trust ≥ exposure
     AND (rule.capability == nil
          OR client_capability ≤ rule.capability)
```

where `≤` is the chimichanga lattice partial order, *not* the trust total
order in `SafeTrust`. The two predicates are orthogonal: trust is "who is
the caller", capability is "what may the caller do".

### Open questions

- **Where does `client_capability` come from?** Candidates: a signed JWT
  claim, an mTLS certificate extension, a header populated by an upstream
  attenuator. Out of scope for this doc.
- **Is the lattice mechanised in echo-types?** Filed for follow-up; see
  `PROOFS_NEEDED.md`. Recorded as `record-as-not-relevant` for the
  current scaffold PRs.

## 3. Service discovery via groove-protocol (proposed surface)

`backend_url` is statically configured today
(`config :http_capability_gateway, :backend_url, "http://localhost:8080"`).
This breaks when estate apps move between hosts or scale horizontally.

### Proposed contract

A new optional config key `:backend_discovery` that takes one of:

- `{:static, url}` — current behaviour (the default)
- `{:groove, service_name}` — resolve the backend URL via groove-protocol
  service discovery at request time, with a circuit-breaker fallback to
  503 on resolution failure (NOT to a static URL — that would be a
  silent-trust-downgrade vector).

`Proxy.forward/2` is the single integration point. The resolver is the
seam.

### Open questions

- **What is the TTL of a discovery hit?** groove-protocol semantics
  determine this; this gateway just consults it.
- **Does the resolved URL participate in policy?** Today the policy is
  path-and-verb-keyed and backend-agnostic. If discovery returns multiple
  candidate URLs, picking one is out of scope for v1.

## 4. Why this is documentation, not code

A small documentation PR is the right step here because:

1. The cross-repo contracts (`chimichanga`, `groove-protocol`) are still
   stabilising.
2. The compiler-side schema change is in flight in #33 (which carries the
   `capability` field) and a code-side discovery seam would prematurely
   commit to a particular resolver shape.
3. The egress mode in #32 is the more urgent consumer of the same
   capability vocabulary; once it stabilises, the chimichanga binding is
   a natural follow-up.

## 5. Echo-types audit

`hyperpolymath/echo-types` was audited per estate convention. The gateway
does not currently participate in any echo protocol; trust hierarchy
proofs live in `proven/SafeTrust.idr`. **Status: record-as-not-relevant.**

The chimichanga attenuation surface *may* introduce an L3 obligation when
it lands; this section will be revisited at that point.

## References

- Audit issue: #31
- Related PRs: #32 (egress scaffold), #33 (capability schema field)
- `PROOFS_NEEDED.md` (this repo)
- `PolicyLoader.load_from_boj_catalog/1` in
  `lib/http_capability_gateway/policy_loader.ex`
