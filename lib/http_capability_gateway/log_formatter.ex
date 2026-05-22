# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway.LogFormatter do
  @moduledoc """
  JSON log formatter for structured logging.

  Formats all log messages as JSON for easy parsing and analysis.
  """

  def format(level, message, timestamp, metadata) do
    log_data = %{
      timestamp: format_timestamp(timestamp),
      level: level,
      message: IO.chardata_to_string(message)
    }

    # Add metadata fields
    log_data =
      Enum.reduce(metadata, log_data, fn {key, value}, acc ->
        Map.put(acc, key, format_value(value))
      end)

    # Encode as JSON and add newline
    case Jason.encode(log_data) do
      {:ok, json} -> [json, "\n"]
      {:error, _} -> [message, "\n"]  # Fallback if JSON encoding fails
    end
  end

  # Format timestamp as ISO 8601
  defp format_timestamp({date, {h, m, s, ms}}) do
    with {:ok, datetime} <- NaiveDateTime.from_erl({date, {h, m, s}}, {ms * 1000, 3}) do
      NaiveDateTime.to_iso8601(datetime)
    else
      _ -> "unknown"
    end
  end

  # Format metadata values for JSON serialization
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value), do: to_string(value)
  defp format_value(value) when is_number(value), do: value
  defp format_value(value) when is_list(value), do: inspect(value)
  defp format_value(value) when is_map(value), do: value
  defp format_value(value), do: inspect(value)
end
