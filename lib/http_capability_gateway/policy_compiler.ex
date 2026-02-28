# SPDX-License-Identifier: PMPL-1.0-or-later
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
      :path_pattern,    # String pattern (for display/debugging)
      :path_regex,      # Compiled Regex for matching
      :verb,            # Atom: :GET, :POST, :PUT, :DELETE, :PATCH, :HEAD, :OPTIONS
      :exposure,        # "public", "authenticated", or "internal"
      :stealth_profile, # String profile name or nil
      :narrative        # Optional explanation string
    ]

    @type t :: %__MODULE__{
            path_pattern: String.t(),
            path_regex: Regex.t(),
            verb: atom(),
            exposure: String.t(),
            stealth_profile: String.t() | nil,
            narrative: String.t() | nil
          }
  end

  @type ets_table :: :ets.tid() | atom()
  @type compile_error :: {String.t(), String.t()}

  @valid_http_verbs [:GET, :POST, :PUT, :DELETE, :PATCH, :HEAD, :OPTIONS]

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

    errors =
      []
      |> compile_global_verbs(policy, main_table)
      |> compile_route_overrides(policy, main_table, regex_table)

    case errors do
      [] ->
        main_count = :ets.info(main_table, :size)
        regex_count = :ets.info(regex_table, :size)
        total_count = main_count + regex_count

        Logger.info("Policy compilation succeeded",
          rules: total_count,
          main_rules: main_count,
          regex_rules: regex_count,
          service: service_name
        )

        # Atomic swap: update BOTH application env references, then delete
        # both old tables. The order matters -- update references BEFORE
        # deleting old tables to avoid any gap where no table exists.
        old_main = Application.get_env(:http_capability_gateway, :policy_table)
        old_regex = Application.get_env(:http_capability_gateway, :policy_regex_table)

        Application.put_env(:http_capability_gateway, :policy_table, temp_main_name)
        Application.put_env(:http_capability_gateway, :policy_regex_table, temp_regex_name)

        # Delete old tables only if they exist and are still registered.
        if old_main && :ets.whereis(old_main) != :undefined do
          Logger.debug("Deleting old main policy table", table: old_main)
          :ets.delete(old_main)
        end

        if old_regex && :ets.whereis(old_regex) != :undefined do
          Logger.debug("Deleting old regex policy table", table: old_regex)
          :ets.delete(old_regex)
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
    # Tiered lookup strategy for fast enforcement:
    #
    # Tier 1: Exact literal path match via ETS key (O(1))
    #   If the route pattern is a literal string (no regex metacharacters),
    #   it was stored with key {:exact, path, verb} in the main table.
    #   This catches 90%+ of lookups in typical policy files.
    #
    # Tier 2: Route-specific regex patterns (O(r) where r = regex routes)
    #   For patterns containing regex metacharacters (e.g., "[0-9]+"),
    #   iterate ONLY through the dedicated regex table. This avoids scanning
    #   exact routes and global rules — the regex table contains only regex
    #   patterns, making Tier 2 scans proportional to the number of regex
    #   routes (typically 5-10% of all routes).
    #
    # Tier 3: Global rules (O(1))
    #   If no route matches, check global verb rules via {:global, verb}
    #   in the main table.
    #
    # Inspired by cadre-router's oneOfGrouped first-segment dispatch
    # and aerie's trie-based verb governance.

    # Tier 1: Exact literal path → O(1) from main table
    case :ets.lookup(table, {:exact, path, verb}) do
      [{_key, rule}] ->
        {:ok, rule}

      [] ->
        # Tier 2: Regex route patterns → O(r) from dedicated regex table.
        # The regex table name is derived from the main table name by the
        # convention established in compile/2 (stored in :policy_regex_table).
        regex_table = Application.get_env(:http_capability_gateway, :policy_regex_table)

        case lookup_regex_routes(regex_table, path, verb) do
          {:ok, _rule} = result ->
            result

          {:error, :no_match} ->
            # Tier 3: Global rules → O(1) from main table
            case :ets.lookup(table, {:global, verb}) do
              [{_key, rule}] -> {:ok, rule}
              [] -> {:error, :no_match}
            end
        end
    end
  end

  # Iterate through the DEDICATED regex route table.
  #
  # Because regex routes are stored in their own ETS table, there is no
  # need to filter out {:global, _} or {:exact, _, _} entries — every
  # entry in this table is a regex route pattern. This makes Tier 2
  # scans faster and simpler.
  #
  # If the regex table is nil (e.g., during tests without full compilation),
  # we return :no_match immediately.
  defp lookup_regex_routes(nil, _path, _verb), do: {:error, :no_match}

  defp lookup_regex_routes(regex_table, path, verb) do
    # Read all regex route rules — this table contains ONLY regex patterns.
    regex_rules = :ets.tab2list(regex_table)

    # Find first route pattern that matches the path
    matching_pattern =
      Enum.find_value(regex_rules, fn {{pattern, _v}, rule} ->
        if Regex.match?(rule.path_regex, path), do: pattern, else: nil
      end)

    case matching_pattern do
      nil ->
        {:error, :no_match}

      pattern ->
        # Route matched — check if verb is allowed for this route
        case Enum.find(regex_rules, fn {{p, v}, _} -> p == pattern and v == verb end) do
          {_key, rule} -> {:ok, rule}
          nil -> {:error, :no_match}
        end
    end
  end

  # Compile global verb rules that apply to all paths (unless overridden)
  defp compile_global_verbs(errors, policy, table) do
    # DSL v1 format: governance.global_verbs is a list of verb strings
    global_verbs = get_in(policy, ["governance", "global_verbs"]) || []

    Enum.reduce(global_verbs, errors, fn verb_str, acc ->
      verb_atom = String.to_existing_atom(verb_str)

      if verb_atom not in @valid_http_verbs do
        [{:global_verb, "Invalid HTTP verb: #{verb_str}"} | acc]
      else
        # DSL v1: global verbs have no specific exposure level, default to "public"
        # (Gateway will handle access control based on trust levels)
        rule = %CompiledRule{
          path_pattern: ".*",
          path_regex: ~r/.*/,
          verb: verb_atom,
          exposure: "public",  # Default for global verbs
          stealth_profile: get_stealth_enabled(policy),
          narrative: nil
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
            verb_atom = String.to_existing_atom(verb_str)

            if verb_atom not in @valid_http_verbs do
              [{:route_verb, "Invalid HTTP verb in route: #{verb_str}"} | verb_acc]
            else
              # DSL v1: route-specific verbs override globals
              rule = %CompiledRule{
                path_pattern: path_pattern,
                path_regex: path_regex,
                verb: verb_atom,
                exposure: "public",  # DSL v1 doesn't specify exposure per-route
                stealth_profile: get_stealth_enabled(policy),
                narrative: nil
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
      true -> "default"  # Use "default" as profile name for enabled stealth
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
    main_rules = :ets.tab2list(table)

    {global_count, exact_count} =
      Enum.reduce(main_rules, {0, 0}, fn
        {{:global, _verb}, _rule}, {g, e} -> {g + 1, e}
        {{:exact, _path, _verb}, _rule}, {g, e} -> {g, e + 1}
        _, {g, e} -> {g, e}
      end)

    # Read rules from the dedicated regex table (if it exists).
    regex_table = Application.get_env(:http_capability_gateway, :policy_regex_table)

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
