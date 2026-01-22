# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyCompilerTest do
  use ExUnit.Case, async: false  # ETS operations can't be async
  alias HttpCapabilityGateway.PolicyCompiler

  setup do
    # Clean up ETS tables if they exist
    try do
      :ets.delete(:gateway_rules)
      :ets.delete(:stealth_config)
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

      assert :ok = PolicyCompiler.compile(policy)

      # Verify ETS table exists
      assert :ets.whereis(:gateway_rules) != :undefined
    end

    test "compiles global verbs correctly" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST", "PUT"]
        }
      }

      assert :ok = PolicyCompiler.compile(policy)

      # Check global verbs are accessible
      case :ets.lookup(:gateway_rules, :global_verbs) do
        [{:global_verbs, verbs}] ->
          assert MapSet.new(verbs) == MapSet.new(["GET", "POST", "PUT"])
        [] ->
          flunk("Global verbs not compiled to ETS")
      end
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

      assert :ok = PolicyCompiler.compile(policy)

      # Verify routes table exists
      assert :ets.info(:gateway_rules) != :undefined
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

      assert :ok = PolicyCompiler.compile(policy)

      # Check stealth config
      case :ets.lookup(:stealth_config, :enabled) do
        [{:enabled, true}] -> assert true
        [{:enabled, false}] -> flunk("Stealth should be enabled")
        [] -> flunk("Stealth config not compiled")
      end
    end

    test "handles empty routes list" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"]
        }
      }

      assert :ok = PolicyCompiler.compile(policy)
    end

    test "compiles large policy efficiently" do
      routes = for i <- 1..1000 do
        %{"path" => "/api/resource#{i}", "verbs" => ["GET", "POST"]}
      end

      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => routes
        }
      }

      {time_us, :ok} = :timer.tc(fn -> PolicyCompiler.compile(policy) end)

      # Compilation should be fast (< 100ms for 1000 routes)
      assert time_us < 100_000
    end

    test "overwrites previous compilation" do
      policy1 = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"]
        }
      }

      policy2 = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST", "PUT"]
        }
      }

      assert :ok = PolicyCompiler.compile(policy1)
      assert :ok = PolicyCompiler.compile(policy2)

      # Verify second compilation overwrote the first
      case :ets.lookup(:gateway_rules, :global_verbs) do
        [{:global_verbs, verbs}] ->
          assert length(verbs) == 3
        [] ->
          flunk("Global verbs not found after recompilation")
      end
    end
  end

  describe "is_verb_allowed?/2" do
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

      PolicyCompiler.compile(policy)
      :ok
    end

    test "allows global verbs on unspecified routes" do
      assert PolicyCompiler.is_verb_allowed?("/api/public", "GET")
      assert PolicyCompiler.is_verb_allowed?("/health", "POST")
    end

    test "denies non-global verbs on unspecified routes" do
      refute PolicyCompiler.is_verb_allowed?("/api/public", "DELETE")
      refute PolicyCompiler.is_verb_allowed?("/health", "PUT")
    end

    test "allows route-specific verbs" do
      assert PolicyCompiler.is_verb_allowed?("/api/admin", "GET")
      assert PolicyCompiler.is_verb_allowed?("/api/users/123", "PUT")
      assert PolicyCompiler.is_verb_allowed?("/api/users/456", "DELETE")
    end

    test "denies verbs not in route config" do
      refute PolicyCompiler.is_verb_allowed?("/api/admin", "POST")
      refute PolicyCompiler.is_verb_allowed?("/api/admin", "DELETE")
      refute PolicyCompiler.is_verb_allowed?("/api/users/123", "POST")
    end

    test "handles regex patterns correctly" do
      # Should match /api/users/[0-9]+
      assert PolicyCompiler.is_verb_allowed?("/api/users/1", "GET")
      assert PolicyCompiler.is_verb_allowed?("/api/users/999", "PUT")

      # Should not match (non-numeric ID)
      refute PolicyCompiler.is_verb_allowed?("/api/users/abc", "DELETE")
    end

    test "case-sensitive verb matching" do
      assert PolicyCompiler.is_verb_allowed?("/api/public", "GET")
      refute PolicyCompiler.is_verb_allowed?("/api/public", "get")
      refute PolicyCompiler.is_verb_allowed?("/api/public", "Get")
    end
  end

  describe "get_stealth_config/0" do
    test "returns stealth config when enabled" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"]
        },
        "stealth" => %{
          "enabled" => true,
          "status_code" => 403
        }
      }

      PolicyCompiler.compile(policy)

      case PolicyCompiler.get_stealth_config() do
        %{enabled: true, status_code: 403} -> assert true
        _ -> flunk("Stealth config not retrieved correctly")
      end
    end

    test "returns stealth config when disabled" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"]
        },
        "stealth" => %{
          "enabled" => false,
          "status_code" => 404
        }
      }

      PolicyCompiler.compile(policy)

      case PolicyCompiler.get_stealth_config() do
        %{enabled: false} -> assert true
        _ -> flunk("Stealth config not retrieved correctly")
      end
    end

    test "returns default config when stealth not specified" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"]
        }
      }

      PolicyCompiler.compile(policy)

      case PolicyCompiler.get_stealth_config() do
        %{enabled: false} -> assert true
        nil -> assert true  # No stealth config
        _ -> flunk("Unexpected stealth config")
      end
    end
  end
end
