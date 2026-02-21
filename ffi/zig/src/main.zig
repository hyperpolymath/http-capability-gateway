// SPDX-License-Identifier: PMPL-1.0-or-later
// Main entry point for gateway FFI library
// Exports functions matching src/abi/Protocol.idr interface

const std = @import("std");

/// Platform endianness detection
/// Exported for Idris2: platform_endian
pub export fn platform_endian() callconv(.c) u8 {
    return switch (@import("builtin").target.cpu.arch.endian()) {
        .little => 0,  // LittleEndian
        .big => 1,     // BigEndian
    };
}

/// Serialize response to wire format
/// Exported for Idris2: serialize_response
pub export fn serialize_response(
    status_code: u32,
    headers_ptr: [*]const u8,
    headers_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
    out_ptr: *[*]u8,
    out_len: *usize,
) callconv(.c) bool {
    _ = status_code;
    _ = headers_ptr;
    _ = headers_len;
    _ = body_ptr;
    _ = body_len;
    _ = out_ptr;
    _ = out_len;

    // TODO: Implement HTTP/2 frame serialization
    return false;
}

test "endian detection" {
    const endian = platform_endian();
    try std.testing.expect(endian == 0 or endian == 1);
}
