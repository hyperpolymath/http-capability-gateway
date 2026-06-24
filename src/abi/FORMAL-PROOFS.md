<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Formal Proofs TODO - Idris2 ABI

This document outlines the formal proof obligations that would be completed for a production-ready ABI.

## Currently Missing Proofs

### 1. WellFormed Predicate (Protocol.idr)

**Purpose:** Prove that byte sequences represent valid protocol messages

```idris
-- TODO: Define WellFormed type
data WellFormed : List Bits8 -> Type where
  -- HTTP well-formedness: valid method, headers, body structure
  HTTPWellFormed : ValidHTTPStructure bytes -> WellFormed bytes

  -- gRPC well-formedness: valid HTTP/2 frame with gRPC headers
  GRPCWellFormed : ValidHTTP2Frame bytes ->
                   HasGRPCHeaders bytes ->
                   WellFormed bytes

  -- GraphQL well-formedness: valid JSON with query field
  GraphQLWellFormed : ValidJSON bytes ->
                      HasQueryField bytes ->
                      WellFormed bytes
```

### 2. ParseResult Type (Protocol.idr)

**Purpose:** Dependent type representing parse outcomes

```idris
-- TODO: Define ParseResult
data ParseResult : List Bits8 -> Type where
  ParseSuccess : (req : Request proto) ->
                 {auto prf : WellFormed bytes} ->
                 ParseResult bytes

  ParseFailure : (reason : String) ->
                 ParseResult bytes
```

### 3. Parse Success Theorem (Protocol.idr)

**Currently:** Postulate (assumed without proof)
**Should be:** Proven theorem

```idris
-- TODO: Prove this theorem
wellFormedParseSuccess :
  {proto : ProtocolType} ->
  (bytes : List Bits8) ->
  WellFormed bytes ->
  parseProtocol proto bytes = Just req
```

**Proof strategy:**
1. Structural induction on WellFormed proof
2. Case analysis on protocol type
3. Show parser implementation matches well-formedness predicate

### 4. ValidLifetime Type (Protocol.idr)

**Purpose:** Memory safety - parsed requests don't outlive buffer

```idris
-- TODO: Define ValidLifetime
data ValidLifetime : (buffer : AnyPtr) -> (req : Request proto) -> Type where
  -- Request fields are subslices of buffer
  FieldsInBuffer : (req : Request proto) ->
                   (buffer : AnyPtr) ->
                   (len : Nat) ->
                   AllFieldsWithinBounds req buffer len ->
                   ValidLifetime buffer req
```

### 5. Memory Safety Theorem (Protocol.idr)

**Currently:** Postulate
**Should be:** Proven theorem

```idris
-- TODO: Prove memory safety
parseMemorySafety :
  {proto : ProtocolType} ->
  (buffer : AnyPtr) ->
  (len : Nat) ->
  (req : Request proto) ->
  ValidLifetime buffer req
```

**Proof strategy:**
1. Show FFI parser only creates pointers within buffer bounds
2. Prove no pointer arithmetic escapes buffer
3. Demonstrate slice bounds checking

### 6. BoundedString Length Proof (Types.idr)

**Currently:** Comment "TODO: Add proof"
**Should be:** Dependent type with proof

```idris
-- TODO: Complete BoundedString with proof
data BoundedString : (maxLen : Nat) -> Type where
  MkBounded : (content : String) ->
              {auto prf : LTE (length content) maxLen} ->
              BoundedString maxLen
```

Where `LTE` is the less-than-or-equal proof from `Data.Nat`.

### 7. Endian Involution Proof (Types.idr)

**Currently:** `believe_me ()` (assumed)
**Should be:** Proven

```idris
-- TODO: Actually prove this
endianInvolution : (x : Bits32) ->
                   fromNetworkOrder32 (toNetworkOrder32 x) = x
```

**Proof strategy:**
1. Case split on platform endianness
2. BigEndian case: trivial (both functions are identity)
3. LittleEndian case: prove swapEndian32 is involution
4. Show swapEndian32 (swapEndian32 x) = x by bit manipulation

## Benefits of Complete Proofs

### Type Safety
- Impossible to call parsers with invalid buffers
- Compiler-checked memory safety
- No runtime bounds checks needed (proven safe)

### Correctness Guarantees
- Parser correctly implements protocol specification
- No undefined behavior possible
- All edge cases handled provably

### FFI Safety Bridge
- Idris2 proofs guarantee Zig FFI correctness
- C calling convention safety verified
- Memory layout consistency proven

## Implementation Priority

1. **High**: BoundedString length proofs (immediate safety benefit)
2. **Medium**: ParseResult and WellFormed types (better type checking)
3. **Low**: Full theorems (academic completeness)

## References

- [Idris2 Documentation](https://idris2.readthedocs.io/)
- [Dependent Types for Verified Systems](https://www.idris-lang.org/pages/example.html)
- [Proof-Carrying Code](https://en.wikipedia.org/wiki/Proof-carrying_code)
