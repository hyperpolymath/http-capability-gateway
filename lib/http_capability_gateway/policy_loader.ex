# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyLoader do
  @moduledoc """
  Loads Verb Governance Spec (YAML) from disk.

  Parses YAML policy file and returns structured Elixir map.
  Handles file I/O errors and YAML parsing errors gracefully.

  ## Example Policy Structure

      %{
        "service" => %{
          "name" => "ledger-api",
          "version" => 1,
          "environment" => "dev"
        },
        "verbs" => %{
          "GET" => %{"exposure" => "public"},
          "POST" => %{"exposure" => "authenticated"},
          "DELETE" => %{"exposure" => "internal"}
        },
        "routes" => [
          %{
            "path" => "/accounts",
            "verbs" => %{
              "DELETE" => %{
                "exposure" => "internal",
                "narrative" => "Account deletion requires internal trust."
              }
            }
          }
        ],
        "stealth" => %{
          "profiles" => %{
            "limited" => %{
              "unauthenticated" => 405,
              "untrusted" => 404
            }
          }
        },
        "narrative" => %{
          "purpose" => "Define safe verb exposure for ledger operations."
        }
      }
  """

  require Logger

  @doc """
  Loads policy from YAML file.

  ## Parameters

    - `path`: Path to policy YAML file

  ## Returns

    - `{:ok, policy}` - Successfully loaded and parsed policy
    - `{:error, reason}` - File not found, parse error, or invalid format

  ## Examples

      iex> PolicyLoader.load_policy("config/policy.yaml")
      {:ok, %{"service" => %{"name" => "my-api", ...}}}

      iex> PolicyLoader.load_policy("nonexistent.yaml")
      {:error, :enoent}
  """
  @spec load_policy(path :: String.t()) :: {:ok, map()} | {:error, term()}
  def load_policy(path) do
    Logger.info("Loading policy from: #{path}")

    with {:ok, content} <- File.read(path),
         {:ok, [policy | _]} <- YamlElixir.read_from_string(content) do
      Logger.info("Policy loaded successfully", service: get_in(policy, ["service", "name"]))
      {:ok, policy}
    else
      {:error, %YamlElixir.FileNotFoundError{}} ->
        Logger.error("Policy file not found: #{path}")
        {:error, :file_not_found}

      {:error, reason} = error ->
        Logger.error("Failed to load policy: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Reloads policy from the same path (for hot reload support).

  Currently not implemented (Phase 2 feature).
  """
  @spec reload_policy(path :: String.t()) :: {:ok, map()} | {:error, term()}
  def reload_policy(path) do
    load_policy(path)
  end
end
