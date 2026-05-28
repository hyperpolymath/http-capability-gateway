// HTTP_CAPABILITY_GATEWAY FFI Implementation
//
// This module implements the C-compatible FFI declared in src/abi/Foreign.idr
// All types and layouts must match the Idris2 ABI definitions.
//
// SPDX-License-Identifier: PMPL-1.0-or-later

const std = @import("std");
const net = std.net;
const http = std.http;

// Version information (keep in sync with project)
const VERSION = "0.1.0";
const BUILD_INFO = "HTTP_CAPABILITY_GATEWAY built with Zig " ++ @import("builtin").zig_version_string;

/// Thread-local error storage
threadlocal var last_error: ?[]const u8 = null;

/// Set the last error message
fn setError(msg: []const u8) void {
    last_error = msg;
}

/// Clear the last error
fn clearError() void {
    last_error = null;
}

//==============================================================================
// Core Types (must match src/abi/Types.idr)
//==============================================================================

/// Result codes (must match Idris2 Result type)
pub const Result = enum(c_int) {
    ok = 0,
    @"error" = 1,
    invalid_param = 2,
    out_of_memory = 3,
    null_pointer = 4,
};

/// Library handle. Internals are hidden from C callers behind `?*Handle`;
/// the struct itself must be a regular Zig struct (not `opaque`) because
/// Zig 0.15 forbids fields on `opaque {}`.
pub const Handle = struct {
    allocator: std.mem.Allocator,
    initialized: bool,
};

//==============================================================================
// Library Lifecycle
//==============================================================================

/// Initialize the library
/// Returns a handle, or null on failure
export fn http_capability_gateway_init() ?*Handle {
    const allocator = std.heap.c_allocator;

    const handle = allocator.create(Handle) catch {
        setError("Failed to allocate handle");
        return null;
    };

    // Initialize handle
    handle.* = .{
        .allocator = allocator,
        .initialized = true,
    };

    clearError();
    return handle;
}

/// Free the library handle
export fn http_capability_gateway_free(handle: ?*Handle) void {
    const h = handle orelse return;
    const allocator = h.allocator;

    // Clean up resources
    h.initialized = false;

    allocator.destroy(h);
    clearError();
}

//==============================================================================
// Core Operations
//==============================================================================

/// Process data (example operation)
export fn http_capability_gateway_process(handle: ?*Handle, input: u32) Result {
    const h = handle orelse {
        setError("Null handle");
        return .null_pointer;
    };

    if (!h.initialized) {
        setError("Handle not initialized");
        return .@"error";
    }

    // Example processing logic
    _ = input;

    clearError();
    return .ok;
}

//==============================================================================
// String Operations
//==============================================================================

/// Get a string result (example)
/// Caller must free the returned string
export fn http_capability_gateway_get_string(handle: ?*Handle) ?[*:0]const u8 {
    const h = handle orelse {
        setError("Null handle");
        return null;
    };

    if (!h.initialized) {
        setError("Handle not initialized");
        return null;
    }

    // Example: allocate and return a string
    const result = h.allocator.dupeZ(u8, "Example result") catch {
        setError("Failed to allocate string");
        return null;
    };

    clearError();
    return result.ptr;
}

/// Free a string allocated by the library
export fn http_capability_gateway_free_string(str: ?[*:0]const u8) void {
    const s = str orelse return;
    const allocator = std.heap.c_allocator;

    const slice = std.mem.span(s);
    allocator.free(slice);
}

//==============================================================================
// Array/Buffer Operations
//==============================================================================

/// Process an array of data
export fn http_capability_gateway_process_array(
    handle: ?*Handle,
    buffer: ?[*]const u8,
    len: u32,
) Result {
    const h = handle orelse {
        setError("Null handle");
        return .null_pointer;
    };

    const buf = buffer orelse {
        setError("Null buffer");
        return .null_pointer;
    };

    if (!h.initialized) {
        setError("Handle not initialized");
        return .@"error";
    }

    // Access the buffer
    const data = buf[0..len];
    _ = data;

    // Process data here

    clearError();
    return .ok;
}

