# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGatewayTest do
  use ExUnit.Case
  doctest HttpCapabilityGateway

  test "greets the world" do
    assert HttpCapabilityGateway.hello() == :world
  end
end
