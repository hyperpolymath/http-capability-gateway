<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Policy DSL v1 Reference — HTTP Capability Gateway

Complete reference for the YAML-based Policy DSL v1 used by the HTTP Capability
Gateway to define verb governance rules. This document covers the schema, field
definitions, regex route patterns, stealth mode, validation rules, and hot reload
behaviour.

## Table of Contents

1. [Overview](#overview)
2. [DSL v1 Schema](#dsl-v1-schema)
3. [Field Reference](#field-reference)
4. [Regex Routes vs Literal Routes](#regex-routes-vs-literal-routes)
5. [Global Rules](#global-rules)
6. [Stealth Mode Configuration](#stealth-mode-configuration)
7. [Example Policy Files](#example-policy-files)
8. [Validation Rules](#validation-rules)
9. [Hot Reload Behaviour](#hot-reload-behaviour)

---

## Overview

The Policy DSL v1 is a declarative YAML format for defining HTTP verb governance.
It controls which HTTP methods (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS) are
allowed on which paths, and what happens when a request is denied.

**Key concepts:**

- **Global verbs**: HTTP methods allowed on all routes by default
- **Route overrides**: Path-specific verb lists that take precedence over globals
- **Stealth mode**: Configurable response for denied requests (hide the API surface)
- **Tiered lookup**: Literal paths use O(1) ETS lookup; regex patterns use O(r) scan

The policy file is loaded at gateway startup and compiled into ETS tables for
sub-microsecond enforcement on every request.

---

## DSL v1 Schema

### Root Structure

```yaml
dsl_version: "1"          # Required: must be "1"
governance:                # Required: verb governance rules
  global_verbs: []         # Required: array of HTTP verb strings
  routes: []               # Optional: array of route override objects
stealth:                   # Optional: stealth mode configuration
  enabled: boolean         # Required if stealth present
  status_code: integer     # Required if stealth present
```

### Route Object Structure

```yaml
path: "/api/users"         # Required: literal path or regex pattern
verbs: [GET, POST]         # Required: array of HTTP verb strings
```

---

## Field Reference

### `dsl_version`

| Property | Value |
|----------|-------|
| Type | String |
| Required | Yes |
| Valid values | `"1"` |

Specifies the policy format version. Must be the string `"1"` for this version
of the gateway. Future versions will use `"2"`, `"3"`, etc.

```yaml
dsl_version: "1"
```

**Validation:**
- Must be present
- Must be a string (not integer `1`)
- Must equal `"1"` exactly

---

### `governance`

| Property | Value |
|----------|-------|
| Type | Object |
| Required | Yes |

Container for all verb governance rules. Must contain `global_verbs` and
optionally `routes`.

---

### `governance.global_verbs`

| Property | Value |
|----------|-------|
| Type | Array of strings |
| Required | Yes |

HTTP methods allowed on **all routes** unless overridden by a route-specific
`verbs` list. These are compiled into `{:global, verb_atom}` entries in the
main ETS table for O(1) fallback lookup (Tier 3 in the tiered lookup strategy).

**Valid HTTP verbs** (case-sensitive, must be uppercase):

- `GET`
- `POST`
- `PUT`
- `DELETE`
- `PATCH`
- `HEAD`
- `OPTIONS`

```yaml
governance:
  global_verbs:
    - GET
    - HEAD
    - OPTIONS
```

**Validation:**
- Must be present
- Must be a non-empty array
- All elements must be valid HTTP verb strings
- Case-sensitive: `get` or `Get` will fail validation

---

### `governance.routes`

| Property | Value |
|----------|-------|
| Type | Array of route objects |
| Required | No |

Route-specific verb overrides. When a request path matches a route pattern,
only the verbs listed for that route are allowed — global verbs do **not**
apply for matched routes.

---

### `governance.routes[].path`

| Property | Value |
|----------|-------|
| Type | String |
| Required | Yes (per route) |

Path pattern to match against incoming request paths. Can be a literal string
or a regular expression pattern.

**Literal paths** (no regex metacharacters):

```yaml
- path: "/api/users"
  verbs: [GET, POST]
```

**Regex patterns** (contain `[`, `]`, `(`, `)`, `.`, `*`, `+`, `?`, `^`, `$`, `|`, or `\`):

```yaml
- path: "/api/users/[0-9]+"
  verbs: [GET, PUT, DELETE]
```

The gateway detects whether a path is literal or regex using the pattern
`/[\[\](){}.*+?^$|\\]/`. Literal paths are stored with `{:exact, path, verb}`
keys for O(1) lookup. Regex paths are compiled to `Regex.t()` structs and
stored in a dedicated regex ETS table for O(r) scanning.

**Validation:**
- Must be a non-empty string
- If containing regex metacharacters, must compile as a valid Elixir/PCRE regex

---

### `governance.routes[].verbs`

| Property | Value |
|----------|-------|
| Type | Array of strings |
| Required | Yes (per route) |

HTTP methods allowed for this specific route. Same valid values as `global_verbs`.

```yaml
- path: "/api/admin"
  verbs: [GET]  # Admin endpoints are read-only
```

**Validation:**
- Must be a non-empty array
- All elements must be valid HTTP verb strings

---

### `stealth`

| Property | Value |
|----------|-------|
| Type | Object |
| Required | No |

Stealth mode configuration. Controls what response is sent when a request
is denied (verb not allowed for the path + trust level combination).

---

### `stealth.enabled`

| Property | Value |
|----------|-------|
| Type | Boolean |
| Required | Yes (if `stealth` present) |

When `true`, denied requests receive the configured `status_code` instead
of the default `403 Forbidden`. This makes it harder for attackers to
enumerate the API surface by probing different HTTP methods.

---

### `stealth.status_code`

| Property | Value |
|----------|-------|
| Type | Integer |
| Required | Yes (if `stealth` present) |

HTTP status code returned for denied requests when stealth is enabled.

**Recommended values:**

| Code | Meaning | Use Case |
|------|---------|----------|
| `404` | Not Found | Best default; hides endpoint existence |
| `410` | Gone | Pretend endpoint was removed |
| `503` | Service Unavailable | Appears as temporary outage |
| `403` | Forbidden | Standard denial (use when stealth.enabled = false) |
| `200` | OK | Pretend success (advanced deception) |

```yaml
stealth:
  enabled: true
  status_code: 404
```

---

## Regex Routes vs Literal Routes

The gateway distinguishes between literal and regex paths for performance:

### Literal Paths (O(1) Lookup — Tier 1)

Paths without regex metacharacters are stored with `{:exact, path, verb}` keys
in the main ETS table. Lookup is a single hash table access.

```yaml
# These are literal paths (O(1) lookup):
- path: "/health"
- path: "/api/v1/users"
- path: "/api/v1/posts"
```

### Regex Paths (O(r) Scan — Tier 2)

Paths containing regex metacharacters (`[ ] ( ) { } . * + ? ^ $ | \`) are
compiled into `Regex.t()` structs and stored in a **dedicated regex ETS table**.
On each request, only the regex table is scanned (not the entire rule set).

```yaml
# These are regex paths (O(r) scan where r = number of regex routes):
- path: "/api/v1/users/[0-9]+"
- path: "/api/v1/posts/.+"
- path: "/api/v1/resources/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
```

### Performance Guideline

In typical policy files, 90%+ of routes are literal paths, making the
overwhelmingly common case an O(1) hash lookup. Keep regex routes to a
minimum for best performance.

---

## Global Rules

Global verbs serve as the **fallback** (Tier 3) when no route-specific rule
matches a request. They are stored with `{:global, verb_atom}` keys in the
main ETS table for O(1) lookup.

### Lookup Priority

For an incoming request to `/api/v1/users/123` with method `GET`:

1. **Tier 1**: Check `{:exact, "/api/v1/users/123", :GET}` in main table -- O(1)
2. **Tier 2**: Scan regex table for a pattern matching `/api/v1/users/123` with verb `:GET` -- O(r)
3. **Tier 3**: Check `{:global, :GET}` in main table -- O(1)
4. **No match**: Return `404` (or stealth response)

If a route-specific rule matches at Tier 1 or Tier 2, global rules are
**not consulted** — the route override takes full precedence.

---

## Stealth Mode Configuration

Stealth mode is a security feature that disguises denied responses to make
API enumeration more difficult.

### Without Stealth (Default)

Denied requests receive `403 Forbidden` with a clear JSON error message
including the required and provided trust levels:

```json
{
  "error": "Forbidden",
  "message": "Insufficient trust level for this operation",
  "required": "internal",
  "provided": "untrusted"
}
```

### With Stealth Enabled

Denied requests receive the configured status code with a generic message:

```json
{
  "error": "Not Found"
}
```

The `status_code` is applied uniformly to all denied requests regardless
of trust level. The profile name `"default"` is used internally.

### Stealth Best Practice

Use `404` as the stealth status code for most deployments. It makes the
API surface indistinguishable from nonexistent paths, forcing attackers
to rely on documentation or source code rather than probing.

---

## Example Policy Files

### Example 1: Public API with Admin Section

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET
    - POST
  routes:
    # Admin: read-only
    - path: "/api/v1/admin/.*"
      verbs: [GET]

    # Users: full CRUD with numeric IDs
    - path: "/api/v1/users/[0-9]+"
      verbs: [GET, PUT, DELETE]

    # Health and metrics: always available
    - path: "/health"
      verbs: [GET]
    - path: "/metrics"
      verbs: [GET]

stealth:
  enabled: true
  status_code: 404
```

**Behaviour:**

- `GET /api/v1/posts` -- Allowed (global GET)
- `POST /api/v1/posts` -- Allowed (global POST)
- `DELETE /api/v1/posts` -- Denied (404 via stealth)
- `GET /api/v1/admin/settings` -- Allowed (route override)
- `POST /api/v1/admin/settings` -- Denied (404 via stealth, admin is GET-only)
- `PUT /api/v1/users/123` -- Allowed (route override)

### Example 2: Strict Read-Only API

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET
    - HEAD
    - OPTIONS

stealth:
  enabled: true
  status_code: 404
```

All endpoints allow only safe HTTP methods. Any write attempt returns 404.

### Example 3: Microservice Gateway

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET

  routes:
    # Auth service
    - path: "/auth/login"
      verbs: [POST]
    - path: "/auth/logout"
      verbs: [POST]
    - path: "/auth/token/refresh"
      verbs: [POST]

    # User service (UUID IDs)
    - path: "/users/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
      verbs: [GET, PUT, DELETE]
    - path: "/users"
      verbs: [GET, POST]

    # Product service
    - path: "/products/[0-9]+"
      verbs: [GET, PUT, DELETE]
    - path: "/products"
      verbs: [GET, POST]

stealth:
  enabled: true
  status_code: 404
```

### Example 4: Development (Permissive)

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET
    - POST
    - PUT
    - DELETE
    - PATCH
    - HEAD
    - OPTIONS

stealth:
  enabled: false
  status_code: 403
```

All HTTP methods allowed globally. Stealth disabled for clearer error messages
during development.

### Example 5: Complex Regex Patterns

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET

  routes:
    # Date-based endpoints (YYYY-MM-DD)
    - path: "/api/reports/[0-9]{4}-[0-9]{2}-[0-9]{2}"
      verbs: [GET, POST]

    # UUID v4 resources
    - path: "/api/resources/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"
      verbs: [GET, PUT, DELETE]

    # Slugs (lowercase alphanumeric + hyphens)
    - path: "/api/posts/[a-z0-9-]+"
      verbs: [GET, PUT, DELETE]

    # Versioned API prefix (v1, v2, etc.)
    - path: "/api/v[0-9]+/.*"
      verbs: [GET, POST]

stealth:
  enabled: true
  status_code: 404
```

---

## Validation Rules

### Startup Validation (PolicyValidator)

The gateway validates the full policy at startup before compiling it into
ETS tables. If validation fails, **the gateway refuses to start**.

#### Schema Validation

- `dsl_version` must be present and equal to `"1"`
- `governance` must be present and be a map
- `governance.global_verbs` must be a non-empty array of valid HTTP verbs
- If `governance.routes` is present, it must be an array of valid route objects
- If `stealth` is present, both `enabled` (boolean) and `status_code` (integer) are required

#### Semantic Validation

- All HTTP verbs must be valid uppercase strings: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS
- All route `path` patterns must compile as valid Elixir/PCRE regular expressions
- Stealth `status_code` must be a recognized HTTP status code

### Compilation Validation (PolicyCompiler)

During compilation, additional checks are performed:

- HTTP verbs are converted to atoms via `String.to_existing_atom/1` (only pre-existing
  atoms from the `@valid_http_verbs` list succeed)
- Regex patterns are compiled via `Regex.compile/1`
- Invalid verbs or patterns produce error tuples; if any errors occur, compilation
  fails and the existing policy tables remain active

### Common Validation Errors

```
dsl_version: must be present and equal to "1"
```
Missing or invalid `dsl_version` field.

```
governance.global_verbs: must not be empty
```
The `global_verbs` array is empty or missing.

```
governance.global_verbs: invalid verb "FETCH"
```
An unrecognized HTTP method was used. Valid methods are GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS.

```
governance.routes[2].path: invalid regex pattern "/api/users/[0-9+"
```
A route path contains a regex syntax error (unclosed bracket in this case).

### Policy Validation Tool

Validate a policy file before deployment without starting the gateway:

```bash
mix run -e '
  case HttpCapabilityGateway.PolicyLoader.load_from_file("policy.yaml") do
    {:ok, policy} ->
      case HttpCapabilityGateway.PolicyValidator.validate(policy) do
        :ok -> IO.puts("Policy is valid")
        {:error, reason} -> IO.puts("Validation failed: #{reason}")
      end
    {:error, reason} ->
      IO.puts("Load failed: #{reason}")
  end
'
```

---

## Hot Reload Behaviour

### Atomic Dual-Table Swap

When a policy reload is triggered, the gateway performs a zero-downtime
atomic swap of **both** ETS tables (main + regex):

1. **Create temporary tables**: New main and regex tables are created with
   unique monotonic-time-based names

2. **Compile into temporary tables**: All policy rules are compiled into
   the appropriate temporary table (literal paths to main, regex paths to
   regex table, global rules to main)

3. **On success** (zero compilation errors):
   - Application environment `:policy_table` is updated to the new main table name
   - Application environment `:policy_regex_table` is updated to the new regex table name
   - Old main and regex tables are deleted
   - All in-flight requests seamlessly transition to the new tables

4. **On failure** (any compilation error):
   - Both temporary tables are deleted
   - Old tables and application environment references remain unchanged
   - The last known good policy continues to serve traffic

### Guarantees

- **Zero downtime**: The app env reference swap is a single atomic operation
  from the perspective of concurrent readers. There is no moment where the
  reference points to a nonexistent or partially-loaded table.

- **Rollback on failure**: If the new policy fails validation or compilation,
  the old policy remains active. No service disruption occurs.

- **Dual-table consistency**: Both the main table and regex table are swapped
  as a pair. It is impossible to have the main table from policy version N
  paired with the regex table from policy version N-1.

---

## Support

- **Issues**: <https://github.com/hyperpolymath/http-capability-gateway/issues>
- **Discussions**: <https://github.com/hyperpolymath/http-capability-gateway/discussions>
