# Policy DSL Reference

Complete reference for the HTTP Capability Gateway Policy DSL v1.

## Table of Contents

1. [Overview](#overview)
2. [Schema](#schema)
3. [Fields Reference](#fields-reference)
4. [Examples](#examples)
5. [Best Practices](#best-practices)
6. [Validation Rules](#validation-rules)

## Overview

The Policy DSL is a declarative YAML-based language for defining HTTP verb governance rules. It supports:

- Global verb allowlists
- Route-specific verb overrides
- Regex pattern matching
- Stealth mode configuration

## Schema

### Root Structure

```yaml
dsl_version: "1"      # Required: string, must be "1"
governance:           # Required: object
  global_verbs: []    # Required: array of HTTP verbs
  routes: []          # Optional: array of route objects
stealth:              # Optional: stealth mode configuration
  enabled: boolean    # Required if stealth present
  status_code: int    # Required if stealth present
```

### Route Object

```yaml
path: "/api/users"    # Required: string, path or regex pattern
verbs: []             # Required: array of HTTP verbs
```

## Fields Reference

### `dsl_version`

**Type**: String
**Required**: Yes
**Valid Values**: `"1"`

Specifies the policy format version. Must be `"1"` for this version of the gateway.

**Example**:

```yaml
dsl_version: "1"
```

**Validation**:
- Must be present
- Must be a string
- Must equal `"1"`

---

### `governance`

**Type**: Object
**Required**: Yes

Container for all governance rules.

**Structure**:

```yaml
governance:
  global_verbs: []
  routes: []
```

**Validation**:
- Must be present
- Must be an object
- Must contain `global_verbs` field

---

### `governance.global_verbs`

**Type**: Array of strings
**Required**: Yes

List of HTTP verbs allowed on all routes unless overridden by route-specific rules.

**Valid Verbs**:
- `GET`
- `POST`
- `PUT`
- `DELETE`
- `PATCH`
- `HEAD`
- `OPTIONS`

**Examples**:

```yaml
# Allow only read operations globally
governance:
  global_verbs:
    - GET
    - HEAD
```

```yaml
# Allow all standard verbs
governance:
  global_verbs:
    - GET
    - POST
    - PUT
    - DELETE
    - PATCH
    - HEAD
    - OPTIONS
```

**Validation**:
- Must be present
- Must be an array
- Must not be empty
- All elements must be valid HTTP verbs
- Case-sensitive (must be uppercase)

---

### `governance.routes`

**Type**: Array of route objects
**Required**: No

List of route-specific rules that override global verbs.

**Structure**:

```yaml
governance:
  routes:
    - path: "/api/users"
      verbs: [GET, POST]
    - path: "/api/admin"
      verbs: [GET]
```

**Validation**:
- Must be an array if present
- Each element must be a valid route object

---

### `governance.routes[].path`

**Type**: String
**Required**: Yes (if route present)

Path or regex pattern to match against request paths.

**Path Types**:

1. **Literal Path**:
   ```yaml
   path: "/api/users"
   ```

2. **Regex Pattern**:
   ```yaml
   path: "/api/users/[0-9]+"  # Numeric user IDs only
   ```

3. **Wildcard Pattern**:
   ```yaml
   path: "/api/posts/.+"      # Any post path
   ```

**Examples**:

```yaml
# Exact match
- path: "/health"
  verbs: [GET]

# Numeric ID pattern
- path: "/api/users/[0-9]+"
  verbs: [GET, PUT, DELETE]

# UUID pattern
- path: "/api/resources/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  verbs: [GET, PUT, DELETE]

# Wildcard any subpath
- path: "/api/public/.*"
  verbs: [GET]
```

**Validation**:
- Must be present for each route
- Must be a non-empty string
- Must be a valid regex pattern (if using regex)

---

### `governance.routes[].verbs`

**Type**: Array of strings
**Required**: Yes (if route present)

List of HTTP verbs allowed for this specific route. **Overrides global_verbs** for this path.

**Examples**:

```yaml
# Admin endpoints: read-only
- path: "/api/admin"
  verbs: [GET]

# User endpoints: full CRUD
- path: "/api/users/[0-9]+"
  verbs: [GET, POST, PUT, DELETE]

# Health check: GET only
- path: "/health"
  verbs: [GET]
```

**Validation**:
- Must be present for each route
- Must be an array
- Must not be empty
- All elements must be valid HTTP verbs

---

### `stealth`

**Type**: Object
**Required**: No

Configuration for stealth mode, which controls the response for denied requests.

**Structure**:

```yaml
stealth:
  enabled: true
  status_code: 404
```

**When Stealth Enabled**:
- Denied requests return the configured status code
- Response body is empty
- Makes it difficult to enumerate allowed endpoints

**When Stealth Disabled**:
- Denied requests return `403 Forbidden`
- Standard error response

**Validation**:
- If present, both `enabled` and `status_code` are required

---

### `stealth.enabled`

**Type**: Boolean
**Required**: Yes (if stealth present)

Whether stealth mode is enabled.

**Examples**:

```yaml
# Stealth enabled
stealth:
  enabled: true
  status_code: 404

# Stealth disabled
stealth:
  enabled: false
  status_code: 403
```

**Validation**:
- Must be a boolean (`true` or `false`)

---

### `stealth.status_code`

**Type**: Integer
**Required**: Yes (if stealth present)

HTTP status code to return for denied requests when stealth is enabled.

**Valid Status Codes**:
- `200` - OK (pretend success)
- `301` - Moved Permanently
- `302` - Found (redirect)
- `403` - Forbidden
- `404` - Not Found (recommended)
- `410` - Gone
- `500` - Internal Server Error
- `503` - Service Unavailable

**Common Patterns**:

```yaml
# Pretend endpoint doesn't exist (most common)
stealth:
  enabled: true
  status_code: 404

# Pretend endpoint was removed
stealth:
  enabled: true
  status_code: 410

# Service unavailable (less suspicious)
stealth:
  enabled: true
  status_code: 503
```

**Validation**:
- Must be an integer
- Must be one of the valid status codes

---

## Examples

### Example 1: Public API with Admin Section

```yaml
dsl_version: "1"
governance:
  # Most endpoints allow GET and POST
  global_verbs:
    - GET
    - POST
  routes:
    # Admin endpoints: read-only
    - path: "/api/v1/admin/.*"
      verbs: [GET]

    # User management: full CRUD
    - path: "/api/v1/users/[0-9]+"
      verbs: [GET, PUT, DELETE]

    # Health check: GET only
    - path: "/health"
      verbs: [GET]

stealth:
  enabled: true
  status_code: 404
```

**Behavior**:
- `/api/v1/public` - GET, POST allowed
- `/api/v1/admin/users` - GET only (route override)
- `/api/v1/users/123` - GET, PUT, DELETE (route override)
- `/health` - GET only
- Any denied request → 404

---

### Example 2: Strict Read-Only API

```yaml
dsl_version: "1"
governance:
  # Global: read-only
  global_verbs:
    - GET
    - HEAD
    - OPTIONS

  # No route overrides - all endpoints read-only

stealth:
  enabled: true
  status_code: 404
```

**Behavior**:
- All endpoints allow only GET, HEAD, OPTIONS
- Any POST, PUT, DELETE → 404

---

### Example 3: Microservice Gateway

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET

  routes:
    # Auth service: POST for login
    - path: "/auth/login"
      verbs: [POST]

    - path: "/auth/logout"
      verbs: [POST]

    - path: "/auth/token/refresh"
      verbs: [POST]

    # User service: full CRUD
    - path: "/users/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
      verbs: [GET, PUT, DELETE]

    - path: "/users"
      verbs: [GET, POST]

    # Product service: public read, admin write
    - path: "/products"
      verbs: [GET, POST]

    - path: "/products/[0-9]+"
      verbs: [GET, PUT, DELETE]

stealth:
  enabled: true
  status_code: 404
```

---

### Example 4: No Stealth Mode (Explicit Denials)

```yaml
dsl_version: "1"
governance:
  global_verbs:
    - GET
    - POST

  routes:
    - path: "/api/admin"
      verbs: [GET]

stealth:
  enabled: false
  status_code: 403
```

**Behavior**:
- Denied requests return `403 Forbidden` with error message
- Easier to debug, but reveals API structure

---

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

    # API versioning
    - path: "/api/v[0-9]+/.*"
      verbs: [GET, POST]

stealth:
  enabled: true
  status_code: 404
```

---

## Best Practices

### 1. Principle of Least Privilege

Start with minimal global verbs, expand as needed:

```yaml
# Good: start restrictive
governance:
  global_verbs:
    - GET

# Then add specific overrides
routes:
  - path: "/api/users"
    verbs: [GET, POST]
```

### 2. Use Stealth Mode

Enable stealth to prevent endpoint enumeration:

```yaml
stealth:
  enabled: true
  status_code: 404  # Most common
```

### 3. Explicit Route Rules

Be specific with route patterns to avoid unintended matches:

```yaml
# Good: specific numeric ID
- path: "/api/users/[0-9]+"
  verbs: [GET, PUT, DELETE]

# Bad: too broad
- path: "/api/users/.*"
  verbs: [GET, PUT, DELETE]
```

### 4. Document Complex Patterns

Add comments for complex regex patterns:

```yaml
routes:
  # UUID v4 pattern for resource IDs
  - path: "/api/resources/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"
    verbs: [GET, PUT, DELETE]
```

### 5. Separate Concerns

Use different policies for different environments:

- `policy.dev.yaml` - Permissive for development
- `policy.staging.yaml` - Moderate restrictions
- `policy.prod.yaml` - Strict production rules

### 6. Health and Metrics Endpoints

Always allow health checks:

```yaml
routes:
  - path: "/health"
    verbs: [GET]
  - path: "/metrics"
    verbs: [GET]
```

### 7. Version Your Policies

Track policy changes in version control:

```bash
git commit -m "Policy: restrict DELETE on /api/admin endpoints"
```

## Validation Rules

### Compile-Time Validation

The gateway validates policies at startup:

1. **Schema Validation**:
   - All required fields present
   - Correct field types
   - Valid enum values

2. **Semantic Validation**:
   - HTTP verbs are valid
   - Regex patterns compile
   - No duplicate routes

3. **Performance Validation**:
   - Policy size reasonable (< 10,000 routes recommended)

### Runtime Validation

During request processing:

1. **Path Matching**:
   - Check if path matches any route pattern
   - Use first matching route

2. **Verb Checking**:
   - If route matches, check route verbs
   - Otherwise, check global verbs

3. **Stealth Response**:
   - If denied, return stealth status or 403

### Policy Validation Tool

Validate policy before deployment:

```bash
# Validate policy file
mix run -e "HttpCapabilityGateway.PolicyValidator.validate_file(\"policy.yaml\")"

# Expected output on success:
# :ok

# Expected output on failure:
# {:error, "governance.global_verbs: must be present"}
```

## Error Messages

### Common Validation Errors

**Missing `dsl_version`**:
```
Error: dsl_version: must be present and equal to "1"
```

**Invalid HTTP verb**:
```
Error: governance.global_verbs: invalid verb "FETCH" (valid: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS)
```

**Empty `global_verbs`**:
```
Error: governance.global_verbs: must not be empty
```

**Invalid stealth status code**:
```
Error: stealth.status_code: invalid status code 999 (valid: 200, 301, 302, 403, 404, 410, 500, 503)
```

**Invalid regex pattern**:
```
Error: governance.routes[2].path: invalid regex pattern "/api/users/[0-9+"
```

## Policy Migration

### From DSL v0 (Future)

When DSL v2 is released, use the migration tool:

```bash
mix run -e "HttpCapabilityGateway.PolicyMigrator.migrate(\"policy.v1.yaml\", \"policy.v2.yaml\")"
```

## Support

For policy questions:
- **GitHub Discussions**: https://github.com/hyperpolymath/http-capability-gateway/discussions
- **Issues**: https://github.com/hyperpolymath/http-capability-gateway/issues
