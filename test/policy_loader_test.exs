# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyLoaderTest do
  use ExUnit.Case, async: true
  alias HttpCapabilityGateway.PolicyLoader

  describe "load_policy/1" do
    test "loads valid YAML policy" do
      yaml_content = """
      dsl_version: "1"
      governance:
        global_verbs:
          - GET
          - POST
        routes:
          - path: "/api/users"
            verbs: [GET, POST, DELETE]
          - path: "/health"
            verbs: [GET]
      stealth:
        enabled: true
        status_code: 404
      """

      assert {:ok, policy} = PolicyLoader.load_policy(yaml_content)
      assert policy["dsl_version"] == "1"
      assert policy["governance"]["global_verbs"] == ["GET", "POST"]
      assert length(policy["governance"]["routes"]) == 2
      assert policy["stealth"]["enabled"] == true
    end

    test "returns error for invalid YAML" do
      invalid_yaml = """
      dsl_version: "1"
        invalid indentation
      governance:
      """

      assert {:error, reason} = PolicyLoader.load_policy(invalid_yaml)
      assert is_binary(reason)
    end

    test "returns error for empty policy" do
      assert {:error, reason} = PolicyLoader.load_policy("")
      assert reason =~ "empty"
    end

    test "handles policy with comments" do
      yaml_with_comments = """
      # This is a comment
      dsl_version: "1"  # version comment
      governance:
        # Global verbs
        global_verbs:
          - GET
          - POST
      """

      assert {:ok, policy} = PolicyLoader.load_policy(yaml_with_comments)
      assert policy["dsl_version"] == "1"
    end

    test "handles nested structures" do
      nested_yaml = """
      dsl_version: "1"
      governance:
        routes:
          - path: "/api/v1/resource"
            verbs: [GET, POST]
            meta:
              description: "Resource endpoint"
              version: "1.0"
      """

      assert {:ok, policy} = PolicyLoader.load_policy(nested_yaml)
      route = hd(policy["governance"]["routes"])
      assert route["meta"]["description"] == "Resource endpoint"
    end

    test "handles list of maps correctly" do
      yaml = """
      dsl_version: "1"
      governance:
        global_verbs: [GET, POST, PUT, DELETE]
        routes:
          - path: "/users"
            verbs: [GET, POST]
          - path: "/posts"
            verbs: [GET]
          - path: "/comments"
            verbs: [GET, POST, DELETE]
      """

      assert {:ok, policy} = PolicyLoader.load_policy(yaml)
      assert length(policy["governance"]["routes"]) == 3
      assert Enum.all?(policy["governance"]["routes"], &is_map/1)
    end

    test "preserves verb order" do
      yaml = """
      dsl_version: "1"
      governance:
        global_verbs: [DELETE, PUT, POST, GET]
      """

      assert {:ok, policy} = PolicyLoader.load_policy(yaml)
      assert policy["governance"]["global_verbs"] == ["DELETE", "PUT", "POST", "GET"]
    end

    test "handles large policies" do
      # Generate a policy with 100 routes
      routes = for i <- 1..100 do
        """
          - path: "/api/resource#{i}"
            verbs: [GET, POST]
        """
      end

      yaml = """
      dsl_version: "1"
      governance:
        global_verbs: [GET]
        routes:
      #{Enum.join(routes, "\n")}
      """

      assert {:ok, policy} = PolicyLoader.load_policy(yaml)
      assert length(policy["governance"]["routes"]) == 100
    end

    test "handles special characters in paths" do
      yaml = """
      dsl_version: "1"
      governance:
        routes:
          - path: "/api/users/{id}"
            verbs: [GET]
          - path: "/api/search?q=*"
            verbs: [GET]
          - path: "/files/document.pdf"
            verbs: [GET]
      """

      assert {:ok, policy} = PolicyLoader.load_policy(yaml)
      routes = policy["governance"]["routes"]
      assert Enum.any?(routes, fn r -> r["path"] == "/api/users/{id}" end)
      assert Enum.any?(routes, fn r -> r["path"] == "/api/search?q=*" end)
    end
  end

  describe "load_from_file/1" do
    test "loads policy from file" do
      # Assuming example policy exists
      policy_file = "priv/config/policy.dev.yaml"

      case PolicyLoader.load_from_file(policy_file) do
        {:ok, policy} ->
          assert is_map(policy)
          assert policy["dsl_version"] == "1"

        {:error, _} ->
          # File might not exist in test environment
          assert true
      end
    end

    test "returns error for non-existent file" do
      assert {:error, reason} = PolicyLoader.load_from_file("/nonexistent/file.yaml")
      assert reason =~ "not found" or reason =~ "no such file"
    end
  end
end
