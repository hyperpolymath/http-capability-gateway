# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.PolicyCapabilityTest do
  use ExUnit.Case, async: false

  alias HttpCapabilityGateway.PolicyValidator
  alias HttpCapabilityGateway.PolicyCompiler
  alias HttpCapabilityGateway.SafeTrust

  describe "PolicyValidator route-level capability field" do
    test "accepts a non-empty capability string" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [%{"path" => "/api/admin", "verbs" => ["GET"], "capability" => "admin:read"}]
        }
      }

      assert :ok = PolicyValidator.validate(policy)
    end

    test "accepts omitted capability (back-compat)" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [%{"path" => "/api/admin", "verbs" => ["GET"]}]
        }
      }

      assert :ok = PolicyValidator.validate(policy)
    end

    test "rejects an empty capability string" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [%{"path" => "/api/admin", "verbs" => ["GET"], "capability" => ""}]
        }
      }

      assert {:error, msg} = PolicyValidator.validate(policy)
      assert msg =~ "capability"
    end

    test "rejects a non-string capability" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [%{"path" => "/api/admin", "verbs" => ["GET"], "capability" => 42}]
        }
      }

      assert {:error, msg} = PolicyValidator.validate(policy)
      assert msg =~ "capability"
    end
  end

  describe "PolicyCompiler propagation of capability" do
    test "compiled rule carries the capability label" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [%{"path" => "/api/admin", "verbs" => ["GET"], "capability" => "admin:read"}]
        }
      }

      assert {:ok, table} = PolicyCompiler.compile(policy, table_name: :pc_test, atomic_swap: false)

      assert {:ok, rule} = PolicyCompiler.lookup(table, "/api/admin", :GET)
      assert rule.capability == "admin:read"

      :ets.delete(table)
    end

    test "compiled rule has nil capability when omitted" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [%{"path" => "/api/public", "verbs" => ["GET"]}]
        }
      }

      assert {:ok, table} = PolicyCompiler.compile(policy, table_name: :pc_test_nil, atomic_swap: false)

      assert {:ok, rule} = PolicyCompiler.lookup(table, "/api/public", :GET)
      assert rule.capability == nil

      :ets.delete(table)
    end
  end

  describe "SafeTrust.parse_exposure/1 fail-closed opt-in" do
    setup do
      original = Application.get_env(:http_capability_gateway, :exposure_fail_closed, false)
      on_exit(fn -> Application.put_env(:http_capability_gateway, :exposure_fail_closed, original) end)
      :ok
    end

    test "default fail-open (back-compat): unknown -> :public" do
      Application.put_env(:http_capability_gateway, :exposure_fail_closed, false)
      assert SafeTrust.parse_exposure("typo") == :public
    end

    test "opt-in fail-closed: unknown -> :internal" do
      Application.put_env(:http_capability_gateway, :exposure_fail_closed, true)
      assert SafeTrust.parse_exposure("typo") == :internal
    end

    test "known values still parse correctly under fail-closed" do
      Application.put_env(:http_capability_gateway, :exposure_fail_closed, true)
      assert SafeTrust.parse_exposure("public") == :public
      assert SafeTrust.parse_exposure("authenticated") == :authenticated
      assert SafeTrust.parse_exposure("internal") == :internal
    end
  end
end
