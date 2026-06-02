# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyValidator do
  @moduledoc """
  Validates DSL v1 policy structure and content.
  """

  require Logger

  @valid_http_verbs ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

  @spec validate(policy :: map()) :: :ok | {:error, String.t()}
  def validate(policy) when is_map(policy) do
    with nil <- validate_dsl_version(policy),
         nil <- validate_governance(policy),
         nil <- validate_stealth(policy) do
      Logger.info("Policy validation passed")
      :ok
    else
      {:error, reason} ->
        Logger.error("Policy validation failed", reason: reason)
        {:error, reason}

      reason when is_binary(reason) ->
        Logger.error("Policy validation failed", reason: reason)
        {:error, reason}
    end
  end

  defp validate_dsl_version(%{"dsl_version" => "1"}), do: nil
  defp validate_dsl_version(%{"dsl_version" => other}) when is_binary(other),
    do: "dsl_version: must be \"1\""

  defp validate_dsl_version(_), do: "dsl_version: must be present and equal to \"1\""

  defp validate_governance(%{"governance" => governance}) when is_map(governance) do
    with nil <- validate_global_verbs(governance),
         nil <- validate_routes(Map.get(governance, "routes")) do
      nil
    else
      error -> error
    end
  end

  defp validate_governance(_), do: "governance: must be a map"

  defp validate_global_verbs(%{"global_verbs" => verbs}) when is_list(verbs) do
    cond do
      verbs == [] ->
        "governance.global_verbs: must not be empty"

      invalid = Enum.find(verbs, &(&1 not in @valid_http_verbs)) ->
        "Invalid HTTP verb: #{invalid}"

      true ->
        nil
    end
  end

  defp validate_global_verbs(_), do: "governance.global_verbs: must be a non-empty list"

  defp validate_routes(nil), do: nil

  defp validate_routes(routes) when is_list(routes) do
    Enum.with_index(routes)
    |> Enum.reduce_while(nil, fn {route, idx}, _acc ->
      case validate_route(route, idx) do
        nil -> {:cont, nil}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_routes(_), do: "governance.routes: must be a list"

  defp validate_route(route, idx) when is_map(route) do
    with nil <- validate_route_path(route, idx),
         nil <- validate_route_verbs(route, idx),
         nil <- validate_route_capability(route, idx) do
      nil
    else
      error -> error
    end
  end

  defp validate_route(_route, idx), do: "governance.routes[#{idx}]: must be a map"

  # Validate the optional `capability` field at the route level.
  #
  # The capability field is a first-class label that travels with the
  # route's policy decision. It is the seam where chimichanga-style
  # capability attenuation (and downstream audit) attach. When present,
  # it MUST be a non-empty string.
  #
  # Allowed shape:
  #
  #     - path: "/api/admin"
  #       verbs: [GET]
  #       capability: "admin:read"   # optional
  #
  # When omitted, the route has no capability label (back-compat with the
  # existing DSL). When present-but-invalid, validation fails fast.
  defp validate_route_capability(route, idx) do
    case Map.get(route, "capability") do
      nil -> nil
      cap when is_binary(cap) and cap != "" -> nil
      _ -> "governance.routes[#{idx}].capability: must be a non-empty string when present"
    end
  end

  defp validate_route_path(route, idx) do
    case Map.get(route, "path") do
      nil ->
        "governance.routes[#{idx}].path: must be present"

      path when is_binary(path) and path != "" ->
        case Regex.compile(path) do
          {:ok, _} -> nil
          {:error, reason} -> "governance.routes[#{idx}].path: invalid regex (#{inspect(reason)})"
        end

      _ ->
        "governance.routes[#{idx}].path: must be a non-empty string"
    end
  end

  defp validate_route_verbs(route, idx) do
    case Map.get(route, "verbs") do
      verbs when is_list(verbs) and verbs != [] ->
        case Enum.find(verbs, &(&1 not in @valid_http_verbs)) do
          nil -> nil
          invalid -> "governance.routes[#{idx}].verbs: invalid HTTP verb #{invalid}"
        end

      verbs when is_list(verbs) ->
        "governance.routes[#{idx}].verbs: must not be empty"

      _ ->
        "governance.routes[#{idx}].verbs: must be a list"
    end
  end

  defp validate_stealth(policy) when is_map(policy) do
    # Extract stealth section from policy
    case Map.get(policy, "stealth") do
      nil ->
        # No stealth section - valid
        nil

      stealth when is_map(stealth) ->
        # Validate stealth configuration
        validate_stealth_config(stealth)

      _ ->
        "stealth: must be a map when present"
    end
  end

  defp validate_stealth_config(%{"enabled" => enabled, "status_code" => status})
       when is_boolean(enabled) and is_integer(status) do
    cond do
      status < 100 or status > 599 ->
        "stealth.status_code: must be an HTTP status code (100-599)"

      true ->
        nil
    end
  end

  defp validate_stealth_config(%{"enabled" => _enabled}) do
    "stealth.status_code: must be an integer and present when stealth is defined"
  end

  defp validate_stealth_config(%{"status_code" => _status}) do
    "stealth.enabled: must be a boolean when stealth is defined"
  end

  defp validate_stealth_config(_), do: "stealth: must be a map with 'enabled' and 'status_code' keys"
end
