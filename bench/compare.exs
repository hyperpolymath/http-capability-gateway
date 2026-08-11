# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
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
    baseline_scenarios = Map.get(baseline, "scenarios", %{})

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
            "is flipped to `active`. Schema drift (a scenario present in " <>
            "results.json but absent from baseline.json, or vice versa) is " <>
            "surfaced inline as `scaffold (would fail: ...)` so a rebaseline " <>
            "PR previews the active-mode verdict before the gate is armed."
        )

        IO.puts("")
        emit_table(results, baseline_scenarios, tolerance, enforce: false)
        System.halt(0)

      "active" ->
        emit_table(results, baseline_scenarios, tolerance, enforce: true)
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
  #
  # Iterates the UNION of scenario names from results and baseline so neither
  # schema-drift direction is silent:
  #   • results-only scenario → "MISSING IN BASELINE" (new harness scenario
  #     landed without a rebaseline; the regression gate has no anchor for it).
  #   • baseline-only scenario → "MISSING IN RESULTS" (the harness dropped a
  #     scenario the baseline still claims; the gate must not silently pass).
  # Both directions fail-closed when `enforce: true` (active mode) and surface
  # as informational `scaffold (would fail: ...)` rows when `enforce: false`
  # (scaffold-placeholder mode) — see docs/perf-contract.md § Schema drift.

  defp emit_table(results, baseline_scenarios, tolerance, opts) do
    enforce = Keyword.fetch!(opts, :enforce)

    # Benchee JSON shape: top-level "statistics" -> per-scenario map.
    stats = Map.get(results, "statistics", %{})

    result_names = stats |> Map.keys() |> MapSet.new()
    baseline_names = baseline_scenarios |> Map.keys() |> MapSet.new()
    all_names = result_names |> MapSet.union(baseline_names) |> Enum.sort()

    IO.puts("| Scenario | p50 (µs) | p95 (µs) | p99 (µs) | Status |")
    IO.puts("|----------|----------|----------|----------|--------|")

    Enum.reduce(all_names, :ok, fn name, acc ->
      in_results = MapSet.member?(result_names, name)
      in_baseline = MapSet.member?(baseline_names, name)

      {p50, p95, p99} =
        if in_results do
          scenario_stats = Map.fetch!(stats, name)

          {percentile_us(scenario_stats, "50"), percentile_us(scenario_stats, "95"),
           percentile_us(scenario_stats, "99")}
        else
          {nil, nil, nil}
        end

      {raw_status, drift?} =
        cond do
          in_results and not in_baseline ->
            {"MISSING IN BASELINE", true}

          in_baseline and not in_results ->
            {"MISSING IN RESULTS", true}

          true ->
            base = Map.fetch!(baseline_scenarios, name)
            regressed? = check_regression(base, p50, p95, p99, tolerance) == "REGRESSED"
            {if(regressed?, do: "REGRESSED", else: "ok"), regressed?}
        end

      display_status =
        cond do
          enforce -> raw_status
          drift? -> "scaffold (would fail: #{raw_status})"
          true -> "scaffold"
        end

      IO.puts("| #{name} | #{fmt(p50)} | #{fmt(p95)} | #{fmt(p99)} | #{display_status} |")

      cond do
        acc == :regressed -> :regressed
        enforce and drift? -> :regressed
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

  defp check_regression(base, p50, p95, p99, tolerance) do
    bp50 = num(base["p50_us"])
    bp95 = num(base["p95_us"])
    bp99 = num(base["p99_us"])

    t50 = Map.get(tolerance, "p50_max_ratio", 1.20)
    t95 = Map.get(tolerance, "p95_max_ratio", 1.30)
    t99 = Map.get(tolerance, "p99_max_ratio", 1.50)

    breached =
      (bp50 && p50 && p50 > bp50 * t50) ||
        (bp95 && p95 && p95 > bp95 * t95) ||
        (bp99 && p99 && p99 > bp99 * t99)

    if breached, do: "REGRESSED", else: "ok"
  end

  defp num(nil), do: nil
  defp num(n) when is_number(n), do: n
  defp num(_), do: nil
end

Bench.Compare.run()
