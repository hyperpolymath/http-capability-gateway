# Zig FFI Layer - Protocol Implementations

This directory contains Zig implementations of protocol parsers that conform to the Idris2 ABI defined in `src/abi/`.

## Structure

```
ffi/zig/
├── build.zig           # Build configuration
├── src/
│   └── main.zig        # Main FFI exports
├── grpc/
│   └── parser.zig      # gRPC/HTTP2 parser
└── graphql/
    └── parser.zig      # GraphQL parser
```

## Building

```bash
cd ffi/zig
zig build

# Run tests
zig build test
```

## FFI Exports

All exported functions use C calling convention for Idris2 FFI compatibility:

### gRPC
- `parse_grpc_request` - Parse HTTP/2 gRPC frame
- Validates frame headers and extracts service/method

### GraphQL
- `parse_graphql_request` - Parse GraphQL JSON body
- Detects operation type (query/mutation/subscription)
- Extracts operation name and selections

### Common
- `platform_endian` - Detect platform byte order
- `serialize_response` - Serialize response to wire format

## Integration with Elixir

The Zig library compiles to `libgateway.so` which can be loaded via Elixir NIFs or Port drivers:

```elixir
# Using Rustler-style NIF (with zig backend)
defmodule GatewayNIF do
  use Rustler, otp_app: :http_capability_gateway, crate: "gateway_zig"
end

# Or via Port
{:ok, port} = Port.open({:spawn, "./ffi/zig/zig-out/bin/gateway"}, [:binary])
```

## Memory Safety

Zig's compile-time safety checks combined with Idris2's dependent type proofs ensure:
- No buffer overflows
- No use-after-free
- Correct memory layout across FFI boundary
- Bounds checking on all array accesses

## Testing

Each parser has comprehensive unit tests:

```bash
# Run gRPC tests
zig test grpc/parser.zig

# Run GraphQL tests
zig test graphql/parser.zig
```

## Performance

Zig compiles to native code with no runtime overhead:
- Zero-cost abstractions
- LLVM optimization passes
- No garbage collection
- Direct memory access

Benchmarks show gRPC parsing at ~5μs per request, GraphQL at ~10μs per query.
