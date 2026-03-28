# SONNET-TASKS: http-capability-gateway

**Date:** 2026-02-12
**Language:** Elixir 1.19+ / OTP 27+
**Build system:** Mix
**Test framework:** ExUnit + StreamData (property tests)
**Honest completion:** ~60%

## Why Not 95%

STATE.scm claims 95% completion. That is aspirational. The reality:

1. **Two test files are entirely broken** -- `policy_property_test.exs` and `performance_test.exs` call three functions that do not exist in the codebase: `PolicyCompiler.is_verb_allowed?/2`, `PolicyCompiler.get_stealth_config/0`, and use ETS table names (`:gateway_rules`, `:stealth_config`) that do not exist.
2. **Gateway tests assume behaviors that do not exist** -- tests check `conn.assigns[:trust_level]`, `conn.assigns[:request_id]`, `conn.halted`, and `conn.resp_body == ""`, but the gateway never sets assigns and always sends JSON response bodies (never empty).
3. **The main module is a "Hello World" stub** -- `lib/http_capability_gateway.ex` still has the auto-generated `hello/0` function.
4. **Dead code** -- `get_stealth_status_code/1` in `PolicyCompiler` is defined but never called. 6 out of 8 public functions in `Logging` module are never called from production code.
5. **Example policy uses a different DSL format** than DSL v1 -- `examples/policy-dev.yaml` uses nested verb objects with exposure/narrative, not the flat list format the code actually parses.
6. **API docs describe functions that do not exist** -- `docs/API.md` documents `PolicyCompiler.is_verb_allowed?/2`, `PolicyCompiler.get_stealth_config/0`, `Proxy.forward/1` (actual signature is `forward/2`).
7. **config/policy.yaml is empty** -- the default policy file referenced in `config/config.exs` is a blank file.
8. **Containerfile references `priv/` directory** which does not exist.
9. **No Mix release configured** -- `mix.exs` has no `releases/0` function, but Containerfile runs `mix release`.
10. **CMS compatibility docs describe features that do not exist** -- bypass_if_cookie, rate_limit, auto-detection, CORS handling, .well-known passthrough, security headers injection -- none of this is implemented.

---

## GROUND RULES FOR SONNET

1. Run `mix test` before AND after every task to confirm you fixed what you claim.
2. Do NOT add new dependencies unless a task explicitly says to.
3. Do NOT refactor working code -- only fix broken things.
4. Each task is self-contained. Complete one fully before starting the next.
5. If a test needs a function that does not exist, implement the function, do not delete the test.
6. All new code MUST have `# SPDX-License-Identifier: PMPL-1.0-or-later` at the top of the file.

---

## TASK 1: Implement Missing PolicyCompiler Functions (is_verb_allowed?, get_stealth_config)

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/lib/http_capability_gateway/policy_compiler.ex`
- `/var$REPOS_DIR/http-capability-gateway/test/policy_property_test.exs`
- `/var$REPOS_DIR/http-capability-gateway/test/performance_test.exs`

**Problem:**
`test/policy_property_test.exs` and `test/performance_test.exs` call three functions that do not exist:
- `PolicyCompiler.is_verb_allowed?(path, verb)` -- called at lines 113, 120, 148, 156, 204, 205, 206, 255 of property test and lines 82, 95, 114 of performance test.
- `PolicyCompiler.get_stealth_config()` -- called at line 181 of property test.

These tests also expect `PolicyCompiler.compile/1` to return `:ok` (bare atom), but the actual implementation returns `{:ok, table}`. See property test lines 72, 73, 82, 179, 235.

Additionally, the property tests reference ETS table names `:gateway_rules` (lines 77, 85) which do not exist -- the actual table name is `:policy_rules`.

**What to do:**

1. Add `is_verb_allowed?/2` to `PolicyCompiler`. It should:
   - Accept `(path :: String.t(), verb :: String.t())` where verb is a string like `"GET"`
   - Look up the default `:policy_rules` ETS table
   - Convert the verb string to an atom and call the existing `lookup/3` function
   - Return `true` if `{:ok, _}` and `false` if `{:error, :no_match}`

2. Add `get_stealth_config/0` to `PolicyCompiler`. It should:
   - Read stealth config from application env (`:http_capability_gateway`, `:stealth_profiles`)
   - Return `%{enabled: boolean, status_code: integer}` or `nil`
   - Check if the `"default"` profile exists in stealth_profiles to determine enabled status

3. Fix the property test assertions that expect `:ok` from `compile/1`:
   - Lines 72, 73, 82, 179, 235: change `assert :ok = PolicyCompiler.compile(policy)` to `assert {:ok, _} = PolicyCompiler.compile(policy)`

4. Fix ETS table name references:
   - Lines 77, 85: change `:gateway_rules` to `:policy_rules`

5. Fix performance test assertions:
   - Lines 44, 66: `{time_us, :ok} = :timer.tc(...)` should destructure `{:ok, _}` not `:ok`

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway
mix test test/policy_property_test.exs --trace 2>&1 | tail -30
mix test test/performance_test.exs --trace 2>&1 | tail -30
```

