# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyCompilerTest do
  use ExUnit.Case, async: false  # ETS operations can't be async
  alias HttpCapabilityGateway.PolicyCompiler

  setup do
    # Clean up ETS table if it exists
    try do
      :ets.delete(:policy_rules)
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  describe "compile/1" do
    test "compiles valid policy to ETS" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => [
            %{"path" => "/api/users", "verbs" => ["GET", "POST", "DELETE"]}
          ]
        }
      }

      assert {:ok, table} = PolicyCompiler.compile(policy)

      # Verify ETS table exists and is accessible
      assert :ets.whereis(:policy_rules) != :undefined
      assert table == :policy_rules
    end

    test "compiles global verbs correctly" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST", "PUT"]
        }
      }

      assert {:ok, table} = PolicyCompiler.compile(policy)

      # Check global verbs are in table
      # Global verbs stored as {{:global, verb_atom}, rule}
      rules = :ets.tab2list(table)
      global_verbs =
        rules
        |> Enum.filter(fn {{key, _verb}, _rule} -> key == :global end)
        |> Enum.map(fn {{:global, verb}, _rule} -> verb end)
        |> MapSet.new()

      assert MapSet.equal?(global_verbs, MapSet.new([:GET, :POST, :PUT]))
    end

    test "compiles routes with regex patterns" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{"path" => "/api/users", "verbs" => ["GET", "POST"]},
            %{"path" => "/api/users/[0-9]+", "verbs" => ["GET", "PUT", "DELETE"]}
          ]
        }
      }

      assert {:ok, table} = PolicyCompiler.compile(policy)

      # Verify routes are compiled
      rules = :ets.tab2list(table)
      route_patterns =
        rules
        |> Enum.filter(fn {{key, _verb}, _rule} -> is_binary(key) end)
        |> Enum.map(fn {{pattern, _verb}, _rule} -> pattern end)
        |> Enum.uniq()

      assert "/api/users" in route_patterns
      assert "/api/users/[0-9]+" in route_patterns
    end

    test "compiles stealth configuration" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"]
        },
        "stealth" => %{
          "enabled" => true,
          "status_code" => 404
        }
      }

      assert {:ok, table} = PolicyCompiler.compile(policy)

      # Stealth configuration should be reflected in rules
      rules = :ets.tab2list(table)
      assert length(rules) > 0

      # Check that rules have stealth_profile set
      {_key, rule} = hd(rules)
      assert rule.stealth_profile == "default"
    end

    test "handles empty routes list" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"]
        }
      }

      assert {:ok, table} = PolicyCompiler.compile(policy)

      # Should only have global verbs
      rules = :ets.tab2list(table)
      assert length(rules) == 2  # GET and POST
    end
  end

  describe "lookup/3" do
    setup do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => [
            %{"path" => "/api/admin", "verbs" => ["GET"]},
            %{"path" => "/api/users/[0-9]+", "verbs" => ["GET", "PUT", "DELETE"]}
          ]
        }
      }

      {:ok, table} = PolicyCompiler.compile(policy)
      {:ok, table: table}
    end

    test "finds global verb for unspecified route", %{table: table} do
      assert {:ok, rule} = PolicyCompiler.lookup(table, "/api/public", :GET)
      assert rule.verb == :GET
      assert rule.exposure == "public"
    end

    test "finds route-specific verb", %{table: table} do
      assert {:ok, rule} = PolicyCompiler.lookup(table, "/api/admin", :GET)
      assert rule.verb == :GET
      assert rule.path_pattern == "/api/admin"
    end

    test "matches regex patterns", %{table: table} do
      assert {:ok, rule} = PolicyCompiler.lookup(table, "/api/users/123", :PUT)
      assert rule.verb == :PUT
      assert rule.path_pattern == "/api/users/[0-9]+"
    end

    test "returns error for non-matching path/verb", %{table: table} do
      assert {:error, :no_match} = PolicyCompiler.lookup(table, "/api/admin", :POST)
    end

    test "returns error for non-global verb on unspecified route", %{table: table} do
      assert {:error, :no_match} = PolicyCompiler.lookup(table, "/api/public", :DELETE)
    end
  end

  describe "stats/1" do
    test "returns correct statistics" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => [
            %{"path" => "/api/users", "verbs" => ["GET", "POST", "PUT"]},
            %{"path" => "/api/admin", "verbs" => ["GET"]}
          ]
        }
      }

      {:ok, table} = PolicyCompiler.compile(policy)
      stats = PolicyCompiler.stats(table)

      assert stats.total_rules == 6  # 2 global + 4 route-specific
      assert stats.global_rules == 2
      assert stats.route_rules == 4
      assert MapSet.new(stats.verbs) == MapSet.new([:GET, :POST, :PUT])
    end
  end
end
