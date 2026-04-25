# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.PolicyLoader do
  @moduledoc """
  Loads Verb Governance Spec (DSL v1) from YAML content, file, or BoJ catalog.

  ## Static mode (YAML file)

      iex> yaml = \"\"\"
      ...> dsl_version: "1"
      ...> governance:
      ...>   global_verbs:
      ...>     - GET
      ...> \"\"\"
      iex> PolicyLoader.load_policy(yaml)
      {:ok, %{"dsl_version" => "1", "governance" => %{"global_verbs" => ["GET"]}}}

      iex> PolicyLoader.load_from_file("nonexistent.yaml")
      {:error, "File not found: nonexistent.yaml"}

  ## Catalog mode (BoJ Server auto-policy)

  `load_from_boj_catalog/1` reads every `<cartridges_root>/*/cartridge.json`
  at boot and infers per-cartridge invoke exposure from `auth.method`:

      "none"         → "public"
      anything else  → "authenticated"

  This eliminates all manual `gateway-policy.yaml` maintenance — adding or
  modifying a cartridge's `auth.method` automatically updates gateway policy
  on the next restart.

  See boj-server's `docs/gateway-catalog-integration.adoc` for the full design.
  """

  require Logger

  @spec load_policy(content :: String.t()) :: {:ok, map()} | {:error, String.t()}
  def load_policy(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        {:error, "Empty policy"}

      true ->
        case YamlElixir.read_from_string(trimmed) do
          {:ok, %{} = policy} ->
            Logger.info("Policy parsed from YAML content", service: get_in(policy, ["service", "name"]))
            {:ok, policy}

          {:ok, [first | _]} when is_map(first) ->
            Logger.info("Policy parsed (first document used)", service: get_in(first, ["service", "name"]))
            {:ok, first}

          {:ok, _} ->
            {:error, "Policy must be a map"}

          {:error, reason} ->
            {:error, "YAML parsing error: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Loads policy from disk and parses the YAML content.
  """
  @spec load_from_file(path :: String.t()) :: {:ok, map()} | {:error, String.t()}
  def load_from_file(path) when is_binary(path) do
    Logger.info("Loading policy from file: #{path}")

    case File.read(path) do
      {:ok, content} ->
        load_policy(content)

      {:error, reason} ->
        {:error, "File not found: #{path} (#{inspect(reason)})"}
    end
  end

  @doc """
  Builds a DSL v1 policy map by reading every `cartridges_root/*/cartridge.json`
  from a BoJ Server cartridges directory.

  Inference table for `auth.method` → gateway exposure:
    "none"        → "public"
    anything else → "authenticated"

  The generated policy covers the full boj-server route surface:
    GET  /health, /menu, /cartridges, /cartridge/:name, /.well-known/boj-node-pubkey
    POST /cartridge/<name>/invoke  — one route per cartridge, exposure inferred

  Returns {:ok, policy_map} on success.  If the cartridges_root does not exist
  or contains no valid cartridge.json files, returns {:error, reason}.
  """
  @spec load_from_boj_catalog(cartridges_root :: String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def load_from_boj_catalog(cartridges_root) when is_binary(cartridges_root) do
    Logger.info("Building gateway policy from BoJ catalog", root: cartridges_root)

    unless File.dir?(cartridges_root) do
      {:error, "BoJ cartridges_root does not exist: #{cartridges_root}"}
    else
      cartridges =
        cartridges_root
        |> File.ls!()
        |> Enum.flat_map(fn name ->
          path = Path.join([cartridges_root, name, "cartridge.json"])

          case File.read(path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, map} when is_map(map) -> [map]
                _ ->
                  Logger.warning("Skipping malformed cartridge.json", path: path)
                  []
              end

            {:error, _} ->
              []
          end
        end)

      if cartridges == [] do
        {:error, "No valid cartridge.json files found in #{cartridges_root}"}
      else
        {:ok, build_policy(cartridges)}
      end
    end
  end

  # ── policy construction ────────────────────────────────────────────────────

  # Builds the DSL v1 policy map from a list of cartridge maps.
  defp build_policy(cartridges) do
    invoke_routes = Enum.flat_map(cartridges, &invoke_route/1)

    static_routes = [
      route("^/health$", ["GET"], "public"),
      route("^/menu$", ["GET"], "public"),
      route("^/cartridges$", ["GET"], "public"),
      route("^/cartridge/[^/]+$", ["GET"], "public"),
      route("^/.well-known/boj-node-pubkey$", ["GET"], "public")
    ]

    %{
      "dsl_version" => "1",
      "service" => %{"name" => "boj-server"},
      "governance" => %{
        "global_verbs" => ["GET"],
        "routes" => static_routes ++ invoke_routes
      },
      "stealth" => %{"enabled" => true, "status_code" => 404}
    }
  end

  defp invoke_route(cart) do
    name = Map.get(cart, "name")

    case name do
      nil ->
        []

      _ ->
        auth_method = get_in(cart, ["auth", "method"]) || "none"
        exposure = if auth_method == "none", do: "public", else: "authenticated"
        path = "^/cartridge/#{Regex.escape(name)}/invoke$"
        [route(path, ["POST"], exposure, %{"cartridge" => name})]
    end
  end

  defp route(path, verbs, exposure, extra \\ %{}) do
    Map.merge(%{"path" => path, "verbs" => verbs, "exposure" => exposure}, extra)
  end
end
