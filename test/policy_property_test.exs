# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias HttpCapabilityGateway.{PolicyValidator, PolicyCompiler}

  @valid_http_verbs ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

  describe "property-based policy validation" do
    property "valid policies always pass validation" do
      check all(
              verbs <- non_empty_list_of(member_of(@valid_http_verbs)),
              route_count <- integer(0..20),
              max_runs: 50
            ) do
        routes =
          for i <- 1..route_count do
            route_verbs =
              Enum.take_random(@valid_http_verbs, Enum.random(1..length(@valid_http_verbs)))

            %{
              "path" => "/api/resource#{i}",
              "verbs" => route_verbs
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

    property "policies with invalid verbs always fail validation" do
      check all(
              invalid_verb <- string(:alphanumeric, min_length: 1),
              max_runs: 20
            ) do
        # Skip if accidentally generates a valid verb
        if invalid_verb not in @valid_http_verbs do
          policy = %{
            "dsl_version" => "1",
            "governance" => %{
              "global_verbs" => [invalid_verb]
            }
          }

          assert {:error, _reason} = PolicyValidator.validate(policy)
        end
      end
    end

    property "policy compilation is idempotent" do
      check all(
              verbs <- non_empty_list_of(member_of(@valid_http_verbs)),
              max_runs: 20
            ) do
        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => Enum.uniq(verbs)
          }
        }

        # Compile twice
        assert :ok = PolicyCompiler.compile(policy)
        assert :ok = PolicyCompiler.compile(policy)

        # Results should be identical
        global_verbs1 =
          case :ets.lookup(:gateway_rules, :global_verbs) do
            [{:global_verbs, v}] -> MapSet.new(v)
            [] -> MapSet.new()
          end

        assert :ok = PolicyCompiler.compile(policy)

        global_verbs2 =
          case :ets.lookup(:gateway_rules, :global_verbs) do
            [{:global_verbs, v}] -> MapSet.new(v)
            [] -> MapSet.new()
          end

        assert global_verbs1 == global_verbs2
      end
    end

    property "verb checking is consistent" do
      check all(
              verbs <- non_empty_list_of(member_of(@valid_http_verbs)),
              path <- string(:alphanumeric, min_length: 1),
              max_runs: 30
            ) do
        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => Enum.uniq(verbs)
          }
        }

        PolicyCompiler.compile(policy)

        full_path = "/" <> path

        # Allowed verbs should always be allowed
        for verb <- Enum.uniq(verbs) do
          assert PolicyCompiler.is_verb_allowed?(full_path, verb)
        end

        # Disallowed verbs should always be denied
        disallowed_verbs = @valid_http_verbs -- verbs

        for verb <- disallowed_verbs do
          refute PolicyCompiler.is_verb_allowed?(full_path, verb)
        end
      end
    end

    property "routes override global verbs correctly" do
      check all(
              global_verbs <- non_empty_list_of(member_of(@valid_http_verbs)),
              route_verbs <- non_empty_list_of(member_of(@valid_http_verbs)),
              path <- string(:alphanumeric, min_length: 1),
              max_runs: 30
            ) do
        full_path = "/" <> path

        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => Enum.uniq(global_verbs),
            "routes" => [
              %{"path" => full_path, "verbs" => Enum.uniq(route_verbs)}
            ]
          }
        }

        PolicyCompiler.compile(policy)

        # Route-specific verbs should be allowed
        for verb <- Enum.uniq(route_verbs) do
          assert PolicyCompiler.is_verb_allowed?(full_path, verb)
        end

        # Verbs not in route config should be denied
        # (even if they're in global_verbs - routes override)
        denied_verbs = @valid_http_verbs -- route_verbs

        for verb <- denied_verbs do
          refute PolicyCompiler.is_verb_allowed?(full_path, verb)
        end
      end
    end

    property "stealth mode configuration is preserved" do
      check all(
              verbs <- non_empty_list_of(member_of(@valid_http_verbs)),
              enabled <- boolean(),
              status_code <- member_of([200, 301, 302, 403, 404, 410, 500, 503]),
              max_runs: 20
            ) do
        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => Enum.uniq(verbs)
          },
          "stealth" => %{
            "enabled" => enabled,
            "status_code" => status_code
          }
        }

        assert :ok = PolicyCompiler.compile(policy)

        config = PolicyCompiler.get_stealth_config()
        assert config.enabled == enabled
        assert config.status_code == status_code
      end
    end

    property "path matching handles various path formats" do
      check all(
              segments <- list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 5),
              max_runs: 30
            ) do
        path = "/" <> Enum.join(segments, "/")

        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => ["GET", "POST"]
          }
        }

        PolicyCompiler.compile(policy)

        # Global verbs should work on any path
        assert PolicyCompiler.is_verb_allowed?(path, "GET")
        assert PolicyCompiler.is_verb_allowed?(path, "POST")
        refute PolicyCompiler.is_verb_allowed?(path, "DELETE")
      end
    end
  end

  describe "invariants" do
    property "compilation never crashes with valid policies" do
      check all(
              verbs <- non_empty_list_of(member_of(@valid_http_verbs)),
              route_count <- integer(0..50),
              max_runs: 30
            ) do
        routes =
          for i <- 1..route_count do
            %{
              "path" => "/path#{i}",
              "verbs" => Enum.take_random(@valid_http_verbs, Enum.random(1..4))
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
        assert :ok = PolicyCompiler.compile(policy)
      end
    end

    property "verb checking never crashes" do
      check all(
              path <- string(:printable, min_length: 1, max_length: 100),
              verb <- string(:alphanumeric, min_length: 1, max_length: 10),
              max_runs: 50
            ) do
        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => ["GET"]
          }
        }

        PolicyCompiler.compile(policy)

        # Should never crash, even with invalid inputs
        result = PolicyCompiler.is_verb_allowed?(path, verb)
        assert is_boolean(result)
      end
    end
  end

  # Helper generators
  defp non_empty_list_of(gen) do
    list_of(gen, min_length: 1, max_length: 7)
  end
end
