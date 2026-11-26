# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

defmodule HttpCapabilityGateway.Plugins.WebhookHardener do
  @moduledoc false
  import Bitwise
  @behaviour HttpCapabilityGateway.Plugin

  @private_cidrs [
    "127.0.0.0/8",
    "::1/128",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16"
  ]

  @impl true
  def inspect_request(conn, opts) do
    target = extract_target(conn)

    cond do
      !check_required_headers(conn, opts[:required_headers] || []) ->
        {:deny, conn, :missing_header}

      target && byte_size(target) > (opts[:max_target_length] || 2048) ->
        {:deny, conn, :target_too_long}

      target && ip_blocked?(target, opts[:blocked_cidrs] || @private_cidrs) ->
        {:deny, conn, :target_ip_blocked}

      true ->
        {:allow, conn}
    end
  end

  defp extract_target(conn) do
    case conn.body_params do
      %{"target" => target} when is_binary(target) -> target
      _ -> get_json_target(conn)
    end
  end

  defp get_json_target(conn) do
    case Jason.decode(Map.get(conn.private, :body) || "") do
      {:ok, %{"target" => target}} when is_binary(target) -> target
      _ -> nil
    end
  end

  defp check_required_headers(conn, required) do
    Enum.all?(required, &(Plug.Conn.get_req_header(conn, &1) != []))
  end

  defp ip_blocked?(target, blocked) do
    case URI.parse(target) do
      %URI{host: host} when is_binary(host) -> resolve_and_check(host, blocked)
      _ -> false
    end
  end

  defp resolve_and_check(host, blocked) do
    case try_parse_ip(host) do
      {:ok, ip} ->
        in_blocked_range?(ip, blocked)

      _ ->
        case :inet.gethostbyname(host) do
          {:ok, {_, _, _, _, ip}} -> in_blocked_range?(ip, blocked)
          _ -> false
        end
    end
  end

  defp try_parse_ip(host) do
    case host && :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      _ -> :error
    end
  end

  defp in_blocked_range?(ip, blocked) do
    Enum.any?(blocked, &in_cidr?(ip, &1))
  end

  defp in_cidr?(ip, cidr) do
    # :inet has no CIDR parser, so split "addr/len" and build the mask here.
    with [addr, len] <- String.split(cidr, "/", parts: 2),
         {prefix, ""} <- Integer.parse(len),
         {:ok, net} <- :inet.parse_address(String.to_charlist(addr)),
         true <- tuple_size(net) == tuple_size(ip),
         bits = if(tuple_size(net) == 4, do: 32, else: 128),
         true <- prefix >= 0 and prefix <= bits,
         {:ok, net_int} <- to_int(net),
         {:ok, ip_int} <- to_int(ip) do
      mask = ((1 <<< prefix) - 1) <<< (bits - prefix)
      (ip_int &&& mask) == (net_int &&& mask)
    else
      _ -> false
    end
  end

  defp to_int({a, b, c, d}), do: {:ok, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d}

  defp to_int({a, b, c, d, e, f, g, h}),
    do:
      {:ok,
       a <<< 112 ||| b <<< 96 ||| c <<< 80 ||| d <<< 64 ||| e <<< 48 ||| f <<< 32 |||
         g <<< 16 ||| h}

  defp to_int(_), do: :error
end
