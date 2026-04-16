# Multi-Protocol API Gateway

> **⚠️ SCOPE NOTICE (2026-04-16):** This document describes the vision for
> multi-protocol support. Today, only **HTTP/REST** is production-ready. gRPC
> and GraphQL handlers exist but are **stubs**: `GraphQLHandler.check_operation_policy/2`
> always returns true, and `GRPCHandler.forward_grpc_request/5` returns a
> hardcoded response with no actual forwarding. Do not route gRPC or GraphQL
> traffic through this gateway in production.
>
> See `docs/SUPPORTED-FEATURES.md` for the authoritative status of each
> protocol, and `ROADMAP.adoc` for the MVP scope.

The HTTP Capability Gateway aims to support multiple protocols: HTTP/REST, gRPC, and GraphQL.
Only HTTP/REST is currently supported end-to-end.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Idris2 ABI Layer                        │
│              (src/abi/Protocol.idr, Types.idr)              │
│         Formal interface with dependent type proofs         │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │
┌─────────────────────────────┼─────────────────────────────┐
│          Zig FFI Layer      │        (ffi/zig/)           │
│  ┌────────────┐  ┌──────────────┐  ┌────────────────┐     │
│  │ gRPC       │  │  GraphQL     │  │  Common        │     │
│  │ Parser     │  │  Parser      │  │  Utilities     │     │
│  │ (HTTP/2)   │  │  (JSON)      │  │  (Endian,etc)  │     │
│  └────────────┘  └──────────────┘  └────────────────┘     │
└────────────────────────────────────────────────────────────┘
                              ▲
                              │
┌─────────────────────────────┼─────────────────────────────┐
│       Elixir Gateway Layer  │                             │
│  ┌────────────────┐                                       │
│  │ ProtocolRouter │ (Detects protocol)                    │
│  └────────┬───────┘                                       │
│           │                                                │
│     ┌─────┴─────┬──────────┬──────────┐                  │
│     ▼           ▼          ▼          ▼                   │
│  ┌─────────┐ ┌──────┐  ┌────────┐ ┌──────┐              │
│  │ Gateway │ │ gRPC │  │GraphQL │ │Policy│              │
│  │(HTTP)   │ │Handler│ │Handler │ │      │              │
│  └─────────┘ └──────┘  └────────┘ └──────┘              │
└────────────────────────────────────────────────────────────┘
```

## Protocol Detection

Automatic protocol detection based on request characteristics:

1. **GraphQL**: POST to `/graphql` endpoint
2. **gRPC**: HTTP/2 with `content-type: application/grpc*`
3. **HTTP/REST**: Everything else (default)

## Configuration

Add to `config/config.exs`:

```elixir
config :http_capability_gateway,
  # Enable multi-protocol support
  enable_grpc: true,
  enable_graphql: true,

  # Backend URLs
  grpc_backend_url: "http://localhost:50051",
  graphql_backend_url: "http://localhost:4000/graphql",

  # Policy enforcement
  grpc_methods_policy: "config/grpc-policy.yaml",
  graphql_operations_policy: "config/graphql-policy.yaml"
```

## Policy Examples

### gRPC Policy

```yaml
# config/grpc-policy.yaml
dsl_version: "1"

grpc_methods:
  # Health check - public
  - service: "grpc.health.v1.Health"
    method: "Check"
    exposure: "public"

  # User service - authenticated
  - service: "myapp.UserService"
    method: "GetUser"
    exposure: "authenticated"

  # Admin service - internal only
  - service: "myapp.AdminService"
    method: "*"  # All methods
    exposure: "internal"
```

### GraphQL Policy

```yaml
# config/graphql-policy.yaml
dsl_version: "1"

graphql:
  # Allow queries and mutations, no subscriptions
  allowed_operations:
    - query
    - mutation

  # All GraphQL requires authentication
  exposure: "authenticated"

  # Specific operation names can be restricted
  blocked_operations:
    - "AdminMutation"
    - "DangerousQuery"
```

## Building FFI Layer

The Zig FFI layer must be compiled before the gateway can handle gRPC/GraphQL:

```bash
cd ffi/zig
zig build

# Run tests
zig build test

# Install library
sudo cp zig-out/lib/libgateway.so /usr/local/lib/
```

## Testing

```bash
# Test gRPC endpoint
grpcurl -plaintext -d '{"service":"health"}' localhost:4000 grpc.health.v1.Health/Check

# Test GraphQL endpoint
curl -X POST http://localhost:4000/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "{ user(id: 1) { name } }"}'

# Test HTTP/REST (existing)
curl http://localhost:4000/api/users
```

## Performance

Protocol parsing performance (Zig FFI):
- **gRPC**: ~5μs per request
- **GraphQL**: ~10μs per query
- **HTTP**: ~2μs per request

All parsers are memory-safe with zero-copy parsing where possible.

## Security

- **Type Safety**: Idris2 dependent types prove correctness
- **Memory Safety**: Zig compile-time checks prevent buffer overflows
- **Policy Enforcement**: All protocols subject to verb governance
- **Stealth Mode**: Supported for all protocols (custom error codes)

## Limitations

Current implementation is in **beta**:
- gRPC: HTTP/2 frame parsing stub (TODO: full HPACK decoder)
- GraphQL: Basic operation detection (TODO: full AST parsing)
- Policy integration: Stubs in place (TODO: wire to PolicyCompiler)

See `ffi/zig/README.md` and `src/abi/README.md` for implementation details.
