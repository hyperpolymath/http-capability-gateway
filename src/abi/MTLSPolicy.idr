-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Phase B (standards#97) deliverable B4: the mTLS trust-policy proof
-- OBLIGATION, stated in Idris2 terms. The proof itself is NOT due in
-- Phase B -- status is "pending Phase C/D" in PROOFS_NEEDED.md. This
-- module is intentionally NOT listed in gateway.ipkg `modules`; it
-- records the claim so it cannot be lost, without gating the build.
--
-- No verification-bypass primitives are used. The obligation is left as a
-- `0`-multiplicity metavariable (an open hole) documented below;
-- discharging it is the Phase C/D task.

module MTLSPolicy

||| Transport-level verification status as established by the Cowboy TLS
||| listener configured with `verify: :verify_peer` and
||| `fail_if_no_peer_cert: true`.
data Verified = CertVerified | CertUnverified

||| The trust classes the gateway forwards as `X-Trust-Level`, mirroring
||| HttpCapabilityGateway.SafeTrust (proven/SafeTrust.idr).
data Trust = Untrusted | Authenticated | Internal

||| The organizational-unit string carried in the client certificate
||| subject. `IsInternalOU` marks `OU = "Internal Services"`.
data OU = IsInternalOU | OtherOU

||| The gateway's cert -> trust decision function, as implemented in
||| Gateway.determine_trust_level_from_cert/2.
classify : Verified -> OU -> Trust
classify CertUnverified _            = Untrusted
classify CertVerified   IsInternalOU = Internal
classify CertVerified   OtherOU      = Authenticated

||| PROOF OBLIGATION (pending Phase C/D):
|||
||| No certificate that failed transport verification can ever be mapped
||| to a privileged trust class. Formally: for every organizational unit
||| `ou`, `classify CertUnverified ou = Untrusted`.
|||
||| This is the security core of mTLS-as-primary-path: header forgery and
||| unverified client certs are indistinguishable from anonymous traffic.
||| The statement is total and decidable; the discharge is scheduled with
||| the Phase C end-to-end verification work.
0 unverifiedNeverPrivileged : (ou : OU) -> classify CertUnverified ou = Untrusted
unverifiedNeverPrivileged ou = ?unverifiedNeverPrivileged_rhs
