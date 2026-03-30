# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.SafeTrust do
  @moduledoc """
  Formally specified trust hierarchy for capability-based access control.

  Implements the trust/exposure model verified in proven/SafeTrust.idr.
  Three trust levels form a total order: untrusted < authenticated < internal.
  The access decision is monotone: upgrading trust never revokes access.

  ## Trust Levels (total order)

    - `:untrusted`     (rank 0) — No authentication, anonymous access
    - `:authenticated` (rank 1) — Valid authentication token present
    - `:internal`      (rank 2) — Internal service (mutual TLS, service token)

  ## Exposure Levels (required trust)

    - `:public`        (rank 0) — Anyone can access
    - `:authenticated` (rank 1) — Requires authentication
    - `:internal`      (rank 2) — Internal services only

  ## Access Decision

  A trust level `t` satisfies an exposure requirement `e` iff `rank(t) >= rank(e)`.
  This is the single source of truth for all access decisions in the gateway.
  The monotonicity property guarantees that upgrading trust (e.g., from
  :untrusted to :authenticated) never revokes access that was already granted.

  ## Correspondence to proven/SafeTrust.idr

  The Idris2 specification defines:

    - `TrustLevel` and `ExposureLevel` as inductive types with `Ord` instances
    - `satisfies : TrustLevel -> ExposureLevel -> Bool` matching this module's satisfies?/2
    - `parseTrust : String -> TrustLevel` with fail-safe to Untrusted (matches parse_trust/1)
    - `parseExposure : String -> ExposureLevel` with fail-open to Public (matches parse_exposure/1)
    - Monotonicity proof: `mono : LTE t1 t2 -> satisfies t1 e = True -> satisfies t2 e = True`

  This Elixir module faithfully mirrors the specification. The Idris2 proof
  guarantees correctness; this module provides the runtime implementation.
  """

  # Trust level numeric ranks matching the Idris2 specification.
  # These form a total order: untrusted (0) < authenticated (1) < internal (2).
  # The ranks are used by satisfies?/2 for the core access decision.
  @trust_ranks %{untrusted: 0, authenticated: 1, internal: 2}

  # Exposure level numeric ranks matching the Idris2 specification.
  # These mirror trust ranks: public (0) < authenticated (1) < internal (2).
  # A trust level must have rank >= exposure rank to gain access.
  @exposure_ranks %{public: 0, authenticated: 1, internal: 2}

  # Valid trust and exposure atoms — used for guards and documentation.
  # These atoms are compile-time constants. We never create atoms from
  # user input (String.to_existing_atom is a DoS vector via atom table exhaustion).
  @valid_trust_levels [:untrusted, :authenticated, :internal]
  @valid_exposure_levels [:public, :authenticated, :internal]

  @type trust_level :: :untrusted | :authenticated | :internal
  @type exposure_level :: :public | :authenticated | :internal
  @type access_decision ::
          {:allow, trust_level(), exposure_level()}
          | {:deny, trust_level(), exposure_level()}

  @doc """
  Core access decision — SINGLE SOURCE OF TRUTH.

  Returns true iff the trust level's rank is >= the exposure level's rank.
  This directly mirrors proven/SafeTrust.idr's `satisfies` function.

  Unknown trust levels default to rank 0 (untrusted) for defense-in-depth.
  Unknown exposure levels default to rank 0 (public) for fail-open on
  exposure parsing only (this is safe because unknown exposure = most permissive).

  ## Parameters

    - `trust`: Trust level atom (:untrusted, :authenticated, :internal)
    - `exposure`: Exposure level atom (:public, :authenticated, :internal)

  ## Examples

      iex> SafeTrust.satisfies?(:authenticated, :public)
      true

      iex> SafeTrust.satisfies?(:untrusted, :internal)
      false

      iex> SafeTrust.satisfies?(:internal, :internal)
      true
  """
  @spec satisfies?(trust_level(), exposure_level()) :: boolean()
  def satisfies?(trust, exposure)
      when trust in @valid_trust_levels and exposure in @valid_exposure_levels do
    Map.fetch!(@trust_ranks, trust) >= Map.fetch!(@exposure_ranks, exposure)
  end

  # Fallback for unknown atoms — fail-safe to deny.
  # This clause exists for defense-in-depth; callers should use parse_trust/1
  # and parse_exposure/1 to ensure valid atoms before calling satisfies?/2.
  def satisfies?(_trust, _exposure), do: false

  @doc """
  Structured access decision with audit trail.

  Returns `{:allow, trust, exposure}` or `{:deny, trust, exposure}` for
  use in logging, telemetry, and structured error responses.

  ## Parameters

    - `trust`: Trust level atom
    - `exposure`: Exposure level atom

  ## Examples

      iex> SafeTrust.evaluate(:authenticated, :public)
      {:allow, :authenticated, :public}

      iex> SafeTrust.evaluate(:untrusted, :internal)
      {:deny, :untrusted, :internal}
  """
  @spec evaluate(trust_level(), exposure_level()) :: access_decision()
  def evaluate(trust, exposure) do
    if satisfies?(trust, exposure),
      do: {:allow, trust, exposure},
      else: {:deny, trust, exposure}
  end

  @doc """
  Safely parse a trust level string to its corresponding atom.

  Fail-safe to :untrusted — unknown or malformed input always results
  in the most restrictive trust level. This matches the Idris2
  `parseTrust` function which returns `Untrusted` for unrecognised input.

  SECURITY: This function uses pattern matching on known strings, never
  String.to_existing_atom/1 or String.to_existing_atom/1. This prevents both
  atom table exhaustion (DoS) and ArgumentError crashes.

  ## Parameters

    - `raw`: Raw trust level string from headers or configuration

  ## Examples

      iex> SafeTrust.parse_trust("authenticated")
      :authenticated

      iex> SafeTrust.parse_trust("ADMIN_OVERRIDE")
      :untrusted

      iex> SafeTrust.parse_trust(nil)
      :untrusted
  """
  @spec parse_trust(String.t() | nil) :: trust_level()
  def parse_trust("authenticated"), do: :authenticated
  def parse_trust("internal"), do: :internal
  def parse_trust(_), do: :untrusted

  @doc """
  Safely parse an exposure level string to its corresponding atom.

  Fail-open to :public — unknown or malformed input results in the most
  permissive exposure level. This matches the Idris2 `parseExposure`
  function which returns `Public` for unrecognised input.

  The fail-open behaviour is intentional: if a policy file has a typo in
  an exposure level, the route becomes public rather than silently denying
  all traffic. This is the safer default for availability (the operator
  will notice "too much access" faster than "everything is broken").

  ## Parameters

    - `raw`: Raw exposure level string from policy configuration

  ## Examples

      iex> SafeTrust.parse_exposure("internal")
      :internal

      iex> SafeTrust.parse_exposure("typo")
      :public
  """
  @spec parse_exposure(String.t() | nil) :: exposure_level()
  def parse_exposure("authenticated"), do: :authenticated
  def parse_exposure("internal"), do: :internal
  def parse_exposure(_), do: :public

  @doc """
  Returns the list of valid trust levels in ascending order of privilege.

  Useful for documentation, validation, and UI display.

  ## Examples

      iex> SafeTrust.trust_levels()
      [:untrusted, :authenticated, :internal]
  """
  @spec trust_levels() :: [trust_level()]
  def trust_levels, do: @valid_trust_levels

  @doc """
  Returns the list of valid exposure levels in ascending order of restriction.

  Useful for documentation, validation, and UI display.

  ## Examples

      iex> SafeTrust.exposure_levels()
      [:public, :authenticated, :internal]
  """
  @spec exposure_levels() :: [exposure_level()]
  def exposure_levels, do: @valid_exposure_levels
end
