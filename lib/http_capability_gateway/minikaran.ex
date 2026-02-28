# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
defmodule HttpCapabilityGateway.Minikaran do
  @moduledoc """
  Traffic shape anomaly detector.

  Learns baseline request patterns (rate per path, trust level distribution,
  response time percentiles) and flags anomalies when current traffic
  deviates significantly from the learned baseline.

  Named after the karan (watchman) pattern -- a small sentinel that
  observes without blocking.

  ## Architecture

  Minikaran operates on a sliding window of 1-minute buckets, maintaining
  the most recent 60 minutes of traffic observations. Every 30 seconds a
  periodic anomaly check compares the latest bucket against the rolling
  baseline derived from the previous 59 buckets.

  Observations are stored in ETS for O(1) concurrent reads (the telemetry
  handler writes frequently, and the dashboard endpoint reads on demand).
  The GenServer owns the ETS table and runs periodic anomaly checks using
  `Process.send_after/3`.

  ## Metrics Tracked Per Window

    - `request_count_by_path` -- `%{path => count}` for traffic distribution
    - `trust_distribution` -- `%{trust_level_atom => count}` for trust profile
    - `latency_samples` -- list of request durations (microseconds) for percentiles
    - `error_count` -- count of 4xx/5xx responses
    - `total_count` -- total requests in this window
    - `unique_clients` -- `MapSet` of client IP strings

  ## Anomaly Detection Strategies

    - **Z-score**: if current window metric > 3 standard deviations from the
      rolling mean of baseline windows, flag as anomalous
    - **Trust shift**: if any trust level's share of traffic changes by > 20
      percentage points from baseline, flag
    - **Latency spike**: if current p95 exceeds 2x baseline p95, flag
    - **Path novelty**: if > 20% of requests go to paths never seen in baseline, flag
    - **Error spike**: if current error rate exceeds baseline by > 2x, flag

  ## ETS Tables

    - `:minikaran_windows` -- ring buffer of 1-minute observation buckets
    - `:minikaran_anomalies` -- current flagged anomalies (replaced each check)

  ## Public API

    - `record/1` -- called from telemetry handler after each request (cast)
    - `anomalies/0` -- get current flagged anomalies (sync read from ETS)
    - `baseline/0` -- get current learned baseline (sync read from ETS)
    - `reset/0` -- clear all learned data and anomalies
    - `status/0` -- operational status for health checks
  """

  use GenServer
  require Logger

  # -------------------------------------------------------------------
  # Constants
  # -------------------------------------------------------------------

  # Number of 1-minute buckets to keep (1 hour rolling baseline).
  @window_count 60

  # Anomaly check interval in milliseconds (30 seconds).
  @check_interval_ms 30_000

  # Bucket duration in seconds (1 minute per bucket).
  @bucket_duration_sec 60

  # Z-score threshold for traffic spike detection.
  # 3 standard deviations covers 99.7% of normal variation.
  @z_score_threshold 3.0

  # Trust distribution shift threshold in percentage points.
  # A 20pp change (e.g., from 5% to 25% untrusted) signals anomaly.
  @trust_shift_threshold_pp 20.0

  # Latency spike multiplier: current p95 > 2x baseline p95.
  @latency_spike_multiplier 2.0

  # Path novelty threshold: > 20% of requests to unseen paths.
  @path_novelty_threshold 0.20

  # Error rate spike multiplier: current rate > 2x baseline rate.
  @error_spike_multiplier 2.0

  # Minimum baseline windows required before anomaly detection activates.
  # Need at least 5 minutes of data to form a meaningful baseline.
  @min_baseline_windows 5

  # ETS table names.
  @windows_table :minikaran_windows
  @anomalies_table :minikaran_anomalies

  # -------------------------------------------------------------------
  # Type specifications
  # -------------------------------------------------------------------

  @typedoc """
  A single observation recorded from a request lifecycle event.

  Fields:
    - `path` -- the HTTP request path (e.g., "/api/v1/users")
    - `trust_level` -- the SafeTrust trust level atom
    - `latency_us` -- request duration in microseconds
    - `status` -- HTTP response status code
    - `client_ip` -- client IP address string
    - `timestamp` -- monotonic time in seconds when recorded
  """
  @type observation :: %{
          path: String.t(),
          trust_level: atom(),
          latency_us: non_neg_integer(),
          status: non_neg_integer(),
          client_ip: String.t(),
          timestamp: integer()
        }

  @typedoc """
  A 1-minute observation bucket aggregating traffic metrics.

  Fields:
    - `bucket_id` -- monotonic bucket index (minute since epoch)
    - `request_count_by_path` -- path frequency map
    - `trust_distribution` -- trust level frequency map
    - `latency_samples` -- raw latency values for percentile computation
    - `error_count` -- count of error responses (status >= 400)
    - `total_count` -- total observations in this bucket
    - `unique_clients` -- set of distinct client IPs
    - `started_at` -- wall clock time when bucket was created
  """
  @type window_bucket :: %{
          bucket_id: integer(),
          request_count_by_path: %{String.t() => non_neg_integer()},
          trust_distribution: %{atom() => non_neg_integer()},
          latency_samples: [non_neg_integer()],
          error_count: non_neg_integer(),
          total_count: non_neg_integer(),
          unique_clients: MapSet.t(String.t()),
          started_at: integer()
        }

  @typedoc """
  An anomaly flagged by the detector.

  Each variant captures the specific metric that deviated, along with
  the current and baseline values for operator inspection.
  """
  @type anomaly ::
          {:traffic_spike, path :: String.t(), current :: number(), baseline :: number()}
          | {:trust_shift, trust_level :: atom(), current_pct :: float(), baseline_pct :: float()}
          | {:latency_spike, percentile :: atom(), current_ms :: float(), baseline_ms :: float()}
          | {:path_novelty, new_paths :: non_neg_integer(), total_paths :: non_neg_integer()}
          | {:error_spike, current_rate :: float(), baseline_rate :: float()}

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  @doc """
  Starts the Minikaran GenServer under the given name.

  ## Options

    - `:name` -- GenServer registration name (default: `__MODULE__`)
    - `:check_interval_ms` -- anomaly check interval (default: 30_000)

  ## Examples

      {:ok, pid} = Minikaran.start_link(name: Minikaran)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records an observation from a completed request.

  Called asynchronously (cast) from the telemetry handler so it never
  blocks the request pipeline. The GenServer batches observations into
  the current 1-minute window bucket.

  ## Parameters

    - `observation` -- map with `:path`, `:trust_level`, `:latency_us`,
      `:status`, and `:client_ip` keys

  ## Examples

      Minikaran.record(%{
        path: "/api/v1/users",
        trust_level: :authenticated,
        latency_us: 1234,
        status: 200,
        client_ip: "10.0.0.1"
      })
  """
  @spec record(observation()) :: :ok
  def record(observation) do
    GenServer.cast(__MODULE__, {:record, observation})
  end

  @doc """
  Returns the list of currently flagged anomalies.

  Reads directly from ETS for O(1) access without hitting the GenServer
  mailbox. Returns an empty list if no anomalies are detected or if the
  baseline has insufficient data.

  ## Examples

      iex> Minikaran.anomalies()
      [{:traffic_spike, "/api/v1/users", 150, 42.3}]
  """
  @spec anomalies() :: [anomaly()]
  def anomalies do
    case :ets.whereis(@anomalies_table) do
      :undefined ->
        []

      _ref ->
        case :ets.lookup(@anomalies_table, :current) do
          [{:current, anomaly_list}] -> anomaly_list
          [] -> []
        end
    end
  end

  @doc """
  Returns the current learned baseline as a summary map.

  Computes aggregate statistics across all non-current baseline windows.
  Returns `nil` if insufficient data has been collected.

  ## Return Shape

      %{
        window_count: integer(),
        avg_requests_per_minute: float(),
        trust_distribution: %{atom() => float()},
        latency_p50_us: float(),
        latency_p95_us: float(),
        latency_p99_us: float(),
        avg_error_rate: float(),
        known_paths: [String.t()],
        avg_unique_clients: float()
      }
  """
  @spec baseline() :: map() | nil
  def baseline do
    case :ets.whereis(@windows_table) do
      :undefined ->
        nil

      _ref ->
        windows = get_baseline_windows()

        if length(windows) < @min_baseline_windows do
          nil
        else
          compute_baseline_summary(windows)
        end
    end
  end

  @doc """
  Clears all learned data, anomalies, and resets to a fresh state.

  Useful for testing and administrative operations. In production, prefer
  letting the sliding window naturally age out stale data.

  ## Examples

      iex> Minikaran.reset()
      :ok
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Returns the operational status of Minikaran for health checks.

  ## Return Shape

      %{
        status: :learning | :active | :stopped,
        windows_collected: integer(),
        min_windows_required: integer(),
        current_anomalies: integer(),
        last_check_at: integer() | nil
      }
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # -------------------------------------------------------------------
  # GenServer Callbacks
  # -------------------------------------------------------------------

  @impl true
  @doc false
  def init(opts) do
    check_interval = Keyword.get(opts, :check_interval_ms, @check_interval_ms)

    # Create ETS tables for window data and anomaly results.
    # Both are :set tables with :public read access so telemetry handlers
    # and dashboard endpoints can read without messaging the GenServer.
    create_ets_table(@windows_table)
    create_ets_table(@anomalies_table)

    # Seed the anomalies table with an empty list so readers never get [].
    :ets.insert(@anomalies_table, {:current, []})

    # Initialize state with the current bucket.
    now_sec = System.system_time(:second)
    bucket_id = div(now_sec, @bucket_duration_sec)

    state = %{
      current_bucket_id: bucket_id,
      current_bucket: new_bucket(bucket_id),
      check_interval: check_interval,
      last_check_at: nil,
      started_at: now_sec
    }

    # Schedule the first anomaly check.
    schedule_check(check_interval)

    Logger.info("Minikaran traffic anomaly detector started",
      check_interval_ms: check_interval,
      window_count: @window_count,
      min_baseline_windows: @min_baseline_windows
    )

    {:ok, state}
  end

  @impl true
  @doc false
  def handle_cast({:record, observation}, state) do
    now_sec = System.system_time(:second)
    bucket_id = div(now_sec, @bucket_duration_sec)

    # If we have moved to a new minute, flush the current bucket to ETS
    # and start a fresh one.
    state =
      if bucket_id != state.current_bucket_id do
        flush_bucket(state.current_bucket)
        prune_old_windows(bucket_id)

        %{state | current_bucket_id: bucket_id, current_bucket: new_bucket(bucket_id)}
      else
        state
      end

    # Merge the observation into the current bucket.
    updated_bucket = merge_observation(state.current_bucket, observation)

    {:noreply, %{state | current_bucket: updated_bucket}}
  end

  @impl true
  @doc false
  def handle_call(:reset, _from, state) do
    # Clear both ETS tables.
    if :ets.whereis(@windows_table) != :undefined do
      :ets.delete_all_objects(@windows_table)
    end

    if :ets.whereis(@anomalies_table) != :undefined do
      :ets.insert(@anomalies_table, {:current, []})
    end

    # Reset state to a fresh bucket.
    now_sec = System.system_time(:second)
    bucket_id = div(now_sec, @bucket_duration_sec)

    new_state = %{
      state
      | current_bucket_id: bucket_id,
        current_bucket: new_bucket(bucket_id),
        last_check_at: nil
    }

    Logger.info("Minikaran baseline reset")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    window_count = ets_window_count()

    status_atom =
      cond do
        window_count < @min_baseline_windows -> :learning
        true -> :active
      end

    current_anomalies = length(anomalies())

    result = %{
      status: status_atom,
      windows_collected: window_count,
      min_windows_required: @min_baseline_windows,
      current_anomalies: current_anomalies,
      last_check_at: state.last_check_at,
      uptime_sec: System.system_time(:second) - state.started_at
    }

    {:reply, result, state}
  end

  @impl true
  @doc false
  def handle_info(:run_anomaly_check, state) do
    # Flush the current bucket snapshot to ETS for the check, but keep
    # accumulating into it (the current minute is still in progress).
    flush_bucket(state.current_bucket)

    # Run the anomaly detection pipeline.
    anomalies_found = run_anomaly_detection()

    # Store results in ETS for O(1) reads.
    :ets.insert(@anomalies_table, {:current, anomalies_found})

    if anomalies_found != [] do
      Logger.warning("Minikaran detected anomalies",
        count: length(anomalies_found),
        anomalies: Enum.map(anomalies_found, &format_anomaly/1)
      )

      # Emit telemetry event for each anomaly so Prometheus can track them.
      Enum.each(anomalies_found, fn anomaly ->
        :telemetry.execute(
          [:http_capability_gateway, :minikaran, :anomaly],
          %{count: 1},
          %{type: elem(anomaly, 0)}
        )
      end)
    end

    now_sec = System.system_time(:second)

    # Schedule the next check.
    schedule_check(state.check_interval)

    {:noreply, %{state | last_check_at: now_sec}}
  end

  # Catch-all for unexpected messages (defensive -- prevents GenServer crash
  # from stray messages in the mailbox).
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Minikaran received unexpected message", message: inspect(msg))
    {:noreply, state}
  end

  # -------------------------------------------------------------------
  # Private: Bucket Management
  # -------------------------------------------------------------------

  # Creates a new empty observation bucket for the given minute index.
  @spec new_bucket(integer()) :: window_bucket()
  defp new_bucket(bucket_id) do
    %{
      bucket_id: bucket_id,
      request_count_by_path: %{},
      trust_distribution: %{},
      latency_samples: [],
      error_count: 0,
      total_count: 0,
      unique_clients: MapSet.new(),
      started_at: System.system_time(:second)
    }
  end

  # Merges a single observation into the accumulating bucket.
  #
  # This is called on every request (via cast), so it must be fast.
  # All operations are O(1) amortized (map updates, MapSet insert,
  # list prepend for latency samples).
  @spec merge_observation(window_bucket(), observation()) :: window_bucket()
  defp merge_observation(bucket, obs) do
    path = Map.get(obs, :path, "/unknown")
    trust_level = Map.get(obs, :trust_level, :untrusted)
    latency_us = Map.get(obs, :latency_us, 0)
    status = Map.get(obs, :status, 0)
    client_ip = Map.get(obs, :client_ip, "unknown")

    is_error = status >= 400

    %{
      bucket
      | request_count_by_path:
          Map.update(bucket.request_count_by_path, path, 1, &(&1 + 1)),
        trust_distribution:
          Map.update(bucket.trust_distribution, trust_level, 1, &(&1 + 1)),
        latency_samples: [latency_us | bucket.latency_samples],
        error_count: bucket.error_count + if(is_error, do: 1, else: 0),
        total_count: bucket.total_count + 1,
        unique_clients: MapSet.put(bucket.unique_clients, client_ip)
    }
  end

  # Writes a bucket to ETS, keyed by its bucket_id.
  #
  # The bucket is serialized without the MapSet (ETS stores terms, and
  # we convert unique_clients to a count for storage efficiency).
  @spec flush_bucket(window_bucket()) :: true
  defp flush_bucket(bucket) do
    # Convert MapSet to count for ETS storage (MapSets are large terms).
    storable = %{
      bucket
      | unique_clients: MapSet.size(bucket.unique_clients)
    }

    :ets.insert(@windows_table, {bucket.bucket_id, storable})
  end

  # Removes windows older than @window_count minutes from ETS.
  #
  # Uses :ets.select_delete with a match spec for efficient bulk removal.
  # Only windows with bucket_id < (current - window_count) are pruned.
  @spec prune_old_windows(integer()) :: non_neg_integer()
  defp prune_old_windows(current_bucket_id) do
    cutoff = current_bucket_id - @window_count

    # Match spec: delete entries where the key (element 1) < cutoff.
    # Format: [{match_head, [guard], [result]}]
    match_spec = [{{:"$1", :_}, [{:<, :"$1", cutoff}], [true]}]
    :ets.select_delete(@windows_table, match_spec)
  end

  # -------------------------------------------------------------------
  # Private: Anomaly Detection Pipeline
  # -------------------------------------------------------------------

  # Runs all anomaly detection checks against the current window data.
  #
  # Returns a list of anomaly tuples. Empty list means no anomalies.
  # The detection pipeline only activates once sufficient baseline data
  # has been collected (@min_baseline_windows).
  @spec run_anomaly_detection() :: [anomaly()]
  defp run_anomaly_detection do
    all_windows = get_all_windows()

    if length(all_windows) < @min_baseline_windows + 1 do
      # Not enough data yet -- still in learning phase.
      []
    else
      # Sort by bucket_id descending; the most recent is the "current" window.
      sorted = Enum.sort_by(all_windows, fn {id, _bucket} -> id end, :desc)
      [{_current_id, current} | baseline_pairs] = sorted
      baseline_buckets = Enum.map(baseline_pairs, fn {_id, bucket} -> bucket end)

      # Run each detector and concatenate results.
      []
      |> Kernel.++(detect_traffic_spikes(current, baseline_buckets))
      |> Kernel.++(detect_trust_shifts(current, baseline_buckets))
      |> Kernel.++(detect_latency_spikes(current, baseline_buckets))
      |> Kernel.++(detect_path_novelty(current, baseline_buckets))
      |> Kernel.++(detect_error_spikes(current, baseline_buckets))
    end
  end

  # Detects paths with abnormally high request counts.
  #
  # For each path in the current window, computes its z-score against
  # the baseline distribution. Paths with z-score > @z_score_threshold
  # are flagged.
  @spec detect_traffic_spikes(map(), [map()]) :: [anomaly()]
  defp detect_traffic_spikes(current, baseline_buckets) do
    current_paths = current.request_count_by_path

    # Build per-path count series from baseline.
    path_series = build_path_series(baseline_buckets)

    Enum.flat_map(current_paths, fn {path, current_count} ->
      series = Map.get(path_series, path, [])

      case z_score(current_count, series) do
        {:ok, z} when z > @z_score_threshold ->
          mean = safe_mean(series)
          [{:traffic_spike, path, current_count, Float.round(mean, 1)}]

        _ ->
          []
      end
    end)
  end

  # Detects significant shifts in trust level distribution.
  #
  # Compares current trust level percentages against baseline averages.
  # A shift exceeding @trust_shift_threshold_pp percentage points is flagged.
  @spec detect_trust_shifts(map(), [map()]) :: [anomaly()]
  defp detect_trust_shifts(current, baseline_buckets) do
    current_total = max(current.total_count, 1)
    current_dist = current.trust_distribution

    # Compute baseline average trust distribution.
    baseline_dist = average_trust_distribution(baseline_buckets)

    Enum.flat_map(current_dist, fn {trust_level, count} ->
      current_pct = count / current_total * 100.0
      baseline_pct = Map.get(baseline_dist, trust_level, 0.0)
      shift = abs(current_pct - baseline_pct)

      if shift > @trust_shift_threshold_pp do
        [{:trust_shift, trust_level, Float.round(current_pct, 1), Float.round(baseline_pct, 1)}]
      else
        []
      end
    end)
  end

  # Detects latency percentile spikes.
  #
  # Compares the current window's p95 against the baseline p95.
  # If current exceeds @latency_spike_multiplier times the baseline, flag.
  @spec detect_latency_spikes(map(), [map()]) :: [anomaly()]
  defp detect_latency_spikes(current, baseline_buckets) do
    current_samples = current.latency_samples

    if current_samples == [] do
      []
    else
      current_p95 = percentile(current_samples, 95)

      # Collect all baseline latency samples and compute their p95.
      baseline_samples =
        Enum.flat_map(baseline_buckets, fn bucket ->
          Map.get(bucket, :latency_samples, [])
        end)

      if baseline_samples == [] do
        []
      else
        baseline_p95 = percentile(baseline_samples, 95)

        if baseline_p95 > 0 and current_p95 > baseline_p95 * @latency_spike_multiplier do
          # Convert microseconds to milliseconds for readability.
          current_ms = Float.round(current_p95 / 1000.0, 1)
          baseline_ms = Float.round(baseline_p95 / 1000.0, 1)
          [{:latency_spike, :p95, current_ms, baseline_ms}]
        else
          []
        end
      end
    end
  end

  # Detects a surge of requests to previously unseen paths.
  #
  # If more than @path_novelty_threshold of requests in the current window
  # target paths not present in any baseline window, flag.
  @spec detect_path_novelty(map(), [map()]) :: [anomaly()]
  defp detect_path_novelty(current, baseline_buckets) do
    current_paths = Map.keys(current.request_count_by_path)
    current_total = max(current.total_count, 1)

    # Collect all paths seen in the baseline.
    known_paths =
      Enum.reduce(baseline_buckets, MapSet.new(), fn bucket, acc ->
        paths = Map.keys(Map.get(bucket, :request_count_by_path, %{}))
        Enum.reduce(paths, acc, &MapSet.put(&2, &1))
      end)

    # Count requests to novel paths.
    novel_request_count =
      Enum.reduce(current.request_count_by_path, 0, fn {path, count}, acc ->
        if MapSet.member?(known_paths, path), do: acc, else: acc + count
      end)

    novel_ratio = novel_request_count / current_total
    novel_path_count = Enum.count(current_paths, fn p -> not MapSet.member?(known_paths, p) end)

    if novel_ratio > @path_novelty_threshold and novel_path_count > 0 do
      [{:path_novelty, novel_path_count, length(current_paths)}]
    else
      []
    end
  end

  # Detects error rate spikes.
  #
  # Compares the current window's error rate (errors / total) against
  # the baseline average error rate. If current exceeds baseline by
  # @error_spike_multiplier, flag.
  @spec detect_error_spikes(map(), [map()]) :: [anomaly()]
  defp detect_error_spikes(current, baseline_buckets) do
    current_total = max(current.total_count, 1)
    current_error_rate = current.error_count / current_total

    # Compute baseline average error rate.
    baseline_rates =
      Enum.map(baseline_buckets, fn bucket ->
        total = max(Map.get(bucket, :total_count, 0), 1)
        Map.get(bucket, :error_count, 0) / total
      end)

    baseline_avg_rate = safe_mean(baseline_rates)

    # Only flag if both the current rate is non-trivial and it exceeds
    # the baseline by the multiplier. Avoid flagging when baseline is
    # near zero (would produce infinite multiplier).
    if current_error_rate > 0.01 and baseline_avg_rate > 0.001 and
         current_error_rate > baseline_avg_rate * @error_spike_multiplier do
      [{:error_spike, Float.round(current_error_rate, 3), Float.round(baseline_avg_rate, 3)}]
    else
      []
    end
  end

  # -------------------------------------------------------------------
  # Private: Statistical Helpers
  # -------------------------------------------------------------------

  # Computes the z-score of a value against a sample series.
  #
  # Returns {:ok, z_score} if the series has enough data and non-zero
  # standard deviation, or :insufficient_data otherwise.
  @spec z_score(number(), [number()]) :: {:ok, float()} | :insufficient_data
  defp z_score(_value, series) when length(series) < 3 do
    :insufficient_data
  end

  defp z_score(value, series) do
    mean = safe_mean(series)
    stddev = safe_stddev(series, mean)

    if stddev < 0.001 do
      # Near-zero stddev means traffic is perfectly constant. Any change
      # is technically infinite z-score, but we avoid division by near-zero.
      # Instead, flag if value is meaningfully different from mean.
      if abs(value - mean) > max(1, mean * 0.5) do
        {:ok, @z_score_threshold + 1.0}
      else
        {:ok, 0.0}
      end
    else
      {:ok, (value - mean) / stddev}
    end
  end

  # Computes the arithmetic mean of a numeric list.
  # Returns 0.0 for empty lists (safe default).
  @spec safe_mean([number()]) :: float()
  defp safe_mean([]), do: 0.0

  defp safe_mean(values) do
    Enum.sum(values) / length(values)
  end

  # Computes the population standard deviation given a pre-computed mean.
  # Returns 0.0 for lists with fewer than 2 elements.
  @spec safe_stddev([number()], float()) :: float()
  defp safe_stddev(values, _mean) when length(values) < 2, do: 0.0

  defp safe_stddev(values, mean) do
    variance =
      values
      |> Enum.map(fn v -> (v - mean) * (v - mean) end)
      |> Enum.sum()
      |> Kernel./(length(values))

    :math.sqrt(variance)
  end

  # Computes the p-th percentile of a list of numeric values.
  #
  # Uses the nearest-rank method: sorts the list, then picks the element
  # at index ceil(p/100 * n) - 1. Returns 0 for empty lists.
  @spec percentile([number()], number()) :: number()
  defp percentile([], _p), do: 0

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    n = length(sorted)
    rank = max(1, ceil(p / 100.0 * n))
    Enum.at(sorted, min(rank - 1, n - 1))
  end

  # -------------------------------------------------------------------
  # Private: Baseline Computation Helpers
  # -------------------------------------------------------------------

  # Builds a per-path time series from baseline buckets.
  #
  # Returns %{path => [count_in_bucket_1, count_in_bucket_2, ...]}
  # where missing paths in a bucket contribute 0.
  @spec build_path_series([map()]) :: %{String.t() => [non_neg_integer()]}
  defp build_path_series(baseline_buckets) do
    # Collect all known paths across baseline.
    all_paths =
      Enum.reduce(baseline_buckets, MapSet.new(), fn bucket, acc ->
        paths = Map.keys(Map.get(bucket, :request_count_by_path, %{}))
        Enum.reduce(paths, acc, &MapSet.put(&2, &1))
      end)

    # For each path, extract the count from each bucket (0 if absent).
    Enum.reduce(all_paths, %{}, fn path, acc ->
      series =
        Enum.map(baseline_buckets, fn bucket ->
          Map.get(Map.get(bucket, :request_count_by_path, %{}), path, 0)
        end)

      Map.put(acc, path, series)
    end)
  end

  # Computes the average trust level distribution across baseline buckets.
  #
  # Returns %{trust_level => average_percentage} where percentages sum to ~100.
  @spec average_trust_distribution([map()]) :: %{atom() => float()}
  defp average_trust_distribution([]), do: %{}

  defp average_trust_distribution(baseline_buckets) do
    n = length(baseline_buckets)

    # Accumulate percentage for each trust level across all buckets.
    Enum.reduce(baseline_buckets, %{}, fn bucket, acc ->
      total = max(Map.get(bucket, :total_count, 0), 1)
      dist = Map.get(bucket, :trust_distribution, %{})

      Enum.reduce(dist, acc, fn {trust_level, count}, inner_acc ->
        pct = count / total * 100.0
        Map.update(inner_acc, trust_level, pct, &(&1 + pct))
      end)
    end)
    |> Enum.into(%{}, fn {trust_level, total_pct} ->
      {trust_level, total_pct / n}
    end)
  end

  # Computes a baseline summary from a list of window buckets.
  #
  # This is the public-facing baseline representation returned by baseline/0.
  @spec compute_baseline_summary([map()]) :: map()
  defp compute_baseline_summary(windows) do
    n = length(windows)

    # Average requests per minute.
    avg_rpm =
      windows
      |> Enum.map(fn w -> Map.get(w, :total_count, 0) end)
      |> safe_mean()

    # Trust distribution average.
    trust_dist = average_trust_distribution(windows)

    # Aggregate latency samples for percentile computation.
    all_latencies =
      Enum.flat_map(windows, fn w ->
        Map.get(w, :latency_samples, [])
      end)

    p50 = percentile(all_latencies, 50)
    p95 = percentile(all_latencies, 95)
    p99 = percentile(all_latencies, 99)

    # Average error rate.
    avg_error_rate =
      windows
      |> Enum.map(fn w ->
        total = max(Map.get(w, :total_count, 0), 1)
        Map.get(w, :error_count, 0) / total
      end)
      |> safe_mean()

    # Known paths (union across all windows).
    known_paths =
      Enum.reduce(windows, MapSet.new(), fn w, acc ->
        paths = Map.keys(Map.get(w, :request_count_by_path, %{}))
        Enum.reduce(paths, acc, &MapSet.put(&2, &1))
      end)

    # Average unique clients per window.
    avg_clients =
      windows
      |> Enum.map(fn w ->
        clients = Map.get(w, :unique_clients, 0)
        if is_integer(clients), do: clients, else: MapSet.size(clients)
      end)
      |> safe_mean()

    %{
      window_count: n,
      avg_requests_per_minute: Float.round(avg_rpm, 1),
      trust_distribution:
        Enum.into(trust_dist, %{}, fn {k, v} -> {k, Float.round(v, 1)} end),
      latency_p50_us: p50,
      latency_p95_us: p95,
      latency_p99_us: p99,
      avg_error_rate: Float.round(avg_error_rate, 4),
      known_paths: MapSet.to_list(known_paths) |> Enum.sort(),
      avg_unique_clients: Float.round(avg_clients, 1)
    }
  end

  # -------------------------------------------------------------------
  # Private: ETS Helpers
  # -------------------------------------------------------------------

  # Creates an ETS table if it does not already exist.
  #
  # Tables are :set, :public, :named_table with write_concurrency enabled
  # for the windows table (high write throughput from telemetry handler)
  # and read_concurrency for the anomalies table (frequent dashboard reads).
  @spec create_ets_table(atom()) :: atom()
  defp create_ets_table(name) do
    if :ets.whereis(name) == :undefined do
      concurrency_opt =
        if name == @windows_table do
          [write_concurrency: true]
        else
          [read_concurrency: true]
        end

      :ets.new(name, [:set, :public, :named_table] ++ concurrency_opt)
      Logger.debug("Minikaran ETS table created", table: name)
    end

    name
  end

  # Returns all window buckets from ETS as [{bucket_id, bucket_map}].
  @spec get_all_windows() :: [{integer(), map()}]
  defp get_all_windows do
    if :ets.whereis(@windows_table) != :undefined do
      :ets.tab2list(@windows_table)
    else
      []
    end
  end

  # Returns baseline windows (all except the most recent bucket).
  @spec get_baseline_windows() :: [map()]
  defp get_baseline_windows do
    all = get_all_windows()

    case all do
      [] ->
        []

      windows ->
        sorted = Enum.sort_by(windows, fn {id, _} -> id end, :desc)
        # Drop the most recent (current) window from baseline.
        sorted
        |> Enum.drop(1)
        |> Enum.map(fn {_id, bucket} -> bucket end)
    end
  end

  # Returns the count of windows currently stored in ETS.
  @spec ets_window_count() :: non_neg_integer()
  defp ets_window_count do
    if :ets.whereis(@windows_table) != :undefined do
      :ets.info(@windows_table, :size)
    else
      0
    end
  end

  # -------------------------------------------------------------------
  # Private: Scheduling
  # -------------------------------------------------------------------

  # Schedules the next anomaly check using Process.send_after/3.
  #
  # This is the non-blocking periodic timer pattern recommended for
  # GenServers -- it avoids holding a dedicated timer process and
  # naturally pauses if the GenServer is busy processing a long check.
  @spec schedule_check(pos_integer()) :: reference()
  defp schedule_check(interval_ms) do
    Process.send_after(self(), :run_anomaly_check, interval_ms)
  end

  # -------------------------------------------------------------------
  # Private: Formatting
  # -------------------------------------------------------------------

  # Formats an anomaly tuple into a human-readable string for logging.
  @spec format_anomaly(anomaly()) :: String.t()
  defp format_anomaly({:traffic_spike, path, current, baseline}) do
    "traffic_spike: #{path} (current=#{current}, baseline=#{baseline})"
  end

  defp format_anomaly({:trust_shift, trust_level, current_pct, baseline_pct}) do
    "trust_shift: #{trust_level} (current=#{current_pct}%, baseline=#{baseline_pct}%)"
  end

  defp format_anomaly({:latency_spike, percentile, current_ms, baseline_ms}) do
    "latency_spike: #{percentile} (current=#{current_ms}ms, baseline=#{baseline_ms}ms)"
  end

  defp format_anomaly({:path_novelty, new_paths, total_paths}) do
    "path_novelty: #{new_paths} new of #{total_paths} total paths"
  end

  defp format_anomaly({:error_spike, current_rate, baseline_rate}) do
    "error_spike: current=#{current_rate}, baseline=#{baseline_rate}"
  end
end
