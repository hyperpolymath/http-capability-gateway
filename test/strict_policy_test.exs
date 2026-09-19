# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.StrictPolicyTest do
  use ExUnit.Case, async: false
  alias HttpCapabilityGateway.{PolicyCompiler, PolicyValidator}

  defp compile(routes, globals \\ ["GET", "POST"]) do
    policy = %{
      "dsl_version" => "1",
      "governance" => %{"global_verbs" => globals, "routes" => routes}
    }

    assert :ok = PolicyValidator.validate(policy)
    assert {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
    table
  end

  test "exact and regex route omissions override every global verb" do
    for path <- ["/private", "\\A/private\\z"] do
      table = compile([%{"path" => path, "verbs" => ["DELETE"], "exposure" => "internal"}])
      assert {:error, :no_match} = PolicyCompiler.lookup(table, "/private", :GET)
      assert {:error, :no_match} = PolicyCompiler.lookup(table, "/private", :POST)
      assert {:ok, rule} = PolicyCompiler.lookup(table, "/private", :DELETE)
      assert rule.exposure == "internal"
      assert {:ok, _} = PolicyCompiler.lookup(table, "/elsewhere", :GET)
    end
  end

  test "empty globals and all-empty governance deny unknown paths" do
    table = compile([%{"path" => "\\A/known\\z", "verbs" => ["GET"]}], [])
    assert {:ok, _} = PolicyCompiler.lookup(table, "/known", :GET)

    for verb <- [:GET, :POST, :PUT, :PATCH, :DELETE, :HEAD, :OPTIONS, :TRACE] do
      assert {:error, :no_match} = PolicyCompiler.lookup(table, "/unknown", verb)
    end

    all_denied = compile([], [])
    assert {:error, :no_match} = PolicyCompiler.lookup(all_denied, "/anything", :GET)
    assert %{total_rules: 0} = PolicyCompiler.stats(all_denied)
  end

  test "exact path owns denial; ambiguous regex paths fail closed regardless of order" do
    routes = [
      %{"path" => "\\A/items/.*\\z", "verbs" => ["GET"]},
      %{"path" => "\\A/items/[^/]+\\z", "verbs" => ["POST"], "exposure" => "internal"},
      %{"path" => "/items/admin", "verbs" => ["DELETE"]}
    ]

    for ordered <- [routes, Enum.reverse(routes)] do
      table = compile(ordered)
      assert {:error, :no_match} = PolicyCompiler.lookup(table, "/items/one", :GET)
      assert {:error, :no_match} = PolicyCompiler.lookup(table, "/items/one", :POST)
      assert {:error, :no_match} = PolicyCompiler.lookup(table, "/items/admin", :GET)
      assert {:ok, _} = PolicyCompiler.lookup(table, "/items/admin", :DELETE)
    end
  end

  test "an old main handle cannot accidentally use a newer regex policy" do
    old = compile([%{"path" => "\\A/private\\z", "verbs" => ["DELETE"]}])
    _new = compile([%{"path" => "\\A/elsewhere\\z", "verbs" => ["GET"]}])
    assert {:error, :no_match} = PolicyCompiler.lookup(old, "/private", :GET)
    assert {:ok, _} = PolicyCompiler.lookup(old, "/private", :DELETE)
    :ets.delete(old)
    assert {:error, :no_match} = PolicyCompiler.lookup(old, "/private", :GET)
  end

  test "malformed exposure and non-string verbs are rejected rather than becoming public" do
    for exposure <- ["interanl", "PUBLIC", nil, false, 1, %{}] do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => [],
          "routes" => [
            %{"path" => "/private", "verbs" => ["GET"], "exposure" => exposure}
          ]
        }
      }

      assert {:error, _} = PolicyValidator.validate(policy)
    end

    for verb <- [nil, false, true, %{}, 1] do
      assert {:error, _} =
               PolicyValidator.validate(%{
                 "dsl_version" => "1",
                 "governance" => %{"global_verbs" => [verb]}
               })

      assert {:error, _} =
               PolicyValidator.validate(%{
                 "dsl_version" => "1",
                 "governance" => %{
                   "global_verbs" => [],
                   "routes" => [%{"path" => "/", "verbs" => [verb]}]
                 }
               })
    end
  end

  test "policy load logging accepts the documented success atom and error tuple" do
    assert :ok = HttpCapabilityGateway.Logging.log_policy_load("test.yaml", :ok)
    assert :ok = HttpCapabilityGateway.Logging.log_policy_load("test.yaml", {:error, :invalid})
  end
end
