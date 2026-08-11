# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.PolicyPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias HttpCapabilityGateway.{PolicyValidator, PolicyCompiler}

  @valid_http_verbs ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

  defp is_allowed?(table, path, verb) do
    verb_atom = if is_binary(verb), do: String.to_existing_atom(verb), else: verb
    case PolicyCompiler.lookup(table, path, verb_atom) do
      {:ok, _rule} -> true
      {:error, :no_match} -> false
    end
  end

  describe "property-based policy validation" do
    property "valid policies always pass validation" do
      check all(
              verbs <- list_of(member_of(@valid_http_verbs), min_length: 1),
              route_count <- integer(0..20),
              max_runs: 20
            ) do
        routes =
          for i <- 1..route_count do
            route_verbs =
              Enum.take_random(@valid_http_verbs, Enum.random(1..length(@valid_http_verbs)))

            %{
              "path" => "/api/resource#{i}",
              "verbs" => route_verbs,
              "backend" => "http://localhost:8080"
            }
          end

        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => Enum.uniq(verbs),
            "routes" => routes
          }
        }

        assert :ok = PolicyValidator.validate(policy)
      end
    end

    property "verb checking is consistent" do
      check all(
              verbs <- list_of(member_of(@valid_http_verbs), min_length: 1),
              path <- string(:alphanumeric, min_length: 1),
              max_runs: 20
            ) do
        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => Enum.uniq(verbs)
          }
        }

        {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)

        full_path = "/" <> path

        # Allowed verbs should always be allowed (via global)
        for verb <- Enum.uniq(verbs) do
          assert is_allowed?(table, full_path, verb)
        end

        # Disallowed verbs should always be denied
        disallowed_verbs = @valid_http_verbs -- verbs

        for verb <- disallowed_verbs do
          refute is_allowed?(table, full_path, verb)
        end
      end
    end

    property "routes override global verbs correctly" do
      check all(
              global_verbs <- list_of(member_of(@valid_http_verbs), min_length: 1),
              route_verbs <- list_of(member_of(@valid_http_verbs), min_length: 1),
              path <- string(:alphanumeric, min_length: 1),
              max_runs: 20
            ) do
        full_path = "/" <> path

        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => Enum.uniq(global_verbs),
            "routes" => [
              %{
                "path" => full_path, 
                "verbs" => Enum.uniq(route_verbs),
                "backend" => "http://localhost:8080"
              }
            ]
          }
        }

        {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)

        # Route-specific verbs should be allowed
        for verb <- Enum.uniq(route_verbs) do
          assert is_allowed?(table, full_path, verb)
        end

        # Verbs NOT in route config should be checked against globals
        # (Wait, the current implementation falls back to global if route doesn't match VERB)
        # So we test that logic.
        other_verbs = @valid_http_verbs -- route_verbs

        for verb <- other_verbs do
          expected = verb in global_verbs
          assert is_allowed?(table, full_path, verb) == expected
        end
      end
    end
  end

  describe "invariants" do
    property "compilation never crashes with valid policies" do
      check all(
              verbs <- list_of(member_of(@valid_http_verbs), min_length: 1),
              route_count <- integer(0..50),
              max_runs: 20
            ) do
        routes =
          for i <- 1..route_count do
            %{
              "path" => "/path#{i}",
              "verbs" => Enum.take_random(@valid_http_verbs, Enum.random(1..4)),
              "backend" => "http://localhost:8080"
            }
          end

        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => Enum.uniq(verbs),
            "routes" => routes
          }
        }

        # Should never crash
        assert {:ok, _} = PolicyCompiler.compile(policy, atomic_swap: false)
      end
    end
  end
end
