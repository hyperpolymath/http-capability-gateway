# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# HttpCapabilityGateway.VeriSimDB — GenServer-backed VeriSimDB persistence client.
#
# Provides async audit log persistence to VeriSimDB for every gateway decision
# (allow, deny, circuit-open, rate-limit-exceeded). ETS remains the hot path
# for O(1) circuit-breaker and rate-limiter lookups; VeriSimDB receives
# a durable append-only stream via cast for forensic replay and Hypatia analysis.
#
# Collection: capgw:audit
# Document schema:
#   id        — "ts:<unix_ms>:<request_id>" (sortable, unique)
#   timestamp — ISO-8601 UTC
#   action    — :allow | :deny | :circuit_open | :rate_limited
#   backend   — backend atom or nil
#   path      — request path
#   verb      — HTTP method
#   trust     — trust level atom
#   latency_us — upstream latency in microseconds (nil for denied)
#   policy_ref — policy rule matched (nil for rate-limit)

defmodule HttpCapabilityGateway.VeriSimDB do
  use GenServer
  require Logger

  @moduledoc """
  Async VeriSimDB client for gateway audit-log persistence.

  Writes are fire-and-forget (GenServer.cast) so the hot request path is
  never blocked by VeriSimDB availability. A local ETS buffer holds entries
  when VeriSimDB is unreachable and flushes on reconnect.

  ## Usage

      VeriSimDB.audit_allow(request, backend, policy_ref, latency_us)
      VeriSimDB.audit_deny(request, policy_ref)
      VeriSimDB.audit_circuit_open(backend)
      VeriSimDB.audit_rate_limited(request)

  ## Configuration

  Set VERISIMDB_URL environment variable (default: http://localhost:8080).
  """

  @collection "capgw:audit"
  @buffer_table :capgw_verisimdb_buffer
  @flush_interval_ms 5_000
  @max_buffer 1_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the VeriSimDB client GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Append an allow decision to the audit log."
  def audit_allow(path, verb, trust, backend, policy_ref, latency_us) do
    entry = build_entry(:allow, path, verb, trust, backend: backend, policy_ref: policy_ref, latency_us: latency_us)
    GenServer.cast(__MODULE__, {:audit, entry})
  end

  @doc "Append a deny decision to the audit log."
  def audit_deny(path, verb, trust, policy_ref) do
    entry = build_entry(:deny, path, verb, trust, policy_ref: policy_ref)
    GenServer.cast(__MODULE__, {:audit, entry})
  end

  @doc "Append a circuit-open event to the audit log."
  def audit_circuit_open(backend) do
    entry = build_entry(:circuit_open, nil, nil, nil, backend: backend)
    GenServer.cast(__MODULE__, {:audit, entry})
  end

  @doc "Append a rate-limit event to the audit log."
  def audit_rate_limited(path, verb, trust) do
    entry = build_entry(:rate_limited, path, verb, trust, [])
    GenServer.cast(__MODULE__, {:audit, entry})
  end

  @doc "Retrieve recent audit entries for a given time range (ISO-8601 strings)."
  def get_range(from_iso, to_iso) do
    GenServer.call(__MODULE__, {:get_range, from_iso, to_iso})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@buffer_table, [:named_table, :ordered_set, :public])
    schedule_flush()
    {:ok, %{base_url: base_url(), healthy: false, buffer_size: 0}}
  end

  @impl true
  def handle_cast({:audit, entry}, state) do
    doc_id = Map.fetch!(entry, :id)
    case put_entry(state.base_url, doc_id, entry) do
      :ok ->
        {:noreply, %{state | healthy: true}}

      {:error, reason} ->
        Logger.warning("VeriSimDB unavailable (#{inspect(reason)}); buffering audit entry #{doc_id}")
        buffer_entry(doc_id, entry, state.buffer_size)
        {:noreply, %{state | healthy: false, buffer_size: min(state.buffer_size + 1, @max_buffer)}}
    end
  end

  @impl true
  def handle_call({:get_range, _from_iso, _to_iso}, _from, state) do
    # Phase 2: prefix-scan by timestamp key not yet available in VeriSimDB v1.
    # Return empty list for now; Hypatia scans the collection directly.
    {:reply, {:ok, []}, state}
  end

  @impl true
  def handle_info(:flush_buffer, state) do
    new_size = flush_buffer(state.base_url)
    schedule_flush()
    {:noreply, %{state | buffer_size: new_size}}
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp base_url do
    System.get_env("VERISIMDB_URL", "http://localhost:8080")
  end

  defp schedule_flush do
    Process.send_after(self(), :flush_buffer, @flush_interval_ms)
  end

  defp build_entry(action, path, verb, trust, extras) do
    ts_ms = System.system_time(:millisecond)
    request_id = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    id = "ts:#{ts_ms}:#{request_id}"

    base = %{
      id: id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      action: action,
      path: path,
      verb: verb,
      trust: trust
    }

    Enum.reduce(extras, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  defp put_entry(base_url, doc_id, entry) do
    safe_id = URI.encode_www_form(doc_id)
    url = "#{base_url}/v1/#{@collection}/#{safe_id}"
    case Req.put(url, json: entry) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s}} -> {:error, {:http_status, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp buffer_entry(doc_id, entry, buffer_size) when buffer_size < @max_buffer do
    :ets.insert(@buffer_table, {doc_id, entry})
  end
  defp buffer_entry(_doc_id, _entry, _full), do: :ok

  defp flush_buffer(base_url) do
    entries = :ets.tab2list(@buffer_table)
    Enum.each(entries, fn {doc_id, entry} ->
      case put_entry(base_url, doc_id, entry) do
        :ok -> :ets.delete(@buffer_table, doc_id)
        {:error, _} -> :ok  # leave in buffer for next flush
      end
    end)
    :ets.info(@buffer_table, :size)
  end
end
