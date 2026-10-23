#!/usr/bin/env bats
# shellcheck disable=SC2016 # backticks / $(...) in single quotes are literal on purpose
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-seat.sh — the custom-seat dispatch for the codex,
# claude and opencode agent-CLI harnesses.
#
# One fake harness (POSIX sh) is installed as codex/claude/opencode and wired
# in through RC_CODEX_BIN / RC_CLAUDE_BIN / RC_OPENCODE_BIN. Because rc-seat.sh
# runs the harness under `env -i`, the fake can NOT be steered by env vars: its
# behaviour is read from files under $CTL (a path baked into the fake at setup),
# and it records what it received (argc/argv, stdin,
# the opencode prompt attachment in its cwd, env, cwd, HOME, fd 3, a scan of
# the private dir for the key, the council-written opencode config) back into
# $CTL. The council config comes from a stub reader
# (RC_CONFIG_SH) that prints $CTL/cfg.txt. No network, no real harness, no LLM.
#
# NB (macOS /bin/bash 3.2): a `[[ ... ]]` that is not a test's last line never
# fails it, so every `[[ ]]` below carries `|| false`.
#
# Run: bats tests/unit/rc-seat.bats

ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/rc-seat.sh"
FIX="$ROOT_DIR/tests/fixtures/seat"
CANARY="canary-value-not-a-credential"

setup() {
  CTL="$BATS_TEST_TMPDIR/ctl"
  FAKEDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$CTL" "$FAKEDIR" "$BATS_TEST_TMPDIR/tmpd"
  export TMPDIR="$BATS_TEST_TMPDIR/tmpd"

  # --- fake harness ----------------------------------------------------------
  # Control files (all optional):
  #   mode            ok (default) | empty (codex: empty -o file) | raw
  #                   (claude/opencode: print $CTL/stdout verbatim) | none
  #   answer          the model's final answer (default: review-ok.md)
  #   stdout          raw stdout for mode=raw
  #   stderr          text the fake prints on stderr
  #   rc              exit code (default 0)
  #   sleep           seconds to sleep (after recording); touches `sleeping`
  #   oc_version      what `opencode --version` prints (default 1.19.0)
  #   claude_subtype  JSON .subtype (default success; non-success => is_error)
  #   claude_model    JSON .modelUsage key (default: the --model argv value)
  # Records: calls argc argv stdin attached attached_mode copy_mode env pwd
  #          priv_real files m.py home fd3 keyscan opencode.json; on
  #          --version: version_pwd version_priv
  cat >"$FAKEDIR/fake" <<FAKE_EOF
#!/bin/sh
CTL='$CTL'
CANARY='$CANARY'
FAKE_EOF
  cat >>"$FAKEDIR/fake" <<'FAKE_EOF'
name="$(basename "$0")"
if [ "${1:-}" = --version ]; then
  echo version >>"$CTL/calls"
  pwd -P >"$CTL/version_pwd"
  (cd "$(dirname "$HOME")" && pwd -P) >"$CTL/version_priv"
  cat "$CTL/oc_version" 2>/dev/null || echo 1.19.0
  exit 0
fi
echo run >>"$CTL/calls"
printf '%s\n' "$#" >"$CTL/argc"
printf '%s\n' "$@" >"$CTL/argv"
prev=""; out=""; model=""
for a; do
  [ "$prev" = -o ] && out="$a"
  if [ "$prev" = --model ] || [ "$prev" = -m ]; then model="$a"; fi
  prev="$a"
done
cat >"$CTL/stdin"
if [ -f .review-council-prompt.md ]; then
  cp .review-council-prompt.md "$CTL/attached"
  ls -l .review-council-prompt.md | cut -c1-10 >"$CTL/attached_mode"
else
  rm -f "$CTL/attached"
fi
env >"$CTL/env"
pwd -P >"$CTL/pwd"
(cd "$(dirname "$HOME")" && pwd -P) >"$CTL/priv_real"
find . -print | sort >"$CTL/files"
[ -f m.py ] && cp m.py "$CTL/m.py"
printf '%s' "$HOME" >"$CTL/home"
if ( : <&3 ) 2>/dev/null; then echo open >"$CTL/fd3"; else echo closed >"$CTL/fd3"; fi
priv="$(dirname "$HOME")"
if grep -rqF "$CANARY" "$priv" 2>/dev/null; then echo found >"$CTL/keyscan"; else echo clean >"$CTL/keyscan"; fi
if [ -f "$priv/prompt.md" ]; then ls -l "$priv/prompt.md" | cut -c1-10 >"$CTL/copy_mode"; fi
if [ -n "${OPENCODE_CONFIG:-}" ]; then cp "$OPENCODE_CONFIG" "$CTL/opencode.json"; fi
if [ -s "$CTL/sleep" ]; then
  : >"$CTL/sleeping"
  sleep "$(cat "$CTL/sleep")"
fi
[ -f "$CTL/stderr" ] && cat "$CTL/stderr" >&2
ans="$CTL/answer"
mode="$(cat "$CTL/mode" 2>/dev/null || echo ok)"
case "$name" in
  codex)
    case "$mode" in
      ok) cp "$ans" "$out" ;;
      empty)
        : >"$out"
        echo "Warning: no last agent message; wrote empty content" >&2
        ;;
    esac
    ;;
  claude)
    case "$mode" in
      raw) cat "$CTL/stdout" ;;
      ok)
        sub="$(cat "$CTL/claude_subtype" 2>/dev/null || echo success)"
        iserr=false
        [ "$sub" = success ] || iserr=true
        mu="$(cat "$CTL/claude_model" 2>/dev/null || printf '%s' "$model")"
        jq -n --rawfile r "$ans" --arg s "$sub" --argjson e "$iserr" --arg mu "$mu" \
          '{type:"result", subtype:$s, is_error:$e, result:$r, modelUsage:{($mu):{inputTokens:1}}}'
        ;;
    esac
    ;;
  opencode)
    case "$mode" in
      raw) cat "$CTL/stdout" ;;
      ok)
        jq -cn --rawfile r "$ans" '
          {type:"step_start", part:{messageID:"m1"}},
          {type:"text", part:{messageID:"m1", type:"text", text:"INTERIM: let me read the files first."}},
          {type:"tool_use", part:{messageID:"m1", tool:"read"}},
          {type:"text", part:{messageID:"m2", type:"text", text:$r}},
          {type:"step_finish", part:{messageID:"m2", reason:"stop"}}'
        ;;
    esac
    ;;
esac
exit "$(cat "$CTL/rc" 2>/dev/null || echo 0)"
FAKE_EOF
  chmod +x "$FAKEDIR/fake"
  for h in codex claude opencode; do cp "$FAKEDIR/fake" "$FAKEDIR/$h"; done
  export RC_CODEX_BIN="$FAKEDIR/codex"
  export RC_CLAUDE_BIN="$FAKEDIR/claude"
  export RC_OPENCODE_BIN="$FAKEDIR/opencode"
  cp "$FIX/review-ok.md" "$CTL/answer"

  # --- Ollama /api/tags (test hook RC_OLLAMA_TAGS_URL; curl reads file://) ---
  printf '%s\n' '{"models":[{"name":"qwen3.6:35b-a3b-coding-nvfp4"},{"name":"~vendor/Model_x.y:tag@v2-~"},{"name":"llama3:latest"}]}' >"$CTL/tags.json"
  export RC_OLLAMA_TAGS_URL="file://$CTL/tags.json"

  # --- stub config reader ----------------------------------------------------
  cat >"$BATS_TEST_TMPDIR/cfg.sh" <<CFG_EOF
#!/bin/sh
cat '$CTL/cfg.txt'
CFG_EOF
  chmod +x "$BATS_TEST_TMPDIR/cfg.sh"
  export RC_CONFIG_SH="$BATS_TEST_TMPDIR/cfg.sh"
  cat >"$CTL/cfg.txt" <<'EOF'
