# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.E2EPropertyTest do
  @moduledoc """
  Phase C (`hyperpolymath/standards#98`) -- property-based invariants of
  the full policy pipeline (validate → compile → lookup → SafeTrust).

  These properties differ from `policy_property_test.exs` (which is
  scoped to the validator/compiler) by combining the compiled lookup
  result with the SafeTrust evaluation step. The invariants asserted
  here only hold if the whole pipeline is internally consistent, so
  this file is the cross-module regression net for Phase C.

  Properties under test:

    1. **Lookup respects the declared verb set.** For any policy that
       loads and validates successfully, `lookup/3` never returns
       `{:ok, rule}` for a `(path, verb)` pair where the verb is not
       declared in the policy -- neither in the route's `verbs` list
       nor in `global_verbs`. (`undeclared verb cannot bypass enforcement`.)

    2. **Monotonicity of denial.** If a `(path, verb)` is denied under
       trust level T, it is also denied under any T' < T. This mirrors
       the Idris2 proof `mono` on SafeTrust and proves it survives
       composition with the policy lookup step (i.e. PolicyCompiler does
       not introduce a non-monotone rule shape).
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias HttpCapabilityGateway.{PolicyCompiler, PolicyValidator, SafeTrust}

  @verbs ["GET", "POST", "PUT", "DELETE", "PATCH"]
  @exposures ["public", "authenticated", "internal"]

  # Trust hierarchy as encoded in SafeTrust: untrusted < authenticated < internal.
  @trust_levels [:untrusted, :authenticated, :internal]

  defp trust_rank(:untrusted), do: 0
  defp trust_rank(:authenticated), do: 1
  defp trust_rank(:internal), do: 2

  # Drive the pipeline end-to-end for one (path, verb, trust) probe:
  # lookup, then SafeTrust.evaluate against the matched rule's exposure.
  # `:no_match` is treated as `:deny` because the gateway's default-deny
  # handler returns the stealth response in that case -- the seam test
  # observes the same outcome.
  defp pipeline_decision(table, path, verb, trust) do
    case PolicyCompiler.lookup(table, path, verb) do
      {:ok, rule} ->
        case SafeTrust.evaluate(trust, SafeTrust.parse_exposure(rule.exposure)) do
          {:allow, _, _} -> :allow
          {:deny, _, _} -> :deny
        end

      {:error, :no_match} ->
        :deny
    end
  end

  defp policy_gen do
    gen all(
          global_verbs <- list_of(member_of(@verbs), min_length: 1, max_length: 4),
          route_count <- integer(0..5),
          routes <- list_of(route_gen(), length: route_count)
        ) do
      %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => Enum.uniq(global_verbs),
          "routes" => uniq_paths(routes)
        }
      }
    end
  end

  defp route_gen do
    gen all(
          idx <- integer(0..255),
          verbs <- list_of(member_of(@verbs), min_length: 1, max_length: 4),
          exposure <- member_of(@exposures)
        ) do
      %{
        "path" => "/api/r#{idx}",
        "verbs" => Enum.uniq(verbs),
        "exposure" => exposure
      }
    end
  end

  defp uniq_paths(routes) do
    routes
    |> Enum.reduce({[], MapSet.new()}, fn route, {acc, seen} ->
      if MapSet.member?(seen, route["path"]) do
        {acc, seen}
      else
        {[route | acc], MapSet.put(seen, route["path"])}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp declared_verbs_for(policy, path) do
    globals = policy["governance"]["global_verbs"] || []

    route_match =
      Enum.find(policy["governance"]["routes"] || [], fn r -> r["path"] == path end)

    case route_match do
      nil -> globals
      %{"verbs" => verbs} -> verbs ++ globals
    end
  end

  property "compiled lookup never returns a rule for a verb not declared at that path" do
    check all(policy <- policy_gen(), max_runs: 25) do
      assert :ok = PolicyValidator.validate(policy)
      assert {:ok, table} = PolicyCompiler.compile(policy, atomic_swap: false)

      route_paths =
        (policy["governance"]["routes"] || [])
        |> Enum.map(& &1["path"])

      paths = ["/probe/path/never/in/policy" | route_paths]

      for path <- paths, verb_str <- @verbs do
        verb_atom = String.to_existing_atom(verb_str)

        case PolicyCompiler.lookup(table, path, verb_atom) do
          {:error, :no_match} ->
            :ok

          {:ok, _rule} ->
            assert verb_str in declared_verbs_for(policy, path),
                   "verb #{verb_str} matched at #{path} but was not declared in policy"
        end
      end
    end
  end

  property "monotonicity of denial: deny at trust T implies deny at every T' < T" do
    check all(policy <- policy_gen(), max_runs: 25) do
      assert :ok = PolicyValidator.validate(policy)
      assert {:ok, table} = PolicyCompiler.compile(policy, atomic_swap: false)

      route_paths =
        (policy["governance"]["routes"] || [])
        |> Enum.map(& &1["path"])

      paths = ["/probe/path/never/in/policy" | route_paths]

      for path <- paths,
          verb_str <- @verbs,
          higher <- @trust_levels,
          lower <- @trust_levels,
          trust_rank(lower) < trust_rank(higher) do
        verb_atom = String.to_existing_atom(verb_str)

        if pipeline_decision(table, path, verb_atom, higher) == :deny do
          assert pipeline_decision(table, path, verb_atom, lower) == :deny,
                 "monotonicity violated for #{path} #{verb_str}: " <>
                   "denied at #{inspect(higher)} but allowed at #{inspect(lower)}"
        end
      end
    end
  end
end
