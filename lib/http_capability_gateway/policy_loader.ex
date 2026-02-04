# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyLoader do
  @moduledoc """
  Loads Verb Governance Spec (DSL v1) from YAML content or file.

  ## Examples

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
end
