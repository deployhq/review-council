#!/usr/bin/env bats
# shellcheck disable=SC2016 # backticks in single quotes are literal §3.1 field names
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-ocr.sh — the `ocr` custom-seat dispatch script and
# its deterministic JSON -> §3.1 mapper.
#
# A fake `ocr` (POSIX sh) stands in for the real CLI. Because rc-ocr.sh runs
# ocr under `env -i`, the fake can NOT be steered by env vars: its behaviour is
# read from files under $CTL (a path baked into the fake at setup), and it
# records what it received (argv, env, HOME, the council-written config) back
# into $CTL so tests can assert on the isolation. The council config comes from
# a stub reader (RC_CONFIG_SH) that prints $CTL/cfg.txt; one test runs the
# real scripts/rc-config.sh. No network, no real ocr, no LLM.
#
# Run: bats tests/unit/rc-ocr.bats

ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/rc-ocr.sh"
FIX="$ROOT_DIR/tests/fixtures/ocr"

setup() {
  CTL="$BATS_TEST_TMPDIR/ctl"
  FAKEDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$CTL" "$FAKEDIR" "$BATS_TEST_TMPDIR/tmpd"
  export TMPDIR="$BATS_TEST_TMPDIR/tmpd"

  # --- fake ocr ------------------------------------------------------------
  # Control files (all optional):
  #   rules_mode   "project" -> rules check reports the repo layer
  #   preview_src  fixture copied to -o for `review --preview` (default real)
  #   review_mode  fixture (default) | noout
  #   review_src   fixture copied to -o for a real `review`
  #   review_rc    exit code of a real `review` (default 0)
  #   review_sleep seconds a real `review` sleeps (after recording) before
  #                writing its output; touches `sleeping` first
  # Records: calls (one line per invocation) rules.argv preview.argv
  #          review.argv review.env home config.json rule.json fd3 stdin
  cat >"$FAKEDIR/ocr" <<FAKE_EOF
#!/bin/sh
CTL='$CTL'
FAKE_EOF
  cat >>"$FAKEDIR/ocr" <<'FAKE_EOF'
printf '%s\n' "${1:-}" >>"$CTL/calls"
if [ "${1:-}" = "--version" ]; then
  echo "open-code-review v1.12.13 (fake) darwin/arm64"
  exit 0
fi
out=""; prev=""; preview=0
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in --preview | -p) preview=1 ;; esac
  prev="$a"
done
if [ "$1" = rules ]; then
  printf '%s\n' "$@" >"$CTL/rules.argv"
  if [ "$(cat "$CTL/rules_mode" 2>/dev/null)" = project ]; then
    printf 'File: x\nSource: Project (.opencodereview/rule.json)\n'
  else
    printf 'File: x\nSource: Custom (--rule)\nPattern: **\n'
  fi
  exit 0
fi
if [ "$preview" = 1 ]; then
  printf '%s\n' "$@" >"$CTL/preview.argv"
  src="$(cat "$CTL/preview_src" 2>/dev/null)"
  cp "$src" "$out"
  exit 0
fi
printf '%s\n' "$@" >"$CTL/review.argv"
env >"$CTL/review.env"
printf '%s' "$HOME" >"$CTL/home"
cp "$HOME/.opencodereview/config.json" "$CTL/config.json"
cp "$HOME/rule.json" "$CTL/rule.json"
if ( : <&3 ) 2>/dev/null; then echo open >"$CTL/fd3"; else echo closed >"$CTL/fd3"; fi
cat >"$CTL/stdin" 2>/dev/null
if [ -s "$CTL/review_sleep" ]; then
  : >"$CTL/sleeping"
  sleep "$(cat "$CTL/review_sleep")"
fi
mode="$(cat "$CTL/review_mode" 2>/dev/null || echo fixture)"
rc="$(cat "$CTL/review_rc" 2>/dev/null || echo 0)"
case "$mode" in
  fixture) cp "$(cat "$CTL/review_src")" "$out" ;;
  noout) echo "Error: boom from the fake" >&2 ;;
esac
exit "$rc"
FAKE_EOF
  chmod +x "$FAKEDIR/ocr"
  export RC_OCR_BIN="$FAKEDIR/ocr"
  printf '%s' "$FIX/preview-real.json" >"$CTL/preview_src"
  printf '%s' "$FIX/run5-excerpt.json" >"$CTL/review_src"

  # --- stub config reader --------------------------------------------------
  cat >"$BATS_TEST_TMPDIR/cfg.sh" <<CFG_EOF
#!/bin/sh
printf '%s\n' "\$1" >'$CTL/cfg.arg'
cat '$CTL/cfg.txt'
CFG_EOF
  chmod +x "$BATS_TEST_TMPDIR/cfg.sh"
  export RC_CONFIG_SH="$BATS_TEST_TMPDIR/cfg.sh"
  cat >"$CTL/cfg.txt" <<'EOF'
