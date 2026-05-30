# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# bench/rebaseline.exs — Phase D-4 baseline regeneration helper
# (standards#99 of the standards#91 single-lane HCG channel).
#
# Reads bench/results.json (produced by bench/gateway_latency.exs) and
# bench/baseline.json, then writes a regenerated bench/baseline.json
# that replaces the per-scenario TODO values with the real p50/p95/p99/
# ips from results.json — preserving _comment, _schema_version, tolerance,
# per-scenario _comment_* fields, and (deliberately) _status.
#
# `_status` is left as "scaffold-placeholder". The rebaseline PR is the
# review gate; the maintainer flips `_status` → "active" in the PR
# (arming perf-regression.yml's gate) or in a follow-up. See
# docs/perf-contract.md § Baseline lifecycle and the workflow file
# .github/workflows/perf-rebaseline.yml for the surrounding ritual.
#
# Field ordering is preserved via Jason.OrderedObject so the diff
# against the prior baseline is review-grade (numbers move; structure
# does not).
#
# Runs:
#
#   • Driven by .github/workflows/perf-rebaseline.yml on ubuntu-latest
#     (the published reference target per docs/perf-contract.md).
#   • Locally after `just bench-collect`:
#
#         just rebaseline
#
#     or directly:
#
#         mix run bench/rebaseline.exs

defmodule Bench.Rebaseline do
  alias Jason.OrderedObject

  @results_path "bench/results.json"
  @baseline_path "bench/baseline.json"

  def run do
    with {:ok, results_raw} <- File.read(@results_path),
         {:ok, baseline_raw} <- File.read(@baseline_path),
         {:ok, results} <- Jason.decode(results_raw),
         {:ok, baseline} <- Jason.decode(baseline_raw, objects: :ordered_objects) do
      new_baseline = rebaseline(baseline, results)
      json = Jason.encode!(new_baseline, pretty: true)
      File.write!(@baseline_path, json <> "\n")
      report(new_baseline)
    else
      {:error, :enoent} ->
        IO.puts(
          :stderr,
          "ERROR: #{@results_path} or #{@baseline_path} missing. " <>
            "Did `mix run bench/gateway_latency.exs` run first?"
        )

        System.halt(2)

      {:error, reason} ->
        IO.puts(:stderr, "ERROR reading baseline/results: #{inspect(reason)}")
        System.halt(2)
    end
  end

  # ── Rebaseline logic ───────────────────────────────────────────────────────

  defp rebaseline(%OrderedObject{} = baseline, results) do
    results_stats = Map.get(results, "statistics", %{})
    existing_scenarios = oget(baseline, "scenarios", %OrderedObject{values: []})

    rebaselined_scenarios =
      results_stats
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, stats} ->
        {name, scenario_entry(oget(existing_scenarios, name, %OrderedObject{values: []}), stats)}
      end)
      |> then(fn pairs -> %OrderedObject{values: pairs} end)

    baseline
    |> oput("_generated_at", DateTime.utc_now() |> DateTime.to_iso8601())
    |> oput("_generated_by", generated_by())
    |> oput("scenarios", rebaselined_scenarios)
  end

  defp scenario_entry(%OrderedObject{values: existing_pairs}, stats) do
    comments =
      existing_pairs
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "_comment") end)

    numbers = [
      {"p50_us", us(stats, "50")},
      {"p95_us", us(stats, "95")},
      {"p99_us", us(stats, "99")},
      {"ips", round2(Map.get(stats, "ips"))}
    ]

    %OrderedObject{values: comments ++ numbers}
  end

  defp us(stats, p) do
    case get_in(stats, ["percentiles", p]) do
      nil -> nil
      ns when is_number(ns) -> round2(ns / 1_000.0)
    end
  end

  defp round2(nil), do: nil
  defp round2(n) when is_integer(n), do: Float.round(n / 1.0, 2)
  defp round2(n) when is_float(n), do: Float.round(n, 2)

  defp generated_by do
    run_id = System.get_env("REBASELINE_RUN_ID")
    ref = System.get_env("REBASELINE_RUN_REF")

    case run_id do
      nil ->
        "local: mix run bench/rebaseline.exs"

      run ->
        ".github/workflows/perf-rebaseline.yml (ubuntu-latest; ref=#{ref || "main"}; run=#{run})"
    end
  end

  # ── OrderedObject helpers ──────────────────────────────────────────────────
  #
  # Jason.OrderedObject does not implement the full Access protocol, so
  # tiny get/put helpers keep the rebaseline code shape close to the
  # equivalent Map.get / Map.put it would otherwise use.

  defp oget(%OrderedObject{values: pairs}, key, default) do
    case List.keyfind(pairs, key, 0) do
      {^key, v} -> v
      nil -> default
    end
  end

  defp oput(%OrderedObject{values: pairs}, key, value) do
    new_pairs =
      case List.keymember?(pairs, key, 0) do
        true -> List.keyreplace(pairs, key, 0, {key, value})
        false -> pairs ++ [{key, value}]
      end

    %OrderedObject{values: new_pairs}
  end

  # ── Reporter ───────────────────────────────────────────────────────────────

  defp report(%OrderedObject{} = baseline) do
    IO.puts("")
    IO.puts("bench/baseline.json regenerated.")
    IO.puts("  _status:        #{inspect(oget(baseline, "_status", nil))}")
    IO.puts("  _generated_at:  #{oget(baseline, "_generated_at", "?")}")
    IO.puts("  _generated_by:  #{oget(baseline, "_generated_by", "?")}")
    IO.puts("")

    scenarios = oget(baseline, "scenarios", %OrderedObject{values: []})

    IO.puts("Per-scenario numbers (µs / ips):")

    Enum.each(scenarios.values, fn {name, %OrderedObject{values: pairs}} ->
      m = Map.new(pairs)

      IO.puts(
        "  #{name}: p50=#{fmt(m["p50_us"])} p95=#{fmt(m["p95_us"])} " <>
          "p99=#{fmt(m["p99_us"])} ips=#{fmt(m["ips"])}"
      )
    end)

    IO.puts("")

    IO.puts(
      "Next: review numbers in the rebaseline PR; flip `_status` → \"active\" " <>
        "to arm the perf-regression gate (see docs/perf-contract.md § Baseline lifecycle)."
    )
  end

  defp fmt(nil), do: "—"
  defp fmt(n) when is_number(n), do: to_string(n)
end

Bench.Rebaseline.run()