All property tests and performance tests must pass. Zero failures.

---

## TASK 2: Fix Gateway Tests (assigns, halted, empty body assertions)

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/lib/http_capability_gateway/gateway.ex`
- `/var$REPOS_DIR/http-capability-gateway/test/gateway_test.exs`

**Problem:**
The gateway tests have multiple mismatches with the actual gateway implementation:

1. **`conn.assigns[:trust_level]`** (test lines 217-218, 226): The gateway never calls `Plug.Conn.assign(conn, :trust_level, ...)`. The trust level is extracted into a local variable but never stored on the conn.

2. **`conn.assigns[:request_id]`** (test line 204): Same issue -- request ID is extracted into a local variable, never assigned to conn.

3. **`conn.halted`** (test lines 53, 69, 153): When a request is denied, the gateway calls `send_resp/3` which marks `conn.state` as `:sent`, but does not explicitly call `Plug.Conn.halt/1`. Whether `conn.halted` is true depends on Plug.Router internals after `send_resp` -- it is unreliable here.

4. **`conn.resp_body == ""`** (test line 160): The gateway always sends JSON response bodies, even in stealth mode. The test expects an empty body in stealth mode.

5. **Trust level tests reference wrong values**: Tests check for `"high"` and `"low"` trust levels (lines 217, 226), but the gateway uses `"untrusted"`, `"authenticated"`, `"internal"`.

6. **Gateway tests setup deletes wrong ETS tables**: Setup (lines 11-12) deletes `:gateway_rules` and `:stealth_config`, but the actual tables are `:policy_rules` and stealth is stored in application env.

7. **Tests at lines 39-93 test verb enforcement but the gateway tries to proxy allowed requests to `http://localhost:9999`** which will fail with a 502 -- so `refute conn.status == 404` might pass but the status will be 502, not the expected 200.

**What to do:**

1. In `gateway.ex`, add assigns for `trust_level` and `request_id` to the conn in `handle_request/1`:
   - After line 90 (`trust_level = extract_trust_level(conn)`), add: `conn = Plug.Conn.assign(conn, :trust_level, trust_level)`
   - After line 83 (`request_id = get_request_id(conn)`), add: `conn = Plug.Conn.assign(conn, :request_id, request_id)`

2. In `gateway.ex`, call `Plug.Conn.halt/1` on all response paths in `handle_request/1` and `handle_denial/1` so `conn.halted` is reliably `true` after sending a response.

3. Fix the gateway test setup (lines 11-12): Change `:gateway_rules` to `:policy_rules` and remove the `:stealth_config` cleanup (it does not exist as an ETS table).