settings.run_budget_seconds=600
# custom reviewers
reviewer.custom_slots=qwen
reviewer.custom.qwen.enabled=true
reviewer.custom.qwen.source=local
reviewer.custom.qwen.harness=ocr
reviewer.custom.qwen.provider=ollama
reviewer.custom.qwen.model=qwen3.6:35b-a3b-coding-nvfp4
reviewer.custom.qwen.role=signal
reviewer.custom.qwen.api_key_env=
reviewer.custom.qwen.family=Qwen
reviewer.custom.qwen.distinct=true
reviewer.custom.qwen.opt.effort=low
reviewer.custom.qwen.opt.concurrency=
reviewer.custom.qwen.opt.max_tokens_budget=0
reviewer.custom.qwen.opt.timeout_minutes=
EOF

  # host vars a Claude Code session (or a CI box) would carry — must not leak
  export ANTHROPIC_BASE_URL="https://leak.example/anthropic"
  export ANTHROPIC_AUTH_TOKEN="leak-anthropic-token"
  export AWS_SECRET_ACCESS_KEY="leak-aws-secret"
  unset OPENROUTER_API_KEY MY_OR_KEY RC_JQ RC_CONFIG_DIR

  # --- a tiny git repo with two commits -------------------------------------
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  cd "$REPO" || return 1
  git init -q
  git config user.email t@example.com
  git config user.name t
  printf 'a\n' >a.sh
  git add -A && git commit -qm one
  printf 'b\n' >>a.sh
  git add -A && git commit -qm two
  BASE="$(git rev-parse HEAD~1)"
  HEAD_SHA="$(git rev-parse HEAD)"
  OUTF="$BATS_TEST_TMPDIR/result.md"
}

# cfg_set <key> <value>: replace (or add) one reader line.
cfg_set() {
  grep -v "^$1=" "$CTL/cfg.txt" >"$CTL/cfg.tmp" || true
  printf '%s=%s\n' "$1" "$2" >>"$CTL/cfg.tmp"
  mv "$CTL/cfg.tmp" "$CTL/cfg.txt"
}

use_openrouter() {
  cfg_set reviewer.custom.qwen.provider openrouter
  cfg_set reviewer.custom.qwen.model qwen/qwen3.8-max-0902
  cfg_set reviewer.custom.qwen.api_key_env OPENROUTER_API_KEY
  export OPENROUTER_API_KEY="sk-or-test-SECRET-123"
}

# refute_in <file> <grep-args...>: <file> must EXIST and must NOT match. (A bare
# `! grep` mid-test does not fail a bats test, and a missing file would make
# grep "not match" vacuously.)
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

run_ocr() {
  run --separate-stderr "$SCRIPT" qwen "$OUTF" "$@"
}

# ===========================================================================
# Happy path: run-5 excerpt (ollama)
# ===========================================================================

@test "run-5 excerpt: TOOL line, 3 findings kept, dockerignore dropped, exit 0" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  [ "$(head -n 1 "$OUTF")" = "TOOL: qwen (ocr)" ]
  [ "$(cat "$OUTF")" = "$output" ]
  [ "$(meta status)" = complete ]
  [ "$(meta findings)" = 3 ]
  [ "$(meta dropped)" = 1 ]
  [ "$(grep -c '^#### ocr finding' "$OUTF")" -eq 3 ]
  refute_in "$OUTF" -q 'dockerignore:0'
}

@test "severity: high -> important, absent -> suggestion" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  grep -A1 '^#### ocr finding 1' "$OUTF" | grep -qx -- '- `severity`: important'
  grep -A1 '^#### ocr finding 2' "$OUTF" | grep -qx -- '- `severity`: suggestion'
}

@test "start_line 0 -> <path>:0 and symbol file-level; ranged -> L<s>-L<e>" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  grep -qx -- '- `location`: Makefile:0' "$OUTF"
  grep -A4 'location`: Makefile:0' "$OUTF" | grep -qx -- '- `symbol`: file-level'
  grep -qx -- '- `location`: docker/entrypoint.sh:369' "$OUTF"
  grep -qx -- '- `symbol`: L369-L377' "$OUTF"
}

@test "fields: confidence low, concern ocr-<category>, source slot, fixed templates" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$(grep -c -x -- '- `confidence`: low' "$OUTF")" -eq 3 ]
  grep -qx -- '- `concern`: ocr-maintainability' "$OUTF"
  grep -qx -- '- `concern`: ocr-other' "$OUTF"
  [ "$(grep -c -x -- '- `source`: qwen' "$OUTF")" -eq 3 ]
  grep -qx -- '- `recommendation`: No fix proposed by ocr — see issue.' "$OUTF"
  grep -qx -- '- `issue`: When the domain is set, the endpoint is built by appending a fixed /v1/traces path to it.' "$OUTF"
  grep -qx '### Findings' "$OUTF"
  grep -qx "### What's Good" "$OUTF"
  grep -qx 'N/A — ocr does not report positives.' "$OUTF"
  grep -qx '### Overall Assessment' "$OUTF"
}

