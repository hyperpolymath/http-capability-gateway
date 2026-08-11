# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.EgressPolicyTest do
  use ExUnit.Case, async: true

  alias HttpCapabilityGateway.EgressPolicy
  alias HttpCapabilityGateway.EgressPolicy.Entry

  describe "validate/1" do
    test "nil section yields deny-by-default with empty allowlist" do
      assert {:ok, %{default: :deny, allow: []}} = EgressPolicy.validate(nil)
    end

    test "validates a minimal egress section" do
      raw = %{
        "default" => "deny",
        "allow" => [
          %{"host" => "api.anthropic.com", "verbs" => ["POST"], "capability" => "llm:complete"}
        ]
      }

      assert {:ok, policy} = EgressPolicy.validate(raw)
      assert policy.default == :deny
      assert [%Entry{host: "api.anthropic.com", verbs: ["POST"], capability: "llm:complete"}] = policy.allow
    end

    test "rejects unknown default value" do
      raw = %{"default" => "whatever", "allow" => []}
      assert {:error, msg} = EgressPolicy.validate(raw)
      assert msg =~ "egress.default"
    end

    test "rejects invalid HTTP verb" do
      raw = %{"default" => "deny", "allow" => [%{"host" => "h", "verbs" => ["PROPFIND"]}]}
      assert {:error, msg} = EgressPolicy.validate(raw)
      assert msg =~ "PROPFIND"
    end

    test "rejects empty host" do
      raw = %{"default" => "deny", "allow" => [%{"host" => "", "verbs" => ["GET"]}]}
      assert {:error, msg} = EgressPolicy.validate(raw)
      assert msg =~ "host"
    end

    test "host is lowercased on ingest" do
      raw = %{"default" => "deny", "allow" => [%{"host" => "API.ANTHROPIC.COM", "verbs" => ["POST"]}]}
      assert {:ok, %{allow: [%Entry{host: "api.anthropic.com"}]}} = EgressPolicy.validate(raw)
    end
  end

  describe "decide/3" do
    setup do
      {:ok, policy} =
        EgressPolicy.validate(%{
          "default" => "deny",
          "allow" => [
            %{
              "host" => "api.anthropic.com",
              "verbs" => ["POST"],
              "capability" => "llm:complete",
              "classification" => "redacted-sensor-summary"
            }
          ]
        })

      %{policy: policy}
    end

    test "allows a listed host+verb and returns the matched entry", %{policy: policy} do
      assert {:allow, %Entry{capability: "llm:complete"}} =
               EgressPolicy.decide(policy, "api.anthropic.com", "POST")
    end

    test "denies an unlisted host", %{policy: policy} do
      assert {:deny, reason} = EgressPolicy.decide(policy, "evil.example", "POST")
      assert reason =~ "default=deny"
    end

    test "denies a listed host with the wrong verb", %{policy: policy} do
      assert {:deny, _} = EgressPolicy.decide(policy, "api.anthropic.com", "GET")
    end

    test "host comparison is case-insensitive (via lowercased ingest)", %{policy: policy} do
      assert {:allow, _} = EgressPolicy.decide(policy, "API.anthropic.COM", "POST")
    end
  end
end