4. Fix trust level test values:
   - Line 213: Change the header value from `"high"` to `"authenticated"` or `"internal"`.
   - Line 217-218: Change expected value to match what was set.
   - Lines 221-226: Change expected trust level from `["low", :low, nil]` to `["untrusted", nil]`.

5. For the stealth "empty body" test (line 160): Either change the gateway to send empty bodies in stealth mode, or fix the test to check for the JSON body the gateway actually sends.

6. For proxy-dependent tests (lines 39-93): These tests assert `refute conn.status == 404` for allowed requests, but the backend is at `localhost:9999` (does not exist), so the status will be 502. Either:
   - Mock the backend (recommended: use a simple Plug in the test), or
   - Change assertions to `refute conn.status in [403, 404]` and accept 502 for now, or
   - Configure a test backend URL that returns 200.

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway
mix test test/gateway_test.exs --trace 2>&1 | tail -50
```

All 22 gateway tests must pass. Zero failures.

---

## TASK 3: Fix Main Module Stub and Dead Code

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/lib/http_capability_gateway.ex`
- `/var$REPOS_DIR/http-capability-gateway/test/http_capability_gateway_test.exs`
- `/var$REPOS_DIR/http-capability-gateway/lib/http_capability_gateway/policy_compiler.ex`

**Problem:**

1. `lib/http_capability_gateway.ex` is still the auto-generated Mix stub with a `hello/0` function and a doctest that says "Hello world." This is the root module of a production gateway. The `hello/0` function is meaningless.

2. `test/http_capability_gateway_test.exs` tests `hello/0` which is meaningless.

3. `PolicyCompiler.get_stealth_status_code/1` (line 272 of policy_compiler.ex) is defined but never called anywhere in the codebase. It is dead code.

**What to do:**

1. Replace the contents of `lib/http_capability_gateway.ex` with a proper root module:
   - Keep `@moduledoc` but write a real description of the gateway.
   - Remove the `hello/0` function.
   - Add a public function `version/0` that returns the version string from `mix.exs` (use `Application.spec(:http_capability_gateway, :vsn) |> to_string()`).
   - Optionally add a `policy_loaded?/0` function that checks if the policy table exists.

2. Update `test/http_capability_gateway_test.exs`:
   - Remove the `hello/0` test.
   - Remove or fix the `doctest HttpCapabilityGateway` line (doctests will fail if hello/0 example is removed).
   - Add a test for `version/0` that asserts it returns a string.

3. Remove `get_stealth_status_code/1` from `policy_compiler.ex` (line 272-274). It is dead code -- the stealth status code is handled by `get_stealth_enabled/1` and `Application.put_env` in `application.ex`.

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway
mix test test/http_capability_gateway_test.exs --trace 2>&1 | tail -10
mix compile --warnings-as-errors 2>&1 | tail -20
```

The test must pass. Compilation must succeed with no warnings about unused functions.

---

## TASK 4: Fix Example Policy and Empty config/policy.yaml

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/config/policy.yaml`
- `/var$REPOS_DIR/http-capability-gateway/examples/policy-dev.yaml`

**Problem:**

1. `config/policy.yaml` is completely empty (0 bytes of content). This is the default policy file referenced in `config/config.exs` line 13. If someone runs the gateway without setting `POLICY_PATH`, it will try to load this empty file and fail with `"Empty policy"`.

2. `examples/policy-dev.yaml` uses a DIFFERENT DSL format than what the code actually parses. The example uses:
   ```yaml
   verbs:
     GET:
       exposure: "public"
       narrative: "..."
   routes:
     - path: "^/health$"
       verbs:
         GET:
           exposure: "public"
   stealth:
     default: "limited"
     profiles:
       limited:
         unauthenticated: 405
   ```
   But the actual DSL v1 format parsed by `PolicyLoader` and `PolicyValidator` is:
   ```yaml
   dsl_version: "1"
   governance:
     global_verbs: [GET, POST]
     routes:
       - path: "/health"
         verbs: [GET]
   stealth:
     enabled: true
     status_code: 404
   ```

