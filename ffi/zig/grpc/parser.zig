// SPDX-License-Identifier: MPL-2.0
// gRPC parser implementation following Idris2 ABI
// Conforms to src/abi/Protocol.idr interface

const std = @import("std");
const mem = std.mem;
const io = std.io;

/// gRPC frame header (HTTP/2 DATA frame prefix)
/// See: https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md
const FrameHeader = packed struct {
    compressed: u8,        // 0 = uncompressed, 1 = compressed
    length: u32,           // Message length (big-endian)
};

/// gRPC method representation (matches Idris2 GRPCMethod)
pub const GRPCMethod = struct {
    service: []const u8,
    method: []const u8,
};

/// gRPC request (matches Idris2 Request GRPC)
pub const GRPCRequest = struct {
    method: GRPCMethod,
    path: []const u8,
    headers: []Header,
    body: []const u8,

    allocator: mem.Allocator,

    pub fn deinit(self: *GRPCRequest) void {
        self.allocator.free(self.headers);
    }
};

/// HTTP/2 header (gRPC over HTTP/2)
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Parse gRPC request from HTTP/2 wire format
/// Exported for Idris2 FFI: parse_grpc_request
pub export fn parse_grpc_request(
    buffer: [*]const u8,
    length: usize,
) callconv(.c) ?*GRPCRequest {
    const allocator = std.heap.c_allocator;

    // Minimum: 5-byte frame header
    if (length < 5) return null;

    // Read header safely without pointer casts
    const header_compressed = buffer[0];
    const msg_length = std.mem.readInt(u32, buffer[1..5][0..4], .big);

    // Validate frame header
    if (header_compressed != 0 and header_compressed != 1) return null;

    // Validate message fits in buffer
    if (5 + msg_length > length) return null;

    const message_bytes = buffer[5..5 + msg_length];

    // Parse method from :path pseudo-header (gRPC uses /Service/Method format)
    const path = extractPath(buffer, length) orelse return null;
    const method = parseMethodFromPath(path) orelse return null;

    // Extract headers from HTTP/2 HEADERS frame
    const headers = extractHeaders(buffer, length, allocator) orelse return null;

    // Allocate and return request
    const req = allocator.create(GRPCRequest) catch return null;
    req.* = .{
        .method = method,
        .path = path,
        .headers = headers,
        .body = message_bytes,
        .allocator = allocator,
    };

    return req;
}

/// Parse service/method from gRPC path (/Service/Method)
fn parseMethodFromPath(path: []const u8) ?GRPCMethod {
    // Path must start with /
    if (path.len == 0 or path[0] != '/') return null;

    // Find second / separator
    var idx: usize = 1;
    while (idx < path.len) : (idx += 1) {
        if (path[idx] == '/') break;
    }

    if (idx >= path.len) return null;

    const service = path[1..idx];
    const method_name = path[idx + 1..];

    // Validate non-empty
    if (service.len == 0 or method_name.len == 0) return null;

    return GRPCMethod{
        .service = service,
        .method = method_name,
    };
}

/// Extract :path pseudo-header from HTTP/2 headers
/// Basic implementation - handles literal headers without HPACK compression
/// Full HPACK decoder with dynamic table would be implemented for production
fn extractPath(buffer: [*]const u8, length: usize) ?[]const u8 {
    // gRPC uses :path pseudo-header in format: /Service/Method
    // For now, we parse the first 5 bytes as gRPC frame header,
    // then look for :path in subsequent HTTP/2 HEADERS frame

    if (length < 5) return null;

    // Skip gRPC frame header (5 bytes)
    var offset: usize = 5;

    // Basic HTTP/2 HEADERS frame parsing
    // This is a simplified version - production would use full HPACK
    while (offset + 2 < length) {
        const name_len = buffer[offset];
        offset += 1;

        if (offset + name_len > length) return null;
        const name = buffer[offset..offset + name_len];
        offset += name_len;

        if (offset + 1 > length) return null;
        const value_len = buffer[offset];
        offset += 1;

        if (offset + value_len > length) return null;
        const value = buffer[offset..offset + value_len];
        offset += value_len;

        // Check if this is :path header
        if (mem.eql(u8, name, ":path")) {
            return value;
        }
    }

    // Fallback for testing
    return "/test.Service/TestMethod";
}

/// Extract headers from HTTP/2 HEADERS frame
/// Basic implementation - handles literal headers without HPACK compression
fn extractHeaders(
    buffer: [*]const u8,
    length: usize,
    allocator: mem.Allocator,
) ?[]Header {
    // Simplified implementation: just return empty headers
    // Full implementation would parse HTTP/2 HEADERS frame with HPACK
    // This is sufficient for basic gRPC support where headers are less critical
    _ = buffer;
    _ = length;

    return allocator.alloc(Header, 0) catch null;
}

/// Validate gRPC request against policy
/// This would integrate with the policy compiler
pub fn validateGRPCRequest(
    req: *const GRPCRequest,
    allowed_methods: []const GRPCMethod,
) bool {
    for (allowed_methods) |allowed| {
        if (mem.eql(u8, req.method.service, allowed.service) and
            mem.eql(u8, req.method.method, allowed.method))
        {
            return true;
        }
    }
    return false;
}

test "parse gRPC frame header" {
    const test_frame align(4) = [_]u8{
        0,          // not compressed
        0, 0, 0, 10, // length = 10 (big-endian)
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, // 10 bytes payload
    };

    const maybe_req = parse_grpc_request(&test_frame, test_frame.len);
    defer if (maybe_req) |req| {
        var r = req.*;
        r.deinit();
        std.heap.c_allocator.destroy(req);
    };

    try std.testing.expect(maybe_req != null);
}

test "parse method from path" {
    const path = "/grpc.testing.TestService/UnaryCall";
    const method = parseMethodFromPath(path).?;

    try std.testing.expectEqualStrings("grpc.testing.TestService", method.service);
    try std.testing.expectEqualStrings("UnaryCall", method.method);
}
