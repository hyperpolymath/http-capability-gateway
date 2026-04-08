# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyCompilerTest do
  use ExUnit.Case, async: false
  alias HttpCapabilityGateway.PolicyCompiler

  describe "compile/1" do
    test "compiles valid policy to dynamic ETS table" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => [
            %{"path" => "/api/users", "verbs" => ["GET", "POST", "DELETE"], "backend" => "http://localhost:8080"}
          ]
        }
      }

      assert {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
      assert :ets.info(table, :size) > 0
    end

    test "compiles global verbs correctly" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST", "PUT"]
        }
      }

      assert {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)

      rules = :ets.tab2list(table)
      global_verbs =
        rules
        |> Enum.filter(fn {{key, _v}, _rule} -> key == :global end)
        |> Enum.map(fn {{:global, verb}, _rule} -> verb end)
        |> MapSet.new()

      assert MapSet.equal?(global_verbs, MapSet.new([:GET, :POST, :PUT]))
    end
  end

  describe "lookup/3" do
    setup do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => [
            %{"path" => "/api/admin", "verbs" => ["GET"], "backend" => "http://localhost:8080"},
            %{"path" => "/api/users/[0-9]+", "verbs" => ["GET", "PUT", "DELETE"], "backend" => "http://localhost:8080"}
          ]
        }
      }

      {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
      {:ok, table: table}
    end

    test "finds global verb for unspecified route", %{table: table} do
      assert {:ok, rule} = PolicyCompiler.lookup(table, "/api/public", :GET)
      assert rule.verb == :GET
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

    test "falls back to global verb if route doesn't match verb", %{table: table} do
      # /api/admin only specifies GET, but POST is global
      assert {:ok, rule} = PolicyCompiler.lookup(table, "/api/admin", :POST)
      assert rule.name == "global_POST"
    end

    test "returns error for non-global verb on unspecified route", %{table: table} do
      assert {:error, :no_match} = PolicyCompiler.lookup(table, "/api/public", :DELETE)
    end
  end
end