//==============================================================================
// Error Handling
//==============================================================================

/// Get the last error message
/// Returns null if no error
export fn http_capability_gateway_last_error() ?[*:0]const u8 {
    const err = last_error orelse return null;

    // Return C string (static storage, no need to free)
    const allocator = std.heap.c_allocator;
    const c_str = allocator.dupeZ(u8, err) catch return null;
    return c_str.ptr;
}

//==============================================================================
// Version Information
//==============================================================================

/// Get the library version
export fn http_capability_gateway_version() [*:0]const u8 {
    return VERSION.ptr;
}

/// Get build information
export fn http_capability_gateway_build_info() [*:0]const u8 {
    return BUILD_INFO.ptr;
}

//==============================================================================
// Callback Support
//==============================================================================

/// Callback function type (C ABI)
pub const Callback = *const fn (u64, u32) callconv(.c) u32;

/// Register a callback
export fn http_capability_gateway_register_callback(
    handle: ?*Handle,
    callback: ?Callback,
) Result {
    const h = handle orelse {
        setError("Null handle");
        return .null_pointer;
    };

    const cb = callback orelse {
        setError("Null callback");
        return .null_pointer;
    };

    if (!h.initialized) {
        setError("Handle not initialized");
        return .@"error";
    }

    // Store callback for later use
    _ = cb;

    clearError();
    return .ok;
}

//==============================================================================
// Utility Functions
//==============================================================================

/// Check if handle is initialized
export fn http_capability_gateway_is_initialized(handle: ?*Handle) u32 {
    const h = handle orelse return 0;
    return if (h.initialized) 1 else 0;
}

//==============================================================================
// HTTP server primitives (hpm_http_server_*)
//
// Synchronous, single-threaded HTTP/1.1 server intended to sit behind a TLS
// reverse proxy (Caddy / nginx). Designed for the OikosBot's webhook
// receiver path: bind once, accept in a loop, inspect the request, reply,
// free. No keep-alive — every response closes the connection.
//
// The OikosBot links libhpm_crypto.so (for HMAC + RS256) alongside this
// library. Both surfaces are intentionally narrow: no router, no TLS, no
// concurrency primitives. Caller composes.
//==============================================================================

const HTTP_RECV_BUF = 16 * 1024;
const HTTP_SEND_BUF = 16 * 1024;
const HTTP_BODY_SCRATCH = 4 * 1024;
const HTTP_MAX_BODY_BYTES = 1 * 1024 * 1024;

/// One per call to `hpm_http_server_listen`. Owns the TCP listener.
pub const HpmHttpServer = struct {
    listener: net.Server,
    allocator: std.mem.Allocator,
};

/// One per call to `hpm_http_server_accept`. Owns the connection + IO
/// buffers + parsed request. Must be freed exactly once with
/// `hpm_http_request_free`.
pub const HpmHttpRequest = struct {
    allocator: std.mem.Allocator,
    connection: net.Server.Connection,
    recv_buf: [HTTP_RECV_BUF]u8,
    send_buf: [HTTP_SEND_BUF]u8,
    conn_reader: net.Stream.Reader,
    conn_writer: net.Stream.Writer,
    http_server: http.Server,
    request: http.Server.Request,
    body_consumed: bool,
    responded: bool,
};

/// Bind a TCP listener on `host:port`. Host is an IPv4/IPv6 string
/// (e.g. "0.0.0.0", "127.0.0.1", "::1"). Returns an opaque server handle
/// or NULL on error. Free with `hpm_http_server_free`.
export fn hpm_http_server_listen(
    host_ptr: ?[*]const u8,
    host_len: usize,
    port: u16,
) ?*HpmHttpServer {
    const allocator = std.heap.c_allocator;
    const hp = host_ptr orelse return null;
    if (host_len == 0) return null;
    const host = hp[0..host_len];

    const addr = net.Address.parseIp(host, port) catch return null;
    var listener = addr.listen(.{ .reuse_address = true }) catch return null;

    const ctx = allocator.create(HpmHttpServer) catch {
        listener.deinit();
        return null;
    };
    ctx.* = .{
        .listener = listener,
        .allocator = allocator,
    };
    return ctx;
}