@test "meta: complete coverage line, family, role, version" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$(meta family)" = Qwen ]
  [ "$(meta distinct)" = true ]
  [ "$(meta role)" = signal ]
  [ "$(meta ocr_version)" = v1.12.13 ]
  [ "$(meta coverage)" = "ocr v1.12.13 · qwen (qwen3.6:35b-a3b-coding-nvfp4): reviewed 23/23 selected files · 0 failed · 2 of 4 changed files excluded before review · 1 comment dropped (path not reviewed) · 0 warnings" ]
  refute_in "$OUTF.meta" -q '^reason='
}

@test "ELAPSED appears exactly once on stderr (success)" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$(printf '%s\n' "$stderr" | grep -c '^ELAPSED: [0-9][0-9]*$')" -eq 1 ]
}

# ===========================================================================
# Partial (synthetic) + severity vocabulary
# ===========================================================================

@test "partial: coverage counts completed+reused and groups failures" {
  printf '%s' "$FIX/partial-synthetic.json" >"$CTL/review_src"
  use_openrouter
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$(meta status)" = partial ]
  [ "$(meta findings)" = 6 ]
  [ "$(meta coverage)" = "ocr v1.12.13 · qwen (qwen/qwen3.8-max-0902): reviewed 3/5 selected files · 2 failed: provider (1), timeout (1) · 2 of 4 changed files excluded before review · 0 comments dropped (path not reviewed) · 1 warnings" ]
}

@test "coverage: a selected file neither completed nor reused -> partial, never complete" {
  # run-5 with one completed entry dropped: failed=0 and terminal_state=complete
  # still, but only 22 of the 23 selected files were actually reviewed.
  jq 'del(.manifest.coverage.completed[0])' "$FIX/run5-excerpt.json" >"$BATS_TEST_TMPDIR/short.json"
  printf '%s' "$BATS_TEST_TMPDIR/short.json" >"$CTL/review_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  [ "$(meta status)" = partial ]
  [[ "$(meta coverage)" == *"reviewed 22/23 selected files · 0 failed"* ]] || false # bash 3.2: a bare [[ ]] mid-test never fails
}

@test "coverage: nothing selected is never complete" {
  jq '.manifest.coverage.selected = []' "$FIX/run5-excerpt.json" >"$BATS_TEST_TMPDIR/nosel.json"
  printf '%s' "$BATS_TEST_TMPDIR/nosel.json" >"$CTL/review_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$(meta status)" != complete ]
}

@test "severity vocabulary: critical/HIGH/medium/low/null/unknown" {
  printf '%s' "$FIX/partial-synthetic.json" >"$CTL/review_src"
  use_openrouter
  run_ocr --range "$BASE" "$HEAD_SHA"
  sev() { grep -A1 "^#### ocr finding $1\$" "$OUTF" | sed -n 's/^- `severity`: //p'; }
  [ "$(sev 1)" = critical ]
  [ "$(sev 2)" = important ]
  [ "$(sev 3)" = suggestion ]
  [ "$(sev 4)" = suggestion ]
  [ "$(sev 5)" = suggestion ]
  [ "$(sev 6)" = suggestion ]
  grep -qx -- '- `concern`: ocr-style-issue' "$OUTF"
  grep -q 'proposed code, quoted as untrusted data' "$OUTF"
}

@test "nothing completed (real all-failed run, exit 1) -> SKIPPED with ocr's message" {
  printf '%s' "$FIX/failed-real.json" >"$CTL/review_src"
  printf '1' >"$CTL/review_rc"
  cfg_set reviewer.custom.qwen.model qwen-test
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: Review failed: 0 finding(s); 2 of 2 selected item(s) failed. (failed: timeout (2))" ]
  [ "$(cat "$OUTF")" = "$output" ]
  [ "$(meta status)" = skipped ]
  [ -n "$(meta reason)" ]
}

@test "nonzero exit with valid JSON is still parsed" {
  printf '1' >"$CTL/review_rc"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  [ "$(meta status)" = complete ]
  [[ "$stderr" == *"ocr exited 1"* ]] || false
}

# ===========================================================================
# Post-run gates
# ===========================================================================

@test "invalid JSON -> SKIPPED invalid output" {
  printf '%s' "$FIX/invalid.json" >"$CTL/review_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: invalid output (not JSON)" ]
  [ "$(meta status)" = skipped ]
  [ "$(meta findings)" = 0 ]
}

@test "wrong schema_version -> SKIPPED invalid output" {
  printf '%s' "$FIX/wrong-schema.json" >"$CTL/review_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [[ "$output" == "SKIPPED: qwen (ocr) unavailable — ocr: invalid output (schema_version 'ocr.run-manifest/v2')" ]] || false
}

