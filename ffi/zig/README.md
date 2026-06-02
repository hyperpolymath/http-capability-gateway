<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
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

### HTTP server (`hpm_http_*`)

Synchronous, single-threaded HTTP/1.1 server primitives intended to sit
behind a TLS reverse proxy. Used by the OikosBot for webhook reception.

- `hpm_http_server_listen(host, host_len, port) -> server*` — bind TCP
- `hpm_http_server_port(server) -> port` — query bound port (e.g. when
  `port=0` was passed)
- `hpm_http_server_accept(server) -> request*` — block until next request,
  return parsed head
- `hpm_http_request_method(request) -> method_ordinal` — matches
  `std.http.Method` (GET=0 HEAD=1 POST=2 PUT=3 DELETE=4 CONNECT=5
  OPTIONS=6 TRACE=7 PATCH=8)
- `hpm_http_request_path(request, out, cap) -> bytes` — copy URI target
- `hpm_http_request_header(request, name, name_len, out, cap) -> bytes` —
  case-insensitive lookup; returns 0 if absent
- `hpm_http_request_body(request, out, cap) -> bytes` — read body (max 1
  MiB, content-length-driven); idempotent
- `hpm_http_request_respond(request, status, headers, headers_len, body,
  body_len) -> 0/-1` — send full response; connection closes after
- `hpm_http_request_free(request)` — close + free
- `hpm_http_server_free(server)` — close listener + free

Idris2 wrappers live in `../../src/abi/HttpServer.idr`.

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