/// Returns the actual port the listener is bound to. Useful when
/// `port` was passed as 0 to `listen` (kernel-picked). Returns 0 on
/// null pointer.
export fn hpm_http_server_port(server: ?*HpmHttpServer) u16 {
    const s = server orelse return 0;
    return s.listener.listen_address.getPort();
}

/// Close the listener and free the handle. Does not affect requests
/// already returned by `accept` — those must be freed independently.
export fn hpm_http_server_free(server: ?*HpmHttpServer) void {
    const s = server orelse return;
    s.listener.deinit();
    s.allocator.destroy(s);
}

/// Block until a request arrives, parse its head, return a request
/// handle. Returns NULL if accept failed, the client sent a malformed
/// head, or the allocator failed. The TCP connection is closed
/// automatically on failure.
export fn hpm_http_server_accept(server: ?*HpmHttpServer) ?*HpmHttpRequest {
    const s = server orelse return null;
    const allocator = s.allocator;

    const conn = s.listener.accept() catch return null;

    const ctx = allocator.create(HpmHttpRequest) catch {
        conn.stream.close();
        return null;
    };

    ctx.* = .{
        .allocator = allocator,
        .connection = conn,
        .recv_buf = undefined,
        .send_buf = undefined,
        .conn_reader = undefined,
        .conn_writer = undefined,
        .http_server = undefined,
        .request = undefined,
        .body_consumed = false,
        .responded = false,
    };

    // Wire up reader/writer/http server. All inner pointers (Io.Reader,
    // Io.Writer, http.Server) reference fields inside `ctx`, which is
    // heap-allocated and therefore has a stable address.
    ctx.conn_reader = conn.stream.reader(&ctx.recv_buf);
    ctx.conn_writer = conn.stream.writer(&ctx.send_buf);
    ctx.http_server = http.Server.init(ctx.conn_reader.interface(), &ctx.conn_writer.interface);

    ctx.request = ctx.http_server.receiveHead() catch {
        conn.stream.close();
        allocator.destroy(ctx);
        return null;
    };
    // After receiveHead, `request.server` was set during the call but to a
    // value relative to the http.Server inside ctx — that's already stable
    // because ctx is heap-allocated.

    return ctx;
}

/// Returns the request method's ordinal, matching `std.http.Method`:
/// 0=GET 1=HEAD 2=POST 3=PUT 4=DELETE 5=CONNECT 6=OPTIONS 7=TRACE 8=PATCH.
/// Returns -1 on null pointer.
export fn hpm_http_request_method(req: ?*HpmHttpRequest) c_int {
    const r = req orelse return -1;
    return @intCast(@intFromEnum(r.request.head.method));
}

/// Copy the request target (URI path + query) into `out_ptr`. Returns
/// bytes written, or the required size if `out_ptr` is NULL or `cap` is
/// 0 (size-query). Returns -1 if `cap < required` or `req` is NULL.
export fn hpm_http_request_path(
    req: ?*HpmHttpRequest,
    out_ptr: ?[*]u8,
    cap: usize,
) isize {
    const r = req orelse return -1;
    const target = r.request.head.target;
    if (out_ptr == null or cap == 0) return @intCast(target.len);
    if (cap < target.len) return -1;
    @memcpy(out_ptr.?[0..target.len], target);
    return @intCast(target.len);
}

