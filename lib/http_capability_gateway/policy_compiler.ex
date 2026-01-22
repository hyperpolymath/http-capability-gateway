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
    # Iterate through all rules and find first matching pattern
    case :ets.tab2list(table) do
      [] ->
        {:error, :no_match}

      rules ->
        Enum.find_value(rules, {:error, :no_match}, fn {_key, rule} ->
          if rule.verb == verb and Regex.match?(rule.path_regex, path) do
            {:ok, rule}
          else
            nil
          end
        end)
    end
  end

  # Compile global verb rules that apply to all paths (unless overridden)
  defp compile_global_verbs(errors, policy, table) do
    global_verbs = Map.get(policy, "verbs", %{})

    Enum.reduce(global_verbs, errors, fn {verb_str, config}, acc ->
      verb_atom = String.to_existing_atom(verb_str)

      if verb_atom not in @valid_http_verbs do
        [{:global_verb, "Invalid HTTP verb: #{verb_str}"} | acc]
      else
        exposure = Map.get(config, "exposure")

        # Global rules match any path
        rule = %CompiledRule{
          path_pattern: ".*",
          path_regex: ~r/.*/,
          verb: verb_atom,
          exposure: exposure,
          stealth_profile: get_default_stealth_profile(policy),
          narrative: Map.get(config, "narrative")
        }

        # Use verb atom as part of key for global rules
        :ets.insert(table, {{:global, verb_atom}, rule})
        acc
      end
    end)
  end

  # Compile route-specific overrides that take precedence over globals
  defp compile_route_overrides(errors, policy, table) do
    routes = Map.get(policy, "routes", [])

    Enum.reduce(routes, errors, fn route, acc ->
      path_pattern = Map.get(route, "path")
      route_verbs = Map.get(route, "verbs", %{})

      # Compile the regex pattern
      case Regex.compile(path_pattern) do
        {:ok, path_regex} ->
          # Compile each verb override for this route
          Enum.reduce(route_verbs, acc, fn {verb_str, config}, verb_acc ->
            verb_atom = String.to_existing_atom(verb_str)

            if verb_atom not in @valid_http_verbs do
              [{:route_verb, "Invalid HTTP verb in route: #{verb_str}"} | verb_acc]
            else
              exposure = Map.get(config, "exposure")

              rule = %CompiledRule{
                path_pattern: path_pattern,
                path_regex: path_regex,
                verb: verb_atom,
                exposure: exposure,
                stealth_profile: Map.get(config, "stealth_profile") || get_default_stealth_profile(policy),
                narrative: Map.get(config, "narrative")
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

  # Extract default stealth profile name from policy
  defp get_default_stealth_profile(policy) do
    case get_in(policy, ["stealth", "default"]) do
      nil -> nil
      profile when is_binary(profile) -> profile
    end
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