**What to do:**

1. Write a valid DSL v1 policy into `config/policy.yaml`. Use the same structure as `test/fixtures/test-policy.yaml` but with sensible defaults for a generic API gateway:
   ```yaml
   dsl_version: "1"
   governance:
     global_verbs:
       - GET
       - HEAD
       - OPTIONS
     routes:
       - path: "/health"
         verbs:
           - GET
       - path: "/metrics"
         verbs:
           - GET
   stealth:
     enabled: false
     status_code: 403
   ```

2. Rewrite `examples/policy-dev.yaml` to use the actual DSL v1 format. Preserve the intent (different exposure levels, narratives, stealth profiles, admin routes, user routes) but use the format the code actually parses. Add YAML comments explaining what each section does. The DSL v1 format does not support per-route exposure or narrative fields -- those are aspirational features. The example should be honest.

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway
# Validate config/policy.yaml can be loaded
mix run -e '
{:ok, policy} = HttpCapabilityGateway.PolicyLoader.load_from_file("config/policy.yaml")
:ok = HttpCapabilityGateway.PolicyValidator.validate(policy)
{:ok, _table} = HttpCapabilityGateway.PolicyCompiler.compile(policy)
IO.puts("config/policy.yaml: VALID")
'

# Validate examples/policy-dev.yaml can be loaded
mix run -e '
{:ok, policy} = HttpCapabilityGateway.PolicyLoader.load_from_file("examples/policy-dev.yaml")
:ok = HttpCapabilityGateway.PolicyValidator.validate(policy)
{:ok, _table} = HttpCapabilityGateway.PolicyCompiler.compile(policy)
IO.puts("examples/policy-dev.yaml: VALID")
'
```

Both files must load, validate, and compile without errors.

---

## TASK 5: Fix Containerfile and Add Mix Release Config

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/Containerfile`
- `/var$REPOS_DIR/http-capability-gateway/mix.exs`

**Problem:**

1. The Containerfile at line 27 copies `priv ./priv` but the `priv/` directory does not exist in the repository. This will cause the container build to fail with `COPY failed: file not found`.

2. The Containerfile at line 33 runs `mix release` but `mix.exs` does not define a `releases/0` function in the project config. Without `releases:` in the project config, `mix release` will use defaults, but it is better to be explicit. Also, the Containerfile should use `System.get_env` for runtime config but `prod.exs` uses `System.fetch_env!("POLICY_PATH")` at compile time, which will fail during `mix release` build since `POLICY_PATH` is not set during build.

3. The Containerfile uses `docker.io/hexpm/elixir:1.19.4-erlang-28.2.2-alpine-3.22.1` and `docker.io/alpine:3.22.1` as base images. Per CLAUDE.md and the user's container ecosystem standard, the base image should use `cgr.dev/chainguard/wolfi-base:latest` and the file should be called "Containerfile" (which it already is). The docker.io base images violate the standard.

4. The `docker-compose.yml` file should be renamed to `compose.yml` or at minimum reference `Containerfile` not `Dockerfile` (line 5 says `dockerfile: Containerfile` which is correct, but the file itself is called `docker-compose.yml` not `compose.yml`).

**What to do:**

1. Create the `priv/` directory (it can be empty, just needs to exist):
   ```bash
   mkdir -p /var$REPOS_DIR/http-capability-gateway/priv
   touch /var$REPOS_DIR/http-capability-gateway/priv/.gitkeep
   ```

2. Add a `releases` section to `mix.exs` project config:
   ```elixir
   releases: [
     http_capability_gateway: [
       include_executables_for: [:unix],
       applications: [runtime_tools: :permanent]
     ]
   ]
   ```

3. Fix `config/prod.exs` to not call `System.fetch_env!/1` at compile time. Instead, create `config/runtime.exs` for runtime config and move the `System.fetch_env!` calls there. The `prod.exs` should only set defaults that are known at compile time.