/// Look up a request header by case-insensitive name. Writes value into
/// `out_ptr`. Returns bytes written, 0 if header absent (out untouched),
/// the required size if `out_ptr` is NULL or `cap` is 0 (size-query, 0
/// still means absent), or -1 on `cap < required` / null req / null
/// name.
export fn hpm_http_request_header(
    req: ?*HpmHttpRequest,
    name_ptr: ?[*]const u8,
    name_len: usize,
    out_ptr: ?[*]u8,
    cap: usize,
) isize {
    const r = req orelse return -1;
    const np = name_ptr orelse return -1;
    if (name_len == 0) return -1;
    const name = np[0..name_len];

    var it = r.request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) {
            const v = h.value;
            if (out_ptr == null or cap == 0) return @intCast(v.len);
            if (cap < v.len) return -1;
            @memcpy(out_ptr.?[0..v.len], v);
            return @intCast(v.len);
        }
    }
    return 0;
}

/// Read the entire request body into `out_ptr`. Returns bytes read.
/// If `out_ptr` is NULL or `cap` is 0, returns the body size from
/// `Content-Length` (size-query) without consuming. Returns -1 on
/// over-cap, over-`HTTP_MAX_BODY_BYTES`, IO error, or null req. May
/// only be called once per request — subsequent calls return 0.
export fn hpm_http_request_body(
    req: ?*HpmHttpRequest,
    out_ptr: ?[*]u8,
    cap: usize,
) isize {
    const r = req orelse return -1;
    if (r.body_consumed) return 0;

    const cl_opt = r.request.head.content_length;
    const cl: usize = if (cl_opt) |v| @intCast(v) else 0;

    if (cl > HTTP_MAX_BODY_BYTES) return -1;
    if (out_ptr == null or cap == 0) return @intCast(cl);
    if (cap < cl) return -1;
    if (cl == 0) {
        r.body_consumed = true;
        return 0;
    }

    var scratch: [HTTP_BODY_SCRATCH]u8 = undefined;
    const reader = r.request.readerExpectNone(&scratch);

    var total: usize = 0;
    while (total < cl) {
        const n = reader.readSliceShort(out_ptr.?[total..cl]) catch return -1;
        if (n == 0) break;
        total += n;
    }
    r.body_consumed = true;
    return @intCast(total);
}

/// Send a complete HTTP response. `status` is the numeric status code
/// (e.g. 200, 404, 500). `headers_ptr` / `headers_len` is an optional
/// buffer of extra headers in "Name:Value\r\nName:Value\r\n" format
/// (max 16 entries). `body_ptr` / `body_len` is the response body.
/// Connection is always closed after (no keep-alive). Returns 0 on
/// success, -1 on error.
export fn hpm_http_request_respond(
    req: ?*HpmHttpRequest,
    status: u16,
    headers_ptr: ?[*]const u8,
    headers_len: usize,
    body_ptr: ?[*]const u8,
    body_len: usize,
) c_int {
    const r = req orelse return -1;
    if (r.responded) return -1;

    var extra_storage: [16]http.Header = undefined;
    var n_extra: usize = 0;

    if (headers_ptr) |hp| {
        if (headers_len > 0) {
            const hdrs = hp[0..headers_len];
            var lines = std.mem.splitSequence(u8, hdrs, "\r\n");
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (colon == 0) continue;
                if (n_extra >= extra_storage.len) return -1;
                extra_storage[n_extra] = .{
                    .name = line[0..colon],
                    .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
                };
                n_extra += 1;
            }
        }
    }

    const body = if (body_ptr) |bp| bp[0..body_len] else "";
    const st: http.Status = @enumFromInt(@as(u10, @truncate(status)));

    r.request.respond(body, .{
        .status = st,
        .extra_headers = extra_storage[0..n_extra],
        .keep_alive = false,
    }) catch return -1;

    r.responded = true;
    return 0;
}

/// Close the TCP connection and free the request handle. Must be
/// called exactly once for every request returned by `accept`.
export fn hpm_http_request_free(req: ?*HpmHttpRequest) void {
    const r = req orelse return;
    r.connection.stream.close();
    r.allocator.destroy(r);
}

