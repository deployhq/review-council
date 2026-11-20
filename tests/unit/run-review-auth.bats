#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for the credential checks in .github/actions/review/run-review.sh
# (`--check-auth`): which Claude and Codex credentials may be combined, and
# the claude_model charset. Runs the real script under a clean env.
#
# Run: bats tests/unit/run-review-auth.bats

ACTION="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.github/actions/review"

# check [VAR=value ...]: run --check-auth with only the given variables set.
check() {
  run --separate-stderr env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" GITHUB_ACTION_PATH="$ACTION" \
    RC_AUTH_MODE="${MODE:-api_key}" "$@" bash "$ACTION/run-review.sh" --check-auth
}
fails_with() { [ "$status" -ne 0 ] && printf '%s' "$output" | grep -qF "$1"; }

@test "auth: an API key alone is accepted" {
  check ANTHROPIC_API_KEY=k
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'API key'
}

@test "auth: a Claude OAuth token alone is accepted" {
  check CLAUDE_CODE_OAUTH_TOKEN=t
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'OAuth'
}

@test "auth: an API key and an OAuth token together are refused" {
  check ANTHROPIC_API_KEY=k CLAUDE_CODE_OAUTH_TOKEN=t
  fails_with 'only one'
}

@test "auth: an OAuth token with federation IDs is refused" {
  MODE=federation check CLAUDE_CODE_OAUTH_TOKEN=t ANTHROPIC_FEDERATION_RULE_ID=r ANTHROPIC_ORGANIZATION_ID=o ANTHROPIC_SERVICE_ACCOUNT_ID=s
  fails_with 'only one'
}

@test "auth: no Claude credential is refused and names all three options" {
  check
  fails_with 'CLAUDE_CODE_OAUTH_TOKEN'
  printf '%s' "$output" | grep -qF 'ANTHROPIC_API_KEY'
}

@test "auth: an empty credential counts as not set" {
  check ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN=t
  [ "$status" -eq 0 ]
}

@test "auth: an OpenAI key and a Codex access token together are refused" {
  check ANTHROPIC_API_KEY=k CODEX_API_KEY=o CODEX_ACCESS_TOKEN=a
  fails_with 'Codex'
}

@test "auth: a Codex access token alone is accepted" {
  check ANTHROPIC_API_KEY=k CODEX_ACCESS_TOKEN=a
  [ "$status" -eq 0 ]
}

@test "auth: a valid claude_model is accepted" {
  check ANTHROPIC_API_KEY=k RC_CLAUDE_MODEL=claude-opus-5-5
  [ "$status" -eq 0 ]
  check ANTHROPIC_API_KEY=k RC_CLAUDE_MODEL='sonnet[1m]'
  [ "$status" -eq 0 ]
}

@test "auth: a claude_model with shell characters is refused" {
  check ANTHROPIC_API_KEY=k RC_CLAUDE_MODEL='opus; id'
  fails_with 'claude_model'
}

@test "auth: a multi-line claude_model is refused, and the value isn't echoed" {
  check ANTHROPIC_API_KEY=k RC_CLAUDE_MODEL="$(printf 'sonnet\nevil')"
  fails_with 'claude_model'
  ! printf '%s' "$output" | grep -qF 'evil' || return 1
}

@test "auth: a valid codex_model is accepted" {
  check ANTHROPIC_API_KEY=k RC_CODEX_MODEL=gpt-6-luna
  [ "$status" -eq 0 ]
}

@test "auth: a codex_model with shell or TOML characters is refused" {
  check ANTHROPIC_API_KEY=k RC_CODEX_MODEL='luna"; id'
  fails_with 'codex_model'
}

@test "auth: a multi-line codex_model is refused, and the value isn't echoed" {
  check ANTHROPIC_API_KEY=k RC_CODEX_MODEL="$(printf 'gpt-6-luna\nevil')"
  fails_with 'codex_model'
  ! printf '%s' "$output" | grep -qF 'evil' || return 1
}

# run_stub [VAR=value ...]: a full (non --check-auth) run with a stub `claude`
# that records Codex's config and RC_FAIL_LOG instead of reviewing.
run_stub() {
  local bin="$BATS_TEST_TMPDIR/bin" work="$BATS_TEST_TMPDIR/work"
  mkdir -p "$bin" "$work" "$BATS_TEST_TMPDIR/runner"
  cat >"$bin/claude" <<'STUB'
#!/bin/sh
cat "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null
echo "fail_log=${RC_FAIL_LOG:-}"
echo "plan_out=${RC_PLAN_OUT:-}"
echo "args=$*" >>"$HOME/claude.calls"
[ -z "${STUB_PLAN:-}" ] || printf '%s\n' "$STUB_PLAN" >"$RC_PLAN_OUT"
STUB
  chmod +x "$bin/claude"
  # macOS has no `timeout`; the stub drops its options and runs the command.
  command -v timeout >/dev/null || printf '#!/bin/sh\nwhile [ "${1#-}" != "$1" ]; do shift 2; done; shift; exec "$@"\n' >"$bin/timeout"
  chmod +x "$bin/timeout" 2>/dev/null || :
  run --separate-stderr env -i PATH="$bin:$PATH" HOME="$BATS_TEST_TMPDIR" GITHUB_ACTION_PATH="$ACTION" \
    RUNNER_TEMP="$BATS_TEST_TMPDIR/runner" RC_AUTH_MODE=api_key ANTHROPIC_API_KEY=k PR_NUMBER=1 "$@" \
    bash -c 'cd "$1" && bash "$2/run-review.sh"' _ "$work" "$ACTION"
}

