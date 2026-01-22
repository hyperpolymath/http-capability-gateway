defmodule HttpCapabilityGatewayTest do
  use ExUnit.Case
  doctest HttpCapabilityGateway

  test "greets the world" do
    assert HttpCapabilityGateway.hello() == :world
  end
end
