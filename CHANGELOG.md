<!--
SPDX-License-Identifier: MPL-2.0
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Changelog

All notable changes to `http-capability-gateway` will be documented in this file.

This file is generated from conventional commits by the
[`changelog-reusable.yml`](https://github.com/hyperpolymath/standards/blob/main/.github/workflows/changelog-reusable.yml)
workflow (`hyperpolymath/standards#206`). Adopt the workflow in this repo's CI to keep this file in sync automatically — see
[`templates/cliff.toml`](https://github.com/hyperpolymath/standards/blob/main/templates/cliff.toml)
for the canonical config.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- feat(perf): Phase D benchmark harness scaffold (standards#99 / #91 channel) (#12)
- feat(policy): catalog mode — auto-policy from BoJ cartridge.json
- feat(p2): bug fixes, unit tests, P2 productization docs
- feat(p1): gateway hardening — bug fixes, concurrency tests, benchmarks, docs
- feat(crg): add crg-grade and crg-badge justfile recipes
- feat: add VeriSimDB async audit log client (capgw:audit)
- feat: wire conflow config validation pipeline
- feat: add k9iser.toml and generate K9 contracts
- feat: add stapeln.toml layer-based container definition\n\nConverted from existing Containerfile to stapeln format.\nIncludes Chainguard base, security hardening, SBOM generation.\n\nCo-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
- feat: deploy UX Manifesto infrastructure

### Fixed

- fix(ci): switch CodeQL language matrix to `actions` (#13)
- fix(ci): bump a2ml/k9-validate-action pins to canonical (standards#85) (#7)
- fix(ci): sync hypatia-scan.yml to canonical (kill cd-scanner build drift) (#6)
- fix(ci): adopt canonical hypatia-scan.yml (env.HOME/scanner-layout + Comment-step gate) (#5)
- fix(p0): resolve all 5 P0 release blockers
- fix: set correct Groove capability type (was: custom)
- fix: replace String.to_atom with String.to_existing_atom
- fix(scorecard): enforce granular permissions and add fuzzing placeholder
- fix(ci): Resolve workflow-linter self-matching and metadata issues
- fix: global AGPL-3.0-or-later → PMPL-1.0-or-later replacement

### Changed

- perf(d-2): wire in-process loopback backend so proxy-200 scenario measures real dial-and-read (#14)
- refactor: migrate 6SCM → 6A2 (.scm → .a2ml format)

### Documentation

- docs: record tech-debt audit findings (2026-05-26) (#16)
- docs: substantive CRG C annotation (EXPLAINME.adoc)
- docs: add TEST-NEEDS.md and/or PROOF-NEEDS.md from audit
- docs: add comprehensive v2.0 roadmap for irresistible gateway
- docs: add CONTRIBUTING.md
- docs: add checkpoint files for state tracking

### CI

- ci: redistribute concurrency-cancel guard to read-only check workflows (#9)
- ci: bump actions/upload-artifact SHA to current v4 (#4)
- ci: SHA-pin hyperpolymath validate-actions in dogfood-gate
- ci: wire hypatia-scan.yml to query own Dependabot alerts
- ci: deploy dogfood-gate, add Groove manifest and CRG tests

## Pre-history

Prior commits to this file's introduction are recorded in git history but not formally classified into Keep-a-Changelog sections. To backfill, run `git cliff -o CHANGELOG.md` locally using the canonical [`cliff.toml`](https://github.com/hyperpolymath/standards/blob/main/templates/cliff.toml) — this is one-shot mechanical work.

---

<!-- This file was seeded by the 2026-05-26 estate tech-debt audit follow-up (Row-2 Phase 3); see [`hyperpolymath/standards/docs/audits/2026-05-26-estate-documentation-debt.md`](https://github.com/hyperpolymath/standards/blob/main/docs/audits/2026-05-26-estate-documentation-debt.md). -->