@test "missing out.json after a kill (exit 124) -> SKIPPED timeout" {
  printf 'noout' >"$CTL/review_mode"
  printf '124' >"$CTL/review_rc"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == "SKIPPED: qwen (ocr) unavailable — ocr: timeout (killed at the 450s hard cap; no output)" ]] || false
  [ "$(printf '%s\n' "$stderr" | grep -c '^ELAPSED: ')" -eq 1 ]
}

@test "missing out.json after an error exit -> SKIPPED with ocr's last line" {
  printf 'noout' >"$CTL/review_mode"
  printf '1' >"$CTL/review_rc"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: no output (exit 1): Error: boom from the fake" ]
}

@test "execution model mismatch -> findings kept, family unknown, note" {
  printf '%s' "$FIX/model-mismatch.json" >"$CTL/review_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  [ "$(meta family)" = unknown ]
  [ "$(meta distinct)" = false ]
  [ "$(meta findings)" = 3 ]
  [[ "$stderr" == *"family set to unknown"* ]] || false
}

# ===========================================================================
# Untrusted text
# ===========================================================================

@test "hostile content: control chars stripped, fences outrun inner backticks" {
  printf '%s' "$FIX/hostile.json" >"$CTL/review_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$(meta findings)" = 1 ]
  # no ESC, BEL, CR, NUL, C1 (U+009B) or bidi override (U+202E) survives
  LC_ALL=C refute_in "$OUTF" -q "$(printf '[\033\007\015\001]')"
  refute_in "$OUTF" -q "$(printf '\302\233')"
  refute_in "$OUTF" -q "$(printf '\342\200\256')"
  # inner ```` runs are wrapped by a 5-backtick fence
  grep -qx '`````' "$OUTF"
  # the injected heading only appears inside a fence, never as a real section
  [ "$(grep -c -x '### Findings' "$OUTF")" -eq 2 ]
  awk '/^`````$/{f=!f; next} /^````$/ && !f {next} /^### Findings$/ && f {found=1} END{exit !found}' "$OUTF"
  # the issue is one line: the first sentence only
  grep -qx -- '- `issue`: Bad\[31m thing here.' "$OUTF"
}

@test "first heading occurrence is the council's, before any finding" {
  printf '%s' "$FIX/hostile.json" >"$CTL/review_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "${lines[1]}" = "### Findings" ]
}

# ===========================================================================
# Isolation
# ===========================================================================

@test "openrouter: key in ocr's env only — never argv, never config, never disk" {
  use_openrouter
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  grep -qx 'OPENROUTER_API_KEY=sk-or-test-SECRET-123' "$CTL/review.env"
  refute_in "$CTL/review.argv" -q 'SECRET-123'
  refute_in "$CTL/config.json" -q 'SECRET-123'
  [ "$(jq 'has("api_key") or (.providers.openrouter | has("api_key"))' "$CTL/config.json")" = false ]
  [ "$(cat "$CTL/fd3")" = closed ]
  [ ! -s "$CTL/stdin" ]
}

@test "openrouter: council config pins endpoint, model and data_collection deny" {
  use_openrouter
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$(jq -r .provider "$CTL/config.json")" = openrouter ]
  [ "$(jq -r .providers.openrouter.url "$CTL/config.json")" = "https://openrouter.ai/api/v1" ]
  [ "$(jq -r .providers.openrouter.model "$CTL/config.json")" = "qwen/qwen3.8-max-0902" ]
  [ "$(jq -r .providers.openrouter.extra_body.provider.data_collection "$CTL/config.json")" = deny ]
}

@test "openrouter: a custom api_key_env is read by name and exported as OPENROUTER_API_KEY" {
  use_openrouter
  unset OPENROUTER_API_KEY
  cfg_set reviewer.custom.qwen.api_key_env MY_OR_KEY
  export MY_OR_KEY="sk-or-custom-SECRET-9"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  grep -qx 'OPENROUTER_API_KEY=sk-or-custom-SECRET-9' "$CTL/review.env"
  refute_in "$CTL/review.env" -q '^MY_OR_KEY='
}

@test "env -i allowlist: host vars do not reach ocr; HOME is the temp dir" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  refute_in "$CTL/review.env" -q 'ANTHROPIC_'
  refute_in "$CTL/review.env" -q 'AWS_SECRET_ACCESS_KEY'
  refute_in "$CTL/review.env" -q 'OPENROUTER_API_KEY'
  grep -qx 'OCR_NO_UPDATE=1' "$CTL/review.env"
  home="$(cat "$CTL/home")"
  # rc-ocr-home.*, never rc-ocr.* — the orchestrator's result dirs use that
  case "$home" in "$TMPDIR"/rc-ocr-home.*) ;; *) false ;; esac
  grep -qx "TMPDIR=$home/tmp" "$CTL/review.env"
}