4. In the Containerfile, either keep the `COPY priv ./priv` line (now that priv/ exists) or make it conditional. Also, consider changing the base images to chainguard per the user's standard, but this is lower priority -- at minimum add a comment noting the deviation.

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway

# Verify priv/ exists
test -d priv && echo "priv/ exists" || echo "FAIL: priv/ missing"

# Verify mix release config
mix run -e 'IO.inspect(Mix.Project.config()[:releases])' 2>&1

# Verify prod config does not crash without POLICY_PATH
MIX_ENV=prod mix compile 2>&1 | tail -10

# If runtime.exs was created, verify it loads
MIX_ENV=prod mix run -e 'IO.puts("OK")' 2>&1
```

`MIX_ENV=prod mix compile` must succeed without requiring environment variables at compile time.

---

## TASK 6: Fix Unused Logging Functions and Wire Them Into Gateway

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/lib/http_capability_gateway/logging.ex`
- `/var$REPOS_DIR/http-capability-gateway/lib/http_capability_gateway/gateway.ex`
- `/var$REPOS_DIR/http-capability-gateway/lib/http_capability_gateway/proxy.ex`

**Problem:**
The `Logging` module defines 8 public functions but only 1 is called from production code (`log_policy_load/3`). The other 7 are dead code:
- `log_request_received/3` -- never called
- `log_access_decision/3` -- never called
- `log_backend_forward/4` -- never called
- `log_backend_response/4` -- never called
- `log_request_completed/4` -- never called
- `log_error/4` -- never called
- `log_health_check/3` -- never called

The Gateway module has its own inline `log_decision/7` private function that duplicates the purpose of `Logging.log_access_decision/3`. The Proxy module does its own `Logger.info`/`Logger.error` calls instead of using the Logging module.

**What to do:**

1. In `gateway.ex`, replace the inline `log_decision/7` private function with calls to `Logging.log_access_decision/3`. Add the `Logging` alias (it is already imported via `Application` alias but `Logging` itself is not aliased in `gateway.ex`).

2. In `gateway.ex` `handle_request/1`, add a call to `Logging.log_request_received/3` at the start of request processing.

3. In `proxy.ex` `forward/2`, replace the inline `Logger.info("Forwarding request", ...)` with `Logging.log_backend_forward/4`. Replace the `Logger.error("Backend request failed", ...)` with `Logging.log_error/4`. Add response logging with `Logging.log_backend_response/4` after receiving the backend response.

4. In `gateway.ex` health check handlers, add calls to `Logging.log_health_check/3`.

5. Ensure that after these changes, `mix compile --warnings-as-errors` succeeds (no unused function warnings for the Logging module).

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway
mix compile --warnings-as-errors 2>&1 | tail -20
# Check that Logging functions are actually called now
grep -rn "Logging\." lib/ --include="*.ex" | grep -v "^.*:#" | wc -l
# Should be >= 8 (one for each public function, at minimum)
mix test 2>&1 | tail -10
```

Compilation must succeed with zero warnings. At least 6 of the 8 `Logging` public functions must now be called from production code.

---

## TASK 7: Fix dev.exs Phoenix Config and policy_hot_reload

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/config/dev.exs`

**Problem:**

1. Line 25 of `dev.exs` sets `config :phoenix, :plug_init_mode, :runtime`. This project does NOT use Phoenix -- it uses plain Plug + Cowboy. This config line references a dependency that is not in `mix.exs` and will generate a warning or silently be ignored.

2. The `policy_hot_reload: true` config (line 12) is set in dev.exs and `policy_hot_reload: false` in test.exs, but NO CODE in the application reads or acts on this config value. It is a config for a feature that does not exist.

**What to do:**

1. Remove the `config :phoenix, :plug_init_mode, :runtime` line from `dev.exs`.

2. Either:
   - (a) Remove `policy_hot_reload` from both `dev.exs` and `test.exs` since the feature does not exist, OR
   - (b) Add a comment `# Future feature: policy hot reload (not yet implemented)` next to the config.

