# SPDX-License-Identifier: MPL-2.0
ExUnit.start()

# Initialize ETS tables and set high rate limits for tests
Application.put_env(:http_capability_gateway, :rate_limits, %{
  untrusted: {10000, 1000},
  authenticated: {100000, 10000},
  internal: :unlimited
})

# Start a process to own the ETS tables for tests
# This prevents them from being deleted when setup_all processes exit.
spawn(fn ->
  HttpCapabilityGateway.RateLimiter.init([])
  HttpCapabilityGateway.K9Contract.init()
  Process.sleep(:infinity)
end)
