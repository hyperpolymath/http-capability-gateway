# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# HttpCapabilityGateway.A2ML — a2ml-format attestation generator for access decisions.
#
# Produces content-addressable audit records for every access decision made by
# the gateway. Adapted from HAR.Attestation.A2ML for HTTP capability gateway
# context, where the attested events are access control decisions (allow/deny)
# rather than routing decisions (which backend to use).

defmodule HttpCapabilityGateway.A2ML do
  @moduledoc """
  Generates a2ml-format attestations for access control decisions.

  Every access decision made by the HTTP Capability Gateway produces an attestation
  record that captures the full context of the decision in a verifiable,
  content-addressable format. This serves as the immutable audit trail for
  all access control activity, enabling post-hoc verification, compliance auditing,
  and forensic analysis of policy enforcement.

  ## What Gets Attested

  Each attestation captures the dimensions of an access decision:

  - **Who** — the trust level of the requester (untrusted, authenticated, internal)
  - **What** — the HTTP method and path requested
  - **Why** — the exposure requirement and policy hash that governed the decision
  - **Verdict** — whether access was allowed or denied
  - **When** — RFC 3339 timestamp with UTC timezone
  - **Verification** — SHA-256 hash of the entire decision context

  ## Attestation Types

  Four types of decisions can be attested:

  - `:access` — Standard access control decisions (trust vs exposure evaluation)
  - `:policy` — Policy load/reload events with policy hash
  - `:trust` — Trust level assignments and upgrades
  - `:rate_limit` — Rate limiting decisions (allow/deny with bucket state)

  ## Content Addressability

  Attestations are content-addressable: the same decision inputs always produce
  the same `decision_hash`. This property enables verification without requiring
  the original request context — you can recompute the hash from the payload and
  compare it to the declared hash to confirm integrity.

  The hash is computed over deterministic JSON serialisation (sorted keys via Jason)
  of the decision payload. Sensitive fields (passwords, tokens, secrets, API keys)
  are redacted before hashing to prevent credential leakage into audit logs.

  ## a2ml Envelope Format

  The attestation follows the a2ml (Anthropic Agent Markup Language) envelope
  structure, providing a standardised wrapper for machine-readable declarations:

      %{
        "a2ml" => %{
          "version" => "1.0",
          "type" => "access",
          "issued_at" => "2026-02-28T12:34:56.789Z",
          "issuer" => "http-capability-gateway",
          "decision_hash" => "sha256:abcdef..."
        },
        "decision" => %{
          "trust_level" => "authenticated",
          "exposure" => "public",
          "path" => "/api/v1/users",
          "method" => "GET",
          "verdict" => "allow",
          "policy_hash" => "sha256:..."
        }
      }

  ## Security Considerations

  - **Sensitive field redaction**: Decision data is sanitised before hashing — fields
    whose keys contain `password`, `token`, `secret`, `key`, `credential`, `api_key`,
    `access_key`, or `private_key` (case-insensitive) are replaced with `"[REDACTED]"`.
    This prevents credentials from leaking into audit logs while preserving enough
    context for meaningful verification.
  - **Deterministic hashing**: JSON encoding uses sorted keys (via Jason) to ensure
    the same logical payload always hashes identically, regardless of Elixir map key
    ordering.
  - **SHA-256**: The hash algorithm provides 128-bit collision resistance, sufficient
    for audit integrity (not used for cryptographic signatures).

  ## Integration Points

  - Called by `HttpCapabilityGateway.Gateway` after access decisions
  - Called by `HttpCapabilityGateway.K9Contract` after contract enforcement
  - Attestations can be forwarded to external audit stores (IPFS, VeriSimDB)
  - Consumed by monitoring dashboards for audit trail display
  """

  require Logger

  # Sensitive key patterns that must be redacted before hashing.
  # Case-insensitive matching is applied by downcasing the key before comparison.
  # This list covers common credential field names across various APIs and
  # configuration formats.
  @sensitive_keys ~w(password token secret key credential api_key access_key private_key)

  # Valid attestation types. Using an allowlist prevents atom exhaustion from
  # external input — callers must use one of these atoms, never raw strings.
  @valid_types [:access, :policy, :trust, :rate_limit]

  @typedoc """
  Attestation type discriminator.

  - `:access` — Access control decision (trust level vs exposure requirement)
  - `:policy` — Policy load, reload, or compilation event
  - `:trust` — Trust level assignment or escalation event
  - `:rate_limit` — Rate limiter decision (bucket allow/deny)
  """
  @type attestation_type :: :access | :policy | :trust | :rate_limit

  @typedoc """
  A complete attestation envelope containing the a2ml metadata and the
  decision payload. The `decision_hash` in the a2ml section is the SHA-256
  of the canonical JSON representation of the decision section.
  """
  @type attestation :: %{
          String.t() => %{
            String.t() => String.t()
          }
        }

  @doc """
  Generate an a2ml attestation for an access decision.

  Takes a map describing the decision context and produces a content-addressable
  attestation envelope. The attestation includes a SHA-256 hash of the decision
  payload, making it independently verifiable.

  ## Parameters

    - `decision_data` — A map containing decision context. Expected keys:
      - `:type` — Attestation type atom (`:access`, `:policy`, `:trust`, `:rate_limit`).
        Defaults to `:access` if not provided.
      - `:trust_level` — Trust level atom or string (e.g., `:authenticated`, `"internal"`)
      - `:exposure` — Exposure requirement string (e.g., `"public"`, `"authenticated"`)
      - `:path` — HTTP request path (e.g., `"/api/v1/users"`)
      - `:method` — HTTP method string (e.g., `"GET"`, `"POST"`)
      - `:verdict` — Decision outcome (`:allow`, `:deny`, `"allow"`, `"deny"`)
      - `:policy_hash` — Hash of the policy that governed this decision
      - Any additional keys are included in the decision payload after redaction.

  ## Returns

  A map with two top-level keys:
    - `"a2ml"` — Envelope metadata (version, type, issuer, timestamp, hash)
    - `"decision"` — The decision data that was hashed (after redaction)

  ## Examples

      iex> data = %{
      ...>   type: :access,
      ...>   trust_level: :authenticated,
      ...>   exposure: "public",
      ...>   path: "/api/v1/users",
      ...>   method: "GET",
      ...>   verdict: :allow,
      ...>   policy_hash: "sha256:abc123"
      ...> }
      iex> attestation = A2ML.attest(data)
      iex> attestation["a2ml"]["type"]
      "access"
      iex> attestation["a2ml"]["issuer"]
      "http-capability-gateway"
  """
  @spec attest(map()) :: attestation()
  def attest(decision_data) when is_map(decision_data) do
    # Step 1: Extract and validate the attestation type.
    # Default to :access for backward compatibility with callers that
    # don't specify a type explicitly.
    type = Map.get(decision_data, :type, :access)
    type_str = validate_and_stringify_type(type)

    # Step 2: Build the canonical decision payload.
    # This converts all values to strings for deterministic JSON serialisation,
    # removes the :type key (it lives in the envelope, not the payload), and
    # redacts sensitive fields to prevent credential leakage.
    payload =
      decision_data
      |> Map.delete(:type)
      |> stringify_decision()
      |> redact_sensitive()

    # Step 3: Compute the SHA-256 hash of the canonical JSON representation.
    # This hash becomes the content address — the same decision always produces
    # the same hash, enabling verification without the original context.
    decision_hash = hash_decision(payload)

    # Step 4: Wrap the payload in the a2ml envelope structure.
    # The envelope provides versioning, typing, and issuer identification
    # so consumers can parse attestations without knowing the producer.
    %{
      "a2ml" => %{
        "version" => "1.0",
        "type" => type_str,
        "issued_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "issuer" => "http-capability-gateway",
        "decision_hash" => decision_hash
      },
      "decision" => payload
    }
  end

  @doc """
  Verify an attestation by recomputing the decision hash.

  Takes a previously generated attestation and recomputes the SHA-256 hash
  of its decision payload. If the computed hash matches the declared
  `decision_hash` in the a2ml envelope, the attestation is valid — its
  payload has not been tampered with since generation.

  This verification is independent of any external state: it only requires
  the attestation map itself. No database lookup, no network call, no
  original request context.

  ## Parameters

    - `attestation` — A map with `"a2ml"` and `"decision"` keys, as
      produced by `attest/1`.

  ## Returns

    - `:valid` — The decision hash matches; payload integrity confirmed.
    - `:tampered` — The hash does not match; payload has been modified.

  ## Examples

      iex> attestation = A2ML.attest(decision_data)
      iex> A2ML.verify(attestation)
      :valid

      iex> tampered = put_in(attestation, ["decision", "verdict"], "allow")
      iex> A2ML.verify(tampered)
      :tampered
  """
  @spec verify(map()) :: :valid | :tampered
  def verify(%{"a2ml" => %{"decision_hash" => declared_hash}, "decision" => decision}) do
    # Recompute the hash from the decision payload and compare with the
    # declared hash. If the payload has been modified after attestation
    # generation, the hashes will diverge, revealing tampering.
    computed_hash = hash_decision(decision)

    if computed_hash == declared_hash do
      :valid
    else
      :tampered
    end
  end

  # Catch-all for malformed attestation maps — return :tampered rather than
  # crashing, since verification is a query operation that should not raise
  # exceptions on bad input.
  def verify(_), do: :tampered

  @doc """
  Redact sensitive fields from a decision map.

  Replaces the values of keys that match sensitive patterns (password, token,
  secret, key, credential, api_key, access_key, private_key) with the string
  `"[REDACTED]"`. Matching is case-insensitive — keys like `"API_KEY"`,
  `"apiKey"`, `"Api_Key"`, `"access_key"`, and `"PRIVATE_KEY"` are all caught.

  This function operates recursively on nested maps, ensuring that sensitive
  fields at any depth are redacted.

  ## Parameters

    - `data` — A map (typically the decision payload before hashing).

  ## Returns

    - The map with sensitive field values replaced by `"[REDACTED]"`.

  ## Examples

      iex> A2ML.redact_sensitive(%{"user" => "alice", "password" => "s3cret"})
      %{"user" => "alice", "password" => "[REDACTED]"}

      iex> A2ML.redact_sensitive(%{"api_key" => "abc123", "path" => "/api"})
      %{"api_key" => "[REDACTED]", "path" => "/api"}
  """
  @spec redact_sensitive(map()) :: map()
  def redact_sensitive(data) when is_map(data) do
    Map.new(data, fn {k, v} ->
      key_lower = k |> to_string() |> String.downcase()

      cond do
        is_sensitive_key?(key_lower) ->
          {k, "[REDACTED]"}

        is_map(v) ->
          {k, redact_sensitive(v)}

        true ->
          {k, v}
      end
    end)
  end

  def redact_sensitive(data), do: data

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  # Validates the attestation type and converts it to a string.
  # Unknown types default to "access" with a warning log, ensuring the system
  # never crashes due to a bad type while still recording that something
  # unexpected happened.
  @spec validate_and_stringify_type(atom() | String.t()) :: String.t()
  defp validate_and_stringify_type(type) when is_atom(type) do
    if type in @valid_types do
      Atom.to_string(type)
    else
      Logger.warning("A2ML: unknown attestation type, defaulting to 'access'",
        provided: inspect(type)
      )

      "access"
    end
  end

  defp validate_and_stringify_type(type) when is_binary(type), do: type
  defp validate_and_stringify_type(_), do: "access"

  # Converts all map keys and values to strings for deterministic JSON
  # serialisation. Atom keys become strings, atom values become strings,
  # numeric values are preserved (Jason handles them deterministically),
  # and nested maps are recursively stringified.
  #
  # This ensures that `%{trust_level: :authenticated}` and
  # `%{"trust_level" => "authenticated"}` produce identical hashes.
  @spec stringify_decision(map()) :: map()
  defp stringify_decision(data) when is_map(data) do
    Map.new(data, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)

      value =
        cond do
          is_atom(v) -> Atom.to_string(v)
          is_map(v) -> stringify_decision(v)
          is_list(v) -> Enum.map(v, &stringify_value/1)
          true -> v
        end

      {key, value}
    end)
  end

  # Stringifies a single value for list elements within the decision payload.
  @spec stringify_value(term()) :: term()
  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v) when is_map(v), do: stringify_decision(v)
  defp stringify_value(v), do: v

  # Checks whether a lowercase key string matches any sensitive key pattern.
  # The check uses String.contains?/2 so that compound keys like
  # "database_password" or "auth_token_value" are also caught.
  @spec is_sensitive_key?(String.t()) :: boolean()
  defp is_sensitive_key?(key_lower) do
    Enum.any?(@sensitive_keys, fn sensitive ->
      String.contains?(key_lower, sensitive)
    end)
  end

  # Compute SHA-256 hash of the decision payload.
  #
  # The payload is first encoded to JSON using Jason, which produces
  # deterministic output for maps (keys sorted lexicographically).
  # This ensures that the same logical payload always produces the
  # same hash, regardless of Elixir's internal map key ordering.
  #
  # The hash is prefixed with "sha256:" following the multihash
  # convention used by IPFS and OCI registries, making the algorithm
  # self-describing. If we ever need to migrate to SHA-3 or BLAKE3,
  # old attestations remain distinguishable from new ones.
  #
  # The hex encoding uses lowercase to match standard conventions
  # (e.g., Git commit hashes, Docker image digests).
  @spec hash_decision(map()) :: String.t()
  defp hash_decision(payload) do
    json = Jason.encode!(payload, pretty: false)
    hash = :crypto.hash(:sha256, json)
    "sha256:" <> Base.encode16(hash, case: :lower)
  end
end
