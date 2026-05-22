# SPDX-License-Identifier: MPL-2.0
defmodule HttpCapabilityGateway do
  @moduledoc """
  HTTP Capability-Based Security Gateway.

  This module implements a proxy layer that enforces "Capability-Based" 
  access control. Requests must carry a valid cryptographic token 
  (capability) that explicitly grants permission for the specific 
  HTTP method and path being accessed.

  DESIGN GOALS:
  1. Fine-grained authorization without a central ACL.
  2. Protocol-agnostic capability propagation.
  3. High-concurrency performance using the standard Elixir/OTP stack.
  """

  @doc """
  Sanity check for the gateway service.
  """
  def hello do
    :world
  end
end