@test "run: codex_model becomes Codex's default model, and the failure log is exported" {
  run_stub RC_CODEX_MODEL=gpt-6-luna
  [ "$status" -eq 0 ]
  grep -qx 'model = "gpt-6-luna"' "$BATS_TEST_TMPDIR/.codex/config.toml"
  grep -qxF "fail_log=$BATS_TEST_TMPDIR/runner/rc-failures.log" "$BATS_TEST_TMPDIR/runner/rc-run.jsonl"
}

@test "run: codex_model never overrides a model already in Codex's config" {
  mkdir -p "$BATS_TEST_TMPDIR/.codex"
  printf 'model = "kept"\n' >"$BATS_TEST_TMPDIR/.codex/config.toml"
  run_stub RC_CODEX_MODEL=gpt-6-luna
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/.codex/config.toml")" = 'model = "kept"' ]
}

@test "run: no codex_model leaves Codex's config alone" {
  run_stub
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/.codex/config.toml" ]
}

@test "run: codex_model goes before any table already in Codex's config (a top-level key)" {
  mkdir -p "$BATS_TEST_TMPDIR/.codex"
  printf '[mcp_servers.x]\ncommand = "y"\n' >"$BATS_TEST_TMPDIR/.codex/config.toml"
  run_stub RC_CODEX_MODEL=gpt-6-luna
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$BATS_TEST_TMPDIR/.codex/config.toml")" = 'model = "gpt-6-luna"' ]
  grep -qx 'command = "y"' "$BATS_TEST_TMPDIR/.codex/config.toml"
}

# codex_provider ---------------------------------------------------------------

@test "auth: an unknown codex_provider is refused, and the value isn't echoed" {
  check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER="$(printf 'azure\nevil')"
  fails_with 'Unknown codex_provider'
  ! printf '%s' "$output" | grep -qF 'evil' || return 1
}

@test "auth: codex_provider openrouter with a key and an OpenRouter model ID is accepted" {
  check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o RC_CODEX_MODEL=openai/gpt-6-luna
  [ "$status" -eq 0 ]
}

@test "auth: codex_provider openrouter needs OPENROUTER_API_KEY" {
  check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER=openrouter RC_CODEX_MODEL=openai/gpt-6-luna
  fails_with 'OPENROUTER_API_KEY'
}

@test "auth: codex_provider openrouter needs codex_model" {
  check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o
  fails_with 'needs codex_model'
}

@test "auth: codex_provider openrouter refuses an OpenAI key or access token alongside" {
  check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o RC_CODEX_MODEL=openai/gpt-6-luna CODEX_API_KEY=x
  fails_with 'OPENROUTER_API_KEY'
  check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o RC_CODEX_MODEL=openai/gpt-6-luna CODEX_ACCESS_TOKEN=x
  fails_with 'OPENROUTER_API_KEY'
}

@test "auth: on OpenRouter a Claude model or a router is refused (Claude would check its own work)" {
  check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o RC_CODEX_MODEL=anthropic/claude-sonnet-5-5
  fails_with 'not allowed'
  check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o RC_CODEX_MODEL=openrouter/auto
  fails_with 'not allowed'
}

@test "auth: on OpenRouter only an OpenAI model is allowed (the Codex reviewer counts as OpenAI)" {
  for m in qwen/qwen3-coder moonshotai/kimi-k2.7-code google/gemini-3-pro deepseek/deepseek-v4 z-ai/glm-5; do
    check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o RC_CODEX_MODEL="$m"
    fails_with 'not allowed'
  done
}

@test "auth: a slash in codex_model is allowed only on OpenRouter" {
  check ANTHROPIC_API_KEY=k RC_CODEX_MODEL=openai/gpt-6-luna
  fails_with 'codex_model'
  check ANTHROPIC_API_KEY=k RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o RC_CODEX_MODEL='openai/gpt"; id'
  fails_with 'codex_model'
}

@test "run: codex_provider openrouter writes the model, the provider and its table once, as valid TOML" {
  mkdir -p "$BATS_TEST_TMPDIR/.codex"
  printf '[mcp_servers.x]\ncommand = "y"\n' >"$BATS_TEST_TMPDIR/.codex/config.toml"
  run_stub RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o RC_CODEX_MODEL=openai/gpt-6-luna
  [ "$status" -eq 0 ]
  cfg="$BATS_TEST_TMPDIR/.codex/config.toml"
  cat "$cfg"
  printf '%s' "$output" | grep -qF 'Codex provider: OpenRouter'
  # A second run (same runner) must not repeat the table.
  run_stub RC_CODEX_PROVIDER=openrouter OPENROUTER_API_KEY=o RC_CODEX_MODEL=openai/gpt-6-luna
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[model_providers\.openrouter\]' "$cfg")" -eq 1 ]
  if python3 -c 'import tomllib' 2>/dev/null; then
    python3 - "$cfg" <<'PY'
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))
assert c["model"] == "openai/gpt-6-luna", c
assert c["model_provider"] == "openrouter", c
p = c["model_providers"]["openrouter"]
assert p["base_url"] == "https://openrouter.ai/api/v1" and p["wire_api"] == "responses" and p["env_key"] == "OPENROUTER_API_KEY", p
assert c["mcp_servers"]["x"]["command"] == "y", c
PY
  fi
}

