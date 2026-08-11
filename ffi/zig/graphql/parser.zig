// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// GraphQL parser implementation following Idris2 ABI
// Conforms to src/abi/Protocol.idr interface

const std = @import("std");
const mem = std.mem;

/// GraphQL operation type (matches Idris2 GraphQLOp)
pub const GraphQLOp = enum(u8) {
    query = 0,
    mutation = 1,
    subscription = 2,
};

/// GraphQL operation (matches Idris2 ProtocolMethod GraphQL)
pub const GraphQLOperation = struct {
    op_type: GraphQLOp,
    name: ?[]const u8,  // Operation name (optional)
    selections: []const u8,  // Selection set (GraphQL AST as string for now)
};

/// GraphQL request (matches Idris2 Request GraphQL)
pub const GraphQLRequest = struct {
    method: GraphQLOperation,
    path: []const u8,  // Always "/graphql" for GraphQL
    headers: []Header,
    body: []const u8,  // JSON-encoded query

    allocator: mem.Allocator,

    pub fn deinit(self: *GraphQLRequest) void {
        self.allocator.free(self.headers);
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// GraphQL query structure (from JSON body)
const QueryBody = struct {
    query: []const u8,
    operationName: ?[]const u8 = null,
    variables: ?std.json.Value = null,
};

/// Parse GraphQL request from HTTP body
/// Exported for Idris2 FFI: parse_graphql_request
pub export fn parse_graphql_request(
    buffer: [*]const u8,
    length: usize,
) callconv(.C) ?*GraphQLRequest {
    const allocator = std.heap.c_allocator;

    if (length == 0) return null;

    // GraphQL queries come as JSON in POST body
    // Format: {"query": "query { ... }", "operationName": "...", "variables": {...}}
    const body = buffer[0..length];

    // Parse JSON
    const parsed = std.json.parseFromSlice(
        QueryBody,
        allocator,
        body,
        .{},
    ) catch return null;
    defer parsed.deinit();

    const query_body = parsed.value;

    // Detect operation type from query string
    const op_type = detectOperationType(query_body.query) orelse .query;

    const method = GraphQLOperation{
        .op_type = op_type,
        .name = query_body.operationName,
        .selections = query_body.query,
    };

    // Allocate request
    const req = allocator.create(GraphQLRequest) catch return null;

    // Empty headers for now (would be parsed from HTTP layer)
    const headers = allocator.alloc(Header, 0) catch {
        allocator.destroy(req);
        return null;
    };

    req.* = .{
        .method = method,
        .path = "/graphql",
        .headers = headers,
        .body = body,
        .allocator = allocator,
    };

    return req;
}

/// Detect GraphQL operation type from query string
fn detectOperationType(query: []const u8) ?GraphQLOp {
    // Skip whitespace
    var idx: usize = 0;
    while (idx < query.len and std.ascii.isWhitespace(query[idx])) : (idx += 1) {}

    if (idx >= query.len) return null;

    // Check for operation keyword
    if (mem.startsWith(u8, query[idx..], "mutation")) {
        return .mutation;
    } else if (mem.startsWith(u8, query[idx..], "subscription")) {
        return .subscription;
    } else if (mem.startsWith(u8, query[idx..], "query")) {
        return .query;
    } else if (query[idx] == '{') {
        // Shorthand query syntax (no "query" keyword)
        return .query;
    }

    return null;
}

/// Validate GraphQL request against policy
pub fn validateGraphQLRequest(
    req: *const GraphQLRequest,
    allowed_operations: []const GraphQLOp,
) bool {
    for (allowed_operations) |allowed| {
        if (req.method.op_type == allowed) {
            return true;
        }
    }
    return false;
}

/// Extract operation name from GraphQL query (if present)
pub fn extractOperationName(query: []const u8, allocator: mem.Allocator) ?[]const u8 {
    // Find operation keyword
    var idx: usize = 0;
    while (idx < query.len) : (idx += 1) {
        if (mem.startsWith(u8, query[idx..], "query") or
            mem.startsWith(u8, query[idx..], "mutation") or
            mem.startsWith(u8, query[idx..], "subscription"))
        {
            // Skip keyword
            const keyword_len = if (mem.startsWith(u8, query[idx..], "subscription"))
                12
            else if (mem.startsWith(u8, query[idx..], "mutation"))
                8
            else
                5;

            idx += keyword_len;

            // Skip whitespace
            while (idx < query.len and std.ascii.isWhitespace(query[idx])) : (idx += 1) {}

            if (idx >= query.len or query[idx] == '{') return null;

            // Extract name until whitespace or {
            const start = idx;
            while (idx < query.len and
                !std.ascii.isWhitespace(query[idx]) and
                query[idx] != '{') : (idx += 1) {}

            const name = allocator.dupe(u8, query[start..idx]) catch return null;
            return name;
        }
    }

    return null;
}

test "detect operation type - query" {
    const query1 = "query { user { id name } }";
    const op1 = detectOperationType(query1).?;
    try std.testing.expect(op1 == .query);

    const query2 = "  { user { id } }";  // Shorthand
    const op2 = detectOperationType(query2).?;
    try std.testing.expect(op2 == .query);
}

test "detect operation type - mutation" {
    const query = "mutation { createUser(name: \"Alice\") { id } }";
    const op = detectOperationType(query).?;
    try std.testing.expect(op == .mutation);
}

test "detect operation type - subscription" {
    const query = "subscription { userUpdated { id name } }";
    const op = detectOperationType(query).?;
    try std.testing.expect(op == .subscription);
}

test "parse graphql request" {
    const json_body =
        \\{"query": "query GetUser { user { id name } }", "operationName": "GetUser"}
    ;

    const maybe_req = parse_graphql_request(json_body.ptr, json_body.len);
    defer if (maybe_req) |req| {
        var r = req.*;
        r.deinit();
        std.heap.c_allocator.destroy(req);
    };

    try std.testing.expect(maybe_req != null);
    const req = maybe_req.?;
    try std.testing.expect(req.method.op_type == .query);
}

test "extract operation name" {
    const allocator = std.testing.allocator;

    const query = "query GetUser { user { id } }";
    const name = extractOperationName(query, allocator).?;
    defer allocator.free(name);

    try std.testing.expectEqualStrings("GetUser", name);
}