//==============================================================================
// Tests
//==============================================================================

test "lifecycle" {
    const handle = http_capability_gateway_init() orelse return error.InitFailed;
    defer http_capability_gateway_free(handle);

    try std.testing.expect(http_capability_gateway_is_initialized(handle) == 1);
}

test "error handling" {
    const result = http_capability_gateway_process(null, 0);
    try std.testing.expectEqual(Result.null_pointer, result);

    const err = http_capability_gateway_last_error();
    try std.testing.expect(err != null);
}

test "version" {
    const ver = http_capability_gateway_version();
    const ver_str = std.mem.span(ver);
    try std.testing.expectEqualStrings(VERSION, ver_str);
}

//------------------------------------------------------------------------------
// HTTP server tests
//------------------------------------------------------------------------------
//
// Each test spawns a single-accept server on 127.0.0.1:0 (kernel-picked
// port), then drives a raw TCP client on the main thread.
//------------------------------------------------------------------------------

const ServerThreadCtx = struct {
    server: *HpmHttpServer,
    /// Filled in by the server thread for the test thread to inspect.
    method_out: c_int = -1,
    path_out: [256]u8 = undefined,
    path_len: isize = -1,
    body_out: [256]u8 = undefined,
    body_len: isize = -1,
    header_out: [256]u8 = undefined,
    header_len: isize = -1,
    respond_rc: c_int = -1,
    /// What status to respond with.
    reply_status: u16 = 200,
    reply_body: []const u8 = "ok",
    reply_extra_headers: []const u8 = "",
    /// Tell server to call `body()` before responding.
    consume_body: bool = false,
    /// Tell server to look up this header (case-insensitive).
    lookup_header_name: []const u8 = "",
};

fn testServerThreadFn(ctx: *ServerThreadCtx) void {
    const req = hpm_http_server_accept(ctx.server) orelse return;
    defer hpm_http_request_free(req);

    ctx.method_out = hpm_http_request_method(req);
    ctx.path_len = hpm_http_request_path(req, &ctx.path_out, ctx.path_out.len);

    if (ctx.lookup_header_name.len > 0) {
        ctx.header_len = hpm_http_request_header(
            req,
            ctx.lookup_header_name.ptr,
            ctx.lookup_header_name.len,
            &ctx.header_out,
            ctx.header_out.len,
        );
    }

    if (ctx.consume_body) {
        ctx.body_len = hpm_http_request_body(req, &ctx.body_out, ctx.body_out.len);
    }

    ctx.respond_rc = hpm_http_request_respond(
        req,
        ctx.reply_status,
        if (ctx.reply_extra_headers.len > 0) ctx.reply_extra_headers.ptr else null,
        ctx.reply_extra_headers.len,
        ctx.reply_body.ptr,
        ctx.reply_body.len,
    );
}

