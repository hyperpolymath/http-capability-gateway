# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.PolicyLoaderTest do
  use ExUnit.Case, async: false
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
      assert reason =~ ~r/empty/i
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
      policy_file = "examples/policy-dev.yaml"

      assert {:ok, policy} = PolicyLoader.load_from_file(policy_file)
      assert is_map(policy)
      assert policy["dsl_version"] == "1"
      assert policy["governance"]["global_verbs"] == ["GET", "POST"]
    end

    test "returns error for non-existent file" do
      assert {:error, reason} = PolicyLoader.load_from_file("/nonexistent/file.yaml")
      assert reason =~ "not found" or reason =~ "no such file"
    end
  end

  describe "load_from_boj_catalog/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "boj_catalog_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    defp write_cartridge(root, name, auth_method) do
      dir = Path.join(root, name)
      File.mkdir_p!(dir)

      manifest = Jason.encode!(%{
        "name" => name,
        "version" => "1.0.0",
        "description" => "Test cartridge #{name}",
        "domain" => "Test",
        "tier" => "Ayo",
        "auth" => %{"method" => auth_method},
        "tools" => [%{"name" => "tool1", "description" => "A tool"}]
      })

      File.write!(Path.join(dir, "cartridge.json"), manifest)
    end

    test "returns error for non-existent root" do
      assert {:error, reason} = PolicyLoader.load_from_boj_catalog("/nonexistent/path")
      assert is_binary(reason)
    end

    test "returns error for empty catalog directory", %{root: root} do
      assert {:error, reason} = PolicyLoader.load_from_boj_catalog(root)
      assert String.contains?(reason, "No valid cartridge.json")
    end

    test "generates valid DSL v1 policy from catalog", %{root: root} do
      write_cartridge(root, "free-cart", "none")
      write_cartridge(root, "keyed-cart", "bearer_token")

      assert {:ok, policy} = PolicyLoader.load_from_boj_catalog(root)
      assert policy["dsl_version"] == "1"
      assert policy["service"]["name"] == "boj-server"
      assert is_list(policy["governance"]["routes"])
      assert policy["stealth"]["enabled"] == true
    end

    test "infers public exposure for auth.method none", %{root: root} do
      write_cartridge(root, "public-cart", "none")

      {:ok, policy} = PolicyLoader.load_from_boj_catalog(root)
      routes = policy["governance"]["routes"]
      invoke = Enum.find(routes, fn r -> r["cartridge"] == "public-cart" end)
      assert invoke != nil, "invoke route for public-cart not found in #{inspect(routes)}"
      assert invoke["exposure"] == "public"
      assert invoke["verbs"] == ["POST"]
    end

    test "infers authenticated exposure for bearer_token", %{root: root} do
      write_cartridge(root, "auth-cart", "bearer_token")

      {:ok, policy} = PolicyLoader.load_from_boj_catalog(root)
      routes = policy["governance"]["routes"]
      invoke = Enum.find(routes, fn r -> r["cartridge"] == "auth-cart" end)
      assert invoke != nil, "invoke route for auth-cart not found"
      assert invoke["exposure"] == "authenticated"
    end

    test "infers authenticated exposure for api-key", %{root: root} do
      write_cartridge(root, "apikey-cart", "api-key")

      {:ok, policy} = PolicyLoader.load_from_boj_catalog(root)
      routes = policy["governance"]["routes"]
      invoke = Enum.find(routes, fn r -> r["cartridge"] == "apikey-cart" end)
      assert invoke != nil, "invoke route for apikey-cart not found"
      assert invoke["exposure"] == "authenticated"
    end

    test "includes all 5 static boj-server routes", %{root: root} do
      write_cartridge(root, "any-cart", "none")

      {:ok, policy} = PolicyLoader.load_from_boj_catalog(root)
      routes = policy["governance"]["routes"]
      paths = Enum.map(routes, & &1["path"])

      assert Enum.any?(paths, &String.contains?(&1, "health"))
      assert Enum.any?(paths, &String.contains?(&1, "menu"))
      assert Enum.any?(paths, &String.contains?(&1, "cartridges"))
      assert Enum.any?(paths, &String.contains?(&1, "[^/]"))
      assert Enum.any?(paths, &String.contains?(&1, "well-known"))
    end

    test "generates one invoke route per cartridge", %{root: root} do
      write_cartridge(root, "cart-a", "none")
      write_cartridge(root, "cart-b", "api-key")
      write_cartridge(root, "cart-c", "oauth2")

      {:ok, policy} = PolicyLoader.load_from_boj_catalog(root)
      invoke_routes =
        policy["governance"]["routes"]
        |> Enum.filter(fn r -> r["path"] =~ "invoke" end)

      assert length(invoke_routes) == 3
    end

    test "skips dirs without cartridge.json", %{root: root} do
      write_cartridge(root, "real-cart", "none")
      # Directory without cartridge.json
      File.mkdir_p!(Path.join(root, "no-manifest-dir"))

      {:ok, policy} = PolicyLoader.load_from_boj_catalog(root)
      invoke_routes =
        policy["governance"]["routes"]
        |> Enum.filter(fn r -> r["path"] =~ "invoke" end)

      assert length(invoke_routes) == 1
      assert hd(invoke_routes)["cartridge"] == "real-cart"
    end

    test "global_verbs is GET only", %{root: root} do
      write_cartridge(root, "g-cart", "none")

      {:ok, policy} = PolicyLoader.load_from_boj_catalog(root)
      assert policy["governance"]["global_verbs"] == ["GET"]
    end
  end
end
