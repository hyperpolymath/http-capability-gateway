# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

defmodule HttpCapabilityGateway.Plugin do
  @moduledoc """
  Behaviour module for pluggable request inspection handlers.

  Plugins implement protocol-specific validation logic that the core gateway
  remains completely oblivious to. This preserves O(1) performance for routes
  without registered plugins.
  """

  @callback inspect_request(Plug.Conn.t(), map()) ::
              {:allow, Plug.Conn.t()} | {:deny, Plug.Conn.t()} | {:deny, Plug.Conn.t(), atom()} | :pass
end
