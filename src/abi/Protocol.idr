-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Protocol.idr - Protocol abstraction ABI for multi-protocol gateway
-- Formal interface definitions with dependent type proofs

module Protocol

import Data.Vect
import Data.List
import Data.String
import Data.Buffer

%default total

||| Protocol type enumeration
||| Represents the supported protocols in the gateway
public export
data ProtocolType = HTTP | GRPC | GraphQL

||| Protocol type equality is decidable
export
Eq ProtocolType where
  HTTP == HTTP = True
  GRPC == GRPC = True
  GraphQL == GraphQL = True
  _ == _ = False

||| HTTP method enumeration (RFC 7231)
public export
data HTTPMethod = GET | POST | PUT | DELETE | PATCH | HEAD | OPTIONS

export
Eq HTTPMethod where
  GET == GET = True
  POST == POST = True
  PUT == PUT = True
  DELETE == DELETE = True
  PATCH == PATCH = True
  HEAD == HEAD = True
  OPTIONS == OPTIONS = True
  _ == _ = False

||| gRPC method type (service.method format)
public export
record GRPCMethod where
  constructor MkGRPCMethod
  service : String
  method : String

||| GraphQL operation type
public export
data GraphQLOp = Query | Mutation | Subscription

||| Protocol-specific method representation
public export
data ProtocolMethod : ProtocolType -> Type where
  HTTPVerb : HTTPMethod -> ProtocolMethod HTTP
  GRPCCall : GRPCMethod -> ProtocolMethod GRPC
  GraphQLOperation : GraphQLOp -> ProtocolMethod GraphQL

||| Trust level for access control
public export
data TrustLevel = Untrusted | Authenticated | Internal

export
Eq TrustLevel where
  Untrusted == Untrusted = True
  Authenticated == Authenticated = True
  Internal == Internal = True
  _ == _ = False

||| Exposure requirement from policy
public export
data ExposureLevel = Public | AuthRequired | InternalOnly

export
Eq ExposureLevel where
  Public == Public = True
  AuthRequired == AuthRequired = True
  InternalOnly == InternalOnly = True
  _ == _ = False

||| Access decision result
public export
data AccessDecision = Allow | Deny | NoMatch

export
Eq AccessDecision where
  Allow == Allow = True
  Deny == Deny = True
  NoMatch == NoMatch = True
  _ == _ = False

||| Proof that trust level satisfies exposure requirement
public export
data Satisfies : TrustLevel -> ExposureLevel -> Type where
  PublicAny : {trust : TrustLevel} -> Satisfies trust Public
  AuthedOK : Satisfies Authenticated AuthRequired
  InternalAuth : Satisfies Internal AuthRequired
  InternalOK : Satisfies Internal InternalOnly

||| Access evaluation with dependent type proof
||| If trust satisfies exposure, return Allow with proof
||| Otherwise return Deny
public export
evaluateAccess : (trust : TrustLevel)
              -> (exposure : ExposureLevel)
              -> Either (Satisfies trust exposure) AccessDecision
evaluateAccess trust Public = Left PublicAny
evaluateAccess Authenticated AuthRequired = Left AuthedOK
evaluateAccess Internal AuthRequired = Left InternalAuth
evaluateAccess Internal InternalOnly = Left InternalOK
evaluateAccess Untrusted AuthRequired = Right Deny
evaluateAccess Untrusted InternalOnly = Right Deny
evaluateAccess Authenticated InternalOnly = Right Deny

||| Protocol request header
public export
record Header where
  constructor MkHeader
  name : String
  value : String

||| Generic request representation across protocols
public export
record Request (proto : ProtocolType) where
  constructor MkRequest
  method : ProtocolMethod proto
  path : String
  headers : List Header
  body : List Bits8  -- Raw bytes

||| Generic response representation
public export
record Response where
  constructor MkResponse
  statusCode : Nat
  headers : List Header
  body : List Bits8  -- Raw bytes

||| Policy rule for a protocol
public export
record PolicyRule (proto : ProtocolType) where
  constructor MkPolicyRule
  pathPattern : String  -- Regex pattern
  allowedMethods : List (ProtocolMethod proto)
  exposure : ExposureLevel
  stealthEnabled : Bool

-- Foreign function interface signatures
-- These will be implemented in Zig
-- Parse protocol from wire format
-- NOTE: FFI functions commented out - would need proper C bindings
-- export
-- %foreign "C:parse_http_request,libgateway"
--          "zig:parse_http_request"
-- parseHTTPRequest : AnyPtr -> Nat -> IO (Maybe (Request HTTP))

-- export
-- %foreign "C:parse_grpc_request,libgateway"
--          "zig:parse_grpc_request"
-- parseGRPCRequest : AnyPtr -> Nat -> IO (Maybe (Request GRPC))

-- export
-- %foreign "C:parse_graphql_request,libgateway"
--          "zig:parse_graphql_request"
-- parseGraphQLRequest : AnyPtr -> Nat -> IO (Maybe (Request GraphQL))

-- ||| Serialize response to wire format
-- export
-- %foreign "C:serialize_response,libgateway"
--          "zig:serialize_response"
-- serializeResponse : Response -> IO (AnyPtr, Nat)

-- ||| Proof that well-formed requests always parse successfully
-- ||| (This would be proven formally in a real implementation)
-- ||| TODO: Define WellFormed, ParseResult types and prove this
-- postulate wellFormedParseSuccess :
--   {proto : ProtocolType} ->
--   (bytes : List Bits8) ->
--   WellFormed bytes ->
--   ParseResult bytes = Just req

-- ||| Memory safety proof - parsed requests don't outlive input buffer
-- ||| TODO: Define ValidLifetime type and prove this
-- postulate parseMemorySafety :
--   {proto : ProtocolType} ->
--   (buffer : Ptr) ->
--   (len : Nat) ->
--   (req : Request proto) ->
--   ValidLifetime buffer req