@test "temp HOME is removed afterwards" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  home="$(cat "$CTL/home")"
  [ -n "$home" ]
  [ ! -e "$home" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "temp HOME is removed on a SKIPPED post-run path too" {
  printf '%s' "$FIX/invalid.json" >"$CTL/review_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ ! -e "$(cat "$CTL/home")" ]
}

@test "TERM mid-run -> SKIPPED interrupted, .meta + ELAPSED written, temp HOME removed, exit 0" {
  printf '3' >"$CTL/review_sleep"
  "$SCRIPT" qwen "$OUTF" --range "$BASE" "$HEAD_SHA" \
    >"$BATS_TEST_TMPDIR/so" 2>"$BATS_TEST_TMPDIR/se" &
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
  [ "$(cat "$OUTF")" = "SKIPPED: qwen (ocr) unavailable — ocr: interrupted" ]
  [ "$(cat "$BATS_TEST_TMPDIR/so")" = "SKIPPED: qwen (ocr) unavailable — ocr: interrupted" ]
  [ "$(meta status)" = skipped ]
  [ "$(meta reason)" = interrupted ]
  [ "$(meta findings)" = 0 ]
  [ "$(grep -c '^ELAPSED: [0-9][0-9]*$' "$BATS_TEST_TMPDIR/se")" -eq 1 ]
  home="$(cat "$CTL/home")"
  [ -n "$home" ]
  [ ! -e "$home" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "neutral rule file is byte-for-byte the council's" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$(cat "$CTL/rule.json")" = '{"rules":[{"path":"**","rule":"","merge_system_rule":true}],"exclude":["__none__"]}' ]
}

@test "ollama: no key needed; non-secret placeholder + local endpoint in config" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  [ "$(jq -r .custom_providers.ollama.url "$CTL/config.json")" = "http://127.0.0.1:11434/v1" ]
  [ "$(jq -r .custom_providers.ollama.api_key "$CTL/config.json")" = ollama ]
  [ "$(jq -r .custom_providers.ollama.protocol "$CTL/config.json")" = openai ]
  [ "$(jq -c .custom_providers.ollama.models "$CTL/config.json")" = '["qwen3.6:35b-a3b-coding-nvfp4"]' ]
}

@test "argv: pinned flags present, reserved flags from config absent" {
  cat >>"$CTL/cfg.txt" <<'EOF'
reviewer.custom.qwen.flag.1=--max-tools
reviewer.custom.qwen.flag.2=80
EOF
  run_ocr --range "$BASE" "$HEAD_SHA"
  argv="$(tr '\n' ' ' <"$CTL/review.argv")"
  [[ "$argv" == "review --format json --audience agent -o "*" --rule "*"/rule.json --repo $(cd "$REPO" && pwd -P) --provider ollama --model qwen3.6:35b-a3b-coding-nvfp4 --effort low --timeout 6 --from $BASE --to $HEAD_SHA --max-tools 80 " ]] || false
  refute_in "$CTL/review.argv" -qx -- '--concurrency'
  refute_in "$CTL/review.argv" -qx -- '--max-tokens-budget'
}

@test "trusted flags with glob chars reach ocr verbatim (no pathname expansion)" {
  : >"$REPO/zz-should-not-glob"
  cat >>"$CTL/cfg.txt" <<'EOF'
reviewer.custom.qwen.flag.1=--exclude=**/gen/*,*
EOF
  run_ocr --range "$BASE" "$HEAD_SHA"
  grep -qx -- '--exclude=\*\*/gen/\*,\*' "$CTL/review.argv"
  refute_in "$CTL/review.argv" -q 'zz-should-not-glob'
}

@test "a reserved flag in the list drops the whole list (fail closed)" {
  cat >>"$CTL/cfg.txt" <<'EOF'
reviewer.custom.qwen.flag.1=--max-tools
reviewer.custom.qwen.flag.2=80
reviewer.custom.qwen.flag.3=-o/tmp/steal.json
EOF
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  refute_in "$CTL/review.argv" -q -- '--max-tools'
  refute_in "$CTL/review.argv" -q 'steal'
  [[ "$stderr" == *"ignoring all harness flags"* ]] || false
}

@test "typed options: concurrency, max_tokens_budget, effort reach argv" {
  cfg_set reviewer.custom.qwen.opt.concurrency 4
  cfg_set reviewer.custom.qwen.opt.max_tokens_budget 2000000
  cfg_set reviewer.custom.qwen.opt.effort medium
  run_ocr --range "$BASE" "$HEAD_SHA"
  grep -A1 -x -- '--concurrency' "$CTL/review.argv" | grep -qx 4
  grep -A1 -x -- '--max-tokens-budget' "$CTL/review.argv" | grep -qx 2000000
  grep -A1 -x -- '--effort' "$CTL/review.argv" | grep -qx medium
}

@test "env extras: trusted env reaches ocr; reserved names never do" {
  cat >>"$CTL/cfg.txt" <<'EOF'
reviewer.custom.qwen.env.OCR_EXTRA_KNOB=hello world
reviewer.custom.qwen.env.HOME=/evil
reviewer.custom.qwen.env.PATH=/evil
EOF
  run_ocr --range "$BASE" "$HEAD_SHA"
  grep -qx 'OCR_EXTRA_KNOB=hello world' "$CTL/review.env"
  refute_in "$CTL/review.env" -q '/evil'
}

# ===========================================================================
# Target modes
# ===========================================================================

@test "--worktree reviews a snapshot of TRACKED changes only (HEAD..stash-create), never ocr's workspace mode" {
  printf 'c\n' >>a.sh
  printf 'SECRET=1\n' >untracked.env
  run_ocr --worktree
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  # a range from HEAD to a snapshot commit — never ocr's own workspace mode
  grep -A1 -x -- '--from' "$CTL/review.argv" | grep -qx "$HEAD_SHA"
  snap="$(grep -A1 -x -- '--to' "$CTL/review.argv" | tail -n 1)"
  [ -n "$snap" ] && [ "$snap" != "$HEAD_SHA" ]
  grep -A1 -x -- '--to' "$CTL/preview.argv" | grep -qx "$snap"
  refute_in "$CTL/review.argv" -qx -- '--commit'
  # the snapshot carries the tracked change but not the untracked file
  git show "$snap:a.sh" | grep -qx c
  run git cat-file -e "$snap:untracked.env"
  [ "$status" -ne 0 ]
  # nothing moved: no stash ref, the file is still modified, the untracked file untouched
  run git stash list
  [ -z "$output" ]
  git status --porcelain | grep -q '^ M a.sh'
  [ -f untracked.env ]
}

@test "--worktree with no tracked changes -> SKIPPED, ocr never reviews" {
  printf 'SECRET=1\n' >untracked.env
  run_ocr --worktree
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: no tracked changes in the working tree" ]
  [ ! -e "$CTL/review.argv" ]
}

@test "--worktree: a failing git stash create is reported as such, not as 'no tracked changes'" {
  printf 'c\n' >>a.sh
  chmod -R a-w .git/objects # stash create must write objects: this makes it fail
  run_ocr --worktree
  chmod -R u+w .git/objects
  [ "$status" -eq 0 ]
  [[ "$output" == "SKIPPED: qwen (ocr) unavailable — ocr: git stash create failed: "* ]] || false # bash 3.2: a bare [[ ]] mid-test never fails
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [ "$(meta status)" = skipped ]
  [ ! -e "$CTL/calls" ]
}

@test "--worktree: a held index.lock (another git snapshotting at once) does not fail the snapshot, and the live index is never written" {
  printf 'c\n' >>a.sh
  sleep 1 && touch a.sh # stale stat info: a refresh must rewrite the index
  : >.git/index.lock
  ix_before="$(cksum <.git/index)"
  run_ocr --worktree
  [ -e .git/index.lock ]
  rm -f .git/index.lock
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  snap="$(grep -A1 -x -- '--to' "$CTL/review.argv" | tail -n 1)"
  git show "$snap:a.sh" | grep -qx c
  [ "$(cksum <.git/index)" = "$ix_before" ]
}

@test "--staged reviews the INDEX only (HEAD..stash^2): unstaged edits never reach ocr" {
  printf 'b\n' >b.txt
  git add b.txt && git commit -qm three
  HEAD_SHA="$(git rev-parse HEAD)"
  printf 'staged\n' >>a.sh
  git add a.sh
  printf 'UNSTAGED-SECRET\n' >>b.txt
  printf 'SECRET=1\n' >untracked.env
  wt_before="$(git diff)"
  ix_before="$(git diff --cached)"
  run_ocr --staged
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  grep -A1 -x -- '--from' "$CTL/review.argv" | grep -qx "$HEAD_SHA"
  snap="$(grep -A1 -x -- '--to' "$CTL/review.argv" | tail -n 1)"
  [ -n "$snap" ] && [ "$snap" != "$HEAD_SHA" ]
  grep -A1 -x -- '--to' "$CTL/preview.argv" | grep -qx "$snap"
  # the reviewed range carries the staged a.sh only
  [ "$(git diff --name-only "$HEAD_SHA" "$snap")" = a.sh ]
  git show "$snap:a.sh" | grep -qx staged
  run git show "$snap:b.txt"
  [ "$output" = b ]
  # nothing moved: no stash ref, HEAD, index and working tree unchanged
  run git stash list
  [ -z "$output" ]
  [ "$(git rev-parse HEAD)" = "$HEAD_SHA" ]
  [ "$(git diff)" = "$wt_before" ]
  [ "$(git diff --cached)" = "$ix_before" ]
  [ -f untracked.env ]
}

@test "--staged with only unstaged edits -> SKIPPED no staged changes, ocr never runs" {
  printf 'c\n' >>a.sh
  run_ocr --staged
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: no staged changes" ]
  [ ! -e "$CTL/calls" ]
}

@test "--staged: a failing git stash create is reported as such" {
  printf 'c\n' >>a.sh
  git add a.sh
  chmod -R a-w .git/objects
  run_ocr --staged
  chmod -R u+w .git/objects
  [[ "$output" == "SKIPPED: qwen (ocr) unavailable — ocr: git stash create failed: "* ]] || false # bash 3.2: a bare [[ ]] mid-test never fails
  [ ! -e "$CTL/calls" ]
}

@test "--staged takes no revs" {
  run_ocr --staged HEAD
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: usage: --staged takes no revs" ]
}

@test "--commit resolves the rev to a SHA for preview and review" {
  run_ocr --commit HEAD
  grep -A1 -x -- '--commit' "$CTL/review.argv" | grep -qx "$HEAD_SHA"
  grep -A1 -x -- '--commit' "$CTL/preview.argv" | grep -qx "$HEAD_SHA"
}

@test "--range resolves symbolic revs to SHAs" {
  run_ocr --range HEAD~1 HEAD
  grep -A1 -x -- '--from' "$CTL/review.argv" | grep -qx "$BASE"
  grep -A1 -x -- '--to' "$CTL/review.argv" | grep -qx "$HEAD_SHA"
}

@test "leading-dash rev -> SKIPPED, ocr never runs" {
  run_ocr --commit --output=/tmp/x
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: ref not found locally: --output=/tmp/x" ]
  [ ! -e "$CTL/review.argv" ]
}

@test "unknown rev -> SKIPPED ref not found" {
  run_ocr --range "$BASE" no-such-branch
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: ref not found locally: no-such-branch" ]
  [ "$(meta status)" = skipped ]
  [ "$(meta reason)" = "ref not found locally: no-such-branch" ]
}

@test "rules check runs on a changed path with the council rule file" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  grep -qx 'check' "$CTL/rules.argv"
  grep -A1 -x -- '--rule' "$CTL/rules.argv" | tail -n 1 | grep -q '/rule.json$'
  [ "$(tail -n 1 "$CTL/rules.argv")" = a.sh ]
}

