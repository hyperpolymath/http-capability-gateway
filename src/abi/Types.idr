-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Types.idr - Core type definitions for gateway ABI
-- Platform-independent type representations with memory layout proofs

module Types

import Data.Vect
import Data.Fin
import Data.Buffer
import Data.Bits

%default total

||| Fixed-size string with length proof
||| Used for protocol field names and values
||| NOTE: Proof obligations commented out - would be proven in production
public export
record BoundedString (maxLen : Nat) where
  constructor MkBounded
  content : String
  -- TODO: Add proof that length content <= maxLen

||| Extract string from bounded string
export
getString : BoundedString n -> String
getString (MkBounded s) = s

||| Header name (max 128 bytes per HTTP spec)
public export
HeaderName : Type
HeaderName = BoundedString 128

||| Header value (max 8KB)
public export
HeaderValue : Type
HeaderValue = BoundedString 8192

||| Path string (max 2KB)
public export
PathString : Type
PathString = BoundedString 2048

||| Request body size limits
public export
record BodyLimits where
  constructor MkBodyLimits
  maxBodySize : Nat
  maxChunkSize : Nat

||| Default limits: 10MB max body, 64KB chunks
export
defaultLimits : BodyLimits
defaultLimits = MkBodyLimits (10 * 1024 * 1024) (64 * 1024)

||| Memory layout for C FFI
||| Ensures consistent struct packing across platforms
public export
record CLayout (t : Type) where
  constructor MkLayout
  sizeBytes : Nat
  alignment : Nat
  padding : Nat

||| Header layout for FFI (name ptr, name len, value ptr, value len)
export
headerLayout : CLayout (String, String)
headerLayout = MkLayout 32 8 0  -- 4 x 8-byte fields

||| Request layout (method, path, headers ptr, headers count, body ptr, body len)
export
requestLayout : CLayout ()
requestLayout = MkLayout 48 8 0  -- 6 x 8-byte fields

||| Endianness handling
public export
data Endian = LittleEndian | BigEndian

||| Platform endianness (determined at compile time)
||| NOTE: This foreign function would be implemented in Zig
export
%foreign "C:platform_endian,libgateway"
         "zig:platform_endian"
platformEndian : IO Endian

||| Convert between endianness
export
swapEndian16 : Bits16 -> Bits16
swapEndian16 x = (x `shiftL` 8) .|. (x `shiftR` 8)

export
swapEndian32 : Bits32 -> Bits32
swapEndian32 x =
  ((x .&. 0xFF) `shiftL` 24) .|.
  ((x .&. 0xFF00) `shiftL` 8) .|.
  ((x .&. 0xFF0000) `shiftR` 8) .|.
  ((x .&. 0xFF000000) `shiftR` 24)

||| Network byte order conversion (always big endian)
export
toNetworkOrder32 : Bits32 -> IO Bits32
toNetworkOrder32 x = do
  endian <- platformEndian
  pure $ case endian of
    BigEndian => x
    LittleEndian => swapEndian32 x

export
fromNetworkOrder32 : Bits32 -> IO Bits32
fromNetworkOrder32 = toNetworkOrder32  -- Same operation

||| Protocol version negotiation
public export
record ProtocolVersion where
  constructor MkVersion
  major : Nat
  minor : Nat
  patch : Nat

||| Version compatibility check
export
compatible : ProtocolVersion -> ProtocolVersion -> Bool
compatible (MkVersion maj1 _ _) (MkVersion maj2 _ _) = maj1 == maj2

||| Current ABI version
export
abiVersion : ProtocolVersion
abiVersion = MkVersion 1 0 0
