# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# bench/compare.exs — Phase D regression-gate comparator (standards#99 scaffold)
#
# Reads:
#   • bench/results.json  (produced by bench/gateway_latency.exs in this run)
#   • bench/baseline.json (checked-in baseline)
#
# Emits:
#   • A markdown table on stdout (also written to the GitHub step summary by CI)
#   • Exit 0 if all scenarios are within tolerance
#   • Exit 1 if any scenario regressed past tolerance
#
# SCAFFOLD MODE
# ─────────────
# Until baseline.json contains real numbers (its "_status" is "scaffold-
# placeholder"), this script is INTENTIONALLY non-blocking — it reports
# the live numbers and exits 0 with a clear "scaffold mode" banner.
# Phase D-4 will flip "_status" to "active" once a real baseline lands;
# the gate becomes blocking from that point on with no code change here.

# `mix run` puts deps (including :jason) on the code path; nothing to start.

defmodule Bench.Compare do
  @results_path "bench/results.json"
  @baseline_path "bench/baseline.json"

  def run do
    with {:ok, results_raw} <- File.read(@results_path),
         {:ok, baseline_raw} <- File.read(@baseline_path),
         {:ok, results} <- Jason.decode(results_raw),
         {:ok, baseline} <- Jason.decode(baseline_raw) do
      compare(results, baseline)
    else
      {:error, :enoent} ->
        IO.puts(:stderr, "ERROR: bench/results.json or bench/baseline.json missing")
        IO.puts(:stderr, "Did `mix run bench/gateway_latency.exs` run first?")
        System.halt(2)

      {:error, reason} ->
        IO.puts(:stderr, "ERROR reading baseline/results: #{inspect(reason)}")
        System.halt(2)
    end
  end

  defp compare(results, baseline) do
    status = Map.get(baseline, "_status", "unknown")
    tolerance = Map.get(baseline, "tolerance", %{})

    IO.puts("# Phase D — Performance Regression Report")
    IO.puts("")
    IO.puts("Baseline status: **#{status}**")
    IO.puts("")

    case status do
      "scaffold-placeholder" ->
        IO.puts(
          "> SCAFFOLD MODE — bench/baseline.json has not been populated yet " <>
            "(Phase D-4 collects the real baseline). This run is informational " <>
            "only; the gate is **non-blocking** until baseline.json `_status` " <>
            "is flipped to `active`."
        )

        IO.puts("")
        emit_table(results, nil, tolerance)
        System.halt(0)

      "active" ->
        emit_table(results, baseline["scenarios"], tolerance)
        |> case do
          :ok -> System.halt(0)
          :regressed -> System.halt(1)
        end

      other ->
        IO.puts(:stderr, "ERROR: unknown baseline _status: #{inspect(other)}")
        System.halt(2)
    end
  end

  # ── Pretty-print + regression check ────────────────────────────────────────

  defp emit_table(results, baseline_scenarios, tolerance) do
    # Benchee JSON shape: top-level "statistics" -> per-scenario map.
    stats = Map.get(results, "statistics", %{})

    IO.puts("| Scenario | p50 (µs) | p95 (µs) | p99 (µs) | Status |")
    IO.puts("|----------|----------|----------|----------|--------|")

    Enum.reduce(stats, :ok, fn {name, scenario_stats}, acc ->
      p50 = percentile_us(scenario_stats, "50")
      p95 = percentile_us(scenario_stats, "95")
      p99 = percentile_us(scenario_stats, "99")

      status =
        case baseline_scenarios do
          nil ->
            "scaffold"

          map ->
            base = Map.get(map, name)
            check_regression(base, p50, p95, p99, tolerance)
        end

      IO.puts("| #{name} | #{fmt(p50)} | #{fmt(p95)} | #{fmt(p99)} | #{status} |")

      cond do
        acc == :regressed -> :regressed
        status == "REGRESSED" -> :regressed
        true -> acc
      end
    end)
  end

  defp percentile_us(scenario_stats, p) do
    # Benchee reports nanoseconds in JSON; convert to µs for human readability
    # and to match the µs units used in docs/perf-contract.md.
    case get_in(scenario_stats, ["percentiles", p]) do
      nil -> nil
      ns when is_number(ns) -> ns / 1_000.0
    end
  end

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)

  defp check_regression(nil, _, _, _, _), do: "no baseline"

  defp check_regression(base, p50, p95, p99, tolerance) do
    bp50 = num(base["p50_us"])
    bp95 = num(base["p95_us"])
    bp99 = num(base["p99_us"])

    t50 = Map.get(tolerance, "p50_max_ratio", 1.20)
    t95 = Map.get(tolerance, "p95_max_ratio", 1.30)
    t99 = Map.get(tolerance, "p99_max_ratio", 1.50)

    breached =
      (bp50 && p50 && p50 > bp50 * t50) or
        (bp95 && p95 && p95 > bp95 * t95) or
        (bp99 && p99 && p99 > bp99 * t99)

    if breached, do: "REGRESSED", else: "ok"
  end

  defp num(nil), do: nil
  defp num(n) when is_number(n), do: n
  defp num(_), do: nil
end

Bench.Compare.run()