settings.reviewer_timeout_seconds=600
settings.claude_max_turns=100
reviewer.custom_slots=s1
reviewer.custom.s1.enabled=true
reviewer.custom.s1.source=local
reviewer.custom.s1.needs_confirm=false
reviewer.custom.s1.harness=codex
reviewer.custom.s1.provider=ollama
reviewer.custom.s1.model=qwen3.6:35b-a3b-coding-nvfp4
reviewer.custom.s1.role=reviewer
reviewer.custom.s1.api_key_env=
reviewer.custom.s1.family=Qwen
reviewer.custom.s1.distinct=true
reviewer.custom.s1.opt.timeout_minutes=
EOF

  # host vars a Claude Code session (or a CI box) would carry — must not leak
  export ANTHROPIC_API_KEY="host-secret"
  export ANTHROPIC_BASE_URL="https://leak.example/anthropic"
  export OPENAI_API_KEY="host-secret"
  export OPENROUTER_API_KEY="host-secret"
  export LANG="en_US.UTF-8"
  unset LC_ALL MY_OR_KEY RC_JQ RC_CONFIG_DIR

  # --- a tiny git repo ---------------------------------------------------------
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/sub"
  cd "$REPO" || return 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  printf 'def add(a, b):\n    return a - b\n' >m.py
  git add -A && git commit -qm one
  REPO_REAL="$(pwd -P)"

  PROMPTF="$BATS_TEST_TMPDIR/prompt.txt"
  printf 'Review this change. Reply with ### Findings and ### Overall Assessment.' >"$PROMPTF"
  OUTF="$BATS_TEST_TMPDIR/result.md"
}

# cfg_set <key> <value>: replace (or add) one reader line.
cfg_set() {
  grep -v "^$1=" "$CTL/cfg.txt" >"$CTL/cfg.tmp" || true
  printf '%s=%s\n' "$1" "$2" >>"$CTL/cfg.tmp"
  mv "$CTL/cfg.tmp" "$CTL/cfg.txt"
}

# seat <harness> <provider>: configure slot s1 (openrouter: model + key).
seat() {
  cfg_set reviewer.custom.s1.harness "$1"
  cfg_set reviewer.custom.s1.provider "$2"
  if [ "$2" = openrouter ]; then
    cfg_set reviewer.custom.s1.model qwen/qwen3-coder
    cfg_set reviewer.custom.s1.api_key_env OPENROUTER_API_KEY
    export OPENROUTER_API_KEY="$CANARY"
  fi
}

# refute_in <file> <grep-args...>: <file> must EXIST and must NOT match.
refute_in() {
  _f="$1"
  shift
  [ -f "$_f" ] || {
    echo "refute_in: missing $_f" >&2
    return 1
  }
  if grep "$@" "$_f"; then
    echo "refute_in: unexpected match in $_f: $*" >&2
    return 1
  fi
}

meta() { sed -n "s/^$1=//p" "$OUTF.meta"; }
envval() { sed -n "s/^$1=//p" "$CTL/env"; }

run_seat() {
  run --separate-stderr "$SCRIPT" s1 "$OUTF" "$@" "$PROMPTF"
}

# argv_is <expected lines...>: the recorded argv, EXACTLY (no prompt element:
# the prompt never travels on argv). Single-line elements only.
argv_is() {
  _n="$(cat "$CTL/argc")"
  _want="$(printf '%s\n' "$@")"
  _got="$(cat "$CTL/argv")"
  [ "$_n" -eq "$#" ] || {
    echo "argc $_n, want $#" >&2
    return 1
  }
  [ "$_got" = "$_want" ] || {
    printf 'argv mismatch\n--- got\n%s\n--- want\n%s\n' "$_got" "$_want" >&2
    return 1
  }
}

# stdin_is_prompt: codex/claude got the exact prompt bytes on stdin, and no
# opencode attachment was placed in their cwd.
stdin_is_prompt() {
  cmp -s "$CTL/stdin" "$PROMPTF" || {
    echo "stdin differs from the prompt file" >&2
    return 1
  }
  [ ! -e "$CTL/attached" ]
}

# attached_is_prompt: opencode got the exact prompt bytes as the attachment in
# its cwd, nothing on stdin, and the live repo was not touched.
attached_is_prompt() {
  cmp -s "$CTL/attached" "$PROMPTF" || {
    echo "attachment differs from the prompt file" >&2
    return 1
  }
  [ ! -s "$CTL/stdin" ]
  [ ! -e "$REPO/.review-council-prompt.md" ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}

# The fixed opencode message (must match OPENCODE_MSG in rc-seat.sh verbatim).
OC_MSG='Your complete task and the full review context are in the attached file .review-council-prompt.md. The attachment may be truncated, so read the WHOLE file with the read tool (in chunks, using offsets) before answering. Then follow its instructions exactly and answer in the format it specifies.'

# ===========================================================================
# Argv per harness × provider (exact)
# ===========================================================================

@test "codex + ollama: exact argv (--oss, KEY vars kept from shell commands, read-only sandbox, -o in the private dir)" {
  run_seat
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "TOOL: s1 (qwen3.6:35b-a3b-coding-nvfp4 via codex)" ]
  priv="$(dirname "$(cat "$CTL/home")")"
  argv_is exec --oss --local-provider ollama \
    -c shell_environment_policy.ignore_default_excludes=false \
    --sandbox read-only --skip-git-repo-check \
    -m qwen3.6:35b-a3b-coding-nvfp4 -o "$priv/last.txt"
  stdin_is_prompt
  [ "$(envval CODEX_HOME)" = "$priv/codex" ]
}

@test "codex + openrouter: exact argv (inline provider, -c model_provider, KEY vars kept from shell commands), key exported as OPENROUTER_API_KEY" {
  seat codex openrouter
  RC_OLLAMA_TAGS_URL="file://$BATS_TEST_TMPDIR/no-such-tags.json" run_seat
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "TOOL: s1 (qwen/qwen3-coder via codex)" ]
  priv="$(dirname "$(cat "$CTL/home")")"
  argv_is exec \
    -c "model_providers.openrouter={ name='OpenRouter', base_url='https://openrouter.ai/api/v1', wire_api='responses', env_key='OPENROUTER_API_KEY' }" \
    -c model_provider=openrouter \
    -c shell_environment_policy.ignore_default_excludes=false \
    --sandbox read-only --skip-git-repo-check -m qwen/qwen3-coder -o "$priv/last.txt"
  stdin_is_prompt
  [ "$(cat "$CTL/pwd")" = "$(cat "$CTL/priv_real")/repo" ]
  [ "$(envval CODEX_HOME)" = "$priv/codex" ]
  [ "$(envval OPENROUTER_API_KEY)" = "$CANARY" ]
  [ "$(meta status)" = complete ]
}

@test "claude + ollama: exact argv (--tools= form, --setting-sources \"\") and env" {
  seat claude ollama
  run_seat
  [ "${lines[0]}" = "TOOL: s1 (qwen3.6:35b-a3b-coding-nvfp4 via claude)" ]
  argv_is -p --tools=Read,Grep,Glob --restricted --strict-mcp-config \
    --setting-sources "" --permission-mode dontAsk --max-turns 100 \
    --no-session-persistence --output-format json --model qwen3.6:35b-a3b-coding-nvfp4
  stdin_is_prompt
  priv="$(dirname "$(cat "$CTL/home")")"
  [ "$(envval CLAUDE_CONFIG_DIR)" = "$priv/claude" ]
  [ "$(envval ANTHROPIC_BASE_URL)" = "http://127.0.0.1:11434" ]
  [ "$(envval ANTHROPIC_AUTH_TOKEN)" = ollama ]
  grep -qx 'ANTHROPIC_API_KEY=' "$CTL/env"
  [ "$(envval CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)" = 1 ]
  [ "$(envval DISABLE_TELEMETRY)" = 1 ]
  refute_in "$CTL/env" -q '^CLAUDE_CODE_EXTRA_BODY='
}

