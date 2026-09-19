# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.PolicyCompiler do
  @moduledoc """
  Compiles validated policy into fast enforcement rules backed by ETS.

  Takes a validated policy map and produces an ETS table for O(1) lookups
  during request processing. Handles global verb rules and route-specific overrides.

  ## Compilation Process

  1. Parse global verb exposure levels (apply to all routes)
  2. Compile route-specific overrides (take precedence over globals)
  3. Compile regex patterns for path matching
  4. Build ETS table with compiled rules

  ## ETS Schema

  - **Table Name**: `:policy_rules`
  - **Type**: `:set` (unique keys)
  - **Key**: `{path_pattern, verb_atom}` where path_pattern is compiled Regex
  - **Value**: `%CompiledRule{}`
  - **Options**: `[:public, :named_table, read_concurrency: true]`

  ## Lookup Strategy

  For incoming request `/api/users POST`:
  1. Iterate through all rules in ETS
  2. Match request path against each compiled regex
  3. Find matching rule for (path_regex, :POST)
  4. Return exposure level and stealth profile
  """

  require Logger

  defmodule CompiledRule do
    @moduledoc """
    Represents a single compiled enforcement rule.
    """
    defstruct [
      # String pattern (for display/debugging)
      :path_pattern,
      # Compiled Regex for matching
      :path_regex,
      # Atom: :GET, :POST, :PUT, :DELETE, :PATCH, :HEAD, :OPTIONS
      :verb,
      # "public", "authenticated", or "internal"
      :exposure,
      # String profile name or nil
      :stealth_profile,
      # Optional explanation string
      :narrative,
      # Target backend URL
      :backend,
      # Unique rule name
      :name,
      # Optional capability label (e.g., "admin:read"); nil if not set
      :capability
    ]

    @type t :: %__MODULE__{
            path_pattern: String.t(),
            path_regex: Regex.t(),
            verb: atom(),
            exposure: String.t(),
            stealth_profile: String.t() | nil,
            narrative: String.t() | nil,
            capability: String.t() | nil
          }
  end

  @type ets_table :: :ets.tid() | atom()
  @type compile_error :: {String.t(), String.t()}

  @valid_http_verbs [:GET, :POST, :PUT, :DELETE, :PATCH, :HEAD, :OPTIONS]

  # Safe verb string to atom conversion with allowlist.
  #
  # Never call String.to_existing_atom on user input (policy file contents are
  # user-controlled at policy authoring time). Instead, use this allowlist-based
  # converter which returns nil for unknown verbs, preventing both ArgumentError
  # (DoS) and atom table exhaustion (audit #31, P5).
  @verb_string_to_atom %{
    "GET" => :GET,
    "POST" => :POST,
    "PUT" => :PUT,
    "DELETE" => :DELETE,
    "PATCH" => :PATCH,
    "HEAD" => :HEAD,
    "OPTIONS" => :OPTIONS
  }

  @doc """
  Safely converts an HTTP verb string to its corresponding atom.

  Returns the atom for valid HTTP methods, or nil for unknown methods.
  This prevents DoS vectors from String.to_existing_atom (ArgumentError) or
  String.to_atom (atom table exhaustion).

  ## Parameters

    - verb_str: HTTP method string (e.g., "GET", "POST")

  ## Returns

    - Atom like :GET, :POST, etc. for valid methods
    - nil for unknown/unsupported methods
  """
  @spec safe_verb_atom(String.t()) :: atom() | nil
  def safe_verb_atom(verb_str) when is_binary(verb_str) do
    Map.get(@verb_string_to_atom, verb_str)
  end

  @doc """
  Compiles a validated policy into an ETS-backed enforcement table.

  ## Parameters

    - `policy`: Validated policy map from PolicyValidator
    - `opts`: Optional keyword list
      - `:table_name` - Custom ETS table name (default: :policy_rules)

  ## Returns

    - `{:ok, table_ref}` - Compilation succeeded, returns ETS table reference
    - `{:error, errors}` - Compilation failed with list of errors

  ## Examples

      iex> policy = %{"service" => %{"name" => "api"}, "verbs" => %{"GET" => %{"exposure" => "public"}}}
      iex> {:ok, table} = PolicyCompiler.compile(policy)
      iex> :ets.info(table, :size)
      1
  """
  @spec compile(policy :: map(), opts :: keyword()) ::
          {:ok, ets_table()} | {:error, [compile_error()]}
  def compile(policy, opts \\ []) when is_map(policy) do
    table_name = Keyword.get(opts, :table_name, :policy_rules)
    service_name = get_in(policy, ["service", "name"]) || "unknown"

    Logger.info("Compiling policy for service: #{service_name}")

    # Atomic policy reload strategy with DUAL ETS tables:
    #
    # We maintain two ETS tables per policy:
    #   1. Main table: exact literal routes ({:exact, path, verb}) and
    #      global rules ({:global, verb}) for O(1) lookups.
    #   2. Regex table: regex route patterns ({pattern, verb}) for O(r)
    #      Tier 2 scans. Keeping regex routes in a dedicated table means
    #      Tier 2 scans read ONLY regex entries (no filtering needed).
    #
    # The atomic swap pattern applies to BOTH tables as a pair:
    #
    #   1. Create a temporary main table and a temporary regex table,
    #      each with a unique name (monotonic time suffix).
    #   2. Compile all policy rules into the appropriate temporary table.
    #   3. If compilation SUCCEEDS:
    #      a. Update :policy_table to point to the new main table name.
    #      b. Update :policy_regex_table to point to the new regex table name.
    #      c. Delete both old tables (if any).
    #   4. If compilation FAILS:
    #      a. Delete both temporary tables.
    #      b. Leave the old tables and app env untouched.
    #
    # This guarantees zero-downtime policy reloads for the entire table pair.
    ts = System.monotonic_time()
    temp_main_name = :"#{table_name}_#{ts}"
    temp_regex_name = :"#{table_name}_regex_#{ts}"

    main_table = :ets.new(temp_main_name, [:set, :public, :named_table, read_concurrency: true])
    regex_table = :ets.new(temp_regex_name, [:set, :public, :named_table, read_concurrency: true])
    # Bind this main-table revision to ITS companion. A lookup must never read
    # the latest global regex pointer while holding an older main-table handle.
    :ets.insert(main_table, {{:metadata, :regex_table}, temp_regex_name})

    errors =
      []
      |> compile_global_verbs(policy, main_table)
      |> compile_route_overrides(policy, main_table, regex_table)

    case errors do
      [] ->
        main_count = :ets.info(main_table, :size) - 1
        regex_count = :ets.info(regex_table, :size)
        total_count = main_count + regex_count

        Logger.info("Policy compilation succeeded",
          rules: total_count,
          main_rules: main_count,
          regex_rules: regex_count,
          service: service_name
        )

        atomic_swap = Keyword.get(opts, :atomic_swap, true)
        delete_old = Keyword.get(opts, :delete_old, true)

        if atomic_swap do
          # Atomic swap: update BOTH application env references, then delete
          # both old tables. The order matters -- update references BEFORE
          # deleting old tables to avoid any gap where no table exists.
          old_main = Application.get_env(:http_capability_gateway, :policy_table)
          old_regex = Application.get_env(:http_capability_gateway, :policy_regex_table)

          Application.put_env(:http_capability_gateway, :policy_table, temp_main_name)
          Application.put_env(:http_capability_gateway, :policy_regex_table, temp_regex_name)

          if delete_old do
            # Delete old tables only if they exist and are still registered.
            if old_main && :ets.whereis(old_main) != :undefined do
              Logger.debug("Deleting old main policy table", table: old_main)
              :ets.delete(old_main)
            end

            if old_regex && :ets.whereis(old_regex) != :undefined do
              Logger.debug("Deleting old regex policy table", table: old_regex)
              :ets.delete(old_regex)
            end
          end
        end

        {:ok, temp_main_name}

      errors ->
        # Compilation failed -- clean up BOTH temporary tables and leave
        # the existing tables (if any) in place. This preserves the last
        # known good policy for in-flight and future requests.
        :ets.delete(main_table)
        :ets.delete(regex_table)
        Logger.error("Policy compilation failed", errors: errors, service: service_name)
        {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Looks up enforcement rule for a given path and HTTP verb.

  ## Parameters

    - `table`: ETS table reference from compile/1
    - `path`: Request path string (e.g., "/api/users")
    - `verb`: HTTP verb atom (e.g., :GET, :POST)

  ## Returns

    - `{:ok, rule}` - Matching rule found
    - `{:error, :no_match}` - No rule matches the path/verb combination

  ## Examples

      iex> {:ok, table} = PolicyCompiler.compile(policy)
      iex> PolicyCompiler.lookup(table, "/api/users", :GET)
      {:ok, %CompiledRule{exposure: "public", ...}}
  """
  @spec lookup(table :: ets_table(), path :: String.t(), verb :: atom()) ::
          {:ok, CompiledRule.t()} | {:error, :no_match}
  def lookup(table, path, verb) when is_atom(verb) do
    # Exact route > a single matching regex route > global ONLY if no path matches.
    # A matched path owns its complete verb allowlist. Missing verbs are denied,
    # never rescued by a global permission or a less-specific route.
    cond do
      verb not in @valid_http_verbs ->
        {:error, :no_match}

      exact_path?(table, path) ->
        lookup_rule(table, {:exact, path, verb})

      true ->
        regex_table =
          case :ets.lookup(table, {:metadata, :regex_table}) do
            [{_, companion}] -> companion
            [] -> nil
          end

        case lookup_regex_routes(regex_table, path, verb) do
          :no_path -> lookup_rule(table, {:global, verb})
          result -> result
        end
    end
  rescue
    # Retired/stale ETS handles must deny, not crash or use another revision.
    ArgumentError -> {:error, :no_match}
  end

  defp exact_path?(table, path) do
    Enum.any?(@valid_http_verbs, &:ets.member(table, {:exact, path, &1}))
  end

  defp lookup_rule(table, key) do
    case :ets.lookup(table, key) do
      [{_, rule}] -> {:ok, rule}
      [] -> {:error, :no_match}
    end
  end

  defp lookup_regex_routes(nil, _path, _verb), do: :no_path

  defp lookup_regex_routes(regex_table, path, verb) do
    matching =
      :ets.tab2list(regex_table)
      |> Enum.filter(fn {_, rule} -> Regex.match?(rule.path_regex, path) end)

    patterns = matching |> Enum.map(fn {{pattern, _}, _} -> pattern end) |> Enum.uniq()

    case patterns do
      [] -> :no_path
      [pattern] -> lookup_rule(regex_table, {pattern, verb})
      # ETS has no meaningful order. Ambiguous overlaps fail closed rather than
      # randomly choosing a public rule over an authenticated/internal rule.
      _ -> {:error, :no_match}
    end
  end

  # Compile global verb rules that apply to all paths (unless overridden)
  defp compile_global_verbs(errors, policy, table) do
    # DSL v1 format: governance.global_verbs is a list of verb strings
    global_verbs = get_in(policy, ["governance", "global_verbs"]) || []

    Enum.reduce(global_verbs, errors, fn verb_str, acc ->
      verb_atom = safe_verb_atom(verb_str)

      if is_nil(verb_atom) or verb_atom not in @valid_http_verbs do
        [{:global_verb, "Invalid HTTP verb: #{verb_str}"} | acc]
      else
        # DSL v1: global verbs have no specific exposure level, default to "public"
        # (Gateway will handle access control based on trust levels)
        rule = %CompiledRule{
          path_pattern: ".*",
          path_regex: ~r/.*/,
          verb: verb_atom,
          # Default for global verbs
          exposure: "public",
          stealth_profile: get_stealth_enabled(policy),
          narrative: nil,
          backend: Map.get(policy["governance"], "global_backend"),
          name: "global_#{verb_str}"
        }

        # Use verb atom as part of key for global rules
        :ets.insert(table, {{:global, verb_atom}, rule})
        acc
      end
    end)
  end

  # Compile route-specific overrides that take precedence over globals.
  #
  # Routes are split between two ETS tables based on path type:
  #   - Literal paths (no regex metacharacters) → main table with {:exact, path, verb}
  #   - Regex patterns → dedicated regex table with {pattern, verb}
  #
  # This separation allows Tier 2 regex scans to iterate ONLY over regex
  # routes (the regex table), avoiding the need to filter out exact and
  # global entries during every request.
  defp compile_route_overrides(errors, policy, main_table, regex_table) do
    # DSL v1 format: governance.routes is a list of route configs
    routes = get_in(policy, ["governance", "routes"]) || []

    Enum.reduce(routes, errors, fn route, acc ->
      path_pattern = Map.get(route, "path")
      # DSL v1: route.verbs is a list of verb strings
      route_verbs = Map.get(route, "verbs", [])

      # Compile the regex pattern
      case Regex.compile(path_pattern) do
        {:ok, path_regex} ->
          # Detect whether this is a literal path (no regex metacharacters).
          # Literal paths go into the main table for O(1) exact lookup;
          # regex patterns go into the dedicated regex table for Tier 2 scans.
          is_literal = not Regex.match?(~r/[\[\](){}.*+?^$|\\]/, path_pattern)

          # Compile each verb for this route
          Enum.reduce(route_verbs, acc, fn verb_str, verb_acc ->
            verb_atom = safe_verb_atom(verb_str)

            if is_nil(verb_atom) or verb_atom not in @valid_http_verbs do
              [{:route_verb, "Invalid HTTP verb in route: #{verb_str}"} | verb_acc]
            else
              # DSL v1: route-specific verbs override globals
              rule = %CompiledRule{
                path_pattern: path_pattern,
                path_regex: path_regex,
                verb: verb_atom,
                exposure: Map.get(route, "exposure", "public"),
                stealth_profile: Map.get(route, "stealth_profile"),
                narrative: Map.get(route, "narrative"),
                backend: Map.get(route, "backend"),
                name: Map.get(route, "name", "route_#{path_pattern}_#{verb_str}"),
                capability: Map.get(route, "capability")
              }

              if is_literal do
                # Literal path → main table with :exact key for O(1) lookup
                :ets.insert(main_table, {{:exact, path_pattern, verb_atom}, rule})
              else
                # Regex pattern → dedicated regex table for Tier 2 scans
                :ets.insert(regex_table, {{path_pattern, verb_atom}, rule})
              end

              verb_acc
            end
          end)

        {:error, reason} ->
          [{:route_path, "Invalid regex pattern '#{path_pattern}': #{inspect(reason)}"} | acc]
      end
    end)
  end

  # Extract stealth configuration from DSL v1 policy
  # DSL v1: stealth = %{"enabled" => bool, "status_code" => int}
  # Return "default" if stealth is enabled, nil otherwise
  defp get_stealth_enabled(policy) do
    case get_in(policy, ["stealth", "enabled"]) do
      # Use "default" as profile name for enabled stealth
      true -> "default"
      _ -> nil
    end
  end

  @doc """
  Returns statistics about compiled policy tables.

  Counts rules from BOTH the main table (exact routes + global rules)
  and the dedicated regex table (regex route patterns).

  ## Parameters

    - `table`: Main ETS table reference from compile/1. The regex table
      is automatically resolved from :policy_regex_table in application env.

  ## Returns

    Map with statistics:
    - `:total_rules` - Total number of rules across both tables
    - `:global_rules` - Number of global verb rules (main table)
    - `:exact_routes` - Number of literal path routes (main table)
    - `:regex_routes` - Number of regex pattern routes (regex table)
    - `:route_rules` - exact_routes + regex_routes (total route count)
    - `:verbs` - List of HTTP verbs with rules (from both tables)

  ## Examples

      iex> {:ok, table} = PolicyCompiler.compile(policy)
      iex> PolicyCompiler.stats(table)
      %{total_rules: 5, global_rules: 3, exact_routes: 1, regex_routes: 1, route_rules: 2, verbs: [:GET, :POST]}
  """
  @spec stats(table :: ets_table()) :: map()
  def stats(table) do
    # Read rules from the main table (exact routes + global rules).
    main_rules =
      :ets.tab2list(table) |> Enum.reject(fn {key, _} -> key == {:metadata, :regex_table} end)

    {global_count, exact_count} =
      Enum.reduce(main_rules, {0, 0}, fn
        {{:global, _verb}, _rule}, {g, e} -> {g + 1, e}
        {{:exact, _path, _verb}, _rule}, {g, e} -> {g, e + 1}
        _, {g, e} -> {g, e}
      end)

    # Read rules from the dedicated regex table (if it exists).
    regex_table =
      case :ets.lookup(table, {:metadata, :regex_table}) do
        [{_, companion}] -> companion
        [] -> nil
      end

    regex_rules =
      if regex_table && :ets.whereis(regex_table) != :undefined do
        :ets.tab2list(regex_table)
      else
        []
      end

    regex_count = length(regex_rules)
    total = length(main_rules) + regex_count

    # Collect verbs from both tables for the summary.
    all_rules = main_rules ++ regex_rules

    verbs =
      all_rules
      |> Enum.map(fn {_key, rule} -> rule.verb end)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      total_rules: total,
      global_rules: global_count,
      exact_routes: exact_count,
      regex_routes: regex_count,
      route_rules: exact_count + regex_count,
      verbs: verbs
    }
  end
end
