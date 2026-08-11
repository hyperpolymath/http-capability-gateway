# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

defmodule HttpCapabilityGateway.Plugins.XmlRpcShield do
  @moduledoc false
  @behaviour HttpCapabilityGateway.Plugin

  @method_pattern ~r/<methodName>([^<]+)</methodName>/u

  @impl true
  def inspect_request(conn, _opts) do
    body = Plug.Conn.get_private(conn, :body)
    
    case extract_method(body) do
      nil -> :pass
      "pingback.ping" -> {:allow, conn}
      _ -> {:deny, conn, :rpc_method_unauthorized}
    end
  end

  defp extract_method(body) when is_binary(body) do
    case Regex.run(@method_pattern, body) do
      [_, method] -> method
      _ -> nil
    end
  end
end