@test "rules check reporting a non-Custom source -> SKIPPED before the run" {
  printf 'project' >"$CTL/rules_mode"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: repo rules would apply" ]
  [ ! -e "$CTL/review.argv" ]
}

@test "preview output that is not valid JSON -> SKIPPED preview failed, no run" {
  printf '%s' "$FIX/invalid.json" >"$CTL/preview_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == "SKIPPED: qwen (ocr) unavailable — ocr: preview failed (exit 0)"* ]] || false
  [ ! -e "$CTL/review.argv" ]
}

@test "a long coverage line is never truncated in .meta" {
  long="qwen/$(printf 'x%.0s' $(seq 1 120))"
  use_openrouter
  cfg_set reviewer.custom.qwen.model "$long"
  printf '%s' "$FIX/partial-synthetic.json" >"$CTL/review_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$(meta coverage | wc -c)" -gt 300 ]
  [[ "$(meta coverage)" == *"· 1 warnings" ]] || false
}

@test "preview with nothing reviewable -> SKIPPED nothing to review" {
  printf '%s' "$FIX/preview-empty.json" >"$CTL/preview_src"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: nothing to review (0 changed, 0 excluded by ocr)" ]
  [ ! -e "$CTL/review.argv" ]
}

# ===========================================================================
# Availability
# ===========================================================================