Option (a) is preferred -- do not configure features that do not exist.

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway
MIX_ENV=dev mix compile --warnings-as-errors 2>&1 | tail -10
grep -n "phoenix" config/dev.exs  # Should return nothing
grep -n "policy_hot_reload" config/*.exs  # Should return nothing (if removed)
```

No warnings. No reference to phoenix in dev.exs.

---

## TASK 8: Fix API Documentation to Match Actual Code

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/docs/API.md`

**Problem:**
`docs/API.md` documents functions that do not exist and has incorrect signatures:

1. **Line 208-250**: Documents `PolicyCompiler.is_verb_allowed?/2` -- this may now exist if TASK 1 is completed, but the signature and behavior should match the actual implementation.

2. **Line 254-276**: Documents `PolicyCompiler.get_stealth_config/0` -- same as above.

3. **Line 170-204**: Documents `PolicyCompiler.compile/1` as returning `:ok` -- actual return is `{:ok, table}`.

4. **Line 182-183**: Says compile creates `:gateway_rules` and `:stealth_config` ETS tables -- actual table name is `:policy_rules` and stealth is in application env, not ETS.

5. **Line 340-368**: Documents `Proxy.forward/1` with a single-argument signature -- actual signature is `forward/2` taking `(conn, rule)`.

6. **Line 385-431**: Documents `Logging.log_request/3` -- this function does not exist. The actual functions are `log_request_received/3`, `log_access_decision/3`, etc.

7. **Line 296-324**: Documents `Gateway.call/2` and claims it sets `conn.assigns.request_id` and `conn.assigns.trust_level` -- this may now be true if TASK 2 is completed.

**What to do:**

Update `docs/API.md` to match the actual code. For every function documented:
- Verify the function exists in the source
- Verify the signature matches
- Verify the return type matches
- Verify the behavior description is accurate
- Remove documentation for functions that do not exist
- Add documentation for public functions that exist but are not documented

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway
# Extract all documented function names from API.md
grep -oP '#### `\K[^`]+' docs/API.md | sort > /tmp/api-docs-funcs.txt

# Extract all public function defs from source
grep -rn "def " lib/ --include="*.ex" | grep -v "defp " | grep -v "defmodule" | sort > /tmp/actual-funcs.txt

# Manual review: every function in api-docs-funcs.txt must exist in actual-funcs.txt
cat /tmp/api-docs-funcs.txt
cat /tmp/actual-funcs.txt
```

Every function documented in API.md must exist in the source code with the documented signature.

---

## TASK 9: Add Elixir Release to mix.exs and Create config/runtime.exs

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/mix.exs`
- `/var$REPOS_DIR/http-capability-gateway/config/runtime.exs` (new file)
- `/var$REPOS_DIR/http-capability-gateway/config/prod.exs`

**Problem:**
`config/prod.exs` line 8 calls `System.fetch_env!("POLICY_PATH")` which executes at compile time. When building a release, this means `POLICY_PATH` must be set during `mix release` -- but environment variables should be read at runtime, not compile time. This is a standard Elixir release footgun.

**What to do:**

1. Create `config/runtime.exs` with runtime-only configuration:
   ```elixir
   import Config

   if config_env() == :prod do
     config :http_capability_gateway,
       policy_path: System.fetch_env!("POLICY_PATH"),
       backend_url: System.get_env("BACKEND_URL"),
       port: String.to_integer(System.get_env("PORT") || "4000"),
       trust_level_header: System.get_env("TRUST_LEVEL_HEADER") || "x-trust-level"
   end
   ```

2. Remove the `System.fetch_env!` and `System.get_env` calls from `config/prod.exs`. Replace with static defaults or remove the lines entirely (runtime.exs handles them).

3. Ensure `mix.exs` project config has `releases:` defined (may already be done in TASK 5).

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway
# Build a release without POLICY_PATH set
MIX_ENV=prod mix release 2>&1 | tail -10
# Should succeed without "POLICY_PATH not set" error

# Verify runtime.exs exists
test -f config/runtime.exs && echo "runtime.exs exists" || echo "FAIL"
```

`MIX_ENV=prod mix release` must succeed without any environment variables set.

---

## TASK 10: Update STATE.scm to Reflect Actual Status

**Files:**
- `/var$REPOS_DIR/http-capability-gateway/.machine_readable/STATE.scm`

**Problem:**
STATE.scm claims:
- `(overall-completion 95)` -- actual is closer to 60%.
- `(phase "production-ready")` -- NOT production-ready due to broken tests, missing functions, stub main module.
- `(policy-pipeline "100%")` -- the pipeline works but tests against it are broken.
- `(http-gateway "100%")` -- gateway tests are broken.
- `(mtls "100%")` -- mTLS trust extraction exists but the Certificate tuple pattern match (line 213 of gateway.ex) uses a non-standard OTP certificate record format and has never been tested.

**What to do:**

Update STATE.scm to reflect reality:
- `(overall-completion 60)` (after these tasks are done it could be 75-80%)
- `(phase "beta")` not `"production-ready"`
- `(policy-pipeline "85%")` -- works but property tests broken
- `(http-gateway "70%")` -- works but tests broken, logging not wired
- `(mtls "50%")` -- implemented but untested, cert parsing may be wrong
- Add to blockers: "Property tests call nonexistent functions", "Gateway tests have wrong assertions", "Example policy uses wrong DSL format"
- Add session entry for today's audit

**Verification:**
```bash
cd /var$REPOS_DIR/http-capability-gateway
cat .machine_readable/STATE.scm | head -30
# Verify overall-completion is 60 or similar honest number
grep "overall-completion" .machine_readable/STATE.scm
```

The completion percentage must be an honest number (50-65% range before fixes, 70-80% after fixes).

---

## FINAL VERIFICATION

After completing all tasks, run the full test suite and compilation checks:

```bash
cd /var$REPOS_DIR/http-capability-gateway

# 1. Clean compile with warnings as errors
mix clean
mix compile --warnings-as-errors 2>&1 | tail -20

# 2. Run ALL tests
mix test --trace 2>&1 | tail -50

# 3. Verify no test failures
mix test 2>&1 | grep -E "tests.*failures"

# 4. Verify policy files load correctly
mix run -e '
{:ok, p1} = HttpCapabilityGateway.PolicyLoader.load_from_file("config/policy.yaml")
:ok = HttpCapabilityGateway.PolicyValidator.validate(p1)
{:ok, _} = HttpCapabilityGateway.PolicyCompiler.compile(p1)
IO.puts("config/policy.yaml: OK")

{:ok, p2} = HttpCapabilityGateway.PolicyLoader.load_from_file("examples/policy-dev.yaml")
:ok = HttpCapabilityGateway.PolicyValidator.validate(p2)
{:ok, _} = HttpCapabilityGateway.PolicyCompiler.compile(p2)
IO.puts("examples/policy-dev.yaml: OK")

{:ok, p3} = HttpCapabilityGateway.PolicyLoader.load_from_file("test/fixtures/test-policy.yaml")
:ok = HttpCapabilityGateway.PolicyValidator.validate(p3)
{:ok, _} = HttpCapabilityGateway.PolicyCompiler.compile(p3)
IO.puts("test/fixtures/test-policy.yaml: OK")
'

# 5. Verify release builds (if TASK 5/9 completed)
MIX_ENV=prod mix release 2>&1 | tail -10

# 6. Check no dead code warnings
mix compile --warnings-as-errors 2>&1 | grep -i "unused" | wc -l
# Must be 0
```

**Expected outcome:**
- 0 compilation warnings
- 0 test failures
- All 3 policy files load, validate, and compile
- Release builds successfully
- No dead/unused function warnings
