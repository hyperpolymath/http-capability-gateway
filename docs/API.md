<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# API Documentation

Complete API reference for HTTP Capability Gateway modules.

## Table of Contents

1. [PolicyLoader](#policyloader)
2. [PolicyValidator](#policyvalidator)
3. [PolicyCompiler](#policycompiler)
4. [Gateway](#gateway)
5. [Proxy](#proxy)
6. [Logging](#logging)
7. [LogFormatter](#logformatter)
8. [Application](#application)

---

## PolicyLoader

**Module**: `HttpCapabilityGateway.PolicyLoader`

Loads and parses YAML policy files.

### Functions

#### `load_policy/1`

Loads a policy from a YAML string.

**Signature**:
```elixir
@spec load_policy(binary()) :: {:ok, map()} | {:error, binary()}
```

**Parameters**:
- `yaml_content` (binary): YAML policy content as string

**Returns**:
- `{:ok, policy}` - Successfully parsed policy map
- `{:error, reason}` - Error message string

**Examples**:

```elixir
# Success case
yaml = """
dsl_version: "1"
governance:
  global_verbs:
    - GET
    - POST
"""

{:ok, policy} = PolicyLoader.load_policy(yaml)
# => {:ok, %{"dsl_version" => "1", "governance" => %{"global_verbs" => ["GET", "POST"]}}}

# Error case
{:error, reason} = PolicyLoader.load_policy("invalid: yaml: [")
# => {:error, "YAML parsing error: ..."}
```

---

#### `load_from_file/1`

Loads a policy from a YAML file path.

**Signature**:
```elixir
@spec load_from_file(binary()) :: {:ok, map()} | {:error, binary()}
```

**Parameters**:
- `file_path` (binary): Path to YAML policy file

**Returns**:
- `{:ok, policy}` - Successfully loaded and parsed policy
- `{:error, reason}` - Error message (file not found, parse error)

**Examples**:

```elixir
# Success
{:ok, policy} = PolicyLoader.load_from_file("priv/config/policy.dev.yaml")

# File not found
{:error, "File not found: /path/to/missing.yaml"} =
  PolicyLoader.load_from_file("/path/to/missing.yaml")
```

---

## PolicyValidator

**Module**: `HttpCapabilityGateway.PolicyValidator`

Validates policy structure against DSL v1 schema.

### Functions

#### `validate/1`

Validates a policy map against the DSL v1 schema.

**Signature**:
```elixir
@spec validate(map()) :: :ok | {:error, binary()}
```

**Parameters**:
- `policy` (map): Policy map from PolicyLoader

**Returns**:
- `:ok` - Policy is valid
- `{:error, reason}` - Validation error message

**Validation Checks**:
1. `dsl_version` is present and equals `"1"`
2. `governance` is present and is a map
3. `governance.global_verbs` is present and non-empty array
4. All verbs are valid HTTP verbs
5. Routes (if present) have `path` and `verbs` fields
6. Stealth config (if present) has `enabled` and `status_code`

**Examples**:

```elixir
# Valid policy
policy = %{
  "dsl_version" => "1",
  "governance" => %{
    "global_verbs" => ["GET", "POST"]
  }
}
:ok = PolicyValidator.validate(policy)

# Invalid: missing dsl_version
policy = %{"governance" => %{"global_verbs" => ["GET"]}}
{:error, "dsl_version: must be present"} = PolicyValidator.validate(policy)

# Invalid: empty global_verbs
policy = %{
  "dsl_version" => "1",
  "governance" => %{"global_verbs" => []}
}
{:error, "global_verbs: must not be empty"} = PolicyValidator.validate(policy)

# Invalid: bad HTTP verb
policy = %{
  "dsl_version" => "1",
  "governance" => %{"global_verbs" => ["GET", "INVALID_VERB"]}
}
{:error, "Invalid HTTP verb: INVALID_VERB"} = PolicyValidator.validate(policy)
```

---

## PolicyCompiler

**Module**: `HttpCapabilityGateway.PolicyCompiler`

Compiles validated policies to ETS tables for fast lookups.

### Functions

#### `compile/1`

Compiles a policy to ETS tables.

**Signature**:
```elixir
@spec compile(map()) :: :ok | {:error, binary()}
```

**Parameters**:
- `policy` (map): Validated policy from PolicyValidator

**Returns**:
- `:ok` - Policy compiled successfully
- `{:error, reason}` - Compilation error

**Side Effects**:
- Creates or updates `:gateway_rules` ETS table
- Creates or updates `:stealth_config` ETS table

**Examples**:

```elixir
policy = %{
  "dsl_version" => "1",
  "governance" => %{
    "global_verbs" => ["GET", "POST"],
    "routes" => [
      %{"path" => "/api/admin", "verbs" => ["GET"]}
    ]
  },
  "stealth" => %{
    "enabled" => true,
    "status_code" => 404
  }
}

:ok = PolicyCompiler.compile(policy)
```

---

#### `is_verb_allowed?/2`

Checks if an HTTP verb is allowed for a given path.

**Signature**:
```elixir
@spec is_verb_allowed?(binary(), binary()) :: boolean()
```

**Parameters**:
- `path` (binary): Request path (e.g., `"/api/users/123"`)
- `verb` (binary): HTTP verb (e.g., `"GET"`)

**Returns**:
- `true` - Verb is allowed for this path
- `false` - Verb is not allowed

**Logic**:
1. Check if path matches any route pattern
2. If matched, check route-specific verbs
3. If not matched, check global verbs

**Examples**:

```elixir
# Assuming policy compiled with:
# global_verbs: ["GET", "POST"]
# routes: [%{"path" => "/api/admin", "verbs" => ["GET"]}]

# Global verb on unspecified route
true = PolicyCompiler.is_verb_allowed?("/api/public", "GET")

# Non-global verb on unspecified route
false = PolicyCompiler.is_verb_allowed?("/api/public", "DELETE")

# Route-specific verb
true = PolicyCompiler.is_verb_allowed?("/api/admin", "GET")
false = PolicyCompiler.is_verb_allowed?("/api/admin", "POST")

# Regex route matching
true = PolicyCompiler.is_verb_allowed?("/api/users/123", "GET")
false = PolicyCompiler.is_verb_allowed?("/api/users/abc", "DELETE")
```

---

#### `get_stealth_config/0`

Retrieves the compiled stealth configuration.

**Signature**:
```elixir
@spec get_stealth_config() :: %{enabled: boolean(), status_code: integer()} | nil
```

**Returns**:
- `%{enabled: true, status_code: 404}` - Stealth config
- `%{enabled: false, status_code: 403}` - Stealth disabled
- `nil` - No stealth config (default to 403)

**Examples**:

```elixir
# With stealth enabled
%{enabled: true, status_code: 404} = PolicyCompiler.get_stealth_config()

# With stealth disabled
%{enabled: false, status_code: 403} = PolicyCompiler.get_stealth_config()
```

---

## Gateway

**Module**: `HttpCapabilityGateway.Gateway`

HTTP gateway with verb enforcement using Plug.

### Functions

#### `call/2`

Plug callback for handling HTTP requests.

**Signature**:
```elixir
@spec call(Plug.Conn.t(), any()) :: Plug.Conn.t()
```

**Parameters**:
- `conn` (Plug.Conn.t): Incoming connection
- `_opts` (any): Options (unused)

**Returns**:
- Modified connection with response or proxy

**Request Flow**:
1. Extract request ID (or generate)
2. Extract trust level from header
3. Check if verb is allowed for path
4. If allowed: proxy to backend
5. If denied: return stealth response or 403

**Examples**:

```elixir
# This is typically called by Plug.Cowboy, not manually
conn = %Plug.Conn{method: "GET", request_path: "/api/users"}
conn = Gateway.call(conn, [])
# => Proxied response or error response
```

**Assigns**:
- `conn.assigns.request_id` - UUID for request tracking
- `conn.assigns.trust_level` - Extracted trust level (e.g., "high")

---

## Proxy

**Module**: `HttpCapabilityGateway.Proxy`

HTTP proxy for forwarding requests to backend services.

### Functions

#### `forward/1`

Forwards a request to the configured backend URL.

**Signature**:
```elixir
@spec forward(Plug.Conn.t()) :: Plug.Conn.t()
```

**Parameters**:
- `conn` (Plug.Conn.t): Connection with allowed verb

**Returns**:
- Connection with backend response

**Behavior**:
1. Constructs backend URL (backend_url + request_path)
2. Forwards HTTP method, headers, and body
3. Streams response back to client
4. Preserves status code and headers

**Examples**:

```elixir
# Proxy a GET request
conn = %Plug.Conn{
  method: "GET",
  request_path: "/api/users/123",
  req_headers: [{"x-request-id", "req-abc"}]
}

conn = Proxy.forward(conn)
# => conn.status = 200, conn.resp_body = "..." (from backend)
```

**Forwarded Headers**:
- `X-Request-ID` - Request correlation ID
- `X-Trust-Level` - Extracted trust level
- `X-Forwarded-For` - Client IP address
- All original request headers

---

## Logging

**Module**: `HttpCapabilityGateway.Logging`

Structured logging with telemetry integration.

### Functions

#### `log_request/3`

Logs a handled request with metadata.

**Signature**:
```elixir
@spec log_request(Plug.Conn.t(), boolean(), integer()) :: :ok
```

**Parameters**:
- `conn` (Plug.Conn.t): Request connection
- `verb_allowed` (boolean): Whether verb was allowed
- `duration_ms` (integer): Request duration in milliseconds

**Returns**:
- `:ok`

**Side Effects**:
- Emits telemetry event: `[:http_capability_gateway, :request, :handled]`
- Logs structured JSON log entry

**Log Fields**:
- `timestamp` - ISO 8601 timestamp
- `level` - Log level (info, warn, error)
- `message` - "request_handled"
- `request_id` - Request correlation ID
- `method` - HTTP method
- `path` - Request path
- `trust_level` - Extracted trust level
- `verb_allowed` - Boolean
- `stealth_triggered` - Boolean
- `response_status` - HTTP status code
- `duration_ms` - Request duration

**Examples**:

```elixir
conn = %Plug.Conn{
  assigns: %{request_id: "req-123", trust_level: "high"},
  method: "GET",
  request_path: "/api/users",
  status: 200
}

Logging.log_request(conn, true, 45)
# Logs: {"timestamp": "...", "message": "request_handled", ...}
```

---

## LogFormatter

**Module**: `HttpCapabilityGateway.LogFormatter`

JSON log formatter for structured logging.

### Functions

#### `format/4`

Formats log entries as JSON.

**Signature**:
```elixir
@spec format(atom(), term(), Logger.Formatter.time(), keyword()) :: IO.chardata()
```

**Parameters**:
- `level` (atom): Log level (:debug, :info, :warn, :error)
- `message` (term): Log message
- `timestamp` (Logger.Formatter.time): Log timestamp
- `metadata` (keyword): Log metadata

**Returns**:
- JSON-formatted log entry as IO.chardata

**Examples**:

```elixir
# This is used internally by Logger
Logger.configure_backend(:console, format: {LogFormatter, :format})

# Logs will be JSON:
# {"timestamp": "2026-01-22T23:00:00.000Z", "level": "info", "message": "request_handled", ...}
```

---

## Application

**Module**: `HttpCapabilityGateway.Application`

OTP application for gateway lifecycle management.

### Callbacks

#### `start/2`

Starts the application supervision tree.

**Signature**:
```elixir
@spec start(any(), any()) :: {:ok, pid()} | {:error, term()}
```

**Behavior**:
1. Loads policy from configured file
2. Validates policy
3. Compiles policy to ETS
4. Starts HTTP server (Plug.Cowboy)

**Configuration**:
```elixir
config :http_capability_gateway,
  policy_file: "priv/config/policy.dev.yaml",
  backend_url: "http://localhost:4000",
  port: 8080
```

**Examples**:

```elixir
# Start application (usually via mix)
{:ok, pid} = Application.start(:http_capability_gateway)

# Application will:
# 1. Load policy.yaml
# 2. Validate DSL v1
# 3. Compile to ETS
# 4. Start HTTP server on port 8080
```

---

## Type Specifications

### Policy Types

```elixir
@type policy :: %{
  required(String.t()) => String.t() | map() | list(),
  "dsl_version" => String.t(),
  "governance" => governance(),
  "stealth" => stealth() | nil
}

@type governance :: %{
  required(String.t()) => list() | list(route()),
  "global_verbs" => [http_verb()],
  "routes" => [route()] | nil
}

@type route :: %{
  required(String.t()) => String.t() | [http_verb()],
  "path" => String.t(),
  "verbs" => [http_verb()]
}

@type stealth :: %{
  required(String.t()) => boolean() | integer(),
  "enabled" => boolean(),
  "status_code" => integer()
}

@type http_verb :: String.t()
# Valid: "GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "HEAD" | "OPTIONS"
```

---

## Error Handling

### Common Errors

**PolicyLoader Errors**:
- `{:error, "File not found: ..."}` - Policy file doesn't exist
- `{:error, "YAML parsing error: ..."}` - Invalid YAML syntax
- `{:error, "Empty policy"}` - Policy file is empty

**PolicyValidator Errors**:
- `{:error, "dsl_version: must be present"}` - Missing version field
- `{:error, "Invalid HTTP verb: ..."}` - Unknown verb in policy
- `{:error, "global_verbs: must not be empty"}` - Empty verb list

**PolicyCompiler Errors**:
- `{:error, "Invalid regex pattern: ..."}` - Bad route pattern

**Runtime Errors**:
- Gateway returns 500 if backend connection fails
- Logs error with request_id for debugging

---

## Performance

### ETS Lookups

- **Global verbs**: O(1) lookup
- **Route matching**: O(n) where n = number of routes
- **Verb checking**: O(1) for route match

### Benchmarks

See `test/performance_test.exs` for detailed benchmarks:

```bash
mix test --only performance
```

Expected results:
- Policy compilation (1000 routes): <100ms
- Verb check: <1ms
- Request handling: <5ms (excluding backend)
- Throughput: >1000 req/s

---

## Examples

### Complete Usage Example

```elixir
# 1. Load policy
{:ok, policy} = PolicyLoader.load_from_file("policy.yaml")

# 2. Validate
:ok = PolicyValidator.validate(policy)

# 3. Compile
:ok = PolicyCompiler.compile(policy)

# 4. Check verbs
true = PolicyCompiler.is_verb_allowed?("/api/users", "GET")
false = PolicyCompiler.is_verb_allowed?("/api/admin", "DELETE")

# 5. Get stealth config
%{enabled: true, status_code: 404} = PolicyCompiler.get_stealth_config()

# 6. Gateway handles requests automatically via Plug
```

---

## Testing

### Unit Tests

```bash
# Test PolicyLoader
mix test test/policy_loader_test.exs

# Test PolicyValidator
mix test test/policy_validator_test.exs

# Test PolicyCompiler
mix test test/policy_compiler_test.exs

# Test Gateway
mix test test/gateway_test.exs
```

### Integration Tests

```bash
# Full request flow tests
mix test test/gateway_test.exs
```

### Property-Based Tests

```bash
# Invariant testing with StreamData
mix test test/policy_property_test.exs
```

---

## Support

For API questions:
- **GitHub Discussions**: https://github.com/hyperpolymath/http-capability-gateway/discussions
- **API Issues**: https://github.com/hyperpolymath/http-capability-gateway/issues