@test "missing ocr binary -> SKIPPED" {
  export RC_OCR_BIN="$BATS_TEST_TMPDIR/nope/ocr"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: ocr not installed" ]
  [ "$(meta status)" = skipped ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^ELAPSED: ')" -eq 1 ]
}

@test "missing jq -> SKIPPED" {
  export RC_JQ="$BATS_TEST_TMPDIR/nope/jq"
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: jq not installed" ]
}

@test "openrouter with the key var unset -> SKIPPED naming the var" {
  use_openrouter
  unset OPENROUTER_API_KEY
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: OPENROUTER_API_KEY not set" ]
  [ ! -e "$CTL/review.argv" ]
}

@test "unknown slot -> SKIPPED not configured" {
  run --separate-stderr "$SCRIPT" other "$OUTF" --worktree
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: other (ocr) unavailable — ocr: slot 'other' is not configured" ]
}

@test "invalid slot name -> SKIPPED, never interpolated" {
  run --separate-stderr "$SCRIPT" 'a;b' "$OUTF" --worktree
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: custom (ocr) unavailable — ocr: invalid slot name" ]
}

@test "disabled slot -> SKIPPED" {
  cfg_set reviewer.custom.qwen.enabled false
  run_ocr --worktree
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: slot disabled" ]
}

@test "needs_confirm=true without --confirmed -> SKIPPED before ocr is ever invoked" {
  cfg_set reviewer.custom.qwen.needs_confirm true
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: not confirmed by the operator" ]
  [ "$(meta status)" = skipped ]
  [ "$(meta reason)" = "not confirmed by the operator" ]
  [ ! -e "$CTL/calls" ]
}

@test "needs_confirm=true with --confirmed -> the seat runs" {
  cfg_set reviewer.custom.qwen.needs_confirm true
  run_ocr --confirmed --range "$BASE" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  [ "$(meta status)" = complete ]
  grep -A1 -x -- '--to' "$CTL/review.argv" | grep -qx "$HEAD_SHA"
}

@test "needs_confirm=false -> runs without --confirmed" {
  cfg_set reviewer.custom.qwen.needs_confirm false
  run_ocr --range "$BASE" "$HEAD_SHA"
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
}

@test "--confirmed is accepted with every mode (--worktree)" {
  cfg_set reviewer.custom.qwen.needs_confirm true
  printf 'c\n' >>a.sh
  run_ocr --confirmed --worktree
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
}

@test "bad usage -> SKIPPED, exit 0, ELAPSED once" {
  run --separate-stderr "$SCRIPT" qwen "$OUTF" --bogus
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED: qwen (ocr) unavailable — ocr: usage: unknown mode" ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^ELAPSED: ')" -eq 1 ]
}

