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

    # Delete existing table if it exists
    if :ets.whereis(table_name) != :undefined do
      :ets.delete(table_name)
    end

    # Create new ETS table
    table = :ets.new(table_name, [:set, :public, :named_table, read_concurrency: true])

    errors =
      []
      |> compile_global_verbs(policy, table)
      |> compile_route_overrides(policy, table)

    case errors do
      [] ->
        rule_count = :ets.info(table, :size)
        Logger.info("Policy compilation succeeded", rules: rule_count, service: service_name)
        {:ok, table}

      errors ->
        :ets.delete(table)
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
    # Lookup strategy: route-specific rules OVERRIDE global rules
    # 1. Check if path matches any route-specific patterns
    # 2. If yes, only allow verbs defined for that route
    # 3. If no route match, fall back to global rules
    case :ets.tab2list(table) do
      [] ->
        {:error, :no_match}

      rules ->
        # Split rules into route-specific and global
        {route_rules, global_rules} =
          Enum.split_with(rules, fn
            {{:global, _}, _rule} -> false
            _ -> true
          end)

        # Check if path matches any route pattern
        matching_route_pattern =
          Enum.find_value(route_rules, fn {{pattern, _verb}, rule} ->
            if Regex.match?(rule.path_regex, path), do: pattern, else: nil
          end)

        case matching_route_pattern do
          nil ->
            # No route-specific pattern matches, use global rules
            find_matching_rule(global_rules, path, verb)

          pattern ->
            # Route-specific pattern matches, only allow verbs for this route
            # Find rule for this pattern and verb
            case Enum.find(route_rules, fn {{p, v}, _rule} -> p == pattern and v == verb end) do
              {_key, rule} -> {:ok, rule}
              nil -> {:error, :no_match}
            end
        end
    end
  end

  # Helper to find matching rule in a list
  defp find_matching_rule(rules, path, verb) do
    Enum.find_value(rules, {:error, :no_match}, fn {_key, rule} ->
      if rule.verb == verb and Regex.match?(rule.path_regex, path) do
        {:ok, rule}
      else
        nil
      end
    end)
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

  # Compile route-specific overrides that take precedence over globals
  defp compile_route_overrides(errors, policy, table) do
    # DSL v1 format: governance.routes is a list of route configs
    routes = get_in(policy, ["governance", "routes"]) || []

    Enum.reduce(routes, errors, fn route, acc ->
      path_pattern = Map.get(route, "path")
      # DSL v1: route.verbs is a list of verb strings
      route_verbs = Map.get(route, "verbs", [])

      # Compile the regex pattern
      case Regex.compile(path_pattern) do
        {:ok, path_regex} ->
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

              # Route-specific rules override globals - use path pattern in key
              :ets.insert(table, {{path_pattern, verb_atom}, rule})
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

  # Get stealth status code from DSL v1 policy
  defp get_stealth_status_code(policy) do
    get_in(policy, ["stealth", "status_code"]) || 404
  end

  @doc """
  Returns statistics about a compiled policy table.

  ## Parameters

    - `table`: ETS table reference from compile/1

  ## Returns

    Map with statistics:
    - `:total_rules` - Total number of rules in table
    - `:global_rules` - Number of global verb rules
    - `:route_rules` - Number of route-specific rules
    - `:verbs` - List of HTTP verbs with rules

  ## Examples

      iex> {:ok, table} = PolicyCompiler.compile(policy)
      iex> PolicyCompiler.stats(table)
      %{total_rules: 5, global_rules: 3, route_rules: 2, verbs: [:GET, :POST, :DELETE]}
  """
  @spec stats(table :: ets_table()) :: map()
  def stats(table) do
    rules = :ets.tab2list(table)
    total = length(rules)

    {global_count, route_count} =
      Enum.reduce(rules, {0, 0}, fn
        {{:global, _verb}, _rule}, {g, r} -> {g + 1, r}
        {{_path, _verb}, _rule}, {g, r} -> {g, r + 1}
      end)

    verbs =
      rules
      |> Enum.map(fn {_key, rule} -> rule.verb end)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      total_rules: total,
      global_rules: global_count,
      route_rules: route_count,
      verbs: verbs
    }
  end
end
