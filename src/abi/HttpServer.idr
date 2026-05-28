||| HTTP server FFI — %foreign declarations binding into libgateway.so.
|||
||| Provides a thin, synchronous HTTP/1.1 server suitable for sitting
||| behind a TLS reverse proxy (Caddy / nginx). Each call to `listen`
||| returns a server handle; `accept` blocks until a request arrives,
||| returning a request handle. Method / path / headers / body can be
||| inspected, then `respond` sends the full response and the request
||| handle must be freed.
|||
||| Designed for the OikosBot's webhook receiver path. No keep-alive —
||| every response closes the connection.
|||
||| Null-pointer discipline: callers MUST treat any AnyPtr returned by
||| `listen` / `accept` as potentially NULL. Idris2's foreign AnyPtr is
||| opaque; the canonical pattern is to check the C handle on the C
||| side. Until a portable Idris2 null-pointer predicate lands, callers
||| should pair these wrappers with a thin C-side wrapper that returns
||| `0` for failure.

module HttpServer

import Data.Buffer

%default total

--------------------------------------------------------------------------------
-- HTTP method ordinal — matches `std.http.Method` in Zig.
--------------------------------------------------------------------------------

public export
data HttpMethod
  = MGet
  | MHead
  | MPost
  | MPut
  | MDelete
  | MConnect
  | MOptions
  | MTrace
  | MPatch
  | MUnknown

export
methodFromInt : Int -> HttpMethod
methodFromInt 0 = MGet
methodFromInt 1 = MHead
methodFromInt 2 = MPost
methodFromInt 3 = MPut
methodFromInt 4 = MDelete
methodFromInt 5 = MConnect
methodFromInt 6 = MOptions
methodFromInt 7 = MTrace
methodFromInt 8 = MPatch
methodFromInt _ = MUnknown

--------------------------------------------------------------------------------
-- Server lifecycle
--------------------------------------------------------------------------------

||| Raw C call.
|||
|||   HpmHttpServer* hpm_http_server_listen(
|||       const uint8_t* host_ptr, size_t host_len, uint16_t port);
|||
||| Returns the raw `AnyPtr`. NULL on bind / parse / OOM failure.
%foreign "C:hpm_http_server_listen, libgateway"
prim__listen : Buffer -> Int -> Int -> PrimIO AnyPtr

export
listen : (host : Buffer) -> (hostLen : Int) -> (port : Int) -> IO AnyPtr
listen host hostLen port = primIO $ prim__listen host hostLen port

||| Returns the port the listener is bound to (useful when `port` was
||| passed as 0). Returns 0 if the server pointer is NULL.
%foreign "C:hpm_http_server_port, libgateway"
prim__serverPort : AnyPtr -> PrimIO Int

export
serverPort : AnyPtr -> IO Int
serverPort s = primIO $ prim__serverPort s

||| Close the listener and free the handle. Safe on NULL.
%foreign "C:hpm_http_server_free, libgateway"
prim__serverFree : AnyPtr -> PrimIO ()

export
serverFree : AnyPtr -> IO ()
serverFree s = primIO $ prim__serverFree s

--------------------------------------------------------------------------------
-- Request lifecycle
--------------------------------------------------------------------------------

||| Block until a request arrives. NULL on IO / parse error.
%foreign "C:hpm_http_server_accept, libgateway"
prim__accept : AnyPtr -> PrimIO AnyPtr

export
accept : AnyPtr -> IO AnyPtr
accept s = primIO $ prim__accept s

||| Return the request method ordinal (matches `std.http.Method` in
||| Zig). Returns -1 on null request.
%foreign "C:hpm_http_request_method, libgateway"
prim__method : AnyPtr -> PrimIO Int

export
requestMethod : AnyPtr -> IO HttpMethod
requestMethod r = do
  rc <- primIO $ prim__method r
  pure (methodFromInt rc)

||| Copy the request target into `out`. Returns bytes written (or
||| required size when `outCap == 0`). -1 on error.
%foreign "C:hpm_http_request_path, libgateway"
prim__path : AnyPtr -> Buffer -> Int -> PrimIO Int

export
requestPath : (req : AnyPtr) -> (out : Buffer) -> (outCap : Int) -> IO Int
requestPath req out cap = primIO $ prim__path req out cap

||| Look up a header by case-insensitive name. Returns bytes written
||| (or required size when `outCap == 0`), 0 if absent, -1 on error.
%foreign "C:hpm_http_request_header, libgateway"
prim__header : AnyPtr -> Buffer -> Int -> Buffer -> Int -> PrimIO Int

export
requestHeader : (req : AnyPtr)
             -> (name : Buffer) -> (nameLen : Int)
             -> (out : Buffer)  -> (outCap : Int)
             -> IO Int
requestHeader req name nameLen out cap =
  primIO $ prim__header req name nameLen out cap

||| Read the entire request body into `out`. Idempotent: subsequent
||| calls return 0. -1 on error / over-cap. Max body = 1 MiB.
%foreign "C:hpm_http_request_body, libgateway"
prim__body : AnyPtr -> Buffer -> Int -> PrimIO Int

export
requestBody : (req : AnyPtr) -> (out : Buffer) -> (outCap : Int) -> IO Int
requestBody req out cap = primIO $ prim__body req out cap

||| Send a complete HTTP response. `extraHeaders` is a buffer of
||| "Name:Value\r\n…" lines (or empty). Returns 0 on success, -1 on error.
%foreign "C:hpm_http_request_respond, libgateway"
prim__respond : AnyPtr -> Int -> Buffer -> Int -> Buffer -> Int -> PrimIO Int

export
requestRespond : (req : AnyPtr)
              -> (status : Int)
              -> (extraHeaders : Buffer) -> (extraHeadersLen : Int)
              -> (body : Buffer) -> (bodyLen : Int)
              -> IO Int
requestRespond req status hdrs hdrsLen body bodyLen =
  primIO $ prim__respond req status hdrs hdrsLen body bodyLen

||| Close the connection and free the handle. Must be called exactly
||| once per successful `accept`. Safe on NULL.
%foreign "C:hpm_http_request_free, libgateway"
prim__requestFree : AnyPtr -> PrimIO ()

export
requestFree : AnyPtr -> IO ()
requestFree r = primIO $ prim__requestFree r