@test "run: without codex_provider no provider is written" {
  run_stub RC_CODEX_MODEL=gpt-6-luna
  [ "$status" -eq 0 ]
  ! grep -q 'model_provider' "$BATS_TEST_TMPDIR/.codex/config.toml" || return 1
}

# mode / recheck ---------------------------------------------------------------

@test "auth: an unknown mode is refused, and the value isn't echoed" {
  check ANTHROPIC_API_KEY=k RC_MODE="$(printf 'recheck\nevil')"
  fails_with 'Unknown mode'
  ! printf '%s' "$output" | grep -qF 'evil' || return 1
  check ANTHROPIC_API_KEY=k RC_MODE=recheck
  [ "$status" -eq 0 ]
  check ANTHROPIC_API_KEY=k RC_MODE=
  [ "$status" -eq 0 ]
}

@test "auth: recheck_model is checked like claude_model" {
  check ANTHROPIC_API_KEY=k RC_RECHECK_MODEL=claude-sonnet-5-5
  [ "$status" -eq 0 ]
  check ANTHROPIC_API_KEY=k RC_RECHECK_MODEL='sonnet; id'
  fails_with 'recheck_model'
  check ANTHROPIC_API_KEY=k RC_RECHECK_MODEL="$(printf 'sonnet\nevil')"
  fails_with 'recheck_model'
  ! printf '%s' "$output" | grep -qF 'evil' || return 1
}

# post_stub: a stand-in for rc-post.sh (RC_POST_BIN) whose `open` says the
# identity is unknown, so rc-recheck.sh stops before any model call.
post_stub() {
  printf '#!/bin/sh\necho "$*" >>"%s/post.calls"\n[ "$1" = open ] && echo %s\n' \
    "$BATS_TEST_TMPDIR" "'{\"head\":\"x\",\"known\":false,\"inline_ok\":true,\"inline\":[],\"outside\":[]}'" \
    >"$BATS_TEST_TMPDIR/post"
  chmod +x "$BATS_TEST_TMPDIR/post"
}

@test "run: full mode exports RC_PLAN_OUT to claude; no plan file -> no recheck" {
  post_stub
  run_stub RC_POST_BIN="$BATS_TEST_TMPDIR/post"
  [ "$status" -eq 0 ]
  grep -qxF "plan_out=$BATS_TEST_TMPDIR/runner/rc-plan.json" "$BATS_TEST_TMPDIR/runner/rc-run.jsonl"
  [ ! -e "$BATS_TEST_TMPDIR/post.calls" ]
}

@test "run: full mode runs the recheck after the run when the plan file exists, keeping claude's exit code" {
  post_stub
  run_stub RC_POST_BIN="$BATS_TEST_TMPDIR/post" STUB_PLAN='{"posted": true, "status": "clean", "block": false, "reported": []}'
  [ "$status" -eq 0 ]
  grep -qx 'open 1 RC_PR_BOT_TOKEN' "$BATS_TEST_TMPDIR/post.calls"
  grep -qF 'identity unknown' "$BATS_TEST_TMPDIR/runner/rc-recheck.md"
  run_stub RC_POST_BIN="$BATS_TEST_TMPDIR/post" STUB_PLAN='{"posted": false}'
  [ "$status" -eq 0 ]
  grep -qF 'posted no review' "$BATS_TEST_TMPDIR/runner/rc-recheck.md"
}

@test "run: a failed recheck after a full run is a warning, not a failed run" {
  printf '#!/bin/sh\nexit 7\n' >"$BATS_TEST_TMPDIR/post"
  chmod +x "$BATS_TEST_TMPDIR/post"
  run_stub RC_POST_BIN="$BATS_TEST_TMPDIR/post" STUB_PLAN='{"posted": true, "status": "clean"}'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '::warning::Review Council: the recheck of earlier comments failed'
}

@test "run: recheck mode never starts the council run and skips the Codex setup" {
  post_stub
  run_stub RC_MODE=recheck RC_POST_BIN="$BATS_TEST_TMPDIR/post" RC_CODEX_MODEL=gpt-6-luna
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/claude.calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/.codex/config.toml" ]
  [ ! -e "$BATS_TEST_TMPDIR/runner/rc-run.jsonl" ]
  grep -qx 'open 1 RC_PR_BOT_TOKEN' "$BATS_TEST_TMPDIR/post.calls"
  printf '%s' "$output" | grep -qF 'recheck exited with 0'
}