@test "config dir defaults to .review-council and honours RC_CONFIG_DIR" {
  run_ocr --worktree
  [ "$(cat "$CTL/cfg.arg")" = .review-council ]
  RC_CONFIG_DIR=/x/y run_ocr --worktree
  [ "$(cat "$CTL/cfg.arg")" = /x/y ]
}

# ===========================================================================
# Budget
# ===========================================================================

@test "budget: default 600s run budget -> 6 min deadline, 450s hard cap" {
  run_ocr --range "$BASE" "$HEAD_SHA"
  [[ "$stderr" == *"budget deadline_min=6 rounds=1 hard_cap_s=450 llm_timeout_s=360 effort=low"* ]] || false
  grep -A1 -x -- '--timeout' "$CTL/review.argv" | grep -qx 6
  grep -qx 'OCR_LLM_TIMEOUT=360' "$CTL/review.env"
}

@test "budget: effort multiplies the hard cap by rounds" {
  cfg_set reviewer.custom.qwen.opt.effort high
  run_ocr --range "$BASE" "$HEAD_SHA"
  [[ "$stderr" == *"deadline_min=6 rounds=3 hard_cap_s=1170 "* ]] || false
}

@test "budget: timeout_minutes overrides; per-request timeout capped at 600" {
  cfg_set reviewer.custom.qwen.opt.timeout_minutes 60
  run_ocr --range "$BASE" "$HEAD_SHA"
  [[ "$stderr" == *"deadline_min=60 rounds=1 hard_cap_s=3690 llm_timeout_s=600 "* ]] || false
  grep -A1 -x -- '--timeout' "$CTL/review.argv" | grep -qx 60
}

@test "budget: derived deadline clamps at 180 min" {
  cfg_set settings.run_budget_seconds 100000
  run_ocr --range "$BASE" "$HEAD_SHA"
  [[ "$stderr" == *"deadline_min=180 rounds=1 hard_cap_s=10890 "* ]] || false
}

@test "budget: tiny run budget floors the deadline at 1 min" {
  cfg_set settings.run_budget_seconds 30
  run_ocr --range "$BASE" "$HEAD_SHA"
  [[ "$stderr" == *"deadline_min=1 rounds=1 hard_cap_s=150 llm_timeout_s=60 "* ]] || false
}

@test "budget: trusted env OCR_LLM_TIMEOUT overrides the derived per-request timeout" {
  echo 'reviewer.custom.qwen.env.OCR_LLM_TIMEOUT=900' >>"$CTL/cfg.txt"
  run_ocr --range "$BASE" "$HEAD_SHA"
  grep -qx 'OCR_LLM_TIMEOUT=900' "$CTL/review.env"
  [ "$(grep -c '^OCR_LLM_TIMEOUT=' "$CTL/review.env")" -eq 1 ]
}

# ===========================================================================
# Real reader integration
# ===========================================================================

@test "real rc-config.sh: a user-layer slot drives the run" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  yq --version 2>&1 | grep -q mikefarah || skip "yq is not mikefarah v4"
  unset RC_CONFIG_SH
  cat >"$BATS_TEST_TMPDIR/user.yml" <<'EOF'
reviewers:
  custom:
    qwen:
      harness: ocr
      provider: ollama
      model: qwen3.6:35b-a3b-coding-nvfp4
      role: reviewer
      harness_options:
        effort: medium
        concurrency: 3
        flags: ["--exclude=**/gen/*"]
EOF
  RC_USER_CONFIG="$BATS_TEST_TMPDIR/user.yml" run_ocr --range "$BASE" "$HEAD_SHA"
  [ "${lines[0]}" = "TOOL: qwen (ocr)" ]
  [ "$(meta role)" = reviewer ]
  grep -A1 -x -- '--effort' "$CTL/review.argv" | grep -qx medium
  grep -A1 -x -- '--concurrency' "$CTL/review.argv" | grep -qx 3
  grep -qx -- '--exclude=\*\*/gen/\*' "$CTL/review.argv"
}
