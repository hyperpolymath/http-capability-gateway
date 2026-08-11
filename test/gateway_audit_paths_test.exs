# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.GatewayAuditPathsTest do
  @moduledoc """
  Regression tests for audit-ledger persistence on the no-match and
  unknown-method denial paths. Both paths were previously logged via
  Logger but not persisted via VeriSimDB. Audit issue #31 (priority 4).
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias HttpCapabilityGateway.{Gateway, PolicyCompiler, VeriSimDB}

  setup_all do
    # Start the VeriSimDB GenServer if it isn't already (so the casts in
    # the gateway have a live mailbox to land in). The buffer ETS table
    # is created on init/1, which is what we assert against.
    case Process.whereis(VeriSimDB) do
      nil ->
        {:ok, _pid} = VeriSimDB.start_link([])
        :ok

      _pid ->
        :ok
    end

    HttpCapabilityGateway.RateLimiter.init([])
    HttpCapabilityGateway.K9Contract.init()
    :ok
  end

  setup do
    policy = %{
      "dsl_version" => "1",
      "governance" => %{
        "global_verbs" => ["GET"],
        "routes" => [%{"path" => "/api/known", "verbs" => ["GET"]}]
      }
    }

    {:ok, table} = PolicyCompiler.compile(policy, delete_old: false)
    Application.put_env(:http_capability_gateway, :policy_table, table)
    Application.put_env(:http_capability_gateway, :stealth_profiles, %{})
    :ok
  end

  # Helper: drain the VeriSimDB buffer ETS table and return all rows
  # that match this test's request_id, so we can assert on what was cast.
  defp read_buffer do
    case :ets.whereis(:capgw_verisimdb_buffer) do
      :undefined ->
        []

      _tid ->
        :ets.tab2list(:capgw_verisimdb_buffer)
    end
  end

  defp wait_for_cast_to_settle do
    # GenServer.cast is async; flush by doing a sync call on the same pid.
    _ = :sys.get_state(VeriSimDB)
    :ok
  end

  defp clear_buffer do
    case :ets.whereis(:capgw_verisimdb_buffer) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:capgw_verisimdb_buffer)
    end

    :ok
  end

  describe "no-match denial path" do
    test "persists a deny entry to the audit ledger" do
      clear_buffer()

      conn = conn(:delete, "/api/totally-undeclared") |> Gateway.call([])
      assert conn.status == 403
      assert conn.halted

      wait_for_cast_to_settle()

      entries = read_buffer()

      # The buffer stores {id, entry_map}; the entry_map carries the
      # action, path, verb, trust, and policy_ref discriminator.
      matching =
        Enum.filter(entries, fn {_id, entry} ->
          entry[:action] == :deny and
            entry[:path] == "/api/totally-undeclared" and
            entry[:policy_ref] == "no_match"
        end)

      assert length(matching) >= 1,
             "expected at least one no_match deny entry; buffer was: #{inspect(entries)}"
    end
  end

  describe "unknown-method denial path" do
    test "persists a deny entry with unknown_method discriminator" do
      clear_buffer()

      # Use a method outside the @valid_methods allowlist. PROPFIND is the
      # canonical WebDAV verb the gateway must reject; previously this
      # only produced a Logger.warning with no audit row.
      conn = conn("PROPFIND", "/api/known") |> Gateway.call([])
      assert conn.status == 405
      assert conn.halted

      wait_for_cast_to_settle()

      entries = read_buffer()

      matching =
        Enum.filter(entries, fn {_id, entry} ->
          entry[:action] == :deny and
            is_binary(entry[:policy_ref]) and
            String.starts_with?(entry[:policy_ref], "unknown_method:")
        end)

      assert length(matching) >= 1,
             "expected at least one unknown_method deny entry; buffer was: #{inspect(entries)}"
    end
  end
end