@test "claude: background/alias models are pinned to the configured model (both providers)" {
  for p in ollama openrouter; do
    seat claude "$p"
    rm -f "$CTL/env"
    run_seat
    [ "$(meta status)" = complete ]
    m="$(sed -n 's/^reviewer\.custom\.s1\.model=//p' "$CTL/cfg.txt")"
    for v in ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
      ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL; do
      [ "$(envval "$v")" = "$m" ] || {
        echo "$p: $v=[$(envval "$v")] want [$m]" >&2
        false
      }
    done
  done
}

@test "claude + openrouter: base URL, token via fd 3, data_collection deny extra body" {
  seat claude openrouter
  run_seat
  [ "${lines[0]}" = "TOOL: s1 (qwen/qwen3-coder via claude)" ]
  argv_is -p --tools=Read,Grep,Glob --restricted --strict-mcp-config \
    --setting-sources "" --permission-mode dontAsk --max-turns 100 \
    --no-session-persistence --output-format json --model qwen/qwen3-coder
  stdin_is_prompt
  [ "$(envval ANTHROPIC_BASE_URL)" = "https://openrouter.ai/api" ]
  [ "$(envval ANTHROPIC_AUTH_TOKEN)" = "$CANARY" ]
  grep -qx 'ANTHROPIC_API_KEY=' "$CTL/env"
  [ "$(envval CLAUDE_CODE_EXTRA_BODY)" = '{"provider":{"data_collection":"deny"}}' ]
  refute_in "$CTL/env" -q '^OPENROUTER_API_KEY='
}

@test "opencode + ollama: exact argv (--pure, --format json, provider/model) and isolation env" {
  seat opencode ollama
  run_seat
  [ "${lines[0]}" = "TOOL: s1 (qwen3.6:35b-a3b-coding-nvfp4 via opencode)" ]
  argv_is run --pure --format json --model ollama/qwen3.6:35b-a3b-coding-nvfp4 \
    -f .review-council-prompt.md -- "$OC_MSG"
  attached_is_prompt
  [ "$(cat "$CTL/pwd")" = "$(cat "$CTL/priv_real")/repo" ]
  priv="$(dirname "$(cat "$CTL/home")")"
  [ "$(envval OPENCODE_DISABLE_PROJECT_CONFIG)" = 1 ]
  [ "$(envval OPENCODE_CONFIG)" = "$priv/opencode.json" ]
  [ "$(envval XDG_CONFIG_HOME)" = "$priv/xdg/config" ]
  [ "$(envval XDG_DATA_HOME)" = "$priv/xdg/data" ]
  [ "$(envval XDG_CACHE_HOME)" = "$priv/xdg/cache" ]
  [ "$(envval XDG_STATE_HOME)" = "$priv/xdg/state" ]
  [ "$(head -n 1 "$CTL/calls")" = version ]
  [ "$(sed -n 2p "$CTL/calls")" = run ]
}

@test "opencode + openrouter: exact argv and key exported as OPENROUTER_API_KEY" {
  seat opencode openrouter
  run_seat
  [ "${lines[0]}" = "TOOL: s1 (qwen/qwen3-coder via opencode)" ]
  argv_is run --pure --format json --model openrouter/qwen/qwen3-coder \
    -f .review-council-prompt.md -- "$OC_MSG"
  attached_is_prompt
  [ "$(envval OPENROUTER_API_KEY)" = "$CANARY" ]
}

# ===========================================================================
# opencode config (council-written, jq-built)
# ===========================================================================

@test "opencode config (ollama): deny-by-default, read-only tools, local provider" {
  seat opencode ollama
  run_seat
  c="$CTL/opencode.json"
  jq -e . "$c" >/dev/null
  [ "$(jq -r '."$schema"' "$c")" = "https://opencode.ai/config.json" ]
  [ "$(jq -r .autoupdate "$c")" = false ]
  [ "$(jq -r .share "$c")" = disabled ]
  [ "$(jq -c .enabled_providers "$c")" = '["ollama"]' ]
  [ "$(jq -r .model "$c")" = ollama/qwen3.6:35b-a3b-coding-nvfp4 ]
  [ "$(jq -r .small_model "$c")" = ollama/qwen3.6:35b-a3b-coding-nvfp4 ]
  [ "$(jq -c .permission "$c")" = '{"*":"deny","read":"allow","grep":"allow","glob":"allow","list":"allow","external_directory":"deny"}' ]
  [ "$(jq -c .provider "$c")" = '{"ollama":{"npm":"@ai-sdk/openai-compatible","name":"Ollama","options":{"baseURL":"http://127.0.0.1:11434/v1"},"models":{"qwen3.6:35b-a3b-coding-nvfp4":{}}}}' ]
}

@test "opencode config (openrouter): data_collection deny on the model, no key in it" {
  seat opencode openrouter
  run_seat
  c="$CTL/opencode.json"
  [ "$(jq -c .enabled_providers "$c")" = '["openrouter"]' ]
  [ "$(jq -c .provider "$c")" = '{"openrouter":{"models":{"qwen/qwen3-coder":{"options":{"provider":{"data_collection":"deny"}}}}}}' ]
  [ "$(jq -r .permission.bash "$c")" = null ]
  [ "$(jq -r '.permission."*"' "$c")" = deny ]
  refute_in "$c" -qF "$CANARY"
}

@test "opencode config: a model slug with every allowed odd char still yields valid JSON" {
  seat opencode ollama
  cfg_set reviewer.custom.s1.model '~vendor/Model_x.y:tag@v2-~'
  run_seat
  [ "$(jq -r .model "$CTL/opencode.json")" = 'ollama/~vendor/Model_x.y:tag@v2-~' ]
  [ "$(jq -r '.provider.ollama.models | keys[0]' "$CTL/opencode.json")" = '~vendor/Model_x.y:tag@v2-~' ]
}

@test "opencode minimum version: older than 1.19.0 or unparseable -> SKIPPED, only --version invoked" {
  for v in 1.18.9 0.99.99 garbage v1.20.0 1.20.0-beta 1..2; do
    seat opencode ollama
    rm -f "$CTL/calls"
    echo "$v" >"$CTL/oc_version"
    run_seat
    [ "$status" -eq 0 ]
    [ "$output" = "SKIPPED: s1 (opencode) unavailable — opencode: opencode $v is older than the minimum tested version 1.19.0" ] || {
      echo "$v: $output" >&2
      false
    }
    [ "$(cat "$CTL/calls")" = version ]
    [ "$(meta status)" = skipped ]
    [ "$(meta harness)" = opencode ]
  done
}

@test "opencode minimum version: an empty --version -> SKIPPED, only --version invoked" {
  seat opencode ollama
  printf '\n' >"$CTL/oc_version"
  run_seat
  [ "$output" = "SKIPPED: s1 (opencode) unavailable — opencode: opencode unknown is older than the minimum tested version 1.19.0" ]
  [ "$(cat "$CTL/calls")" = version ]
}

@test "opencode minimum version: 1.19.0 and every newer version run" {
  for v in 1.19.0 1.19.3 1.20.0 2.0.0 1.19.10; do
    seat opencode ollama
    rm -f "$CTL/calls"
    echo "$v" >"$CTL/oc_version"
    run_seat
    [ "$status" -eq 0 ]
    [ "$(meta status)" = complete ] || {
      echo "$v: $output" >&2
      false
    }
    [ "$(head -n 1 "$CTL/calls")" = version ]
    [ "$(sed -n 2p "$CTL/calls")" = run ]
  done
}