fn sendAndReceive(port: u16, request_bytes: []const u8, response_out: []u8) !usize {
    const addr = try net.Address.parseIp("127.0.0.1", port);
    const stream = try net.tcpConnectToAddress(addr);
    defer stream.close();

    var write_buf: [4096]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var w = stream.writer(&write_buf);
    var r = stream.reader(&read_buf);
    try w.interface.writeAll(request_bytes);
    try w.interface.flush();

    var total: usize = 0;
    while (total < response_out.len) {
        const n = r.interface().readSliceShort(response_out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

test "http server: listen on invalid host returns null" {
    const bogus = "not-a-valid-ip";
    const s = hpm_http_server_listen(bogus.ptr, bogus.len, 0);
    try std.testing.expect(s == null);
}

test "http server: listen with null host returns null" {
    const s = hpm_http_server_listen(null, 0, 0);
    try std.testing.expect(s == null);
}

test "http server: port reflects bound port" {
    const host = "127.0.0.1";
    const s = hpm_http_server_listen(host.ptr, host.len, 0) orelse return error.ListenFailed;
    defer hpm_http_server_free(s);

    const p = hpm_http_server_port(s);
    try std.testing.expect(p != 0);
}

test "http server: GET round trip" {
    const host = "127.0.0.1";
    const s = hpm_http_server_listen(host.ptr, host.len, 0) orelse return error.ListenFailed;
    defer hpm_http_server_free(s);
    const port = hpm_http_server_port(s);

    var ctx: ServerThreadCtx = .{ .server = s };
    const t = try std.Thread.spawn(.{}, testServerThreadFn, .{&ctx});

    var resp_buf: [1024]u8 = undefined;
    const req = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const n = try sendAndReceive(port, req, &resp_buf);
    t.join();

    try std.testing.expectEqual(@as(c_int, @intCast(@intFromEnum(http.Method.GET))), ctx.method_out);
    try std.testing.expectEqualStrings("/hello", ctx.path_out[0..@intCast(ctx.path_len)]);
    try std.testing.expectEqual(@as(c_int, 0), ctx.respond_rc);
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "ok") != null);
}

test "http server: POST body is read" {
    const host = "127.0.0.1";
    const s = hpm_http_server_listen(host.ptr, host.len, 0) orelse return error.ListenFailed;
    defer hpm_http_server_free(s);
    const port = hpm_http_server_port(s);

    var ctx: ServerThreadCtx = .{ .server = s, .consume_body = true };
    const t = try std.Thread.spawn(.{}, testServerThreadFn, .{&ctx});

    var resp_buf: [1024]u8 = undefined;
    const req = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world";
    _ = try sendAndReceive(port, req, &resp_buf);
    t.join();

    try std.testing.expectEqual(@as(c_int, @intCast(@intFromEnum(http.Method.POST))), ctx.method_out);
    try std.testing.expectEqualStrings("/webhook", ctx.path_out[0..@intCast(ctx.path_len)]);
    try std.testing.expectEqualStrings("hello world", ctx.body_out[0..@intCast(ctx.body_len)]);
}

test "http server: header lookup case-insensitive" {
    const host = "127.0.0.1";
    const s = hpm_http_server_listen(host.ptr, host.len, 0) orelse return error.ListenFailed;
    defer hpm_http_server_free(s);
    const port = hpm_http_server_port(s);

    var ctx: ServerThreadCtx = .{ .server = s, .lookup_header_name = "x-hub-signature-256" };
    const t = try std.Thread.spawn(.{}, testServerThreadFn, .{&ctx});

    var resp_buf: [1024]u8 = undefined;
    const req = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Hub-Signature-256: sha256=abcdef\r\nConnection: close\r\n\r\n";
    _ = try sendAndReceive(port, req, &resp_buf);
    t.join();

    try std.testing.expectEqualStrings("sha256=abcdef", ctx.header_out[0..@intCast(ctx.header_len)]);
}

test "http server: header absent returns zero" {
    const host = "127.0.0.1";
    const s = hpm_http_server_listen(host.ptr, host.len, 0) orelse return error.ListenFailed;
    defer hpm_http_server_free(s);
    const port = hpm_http_server_port(s);

    var ctx: ServerThreadCtx = .{ .server = s, .lookup_header_name = "x-not-present" };
    const t = try std.Thread.spawn(.{}, testServerThreadFn, .{&ctx});

    var resp_buf: [1024]u8 = undefined;
    const req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    _ = try sendAndReceive(port, req, &resp_buf);
    t.join();

    try std.testing.expectEqual(@as(isize, 0), ctx.header_len);
}

test "http server: path size-query returns required size" {
    const host = "127.0.0.1";
    const s = hpm_http_server_listen(host.ptr, host.len, 0) orelse return error.ListenFailed;
    defer hpm_http_server_free(s);
    const port = hpm_http_server_port(s);

    const PathQueryCtx = struct {
        server: *HpmHttpServer,
        size_query_result: isize = -2,
        size_write_result: isize = -2,
    };

    var ctx: PathQueryCtx = .{ .server = s };
    const t = try std.Thread.spawn(.{}, struct {
        fn run(c: *PathQueryCtx) void {
            const req = hpm_http_server_accept(c.server) orelse return;
            defer hpm_http_request_free(req);
            c.size_query_result = hpm_http_request_path(req, null, 0);
            var buf: [64]u8 = undefined;
            c.size_write_result = hpm_http_request_path(req, &buf, buf.len);
            _ = hpm_http_request_respond(req, 200, null, 0, "x".ptr, 1);
        }
    }.run, .{&ctx});

    var resp_buf: [512]u8 = undefined;
    const req = "GET /the-target-path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    _ = try sendAndReceive(port, req, &resp_buf);
    t.join();

    try std.testing.expectEqual(@as(isize, @intCast("/the-target-path".len)), ctx.size_query_result);
    try std.testing.expectEqual(@as(isize, @intCast("/the-target-path".len)), ctx.size_write_result);
}

test "http server: extra response headers" {
    const host = "127.0.0.1";
    const s = hpm_http_server_listen(host.ptr, host.len, 0) orelse return error.ListenFailed;
    defer hpm_http_server_free(s);
    const port = hpm_http_server_port(s);

    var ctx: ServerThreadCtx = .{
        .server = s,
        .reply_extra_headers = "x-test:value-1\r\ncontent-type:text/plain",
    };
    const t = try std.Thread.spawn(.{}, testServerThreadFn, .{&ctx});

    var resp_buf: [1024]u8 = undefined;
    const req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const n = try sendAndReceive(port, req, &resp_buf);
    t.join();

    const resp = resp_buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, resp, "x-test: value-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "content-type: text/plain") != null);
}

test "http server: arbitrary status code" {
    const host = "127.0.0.1";
    const s = hpm_http_server_listen(host.ptr, host.len, 0) orelse return error.ListenFailed;
    defer hpm_http_server_free(s);
    const port = hpm_http_server_port(s);

    var ctx: ServerThreadCtx = .{ .server = s, .reply_status = 404, .reply_body = "not found" };
    const t = try std.Thread.spawn(.{}, testServerThreadFn, .{&ctx});

    var resp_buf: [1024]u8 = undefined;
    const req = "GET /missing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const n = try sendAndReceive(port, req, &resp_buf);
    t.join();

    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "not found") != null);
}

