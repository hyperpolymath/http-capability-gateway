# SPDX-License-Identifier: MPL-2.0
# Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.RateLimiter do
  @moduledoc """
  Token bucket rate limiter as a Plug.

  Enforces per-client, per-trust-level rate limits using a token bucket
  algorithm backed by ETS for O(1) state lookups. Each client is identified
  by IP address (from X-Forwarded-For header or peer IP) and rate-limited
  according to their trust level.

  ## Trust-Level Quotas

  Quotas are configured per trust level, matching the SafeTrust hierarchy:

    - `:untrusted`     — 10 requests/second (anonymous clients)
    - `:authenticated` — 100 requests/second (authenticated users)
    - `:internal`      — unlimited (internal services, no rate limiting)

  ## Token Bucket Algorithm

  Each client bucket stores:
    - `tokens`: Current number of available tokens (float)
    - `last_refill`: Timestamp of the last token refill (monotonic nanoseconds)

  On each request:
    1. Calculate elapsed time since last refill
    2. Add tokens proportional to elapsed time (up to bucket capacity)
    3. If tokens >= 1: consume one token, allow request
    4. If tokens < 1: deny with 429 Too Many Requests + Retry-After header

  ## Plug Pipeline Position

  This plug MUST be placed AFTER trust level extraction and BEFORE request
  handling in the gateway pipeline. It reads the trust level from conn.assigns
  (set by a preceding plug or inline in handle_request/1).

  ## Client Key Derivation

  The client key combines IP address and trust level:
    - IP from X-Forwarded-For first entry (if present), else conn.remote_ip
    - Key format: {ip_string, trust_level_atom}

  This allows the same IP to have separate buckets for different trust levels
  (e.g., an authenticated user and an unauthenticated user from the same proxy).

  ## ETS Table

    - Name: `:rate_limiter_buckets`
    - Type: `:set`
    - Key: `{ip_string, trust_level_atom}`
    - Value: `{tokens :: float(), last_refill :: integer()}`
    - Options: `[:public, :named_table, write_concurrency: true]`

  ## Configuration

  Override defaults in config:

      config :http_capability_gateway, :rate_limits, %{
        untrusted: {10, 10},        # {rate_per_sec, burst_capacity}
        authenticated: {100, 100},
        internal: :unlimited
      }
  """

  @behaviour Plug

  require Logger

  alias HttpCapabilityGateway.SafeTrust

  # Default rate limits per trust level: {requests_per_second, burst_capacity}.
  # Internal services are unlimited (no rate limiting applied).
  # These can be overridden via application config :rate_limits.
  @default_rate_limits %{
    untrusted: {10, 10},
    authenticated: {100, 100},
    internal: :unlimited
  }

  # ETS table name for rate limiter bucket state.
  @bucket_table :rate_limiter_buckets

  @type client_key :: {String.t(), SafeTrust.trust_level()}
  @type bucket_state :: {tokens :: float(), last_refill :: integer()}

  @doc """
  Initializes the rate limiter Plug.

  Creates the ETS table for bucket state if it does not already exist.
  Accepts an optional keyword list of options (currently unused, reserved
  for future configuration such as custom table names or rate overrides).

  ## Parameters

    - `opts`: Keyword list of options (passed through from plug declaration)

  ## Returns

    The options, unchanged (passed to call/2).
  """
  @spec init(keyword()) :: keyword()
  def init(opts) do
    # Create the ETS table for bucket state. If it already exists
    # (e.g., during hot code reload or test re-runs), we keep the
    # existing table to preserve bucket state across reloads.
    unless :ets.whereis(@bucket_table) != :undefined do
      :ets.new(@bucket_table, [
        :set,
        :public,
        :named_table,
        write_concurrency: true
      ])

      Logger.info("Rate limiter ETS table created", table: @bucket_table)
    end

    opts
  end

  @doc """
  Rate-limits the incoming request based on trust level and client IP.

  Reads the trust level from `conn.assigns[:trust_level]` (set by the
  gateway before this plug runs). If the trust level is `:internal`,
  the request passes through without rate limiting. Otherwise, the
  token bucket for the client is checked and decremented.

  On rate limit exceeded: sends a 429 Too Many Requests response with
  a JSON body and a Retry-After header indicating when the client can
  retry (in seconds, rounded up).

  ## Parameters

    - `conn`: Plug.Conn struct with :trust_level in assigns
    - `opts`: Options from init/1 (currently unused)

  ## Returns

    - `conn` unchanged if rate limit not exceeded
    - Halted `conn` with 429 response if rate limit exceeded
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    trust_level = Map.get(conn.assigns, :trust_level, :untrusted)

    # Internal services are never rate-limited.
    if trust_level == :internal do
      conn
    else
      client_key = derive_client_key(conn, trust_level)
      {rate_per_sec, burst_capacity} = get_rate_limit(trust_level)
      now = System.monotonic_time(:nanosecond)

      case check_and_consume(client_key, rate_per_sec, burst_capacity, now) do
        {:allow, _remaining} ->
          conn

        {:deny, retry_after_ns} ->
          # Calculate Retry-After in seconds (rounded up to nearest integer).
          retry_after_sec = Float.ceil(retry_after_ns / 1_000_000_000) |> trunc()
          retry_after_sec = max(retry_after_sec, 1)

          Logger.info("Rate limit exceeded",
            client: elem(client_key, 0),
            trust_level: trust_level,
            retry_after: retry_after_sec
          )

          # Emit telemetry event for rate limit hits.
          :telemetry.execute(
            [:http_capability_gateway, :rate_limit, :exceeded],
            %{count: 1},
            %{trust_level: trust_level, client: elem(client_key, 0)}
          )

          conn
          |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after_sec))
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(429, Jason.encode!(%{
            error: "Too Many Requests",
            message: "Rate limit exceeded. Retry after #{retry_after_sec} second(s).",
            retry_after: retry_after_sec
          }))
          |> Plug.Conn.halt()
      end
    end
  end

  # Derive the client key from the connection.
  #
  # Uses X-Forwarded-For first entry if present (typical when behind a
  # load balancer or reverse proxy), otherwise falls back to conn.remote_ip.
  # The key includes the trust level so the same IP can have separate
  # buckets for different authentication states.
  @spec derive_client_key(Plug.Conn.t(), SafeTrust.trust_level()) :: client_key()
  defp derive_client_key(conn, trust_level) do
    ip =
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] ->
          # X-Forwarded-For can contain multiple IPs separated by commas.
          # The first entry is the original client IP; subsequent entries
          # are intermediate proxies. We trim whitespace for robustness.
          forwarded
          |> String.split(",")
          |> List.first()
          |> String.trim()

        [] ->
          # No X-Forwarded-For header -- use the direct peer IP.
          conn.remote_ip |> :inet.ntoa() |> to_string()
      end

    {ip, trust_level}
  end

  # Get the rate limit configuration for a trust level.
  #
  # Returns {rate_per_second, burst_capacity} from application config,
  # falling back to @default_rate_limits for unconfigured levels.
  @spec get_rate_limit(SafeTrust.trust_level()) :: {pos_integer(), pos_integer()}
  defp get_rate_limit(trust_level) do
    rate_limits =
      Application.get_env(:http_capability_gateway, :rate_limits, @default_rate_limits)

    case Map.get(rate_limits, trust_level) do
      {rate, capacity} when is_integer(rate) and is_integer(capacity) ->
        {rate, capacity}

      :unlimited ->
        # This should not be reached because call/2 short-circuits for :internal,
        # but we handle it defensively.
        {1_000_000, 1_000_000}

      nil ->
        # Unknown trust level — apply most restrictive default.
        {10, 10}
    end
  end

  # Token bucket check-and-consume operation.
  #
  # This is the core rate limiting algorithm. It uses :ets.lookup and
  # :ets.insert for O(1) per-client state management. The operation is
  # not strictly atomic across concurrent requests from the same client,
  # but the token bucket algorithm is tolerant of small races — at worst,
  # a client may get 1-2 extra requests through during a burst, which is
  # acceptable for rate limiting (we're not doing financial transactions).
  #
  # For stricter atomicity, :ets.update_counter could be used, but that
  # requires integer tokens (losing sub-token precision for refill rates
  # that don't evenly divide into 1-second windows).
  #
  # Returns:
  #   {:allow, remaining_tokens} — request permitted
  #   {:deny, nanoseconds_until_next_token} — request rejected
  @spec check_and_consume(client_key(), pos_integer(), pos_integer(), integer()) ::
          {:allow, float()} | {:deny, float()}
  defp check_and_consume(client_key, rate_per_sec, burst_capacity, now) do
    {current_tokens, last_refill} =
      case :ets.lookup(@bucket_table, client_key) do
        [{_key, {tokens, refill_time}}] ->
          {tokens, refill_time}

        [] ->
          # New client — start with a full bucket.
          {burst_capacity * 1.0, now}
      end

    # Calculate how many tokens to add based on elapsed time.
    elapsed_ns = max(now - last_refill, 0)
    elapsed_sec = elapsed_ns / 1_000_000_000
    new_tokens = min(current_tokens + elapsed_sec * rate_per_sec, burst_capacity * 1.0)

    if new_tokens >= 1.0 do
      # Consume one token and update the bucket state.
      remaining = new_tokens - 1.0
      :ets.insert(@bucket_table, {client_key, {remaining, now}})
      {:allow, remaining}
    else
      # Not enough tokens — calculate wait time until one token refills.
      deficit = 1.0 - new_tokens
      wait_ns = deficit / rate_per_sec * 1_000_000_000
      # Update the refill timestamp even on deny so that partial token
      # accumulation is not lost on the next request.
      :ets.insert(@bucket_table, {client_key, {new_tokens, now}})
      {:deny, wait_ns}
    end
  end

  @doc """
  Returns the number of active client buckets in the rate limiter.

  Useful for monitoring and diagnostics.

  ## Examples

      iex> RateLimiter.bucket_count()
      42
  """
  @spec bucket_count() :: non_neg_integer()
  def bucket_count do
    if :ets.whereis(@bucket_table) != :undefined do
      :ets.info(@bucket_table, :size)
    else
      0
    end
  end

  @doc """
  Resets (deletes) all rate limiter bucket state.

  Useful for testing and administrative resets. In production, prefer
  letting buckets naturally expire by not being used (they occupy
  minimal memory per entry).

  ## Examples

      iex> RateLimiter.reset()
      :ok
  """
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@bucket_table) != :undefined do
      :ets.delete_all_objects(@bucket_table)
    end

    :ok
  end
end