@test "opencode --version probe runs with cwd = the private dir, never the reviewed repo" {
  seat opencode ollama
  echo 1.18.9 >"$CTL/oc_version" # skip right after the probe
  cd "$REPO/sub"
  run_seat
  [ "$(cat "$CTL/calls")" = version ]
  vp="$(cat "$CTL/version_pwd")"
  [ "$vp" = "$(cat "$CTL/version_priv")" ]
  case "$vp" in */rc-seat-priv.*) ;; *) false ;; esac
  case "$vp" in "$REPO_REAL" | "$REPO_REAL"/*) false ;; esac
}

# ===========================================================================
# Ollama: the model must already be pulled (no harness ever pulls one)
# ===========================================================================

@test "ollama: model present in /api/tags -> runs (every harness)" {
  for h in codex claude opencode; do
    seat "$h" ollama
    rm -f "$CTL/calls"
    run_seat
    [ "$(meta status)" = complete ]
    grep -qx run "$CTL/calls"
  done
}

@test "ollama: model absent from /api/tags -> SKIPPED with the pull hint, no harness binary run" {
  for h in codex claude opencode; do
    seat "$h" ollama
    cfg_set reviewer.custom.s1.model rc-not-pulled:1b
    rm -f "$CTL/calls"
    run_seat
    [ "$status" -eq 0 ]
    [ "$output" = "SKIPPED: s1 ($h) unavailable — $h: model not pulled in Ollama: rc-not-pulled:1b (run: ollama pull rc-not-pulled:1b)" ]
    [ "$(meta status)" = skipped ]
    [ ! -e "$CTL/calls" ]
  done
}

@test "ollama: exact name match only (a prefix / other tag does not count)" {
  cfg_set reviewer.custom.s1.model qwen3.6
  run_seat
  [[ "$output" == *"model not pulled in Ollama: qwen3.6 "* ]] || false
  cfg_set reviewer.custom.s1.model qwen3.6:35b
  run_seat
  [[ "$output" == *"model not pulled in Ollama: qwen3.6:35b "* ]] || false
  cfg_set reviewer.custom.s1.model llama3:8b
  run_seat
  [[ "$output" == *"model not pulled in Ollama: llama3:8b "* ]] || false
  [ ! -e "$CTL/calls" ]
}

@test "ollama: an untagged slug matches <slug>:latest; argv keeps the configured slug" {
  cfg_set reviewer.custom.s1.model llama3
  run_seat
  [ "$(meta status)" = complete ]
  grep -A1 -x -- -m "$CTL/argv" | tail -n 1 | grep -qx llama3
}

@test "ollama: /api/tags unreachable or not JSON -> SKIPPED ollama not reachable, no harness run" {
  for h in codex claude opencode; do
    seat "$h" ollama
    RC_OLLAMA_TAGS_URL="file://$BATS_TEST_TMPDIR/no-such-tags.json" run_seat
    [ "$output" = "SKIPPED: s1 ($h) unavailable — $h: ollama not reachable" ]
    [ ! -e "$CTL/calls" ]
  done
  printf 'not json\n' >"$CTL/tags.json"
  run_seat
  [ "$output" = "SKIPPED: s1 (opencode) unavailable — opencode: ollama not reachable" ]
  [ ! -e "$CTL/calls" ]
}

@test "ollama: the default tags URL is the local Ollama (127.0.0.1:11434), queried with a 5s cap" {
  unset RC_OLLAMA_TAGS_URL
  mkdir -p "$BATS_TEST_TMPDIR/curlwrap"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >%s\nexit 7\n' "$CTL/curl_argv" >"$BATS_TEST_TMPDIR/curlwrap/curl"
  chmod +x "$BATS_TEST_TMPDIR/curlwrap/curl"
  PATH="$BATS_TEST_TMPDIR/curlwrap:$PATH" run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: ollama not reachable" ]
  grep -qx 'http://127.0.0.1:11434/api/tags' "$CTL/curl_argv"
  grep -A1 -x -- --max-time "$CTL/curl_argv" | tail -n 1 | grep -qx 5
  [ ! -e "$CTL/calls" ]
}

@test "openrouter seats never query Ollama" {
  seat claude openrouter
  RC_OLLAMA_TAGS_URL="file://$BATS_TEST_TMPDIR/no-such-tags.json" run_seat
  [ "$(meta status)" = complete ]
}

# ===========================================================================
# env allowlist, key handling, fd 3
# ===========================================================================

@test "env allowlist: only intended vars reach each harness; host secrets never do" {
  for h in codex claude opencode; do
    seat "$h" ollama
    rm -f "$CTL/env"
    run_seat
    [ "$status" -eq 0 ]
    refute_in "$CTL/env" -q 'host-secret'
    refute_in "$CTL/env" -q 'leak.example'
    refute_in "$CTL/env" -q '^OPENAI_'
    refute_in "$CTL/env" -q '^OPENROUTER_API_KEY='
    # shell-created vars (PWD/SHLVL/_/OLDPWD) are not inherited, just set by sh
    got="$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$CTL/env" |
      grep -vxE 'PWD|OLDPWD|SHLVL|_' | sort | tr '\n' ' ')"
    case "$h" in
      codex) want="CODEX_HOME HOME LANG PATH TMPDIR " ;;
      claude) want="ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CONFIG_DIR DISABLE_TELEMETRY HOME LANG PATH TMPDIR " ;;
      opencode) want="HOME LANG OPENCODE_CONFIG OPENCODE_DISABLE_PROJECT_CONFIG PATH TMPDIR XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME " ;;
    esac
    [ "$got" = "$want" ] || {
      echo "$h env: got [$got] want [$want]" >&2
      false
    }
  done
}

@test "HOME and TMPDIR are inside the private dir (rc-seat-priv.*)" {
  run_seat
  home="$(cat "$CTL/home")"
  priv="$(dirname "$home")"
  case "$priv" in "$TMPDIR"/rc-seat-priv.*) ;; *) false ;; esac
  [ "$home" = "$priv/home" ]
  [ "$(envval TMPDIR)" = "$priv/tmp" ]
}

@test "openrouter: a custom api_key_env is read by name; only the harness var carries it" {
  seat opencode openrouter
  unset OPENROUTER_API_KEY
  cfg_set reviewer.custom.s1.api_key_env MY_OR_KEY
  export MY_OR_KEY="$CANARY"
  run_seat
  [ "${lines[0]}" = "TOOL: s1 (qwen/qwen3-coder via opencode)" ]
  [ "$(envval OPENROUTER_API_KEY)" = "$CANARY" ]
  refute_in "$CTL/env" -q '^MY_OR_KEY='
}

@test "key never in argv and never in any file under the private dir (every harness)" {
  # wrap `env` so the WHOLE launch argv (env -i <allowlist> sh -c <shim> ...)
  # is recorded too, not just what the harness itself received
  mkdir -p "$BATS_TEST_TMPDIR/envwrap"
  real_env="$(command -v env)"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >>%s\nexec %s "$@"\n' \
    "$CTL/env_argv" "$real_env" >"$BATS_TEST_TMPDIR/envwrap/env"
  chmod +x "$BATS_TEST_TMPDIR/envwrap/env"
  export PATH="$BATS_TEST_TMPDIR/envwrap:$PATH"
  for h in codex claude opencode; do
    seat "$h" openrouter
    rm -f "$CTL/argv" "$CTL/keyscan" "$CTL/env_argv"
    run_seat
    [ "$status" -eq 0 ]
    [ "$(meta status)" = complete ]
    grep -qx -- -i "$CTL/env_argv"
    refute_in "$CTL/env_argv" -qF "$CANARY"
    refute_in "$CTL/argv" -qF "$CANARY"
    [ "$(cat "$CTL/keyscan")" = clean ]
    refute_in "$OUTF" -qF "$CANARY"
    refute_in "$OUTF.meta" -qF "$CANARY"
  done
}

@test "fd 3 is closed in the harness (openrouter key pipe and ollama)" {
  seat claude openrouter
  run_seat
  [ "$(cat "$CTL/fd3")" = closed ]
  seat codex openrouter
  run_seat
  [ "$(cat "$CTL/fd3")" = closed ]
  seat codex ollama
  run_seat
  [ "$(cat "$CTL/fd3")" = closed ]
}

@test "openrouter: key env var unset -> SKIPPED before any harness call" {
  seat claude openrouter
  unset OPENROUTER_API_KEY
  run_seat
  [ "$output" = "SKIPPED: s1 (claude) unavailable — claude: OPENROUTER_API_KEY not set" ]
  [ ! -e "$CTL/calls" ]
}

@test "invalid api_key_env -> SKIPPED" {
  seat claude openrouter
  cfg_set reviewer.custom.s1.api_key_env 'X;rm'
  run_seat
  [ "$output" = "SKIPPED: s1 (claude) unavailable — claude: invalid api_key_env" ]
  [ ! -e "$CTL/calls" ]
}

# ===========================================================================
# needs_confirm lock
# ===========================================================================

@test "needs_confirm=true without --confirmed -> SKIPPED, no binary ever invoked" {
  for h in codex claude opencode; do
    seat "$h" openrouter
    cfg_set reviewer.custom.s1.needs_confirm true
    run_seat
    [ "$output" = "SKIPPED: s1 ($h) unavailable — $h: not confirmed by the operator" ]
    [ ! -e "$CTL/calls" ]
    [ "$(meta status)" = skipped ]
  done
}

@test "needs_confirm=true with --confirmed -> runs" {
  seat opencode openrouter
  cfg_set reviewer.custom.s1.needs_confirm true
  run_seat --confirmed
  [ "${lines[0]}" = "TOOL: s1 (qwen/qwen3-coder via opencode)" ]
  grep -qx run "$CTL/calls"
}

# ===========================================================================
# Output parsing per harness
# ===========================================================================

@test "codex: result = TOOL line + the -o answer; meta complete with findings count" {
  run_seat
  [ "$(head -n 1 "$OUTF")" = "TOOL: s1 (qwen3.6:35b-a3b-coding-nvfp4 via codex)" ]
  [ "$(tail -n +2 "$OUTF")" = "$(cat "$FIX/review-ok.md")" ]
  [ "$(cat "$OUTF")" = "$output" ]
  [ "$(meta status)" = complete ]
  [ "$(meta harness)" = codex ]
  [ "$(meta family)" = Qwen ]
  [ "$(meta distinct)" = true ]
  [ "$(meta role)" = reviewer ]
  [ "$(meta model_check)" = argv ]
  [ "$(meta findings)" = 2 ]
  refute_in "$OUTF.meta" -q '^reason='
  refute_in "$OUTF.meta" -q '^coverage'
}

@test "meta: exactly the documented keys (complete and skipped)" {
  run_seat
  [ "$(cut -d= -f1 "$OUTF.meta" | tr '\n' ' ')" = "status harness family distinct role model_check findings " ]
  cfg_set reviewer.custom.s1.enabled false
  run_seat
  [ "$(cut -d= -f1 "$OUTF.meta" | tr '\n' ' ')" = "status harness family distinct role model_check findings reason " ]
  [ "$(meta reason)" = "slot disabled" ]
}

@test "codex: empty -o file -> SKIPPED no final answer (transcript never used)" {
  echo empty >"$CTL/mode"
  # the transcript echoes the prompt and even a review-shaped text: ignored
  printf 'user\n### Findings\n### Overall Assessment\n' >"$CTL/stderr"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: no final answer from the model" ]
  [ "$(meta findings)" = 0 ]
}

@test "codex: a prompt echo mentioning 401 is not misread as an auth failure" {
  echo empty >"$CTL/mode"
  printf 'user\nfix: handle HTTP 401 Unauthorized and 429 rate limit\n' >"$CTL/stderr"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: no final answer from the model" ]
}

@test "claude: real JSON sample -> .result is the answer, model_check reported" {
  seat claude ollama
  echo raw >"$CTL/mode"
  cp "$FIX/claude-result-real.json" "$CTL/stdout"
  run_seat
  [ "${lines[0]}" = "TOOL: s1 (qwen3.6:35b-a3b-coding-nvfp4 via claude)" ]
  [ "$(tail -n +2 "$OUTF")" = "$(jq -r .result "$FIX/claude-result-real.json")" ]
  [ "$(meta model_check)" = reported ]
  [ "$(meta family)" = Qwen ]
  [ "$(meta distinct)" = true ]
}

@test "claude: error subtype (error_max_turns) -> SKIPPED with that subtype" {
  seat claude ollama
  echo error_max_turns >"$CTL/claude_subtype"
  run_seat
  [ "$output" = "SKIPPED: s1 (claude) unavailable — claude: error_max_turns" ]
  [ "$(meta reason)" = error_max_turns ]
}

@test "claude: is_error with a 401 in .result -> SKIPPED auth failure" {
  seat claude openrouter
  echo raw >"$CTL/mode"
  printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"result":"API Error: 401 {\"error\":{\"message\":\"User not found.\"}}","modelUsage":{}}' >"$CTL/stdout"
  run_seat
  [ "$output" = "SKIPPED: s1 (claude) unavailable — claude: auth failure" ]
}

@test "claude: model mismatch in .modelUsage -> findings kept, family unknown, distinct false" {
  seat claude ollama
  echo claude-haiku-4-5 >"$CTL/claude_model"
  run_seat
  [ "${lines[0]}" = "TOOL: s1 (qwen3.6:35b-a3b-coding-nvfp4 via claude)" ]
  [ "$(meta status)" = complete ]
  [ "$(meta family)" = unknown ]
  [ "$(meta distinct)" = false ]
  [ "$(meta model_check)" = reported ]
  [ "$(meta findings)" = 2 ]
  [[ "$stderr" == *"not the configured 'qwen3.6:35b-a3b-coding-nvfp4'"* ]] || false
}

@test "claude: real JSON + an extra claude-haiku-* key in .modelUsage -> findings kept, family unknown" {
  seat claude ollama
  echo raw >"$CTL/mode"
  jq '.modelUsage["claude-haiku-4-5-20251001"] = {inputTokens: 12, outputTokens: 3}' \
    "$FIX/claude-result-real.json" >"$CTL/stdout"
  run_seat
  [ "${lines[0]}" = "TOOL: s1 (qwen3.6:35b-a3b-coding-nvfp4 via claude)" ]
  [ "$(tail -n +2 "$OUTF")" = "$(jq -r .result "$FIX/claude-result-real.json")" ]
  [ "$(meta status)" = complete ]
  [ "$(meta family)" = unknown ]
  [ "$(meta distinct)" = false ]
  [ "$(meta model_check)" = reported ]
  [[ "$stderr" == *"claude-haiku-4-5-20251001"* ]] || false
  [[ "$stderr" == *"not the configured 'qwen3.6:35b-a3b-coding-nvfp4'"* ]] || false
}

@test "claude: empty .modelUsage -> family unknown (nothing proves the model ran)" {
  seat claude ollama
  echo raw >"$CTL/mode"
  jq '.modelUsage = {}' "$FIX/claude-result-real.json" >"$CTL/stdout"
  run_seat
  [ "$(meta status)" = complete ]
  [ "$(meta family)" = unknown ]
  [ "$(meta distinct)" = false ]
}

@test "claude: non-JSON stdout -> SKIPPED invalid output (not JSON)" {
  seat claude ollama
  echo raw >"$CTL/mode"
  printf '### Findings\n### Overall Assessment\n' >"$CTL/stdout"
  run_seat
  [ "$output" = "SKIPPED: s1 (claude) unavailable — claude: invalid output (not JSON)" ]
}

@test "opencode: real event sample -> final text part, model_check argv" {
  seat opencode ollama
  echo raw >"$CTL/mode"
  cp "$FIX/opencode-events-real.jsonl" "$CTL/stdout"
  run_seat
  [ "${lines[0]}" = "TOOL: s1 (qwen3.6:35b-a3b-coding-nvfp4 via opencode)" ]
  [ "$(tail -n +2 "$OUTF")" = "$(jq -r 'select(.type=="text") | .part.text' "$FIX/opencode-events-real.jsonl")" ]
  [ "$(meta model_check)" = argv ]
}

@test "opencode: interim text before tool calls is not part of the answer" {
  seat opencode ollama
  run_seat
  [ "$(meta status)" = complete ]
  refute_in "$OUTF" -q INTERIM
  [ "$(tail -n +2 "$OUTF")" = "$(cat "$FIX/review-ok.md")" ]
}

@test "opencode: error event 'Cannot connect to API' (ollama) -> ollama not reachable" {
  seat opencode ollama
  echo raw >"$CTL/mode"
  echo 1 >"$CTL/rc"
  printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"Cannot connect to API: Unable to connect. Is the computer able to access the url?","metadata":{"url":"http://127.0.0.1:11434/v1/chat/completions"}}}}' >"$CTL/stdout"
  run_seat
  [ "$output" = "SKIPPED: s1 (opencode) unavailable — opencode: ollama not reachable" ]
}

# ===========================================================================
# Failure classification
# ===========================================================================

@test "invalid output: an answer without Findings/Overall Assessment headings -> SKIPPED" {
  printf 'Looks fine to me. Findings are in the attached doc.\n' >"$CTL/answer"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: invalid output (no Findings/Overall Assessment)" ]
}

@test "codex ERROR 401 -> auth failure; 402 -> out of credit; 429 -> rate limited" {
  echo none >"$CTL/mode"
  echo 1 >"$CTL/rc"
  echo 'ERROR: unexpected status 401 Unauthorized: User not found., url: https://openrouter.ai/api/v1/responses' >"$CTL/stderr"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: auth failure" ]
  echo 'ERROR: unexpected status 402 Payment Required: Insufficient credits' >"$CTL/stderr"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: out of credit" ]
  echo 'ERROR: unexpected status 429 Too Many Requests' >"$CTL/stderr"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: rate limited" ]
}

@test "codex --oss with no Ollama server -> ollama not reachable" {
  echo none >"$CTL/mode"
  echo 1 >"$CTL/rc"
  echo 'Error: OSS setup failed: No running Ollama server detected. Start it with: `ollama serve`' >"$CTL/stderr"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: ollama not reachable" ]
}

@test "claude stderr ECONNREFUSED (ollama) -> ollama not reachable" {
  seat claude ollama
  echo raw >"$CTL/mode"
  : >"$CTL/stdout"
  echo 1 >"$CTL/rc"
  echo 'API Error: Unable to connect to API (ECONNREFUSED)' >"$CTL/stderr"
  run_seat
  [ "$output" = "SKIPPED: s1 (claude) unavailable — claude: ollama not reachable" ]
}

@test "a valid answer wins even when the harness exits non-zero" {
  echo 1 >"$CTL/rc"
  run_seat
  [ "$(meta status)" = complete ]
  [[ "$stderr" == *"codex exited 1; using its final answer anyway"* ]] || false
}

@test "timeout (reviewer_timeout_seconds=1, harness sleeps) -> SKIPPED timed out" {
  # openrouter: an ollama seat's default cap is 1200 s, not reviewer_timeout_seconds
  seat codex openrouter
  cfg_set settings.reviewer_timeout_seconds 1
  echo 10 >"$CTL/sleep"
  run_seat
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: timed out after 1s" ]
  [ "$(meta status)" = skipped ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "cap (openrouter): opt.timeout_minutes x 60 wins over reviewer_timeout_seconds; default 600" {
  seat codex openrouter
  cfg_set reviewer.custom.s1.opt.timeout_minutes 2
  run_seat
  [[ "$stderr" == *"cap_s=120"* ]] || false
  cfg_set reviewer.custom.s1.opt.timeout_minutes ''
  cfg_set settings.reviewer_timeout_seconds 45
  run_seat
  [[ "$stderr" == *"cap_s=45"* ]] || false
  cfg_set settings.reviewer_timeout_seconds ''
  run_seat
  [[ "$stderr" == *"cap_s=600"* ]] || false
}

@test "cap (ollama): default 1200 s regardless of reviewer_timeout_seconds; opt.timeout_minutes wins" {
  for h in codex claude opencode; do
    seat "$h" ollama
    cfg_set reviewer.custom.s1.opt.timeout_minutes ''
    cfg_set settings.reviewer_timeout_seconds 45
    run_seat
    [[ "$stderr" == *"provider=ollama cap_s=1200"* ]] || false
    cfg_set reviewer.custom.s1.opt.timeout_minutes 3
    run_seat
    [[ "$stderr" == *"provider=ollama cap_s=180"* ]] || false
  done
  cfg_set reviewer.custom.s1.opt.timeout_minutes 0
  run_seat
  [[ "$stderr" == *"invalid timeout_minutes; using the 20-minute local default"* ]] || false
  [[ "$stderr" == *"cap_s=1200"* ]] || false
}

@test "claude --max-turns: opt.max_turns, else settings.claude_max_turns, else 30" {
  seat claude ollama
  cfg_set reviewer.custom.s1.opt.max_turns 7
  run_seat
  grep -A1 -x -- --max-turns "$CTL/argv" | tail -n 1 | grep -qx 7
  cfg_set reviewer.custom.s1.opt.max_turns ''
  run_seat
  grep -A1 -x -- --max-turns "$CTL/argv" | tail -n 1 | grep -qx 100
  cfg_set settings.claude_max_turns ''
  run_seat
  grep -A1 -x -- --max-turns "$CTL/argv" | tail -n 1 | grep -qx 30
}

# ===========================================================================
# Interrupt + cleanup
# ===========================================================================

@test "TERM mid-run -> SKIPPED interrupted, .meta + ELAPSED written, private dir removed, exit 0" {
  echo 3 >"$CTL/sleep"
  "$SCRIPT" s1 "$OUTF" "$PROMPTF" >"$BATS_TEST_TMPDIR/so" 2>"$BATS_TEST_TMPDIR/se" &
  pid=$!
  i=0
  while [ ! -e "$CTL/sleeping" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$CTL/sleeping" ]
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(cat "$OUTF")" = "SKIPPED: s1 (codex) unavailable — codex: interrupted" ]
  [ "$(cat "$BATS_TEST_TMPDIR/so")" = "SKIPPED: s1 (codex) unavailable — codex: interrupted" ]
  [ "$(meta status)" = skipped ]
  [ "$(meta reason)" = interrupted ]
  [ "$(grep -c '^ELAPSED: [0-9][0-9]*$' "$BATS_TEST_TMPDIR/se")" -eq 1 ]
  [ ! -e "$(dirname "$(cat "$CTL/home")")" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "private dir removed on success and on every post-run SKIPPED path" {
  for h in codex claude opencode; do
    seat "$h" ollama
    rm -f "$CTL/answer.bak"
    run_seat
    [ "$(meta status)" = complete ]
    [ ! -e "$(dirname "$(cat "$CTL/home")")" ]
    [ -z "$(ls -A "$TMPDIR")" ]
  done
  printf 'no headings\n' >"$CTL/answer"
  run_seat
  [ "$(meta status)" = skipped ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "ELAPSED appears exactly once on stderr (success and skip)" {
  run_seat
  [ "$(printf '%s\n' "$stderr" | grep -c '^ELAPSED: [0-9][0-9]*$')" -eq 1 ]
  cfg_set reviewer.custom.s1.enabled false
  run_seat
  [ "$(printf '%s\n' "$stderr" | grep -c '^ELAPSED: [0-9][0-9]*$')" -eq 1 ]
}

# ===========================================================================
# Sanitisation
# ===========================================================================

@test "result sanitisation strips control, C1 and bidi chars; keeps tab/newline" {
  {
    printf '### Findings\n'
    printf -- '- `severity`: \033[31mimportant\033[0m\a\n'
    printf -- '- `issue`: evil\342\200\256txet\342\201\246x\342\201\251\342\200\217 done\302\205!\n'
    printf 'col1\tcol2\n'
    printf '### Overall Assessment\nok\n'
  } >"$CTL/answer"
  run_seat
  [ "$(meta status)" = complete ]
  [ "$(meta findings)" = 1 ]
  grep -qx -- '- `severity`: \[31mimportant\[0m' "$OUTF"
  grep -qx -- '- `issue`: eviltxetx done!' "$OUTF"
  grep -q "$(printf 'col1\tcol2')" "$OUTF"
  refute_in "$OUTF" -q "$(printf '\033')"
  refute_in "$OUTF" -q "$(printf '\a')"
  refute_in "$OUTF" -qF "$(printf '\342\200\256')"
  refute_in "$OUTF" -qF "$(printf '\342\201\246')"
}

# ===========================================================================
# Prompt handling
# ===========================================================================

@test "prompt with spaces/newlines/\$(...)/backticks/quotes/leading '-' arrives byte-for-byte, never on argv" {
  for h in codex claude opencode; do
    seat "$h" ollama
    printf -- '--dangerously-bypass-approvals-and-sandbox\nReview this.\n\nline two with  spaces\n$(touch %s/pwned) `touch %s/pwned2` "dq" '"'"'sq'"'"' ; | & * ?\n### end\n\n' \
      "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" >"$PROMPTF"
    rm -f "$CTL/argv" "$CTL/stdin" "$CTL/attached"
    run_seat
    [ "$(meta status)" = complete ] || {
      echo "$h: $output" >&2
      false
    }
    if [ "$h" = opencode ]; then attached_is_prompt; else stdin_is_prompt; fi
    refute_in "$CTL/argv" -qF -- 'dangerously-bypass'
    refute_in "$CTL/argv" -qF 'line two'
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
  done
}

@test "a 1.5 MB prompt (over Linux's 128 KB per-argument limit) reaches every harness intact" {
  head -c 1500000 /dev/zero | tr '\0' 'a' >"$PROMPTF"
  printf '\n### end TOKEN-AT-THE-END' >>"$PROMPTF"
  for h in codex claude opencode; do
    seat "$h" ollama
    rm -f "$CTL/stdin" "$CTL/attached"
    run_seat
    [ "$(meta status)" = complete ] || {
      echo "$h: $output" >&2
      false
    }
    if [ "$h" = opencode ]; then attached_is_prompt; else stdin_is_prompt; fi
    [ "$(wc -c <"$CTL/argv" | tr -d ' ')" -lt 4096 ]
  done
}

@test "the prompt copy the harness reads lives in the private dir and is user-only (0600)" {
  for h in codex claude opencode; do
    seat "$h" ollama
    rm -f "$CTL/copy_mode" "$CTL/attached_mode"
    run_seat
    [ "$(meta status)" = complete ]
    [ "$(cat "$CTL/copy_mode")" = "-rw-------" ]
    if [ "$h" = opencode ]; then [ "$(cat "$CTL/attached_mode")" = "-rw-------" ]; fi
  done
  # the private dir (and so every copy) is gone once the seat returns
  [ -z "$(find "$TMPDIR" -maxdepth 1 -name 'rc-seat-priv.*' -print)" ]
}

@test "prompt larger than 4 MB -> SKIPPED before any call" {
  head -c 4194305 /dev/zero | tr '\0' 'a' >"$PROMPTF"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: prompt too large (> 4 MB)" ]
  [ "$(meta reason)" = "prompt too large (> 4 MB)" ]
  [ ! -e "$CTL/calls" ]
}

@test "prompt of exactly 4 MB is accepted" {
  head -c 4194296 /dev/zero | tr '\0' 'a' >"$PROMPTF"
  printf '\n### end' >>"$PROMPTF"
  [ "$(wc -c <"$PROMPTF" | tr -d ' ')" -eq 4194304 ]
  run_seat
  [ "$(meta status)" = complete ]
  stdin_is_prompt
}

@test "prompt file missing / empty / whitespace-only -> SKIPPED, no call" {
  rm -f "$PROMPTF"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: prompt file missing or unreadable" ]
  : >"$PROMPTF"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: empty prompt" ]
  printf ' \n\t\n\n' >"$PROMPTF"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: empty prompt" ]
  [ ! -e "$CTL/calls" ]
}

@test "opencode: a tracked .review-council-prompt.md symlink in the repo is replaced, never written through" {
  seat opencode ollama
  printf 'outside\n' >"$BATS_TEST_TMPDIR/outside.txt"
  ln -s "$BATS_TEST_TMPDIR/outside.txt" "$REPO/.review-council-prompt.md"
  git -C "$REPO" add .review-council-prompt.md
  git -C "$REPO" commit -qm link
  run_seat
  [ "$(meta status)" = complete ]
  [ "$(cat "$BATS_TEST_TMPDIR/outside.txt")" = outside ]
  cmp -s "$CTL/attached" "$PROMPTF"
  [ -L "$REPO/.review-council-prompt.md" ]
}

# ===========================================================================
# Arguments, config, environment preconditions
# ===========================================================================

@test "cwd for the harness is a snapshot of the repo top level in the private dir, even from a subdir" {
  mkdir -p "$REPO/sub/deep"
  printf 'x = 1\n' >"$REPO/sub/deep/n.py"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm two
  cd "$REPO/sub"
  run_seat
  [ "$(meta status)" = complete ]
  [ "$(cat "$CTL/pwd")" = "$(cat "$CTL/priv_real")/repo" ]
  case "$(cat "$CTL/pwd")" in "$REPO_REAL" | "$REPO_REAL"/*) false ;; esac
  # the repo's relative layout is kept (whole tree, not just the caller's subdir)
  grep -qx './m.py' "$CTL/files"
  grep -qx './sub/deep/n.py' "$CTL/files"
  refute_in "$CTL/files" -qx './.git'
}

@test "snapshot: tracked state only — untracked .env and gitignored files never reach the harness" {
  cd "$REPO"
  printf '*.log\n' >.gitignore
  git add .gitignore && git commit -qm ignore
  for h in codex claude opencode; do
    seat "$h" ollama
    printf 'SECRET=%s\n' "$CANARY" >.env
    printf 'gitignored %s\n' "$CANARY" >debug.log
    mkdir -p sub
    printf 'untracked %s\n' "$CANARY" >sub/notes.txt
    # tracked, unstaged edit
    printf 'def add(a, b):\n    return a + b  # fixed\n' >m.py
    # staged new file + staged edit
    printf 'y = 2\n' >staged.py
    git add staged.py
    before_status="$(git status --porcelain)"
    before_refs="$(git for-each-ref)"
    before_stash="$(git stash list)"
    rm -f "$CTL/files" "$CTL/m.py"
    run_seat
    [ "$(meta status)" = complete ]
    refute_in "$CTL/files" -qxE '\./\.env|\./debug\.log|\./sub/notes\.txt'
    grep -qx './.gitignore' "$CTL/files"
    grep -qx './staged.py' "$CTL/files"
    grep -qF 'a + b  # fixed' "$CTL/m.py"
    # the live repo is untouched: no ref, no stash entry, same status
    [ "$(git status --porcelain)" = "$before_status" ]
    [ "$(git for-each-ref)" = "$before_refs" ]
    [ "$(git stash list)" = "$before_stash" ]
    [ -z "$(git stash list)" ]
    # the snapshot goes with the private dir
    [ ! -e "$(cat "$CTL/priv_real")" ]
    [ -z "$(ls -A "$TMPDIR")" ]
    # reset for the next harness
    git reset -q --hard && git clean -qfdx
  done
}

@test "snapshot: a clean tree snapshots HEAD" {
  run_seat
  [ "$(meta status)" = complete ]
  [ "$(cat "$CTL/m.py")" = "$(git -C "$REPO" show HEAD:m.py)" ]
}

@test "snapshot: repo without a HEAD commit -> SKIPPED before the harness" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  cd "$BATS_TEST_TMPDIR/empty"
  git init -q
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: could not snapshot the repo: no HEAD commit" ]
  [ ! -e "$CTL/calls" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "snapshot: a failing git stash create -> SKIPPED 'could not snapshot the repo: <git's line>'" {
  printf 'edit\n' >>"$REPO/m.py"
  chmod -R a-w "$REPO/.git/objects" # stash create must write objects
  run_seat
  chmod -R u+w "$REPO/.git/objects"
  # git's own wording differs by version, so assert the script's prefix plus
  # a non-empty git line, not git's exact text.
  case "$output" in
  "SKIPPED: s1 (codex) unavailable — codex: could not snapshot the repo: "?*) : ;;
  *) echo "unexpected: $output" && return 1 ;;
  esac
  [ ! -e "$CTL/calls" ]
}

@test "snapshot: a git failure with no stderr -> SKIPPED with the exit code" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  REAL_GIT="$(command -v git)"
  printf '#!/bin/sh\ncase " $* " in *" stash create "*) exit 3 ;; esac\nexec "%s" "$@"\n' "$REAL_GIT" >"$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: could not snapshot the repo: git stash create failed (exit 3)" ]
  [ ! -e "$CTL/calls" ]
}

@test "snapshot: a held index.lock (another seat snapshotting at once) does not fail it, and the live index is never written" {
  printf 'def add(a, b):\n    return a + b  # fixed\n' >"$REPO/m.py"
  sleep 1 && touch "$REPO/m.py" # stale stat info: a refresh must rewrite the index
  : >"$REPO/.git/index.lock"
  ix_before="$(cksum <"$REPO/.git/index")"
  run_seat
  [ -e "$REPO/.git/index.lock" ]
  rm -f "$REPO/.git/index.lock"
  [ "$(meta status)" = complete ]
  grep -qF 'a + b  # fixed' "$CTL/m.py"
  [ "$(cksum <"$REPO/.git/index")" = "$ix_before" ]
}

@test "relative result and prompt paths resolve against the caller's cwd" {
  cd "$REPO/sub"
  cp "$PROMPTF" ./p.txt
  run --separate-stderr "$SCRIPT" s1 rel-out.md p.txt
  [ "$(head -n 1 "$REPO/sub/rel-out.md")" = "TOOL: s1 (qwen3.6:35b-a3b-coding-nvfp4 via codex)" ]
  [ -f "$REPO/sub/rel-out.md.meta" ]
}

@test "not inside a git repo -> SKIPPED" {
  mkdir -p "$BATS_TEST_TMPDIR/nogit"
  cd "$BATS_TEST_TMPDIR/nogit"
  GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: not inside a git repository" ]
  [ ! -e "$CTL/calls" ]
}

@test "harness ocr -> SKIPPED (dispatched by rc-ocr.sh)" {
  cfg_set reviewer.custom.s1.harness ocr
  run_seat
  [ "$output" = "SKIPPED: s1 (ocr) unavailable — ocr: harness ocr is dispatched by rc-ocr.sh" ]
  [ "$(meta harness)" = ocr ]
}

@test "unknown harness / unconfigured slot / invalid slot / bad usage -> SKIPPED, exit 0" {
  cfg_set reviewer.custom.s1.harness 'gemini$(id)'
  run_seat
  [ "$status" -eq 0 ]
  [[ "$output" == "SKIPPED: s1 (seat) unavailable — seat: unsupported harness 'gemini\$(id)'" ]] || false
  run --separate-stderr "$SCRIPT" nope "$OUTF" "$PROMPTF"
  [ "$output" = "SKIPPED: nope (seat) unavailable — seat: slot 'nope' is not configured" ]
  run --separate-stderr "$SCRIPT" 'bad slot' "$OUTF" "$PROMPTF"
  [ "$output" = "SKIPPED: custom (seat) unavailable — seat: invalid slot name" ]
  run --separate-stderr "$SCRIPT" s1 "$OUTF"
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: s1 (seat) unavailable — seat: usage: rc-seat.sh <slot> <result-file> [--confirmed] <prompt-file>" ]
  run --separate-stderr "$SCRIPT" s1 "$OUTF" --confirmed "$PROMPTF" extra
  [ "$output" = "SKIPPED: s1 (seat) unavailable — seat: usage: rc-seat.sh <slot> <result-file> [--confirmed] <prompt-file>" ]
}

@test "invalid model / disabled slot / unsupported provider -> SKIPPED, no call" {
  cfg_set reviewer.custom.s1.model 'qwen;rm -rf'
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: invalid or empty model" ]
  cfg_set reviewer.custom.s1.model qwen3
  cfg_set reviewer.custom.s1.provider anthropic
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: unsupported provider 'anthropic'" ]
  [ ! -e "$CTL/calls" ]
}

@test "harness binary missing -> SKIPPED '<harness> not installed'" {
  export RC_CLAUDE_BIN="$BATS_TEST_TMPDIR/no-such-claude"
  seat claude ollama
  run_seat
  [ "$output" = "SKIPPED: s1 (claude) unavailable — claude: claude not installed" ]
}

@test "role passes through (signal | reviewer); anything else -> signal" {
  cfg_set reviewer.custom.s1.role signal
  run_seat
  [ "$(meta role)" = signal ]
  cfg_set reviewer.custom.s1.role boss
  run_seat
  [ "$(meta role)" = signal ]
}

@test "family comes from the model slug (not the reader's family key)" {
  seat opencode openrouter
  cfg_set reviewer.custom.s1.model openai/gpt-5
  cfg_set reviewer.custom.s1.family Qwen
  run_seat
  [ "$(meta family)" = OpenAI ]
  [ "$(meta distinct)" = false ]
}

# ===========================================================================
# Provider key in the answer (OpenRouter): the seat is SKIPPED, never used
# ===========================================================================

# A key-shaped fake (64 hex chars); not a credential. Assembled at run time so
# the file never holds a literal that secret scanners take for a real key.
FAKE_OR_KEY="sk-or-v1-$(printf '%s' 0123456789abcdef 00112233445566778899aabbccddeeff 0f1e2d3c4b5a6978)"

# leak_seat <harness> <leak line>: OpenRouter seat whose answer carries <leak line>.
leak_seat() {
  seat "$1" openrouter
  export OPENROUTER_API_KEY="$FAKE_OR_KEY"
  { cat "$FIX/review-ok.md"; printf '\n%s\n' "$2"; } >"$CTL/answer"
}

@test "key check: an answer containing the key verbatim is SKIPPED and not written" {
  leak_seat codex "env: OPENROUTER_API_KEY=$FAKE_OR_KEY"
  run_seat
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: answer contained the provider key" ]
  refute_in "$OUTF" -qF "0123456789abcdef"
}

@test "key check: spaced-out, upper-cased and split key text is caught" {
  spaced="$(printf '%s' "$FAKE_OR_KEY" | tr 'a-z' 'A-Z' | sed 's/./& /g')"
  leak_seat codex "The key, one character at a time: $spaced"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: answer contained the provider key" ]
}

@test "key check: the key reversed is caught" {
  rev="$(printf '%s' "$FAKE_OR_KEY" | awk '{ r = ""; for (i = length($0); i > 0; i--) r = r substr($0, i, 1); print r }')"
  leak_seat codex "reversed: $rev"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: answer contained the provider key" ]
}

@test "key check: the key in base64 is caught" {
  leak_seat codex "b64: $(printf '%s' "$FAKE_OR_KEY" | base64 | tr -d '\n')"
  run_seat
  [ "$output" = "SKIPPED: s1 (codex) unavailable — codex: answer contained the provider key" ]
}

@test "key check: other hex (a commit SHA, a short key fragment) is not a match" {
  leak_seat codex "Introduced in 9f8e7d6c5b4a39281706f5e4d3c2b1a098765432; prefix 0123456789ab."
  run_seat
  [ "$(meta status)" = complete ]
  [ "${lines[0]}" = "TOOL: s1 (qwen/qwen3-coder via codex)" ]
}

@test "key check: applies to every OpenRouter seat (claude)" {
  leak_seat claude "$FAKE_OR_KEY"
  run_seat
  [ "$output" = "SKIPPED: s1 (claude) unavailable — claude: answer contained the provider key" ]
}

@test "key check: a failing base64 does not skip a clean answer" {
  leak_seat codex "nothing secret here"
  mkdir -p "$BATS_TEST_TMPDIR/nob64"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/nob64/base64"
  chmod +x "$BATS_TEST_TMPDIR/nob64/base64"
  PATH="$BATS_TEST_TMPDIR/nob64:$PATH" run_seat
  [ "$(meta status)" = complete ]
}