test "http server: method ordinals match std.http.Method" {
    try std.testing.expectEqual(@as(c_int, 0), @as(c_int, @intCast(@intFromEnum(http.Method.GET))));
    try std.testing.expectEqual(@as(c_int, 1), @as(c_int, @intCast(@intFromEnum(http.Method.HEAD))));
    try std.testing.expectEqual(@as(c_int, 2), @as(c_int, @intCast(@intFromEnum(http.Method.POST))));
    try std.testing.expectEqual(@as(c_int, 3), @as(c_int, @intCast(@intFromEnum(http.Method.PUT))));
    try std.testing.expectEqual(@as(c_int, 4), @as(c_int, @intCast(@intFromEnum(http.Method.DELETE))));
    try std.testing.expectEqual(@as(c_int, 8), @as(c_int, @intCast(@intFromEnum(http.Method.PATCH))));
}

test "http server: null req returns -1 from accessors" {
    try std.testing.expectEqual(@as(c_int, -1), hpm_http_request_method(null));
    try std.testing.expectEqual(@as(isize, -1), hpm_http_request_path(null, null, 0));
    const name = "x";
    try std.testing.expectEqual(@as(isize, -1), hpm_http_request_header(null, name.ptr, name.len, null, 0));
    try std.testing.expectEqual(@as(isize, -1), hpm_http_request_body(null, null, 0));
    try std.testing.expectEqual(@as(c_int, -1), hpm_http_request_respond(null, 200, null, 0, null, 0));
    // free is safe on null
    hpm_http_request_free(null);
    hpm_http_server_free(null);
}
