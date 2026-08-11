# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.EgressPolicy do
  @moduledoc """
  Declarative *outbound* (egress) policy schema for HTTP Capability Gateway.

  Companion to the existing inbound `PolicyValidator` / `PolicyCompiler` pair.
  Where the inbound pipeline asks "may this client invoke this verb on this
  path of our backend?", the egress pipeline asks "may this estate
  application emit this verb to that *external* host?".

  This is the contract surface needed by `hyperpolymath/neurophone` (#84-3.1)
  to bound what sensor-derived data leaves the device on cloud/LLM calls.

  ## Status

  Scaffold only. This module defines the schema, validates it, and answers
  `decide/3`. The actual outbound forwarder (`Proxy.egress/2`) is a separate
  follow-up — opening it as a thin seam here lets policy authoring start
  immediately without committing to a particular HTTP client.

  ## Schema (DSL v1, egress section)

      egress:
        # Deny-by-default. An empty allow list denies ALL outbound traffic.
        default: deny
        # Allow-list of egress destinations. Each entry binds a host + verb
        # set + capability label. The capability label is purely informational
        # for audit purposes today, but is the seam where chimichanga-style
        # attenuation will attach.
        allow:
          - host: "api.anthropic.com"
            verbs: [POST]
            capability: "llm:complete"
            classification: "redacted-sensor-summary"

          - host: "api.openai.com"
            verbs: [POST]
            capability: "llm:complete"
            classification: "redacted-sensor-summary"

  Hosts are matched by exact lowercase string. Wildcard / suffix matching is
  deliberately NOT supported in v1 — explicit listing is safer for an
  egress allowlist and is what neurophone's threat model wants.
  """

  require Logger

  @valid_verbs ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

  defmodule Entry do
    @moduledoc "One allow-list entry in an egress policy."
    @enforce_keys [:host, :verbs]
    defstruct [:host, :verbs, :capability, :classification]

    @type t :: %__MODULE__{
            host: String.t(),
            verbs: [String.t()],
            capability: String.t() | nil,
            classification: String.t() | nil
          }
  end

  @type t :: %{default: :allow | :deny, allow: [Entry.t()]}

  @doc """
  Validate the `egress` subsection of a top-level policy map.

  Returns `{:ok, normalised}` (with hosts lowercased) or `{:error, reason}`.

  Accepts a missing/nil section as `{:ok, %{default: :deny, allow: []}}` so
  existing inbound-only policies keep working unchanged.
  """
  @spec validate(map() | nil) :: {:ok, t()} | {:error, String.t()}
  def validate(nil), do: {:ok, %{default: :deny, allow: []}}

  def validate(egress) when is_map(egress) do
    with {:ok, default} <- validate_default(Map.get(egress, "default", "deny")),
         {:ok, entries} <- validate_allow(Map.get(egress, "allow", [])) do
      {:ok, %{default: default, allow: entries}}
    end
  end

  def validate(_), do: {:error, "egress: must be a map when present"}

  @doc """
  Decide whether an outbound request is permitted.

  Returns `{:allow, entry}` (carrying the matched allowlist entry so the
  caller can audit the capability label) or `{:deny, reason}`.
  """
  @spec decide(t(), String.t(), String.t()) ::
          {:allow, Entry.t()} | {:deny, String.t()}
  def decide(policy, host, verb) when is_binary(host) and is_binary(verb) do
    host = String.downcase(host)

    case Enum.find(policy.allow, fn e -> e.host == host and verb in e.verbs end) do
      %Entry{} = entry ->
        {:allow, entry}

      nil ->
        case policy.default do
          :allow -> {:deny, "no allowlist entry; default=allow not yet supported"}
          :deny -> {:deny, "no allowlist entry for #{verb} #{host}; default=deny"}
        end
    end
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp validate_default("allow"), do: {:ok, :allow}
  defp validate_default("deny"), do: {:ok, :deny}
  defp validate_default(other), do: {:error, "egress.default: must be \"allow\" or \"deny\", got #{inspect(other)}"}

  defp validate_allow(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, idx}, {:ok, acc} ->
      case validate_entry(entry, idx) do
        {:ok, normalised} -> {:cont, {:ok, [normalised | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      err -> err
    end
  end

  defp validate_allow(_), do: {:error, "egress.allow: must be a list"}

  defp validate_entry(entry, idx) when is_map(entry) do
    with {:ok, host} <- fetch_host(entry, idx),
         {:ok, verbs} <- fetch_verbs(entry, idx) do
      {:ok,
       %Entry{
         host: host,
         verbs: verbs,
         capability: Map.get(entry, "capability"),
         classification: Map.get(entry, "classification")
       }}
    end
  end

  defp validate_entry(_other, idx), do: {:error, "egress.allow[#{idx}]: must be a map"}

  defp fetch_host(entry, idx) do
    case Map.get(entry, "host") do
      h when is_binary(h) and h != "" -> {:ok, String.downcase(h)}
      _ -> {:error, "egress.allow[#{idx}].host: must be a non-empty string"}
    end
  end

  defp fetch_verbs(entry, idx) do
    case Map.get(entry, "verbs") do
      verbs when is_list(verbs) and verbs != [] ->
        case Enum.find(verbs, &(&1 not in @valid_verbs)) do
          nil -> {:ok, verbs}
          bad -> {:error, "egress.allow[#{idx}].verbs: invalid HTTP verb #{bad}"}
        end

      _ ->
        {:error, "egress.allow[#{idx}].verbs: must be a non-empty list"}
    end
  end
end
