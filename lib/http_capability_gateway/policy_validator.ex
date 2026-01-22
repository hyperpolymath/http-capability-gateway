# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyValidator do
  @moduledoc """
  Validates loaded policy against DSL v1 schema.

  Ensures all required fields are present and correctly formatted.
  Validates exposure levels, route paths (regex), and stealth codes.

  ## Validation Rules

  - `service.name` - required, non-empty string
  - `service.version` - required, positive integer
  - `service.environment` - required, one of: "dev", "staging", "prod"
  - `verbs.<METHOD>.exposure` - required, one of: "public", "authenticated", "internal"
  - `routes[].path` - valid regex pattern
  - `stealth.profiles.<profile>.<level>` - valid HTTP status code (400-599)
  """

  require Logger

  @valid_environments ["dev", "staging", "prod"]
  @valid_exposures ["public", "authenticated", "internal"]
  @valid_http_methods ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

  @type validation_error :: {String.t(), String.t()}

  @doc """
  Validates policy structure and content.

  ## Parameters

    - `policy`: Policy map from PolicyLoader

  ## Returns

    - `:ok` - Policy is valid
    - `{:error, errors}` - List of validation errors

  ## Examples

      iex> PolicyValidator.validate(%{"service" => %{"name" => "api", "version" => 1, "environment" => "dev"}, "verbs" => %{}})
      :ok

      iex> PolicyValidator.validate(%{})
      {:error, [{"service", "missing required field"}]}
  """
  @spec validate(policy :: map()) :: :ok | {:error, [validation_error()]}
  def validate(policy) when is_map(policy) do
    errors =
      []
      |> validate_service(policy)
      |> validate_verbs(policy)
      |> validate_routes(policy)
      |> validate_stealth(policy)

    case errors do
      [] ->
        Logger.info("Policy validation passed")
        :ok

      errors ->
        Logger.error("Policy validation failed", errors: errors)
        {:error, Enum.reverse(errors)}
    end
  end

  defp validate_service(errors, policy) do
    service = Map.get(policy, "service")

    cond do
      is_nil(service) ->
        [{"service", "missing required field"} | errors]

      not is_map(service) ->
        [{"service", "must be a map"} | errors]

      true ->
        errors
        |> validate_service_field(service, "name", &is_binary/1, "must be a non-empty string")
        |> validate_service_field(service, "version", &is_integer/1, "must be an integer")
        |> validate_service_field(
          service,
          "environment",
          &(&1 in @valid_environments),
          "must be one of: #{Enum.join(@valid_environments, ", ")}"
        )
    end
  end

  defp validate_service_field(errors, service, field, validator, error_msg) do
    value = Map.get(service, field)

    cond do
      is_nil(value) ->
        [{"service.#{field}", "missing required field"} | errors]

      not validator.(value) ->
        [{"service.#{field}", error_msg} | errors]

      true ->
        errors
    end
  end

  defp validate_verbs(errors, policy) do
    verbs = Map.get(policy, "verbs", %{})

    if not is_map(verbs) do
      [{"verbs", "must be a map"} | errors]
    else
      Enum.reduce(verbs, errors, fn {method, config}, acc ->
        acc
        |> validate_http_method(method)
        |> validate_verb_config(method, config)
      end)
    end
  end

  defp validate_http_method(errors, method) do
    if method in @valid_http_methods do
      errors
    else
      [{"verbs.#{method}", "invalid HTTP method (expected one of: #{Enum.join(@valid_http_methods, ", ")})"} | errors]
    end
  end

  defp validate_verb_config(errors, method, config) do
    if not is_map(config) do
      [{"verbs.#{method}", "must be a map"} | errors]
    else
      exposure = Map.get(config, "exposure")

      if exposure in @valid_exposures do
        errors
      else
        [{"verbs.#{method}.exposure", "must be one of: #{Enum.join(@valid_exposures, ", ")}"} | errors]
      end
    end
  end

  defp validate_routes(errors, policy) do
    routes = Map.get(policy, "routes", [])

    if not is_list(routes) do
      [{"routes", "must be a list"} | errors]
    else
      routes
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {route, index}, acc ->
        acc
        |> validate_route_path(route, index)
        |> validate_route_verbs(route, index)
      end)
    end
  end

  defp validate_route_path(errors, route, index) do
    path = Map.get(route, "path")

    cond do
      is_nil(path) ->
        [{"routes[#{index}].path", "missing required field"} | errors]

      not is_binary(path) ->
        [{"routes[#{index}].path", "must be a string"} | errors]

      true ->
        # Validate regex compiles
        case Regex.compile(path) do
          {:ok, _regex} ->
            errors

          {:error, reason} ->
            [{"routes[#{index}].path", "invalid regex: #{inspect(reason)}"} | errors]
        end
    end
  end

  defp validate_route_verbs(errors, route, index) do
    verbs = Map.get(route, "verbs", %{})

    if not is_map(verbs) do
      [{"routes[#{index}].verbs", "must be a map"} | errors]
    else
      Enum.reduce(verbs, errors, fn {method, config}, acc ->
        acc
        |> validate_http_method(method)
        |> validate_verb_config("routes[#{index}].verbs.#{method}", config)
      end)
    end
  end

  defp validate_stealth(errors, policy) do
    stealth = Map.get(policy, "stealth")

    case stealth do
      nil ->
        # Stealth is optional
        errors

      stealth when is_map(stealth) ->
        profiles = Map.get(stealth, "profiles", %{})

        if not is_map(profiles) do
          [{"stealth.profiles", "must be a map"} | errors]
        else
          Enum.reduce(profiles, errors, fn {profile_name, profile}, acc ->
            validate_stealth_profile(acc, profile_name, profile)
          end)
        end

      _ ->
        [{"stealth", "must be a map"} | errors]
    end
  end

  defp validate_stealth_profile(errors, profile_name, profile) do
    if not is_map(profile) do
      [{"stealth.profiles.#{profile_name}", "must be a map"} | errors]
    else
      Enum.reduce(profile, errors, fn {level, code}, acc ->
        if is_integer(code) and code >= 400 and code <= 599 do
          acc
        else
          [{"stealth.profiles.#{profile_name}.#{level}", "must be HTTP status code 400-599"} | acc]
        end
      end)
    end
  end
end
