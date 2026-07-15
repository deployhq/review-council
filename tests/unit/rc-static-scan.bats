#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-static-scan.sh — the deterministic static-analysis
# runner (Phase 2, Step 2.5).
#
# Uses FAKE tool binaries (small POSIX sh scripts named gitleaks/trufflehog/
# osv-scanner/semgrep/ruff/… whose behavior is switched per-call via env vars),
# plus a SANDBOXED PATH ($FAKEDIR:$SYSBIN) so the eight real tools are
# deterministically ABSENT unless a fake is installed — the "not installed"
# path is then testable regardless of what the host machine happens to have.
# No network, no real scanners required.
#
# Run: bats tests/unit/rc-static-scan.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/rc-static-scan.sh"

setup() {
  FAKEDIR="$BATS_TEST_TMPDIR/fakebin"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$FAKEDIR" "$SYSBIN" "$WORK"

  # Sandbox: symlink the real coreutils the script (and run_capped, and the
  # fakes) need into $SYSBIN, resolved from the ORIGINAL PATH. The script then
  # runs under PATH=$FAKEDIR:$SYSBIN — no host PATH — so "absent" is real.
  for _c in sh env jq git grep mktemp rm wc head cat sleep timeout gtimeout \
    sort tr sed awk dirname basename kill uname date; do
    _p="$(command -v "$_c" 2>/dev/null || true)"
    if [ -n "$_p" ]; then ln -sf "$_p" "$SYSBIN/$_c"; fi
  done

  SANDBOX="$FAKEDIR:$SYSBIN"

  # Call/argv bookkeeping the fakes append to (a fake records itself here).
  CALLS="$BATS_TEST_TMPDIR/calls"
  ARGS="$BATS_TEST_TMPDIR/args"
  : >"$CALLS"
  : >"$ARGS"

  # Fake refs + a default changed-file list.
  BASE="BASE0"
  HEAD="HEAD0"
  CHANGED="$BATS_TEST_TMPDIR/changed"
  printf '%s\n' "a.py" "secret.txt" >"$CHANGED"

  # Default: run from a NON-git dir so semgrep takes its full-scan+filter
  # fallback path (the baseline-commit path gets its own git-repo test).
  cd "$WORK"
}

# ---- fake-binary factory --------------------------------------------------
# Each fake records its call, then behaves per its <TOOL>_MODE env var. Fakes
# that emit to a report FILE scan argv for the tool's output flag; STDOUT-JSON
# fakes just print (the script redirects their stdout into a report).

install_fake() {
  # $1 = tool name; body read from stdin
  cat >"$FAKEDIR/$1"
  chmod +x "$FAKEDIR/$1"
}

# Shared preamble every fake sources-in-line (records the invocation).
_record='_n="${0##*/}"; printf "%s\n" "$_n" >>"$RC_TEST_CALLS"; { printf "%s:" "$_n"; for _a in "$@"; do printf " %s" "$_a"; done; printf "\n"; } >>"$RC_TEST_ARGS";'

setup_fakes() {
  export RC_TEST_CALLS="$CALLS" RC_TEST_ARGS="$ARGS"

  # --- fake semgrep (Tier B; writes JSON to the --output path) ------------
  install_fake semgrep <<EOF
#!/usr/bin/env sh
$_record
_out=""; _prev=""
for _a in "\$@"; do if [ "\$_prev" = "--output" ]; then _out="\$_a"; fi; _prev="\$_a"; done
case "\${SEMGREP_MODE:-findings}" in
  hang) sleep "\${SEMGREP_SLEEP:-30}" ;;
  empty) printf '%s' '{"results":[]}' >"\$_out" ;;
  findings) printf '%s' '{"results":[{"check_id":"rules.demo","path":"a.py","start":{"line":3},"extra":{"message":"demo finding","severity":"WARNING"}}]}' >"\$_out" ;;
  mixed) printf '%s' '{"results":[{"check_id":"r.a","path":"a.py","start":{"line":3},"extra":{"message":"in changed file","severity":"ERROR"}},{"check_id":"r.b","path":"b.py","start":{"line":9},"extra":{"message":"in UNCHANGED file","severity":"ERROR"}}]}' >"\$_out" ;;
  samefile) printf '%s' '{"results":[{"check_id":"r.in","path":"a.py","start":{"line":3},"extra":{"message":"on a changed line","severity":"ERROR"}},{"check_id":"r.out","path":"a.py","start":{"line":40},"extra":{"message":"far outside any hunk","severity":"ERROR"}}]}' >"\$_out" ;;
esac
exit "\${SEMGREP_EXIT:-1}"
EOF

  # --- fake gitleaks (Tier A; version subcommand + writes JSON to -r path) -
  install_fake gitleaks <<EOF
#!/usr/bin/env sh
$_record
if [ "\${1:-}" = "version" ] || [ "\${1:-}" = "--version" ]; then
  printf '%s\n' "\${GITLEAKS_VERSION:-8.19.0}"; exit 0
fi
_r=""; _prev=""
for _a in "\$@"; do if [ "\$_prev" = "-r" ]; then _r="\$_a"; fi; _prev="\$_a"; done
case "\${GITLEAKS_MODE:-findings}" in
  hang) sleep "\${GITLEAKS_SLEEP:-30}" ;;
  clean) printf '%s' '[]' >"\$_r" ;;
  findings) printf '%s' '[{"RuleID":"generic-api-key","File":"secret.txt","StartLine":1,"Description":"api key detected"}]' >"\$_r" ;;
esac
exit "\${GITLEAKS_EXIT:-1}"
EOF

  # --- fake trufflehog (Tier A; STDOUT NDJSON; netfail => stderr error) ----
  install_fake trufflehog <<EOF
#!/usr/bin/env sh
$_record
case "\${TRUFFLEHOG_MODE:-clean}" in
  hang) sleep "\${TRUFFLEHOG_SLEEP:-30}" ;;
  clean) : ;;
  findings) printf '%s\n' '{"DetectorName":"AWS","Verified":true,"SourceMetadata":{"Data":{"Git":{"file":"env.sh","line":2}}}}' ;;
  netfail) echo "trufflehog: dial tcp 52.0.0.1:443: i/o timeout" >&2 ;;
esac
exit "\${TRUFFLEHOG_EXIT:-0}"
EOF

  # --- fake osv-scanner (Tier A; version flag + STDOUT JSON) ---------------
  install_fake osv-scanner <<EOF
#!/usr/bin/env sh
$_record
if [ "\${1:-}" = "--version" ]; then printf 'osv-scanner version %s\n' "\${OSV_VERSION:-2.0.0}"; exit 0; fi
case "\${OSV_MODE:-findings}" in
  hang) sleep "\${OSV_SLEEP:-30}" ;;
  clean) printf '%s' '{"results":[]}' ;;
  findings) printf '%s' '{"results":[{"source":{"path":"go.mod"},"packages":[{"package":{"name":"foo"},"vulnerabilities":[{"id":"GHSA-xxxx","summary":"RCE in foo","database_specific":{"severity":"HIGH"}}]}]}]}' ;;
  groupsev) printf '%s' '{"results":[{"source":{"path":"go.sum"},"packages":[{"package":{"name":"bar"},"vulnerabilities":[{"id":"CVE-2024-1","summary":"vuln","severity":[{"type":"CVSS_V3","score":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}]}],"groups":[{"ids":["CVE-2024-1"],"max_severity":"9.8"}]}]}]}' ;;
  multigroup) printf '%s' '{"results":[{"source":{"path":"go.sum"},"packages":[{"package":{"name":"baz"},"vulnerabilities":[{"id":"CVE-AAA","summary":"critical vuln"},{"id":"CVE-BBB","summary":"low vuln"}],"groups":[{"ids":["CVE-AAA"],"max_severity":"CRITICAL"},{"ids":["CVE-BBB"],"max_severity":"LOW"}]}]}]}' ;;
esac
exit "\${OSV_EXIT:-1}"
EOF

  # --- fake ruff (Tier B; STDOUT JSON) ------------------------------------
  install_fake ruff <<EOF
#!/usr/bin/env sh
$_record
printf '%s' '[{"code":"F401","filename":"a.py","location":{"row":1},"message":"unused import"}]'
exit "\${RUFF_EXIT:-0}"
EOF
}

# called <tool>: did the tool's fake binary run at all?
called() { grep -qx "$1" "$CALLS"; }

@test "usage: wrong arg count -> exit 2" {
  setup_fakes
  PATH="$SANDBOX" run "$SCRIPT" "$BASE" "$HEAD"
  echo "status=$status"
  [ "$status" -eq 2 ]
}

@test "usage: missing changed-files list -> exit 2" {
  setup_fakes
  PATH="$SANDBOX" run "$SCRIPT" "$BASE" "$HEAD" "/no/such/changed.list"
  echo "status=$status"
  [ "$status" -eq 2 ]
}

@test "enabled=false -> immediate no-op (empty output, exit 0, nothing invoked)" {
  setup_fakes
  RC_STATIC_ANALYSIS=false PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$CALLS" ]
}

@test "findings: gitleaks -> TIER_A line, semgrep -> TIER_B line, both normalized" {
  setup_fakes
  RC_STATIC_TOOLS="gitleaks,semgrep" PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  # exact normalized pipe lines (tier|tool|sev|file|line|rule|message)
  echo "$output" | grep -qxF 'TIER_A|gitleaks|critical|secret.txt|1|gitleaks:generic-api-key|api key detected'
  echo "$output" | grep -qxF 'TIER_B|semgrep|WARNING|a.py|3|semgrep:rules.demo|demo finding'
  # block headers present and ordered A before B
  echo "$output" | grep -qx 'TIER_A'
  echo "$output" | grep -qx 'TIER_B'
  _a=$(echo "$output" | grep -n '^TIER_A$' | cut -d: -f1)
  _b=$(echo "$output" | grep -n '^TIER_B$' | cut -d: -f1)
  [ "$_a" -lt "$_b" ]
}

@test "absent tool -> SKIPPED not installed, batch continues (gitleaks still runs)" {
  setup_fakes
  rm -f "$FAKEDIR/hadolint"   # ensure truly absent
  printf '%s\n' "a.py" "Dockerfile" "secret.txt" >"$CHANGED"
  RC_STATIC_TOOLS="gitleaks,hadolint" PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SKIPPED: hadolint — not installed'
  # batch continued: gitleaks produced its Tier A finding
  echo "$output" | grep -qF 'TIER_A|gitleaks|critical|secret.txt'
}

@test "timeout: semgrep hangs -> killed + SKIPPED timeout, batch continues, bounded wall" {
  setup_fakes
  _t0=$(date +%s)
  RC_STATIC_TOOLS="semgrep,gitleaks" RC_STATIC_TIMEOUT=1 \
    SEMGREP_MODE=hang SEMGREP_SLEEP=30 PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  _el=$(( $(date +%s) - _t0 ))
  echo "status=$status wall=${_el}s"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SKIPPED: semgrep — timeout'
  # semgrep contributed NO Tier B line (it was killed before writing)
  ! echo "$output" | grep -q 'TIER_B|semgrep|'
  # batch continued: gitleaks still ran to completion
  echo "$output" | grep -qF 'TIER_A|gitleaks|critical|secret.txt'
  # cap 1 + grace 3 + gitleaks ~instant; generous <15s proves the cap fired
  [ "$_el" -lt 15 ]
}

@test "not triggered: ruff configured+present but no *.py -> SKIPPED not triggered, never invoked" {
  setup_fakes
  printf '%s\n' "notes.md" "data.csv" >"$CHANGED"
  RC_STATIC_TOOLS="ruff" PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SKIPPED: ruff — not triggered'
  # the sentinel: the fake ruff was never executed
  ! called ruff
}

@test "excluded by config: semgrep present+would-trigger but not in tools -> SKIPPED disabled, never invoked" {
  setup_fakes
  RC_STATIC_TOOLS="gitleaks" PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SKIPPED: semgrep — disabled'
  ! called semgrep
}

@test "semgrep off: RC_SEMGREP_CONFIG=off -> SKIPPED semgrep off, never invoked (even present+triggered)" {
  setup_fakes
  RC_STATIC_TOOLS="semgrep" RC_SEMGREP_CONFIG=off PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SKIPPED: semgrep — semgrep off'
  ! called semgrep
}

@test "semgrep config default -> uses --config p/default (auto+metrics-off breakage fixed)" {
  setup_fakes
  RC_STATIC_TOOLS="semgrep" PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "args=<<$(cat "$ARGS")>>"
  [ "$status" -eq 0 ]
  called semgrep
  grep -qF -- '--config p/default' "$ARGS"
  ! grep -qF -- '--config auto' "$ARGS"
}

@test "semgrep config=auto -> SKIPPED (needs metrics, incompatible with --metrics=off), never invoked" {
  setup_fakes
  RC_STATIC_TOOLS="semgrep" RC_SEMGREP_CONFIG=auto PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "SKIPPED: semgrep — config 'auto' needs metrics/telemetry"
  ! called semgrep
}

@test "semgrep config=p/ruby -> registry ref passed through as --config p/ruby" {
  setup_fakes
  RC_STATIC_TOOLS="semgrep" RC_SEMGREP_CONFIG=p/ruby PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "args=<<$(cat "$ARGS")>>"
  [ "$status" -eq 0 ]
  called semgrep
  grep -qF -- '--config p/ruby' "$ARGS"
}

@test "semgrep config=<unreadable path> -> falls back to p/default with a note" {
  setup_fakes
  RC_STATIC_TOOLS="semgrep" RC_SEMGREP_CONFIG="/no/such/ruleset.yml" PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "args=<<$(cat "$ARGS")>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  called semgrep
  grep -qF -- '--config p/default' "$ARGS"
  echo "$stderr" | grep -qF "not a readable file; using p/default"
}

@test "network-unreachable: trufflehog runs, 0 verified + net error -> graceful SKIPPED, never errors" {
  setup_fakes
  RC_STATIC_TOOLS="trufflehog" TRUFFLEHOG_MODE=netfail PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SKIPPED: trufflehog — network-unreachable'
  # it DID run (attempted verification) and produced no Tier A finding
  called trufflehog
  ! echo "$output" | grep -q 'TIER_A|trufflehog|'
}

@test "trufflehog verified finding -> Tier A line (no spurious network note)" {
  setup_fakes
  RC_STATIC_TOOLS="trufflehog" TRUFFLEHOG_MODE=findings PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF 'TIER_A|trufflehog|critical|env.sh|2|trufflehog:aws|verified AWS secret'
  ! echo "$output" | grep -q 'network-unreachable'
}

@test "semgrep full-scan fallback (Risk #6): findings outside changed files are dropped" {
  setup_fakes
  printf '%s\n' "a.py" >"$CHANGED"   # only a.py changed; b.py is NOT
  RC_STATIC_TOOLS="semgrep" SEMGREP_MODE=mixed PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  # a.py finding kept; b.py finding filtered out by the changed-hunk post-filter
  echo "$output" | grep -qF 'TIER_B|semgrep|ERROR|a.py|3|semgrep:r.a|in changed file'
  ! echo "$output" | grep -qF 'b.py'
  # fallback path => NO --baseline-commit in the invocation (non-git CWD)
  ! grep -qF -- '--baseline-commit' "$ARGS"
}

@test "semgrep baseline path: clean git repo with valid base -> uses --baseline-commit" {
  setup_fakes
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  (
    cd "$REPO"
    PATH="$SANDBOX" git init -q
    PATH="$SANDBOX" git config user.email t@e.x
    PATH="$SANDBOX" git config user.name t
    : >a.py
    PATH="$SANDBOX" git add a.py
    PATH="$SANDBOX" git commit -qm init
  )
  _base="$(cd "$REPO" && PATH="$SANDBOX" git rev-parse HEAD)"
  printf '%s\n' "a.py" >"$CHANGED"
  cd "$REPO"
  RC_STATIC_TOOLS="semgrep" SEMGREP_MODE=findings PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$_base" "$REPO" "$CHANGED"
  echo "status=$status"
  echo "args=<<$(cat "$ARGS")>>"
  [ "$status" -eq 0 ]
  grep -qF -- "--baseline-commit $_base" "$ARGS"
}

@test "gitleaks version branch (Risk #7): old->detect subcommand, modern->git subcommand" {
  setup_fakes
  # old (< 8.19): must use the deprecated `detect` subcommand
  : >"$ARGS"
  RC_STATIC_TOOLS="gitleaks" GITLEAKS_VERSION=8.18.4 PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "old-args=<<$(cat "$ARGS")>>"
  grep -qE '^gitleaks: detect ' "$ARGS"
  ! grep -qE '^gitleaks: git ' "$ARGS"

  # modern (>= 8.19): must use the `git` subcommand
  : >"$ARGS"
  RC_STATIC_TOOLS="gitleaks" GITLEAKS_VERSION=8.20.0 PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "modern-args=<<$(cat "$ARGS")>>"
  grep -qE '^gitleaks: git ' "$ARGS"
  ! grep -qE '^gitleaks: detect ' "$ARGS"
}

@test "worktree-head mode (local staged/unstaged): gitleaks -> dir scan, trufflehog -> filesystem, no empty git range" {
  setup_fakes
  # env.sh is where the fake trufflehog reports; secret.txt is gitleaks' file.
  # Both must be in the changed list so the working-tree scan's diff-scope
  # filter (a whole-tree scan keeps only changed files) keeps them.
  printf '%s\n' "a.py" "secret.txt" "env.sh" >"$CHANGED"
  # base=HEAD, head="." (the worktree) is exactly what the orchestrator passes for
  # a local staged/unstaged review — the git-range forms would scan 0 commits and
  # silently report nothing. The Tier-A scanners must switch to a working-tree scan.
  RC_STATIC_TOOLS="gitleaks,trufflehog" GITLEAKS_MODE=findings TRUFFLEHOG_MODE=findings \
    PATH="$SANDBOX" run --separate-stderr "$SCRIPT" "HEAD" "." "$CHANGED"
  echo "status=$status"
  echo "args=<<$(cat "$ARGS")>>"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  # gitleaks: modern `dir` (directory) scan, NOT a git-range scan
  grep -qE '^gitleaks: dir ' "$ARGS"
  ! grep -qE '^gitleaks: git ' "$ARGS"
  ! grep -qF -- '--log-opts=' "$ARGS"
  # trufflehog: filesystem scan, NOT the --since-commit/--branch git range
  grep -qE '^trufflehog: filesystem ' "$ARGS"
  ! grep -qF -- '--branch' "$ARGS"
  ! grep -qF -- '--since-commit' "$ARGS"
  # both actually RAN and produced their Tier A findings (not a silent 0)
  echo "$output" | grep -qF 'TIER_A|gitleaks|critical|secret.txt'
  echo "$output" | grep -qF 'TIER_A|trufflehog|critical|env.sh'
}

@test "worktree-head mode via base==head: gitleaks switches off the empty range" {
  setup_fakes
  printf '%s\n' "secret.txt" >"$CHANGED"
  # base==head is another empty-range shape the orchestrator can produce.
  RC_STATIC_TOOLS="gitleaks" GITLEAKS_MODE=findings PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "HEAD" "HEAD" "$CHANGED"
  echo "args=<<$(cat "$ARGS")>>"
  [ "$status" -eq 0 ]
  grep -qE '^gitleaks: dir ' "$ARGS"
  ! grep -qF -- '--log-opts=' "$ARGS"
}

@test "osv-scanner: lockfile in diff triggers v2 'scan source' + Tier A CVE line" {
  setup_fakes
  printf '%s\n' "go.mod" "README.md" >"$CHANGED"
  RC_STATIC_TOOLS="osv-scanner" OSV_VERSION=2.1.0 OSV_MODE=findings PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "args=<<$(cat "$ARGS")>>"
  [ "$status" -eq 0 ]
  grep -qE '^osv-scanner: scan source ' "$ARGS"
  grep -qF -- '--lockfile=go.mod' "$ARGS"
  echo "$output" | grep -qxF 'TIER_A|osv-scanner|HIGH|go.mod||osv-scanner:ghsa-xxxx|GHSA-xxxx RCE in foo'
}

@test "osv-scanner severity fallback: groups[].max_severity, never the CVSS vector string" {
  setup_fakes
  printf '%s\n' "go.sum" >"$CHANGED"
  # No .database_specific.severity; the vuln has a CVSS *vector* .severity[].score
  # (not a level) plus a package group max_severity — the level-bearing field.
  RC_STATIC_TOOLS="osv-scanner" OSV_VERSION=2.1.0 OSV_MODE=groupsev PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  # severity_raw = 9.8 (from groups[].max_severity), not the CVSS:3.1/... vector
  echo "$output" | grep -qxF 'TIER_A|osv-scanner|9.8|go.sum||osv-scanner:cve-2024-1|CVE-2024-1 vuln'
  ! echo "$output" | grep -qF 'CVSS:3.1'
}

@test "osv-scanner multi-group: each vuln gets ITS group's max_severity, not the first" {
  setup_fakes
  printf '%s\n' "go.sum" >"$CHANGED"
  # One package, two vulns in two groups of differing severity. The old
  # first($p.groups[]?.max_severity) would stamp BOTH with the first group's
  # value; the id-matched select must give each vuln its own group's severity.
  RC_STATIC_TOOLS="osv-scanner" OSV_VERSION=2.1.0 OSV_MODE=multigroup PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF 'TIER_A|osv-scanner|CRITICAL|go.sum||osv-scanner:cve-aaa|CVE-AAA critical vuln'
  echo "$output" | grep -qxF 'TIER_A|osv-scanner|LOW|go.sum||osv-scanner:cve-bbb|CVE-BBB low vuln'
  # regression guard: CVE-BBB must NOT inherit the first group's CRITICAL
  ! echo "$output" | grep -qxF 'TIER_A|osv-scanner|CRITICAL|go.sum||osv-scanner:cve-bbb|CVE-BBB low vuln'
}

@test "osv-scanner: no lockfile in diff -> not triggered, never invoked" {
  setup_fakes
  printf '%s\n' "a.py" "src/app.js" >"$CHANGED"
  RC_STATIC_TOOLS="osv-scanner" PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SKIPPED: osv-scanner — not triggered'
  ! called osv-scanner
}

@test "invalid RC_STATIC_TIMEOUT -> note on stderr, falls back to 60, tool still runs" {
  setup_fakes
  RC_STATIC_TOOLS="gitleaks" RC_STATIC_TIMEOUT=abc PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  echo "$stderr" | grep -q "RC_STATIC_TIMEOUT='abc' invalid"
  echo "$output" | grep -qF 'TIER_A|gitleaks|critical|secret.txt'
}

@test "clean run: a tool that finds nothing emits neither a finding nor a SKIPPED line" {
  setup_fakes
  RC_STATIC_TOOLS="gitleaks" GITLEAKS_MODE=clean PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  # ran (no SKIPPED) but produced zero findings
  ! echo "$output" | grep -q 'gitleaks'
  # both block headers still present (stable contract)
  echo "$output" | grep -qx 'TIER_A'
  echo "$output" | grep -qx 'TIER_B'
}

@test "execution failure (Fix 1): unexpected non-zero exit -> SKIPPED execution failed + no Tier finding; exit-1-with-findings still emits" {
  setup_fakes
  # FAIL: gitleaks crashes with an unexpected code (2) yet still left a report —
  # a partial/garbage report must NOT leak into Tier A.
  RC_STATIC_TOOLS="gitleaks" GITLEAKS_MODE=findings GITLEAKS_EXIT=2 PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "fail-status=$status"
  echo "fail-output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'SKIPPED: gitleaks — execution failed (exit 2)'
  ! echo "$output" | grep -q 'TIER_A|gitleaks|'

  # OK: exit 1 is a tool's normal "found something" code — must emit, NOT skip.
  RC_STATIC_TOOLS="gitleaks" GITLEAKS_MODE=findings GITLEAKS_EXIT=1 PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "ok-output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'TIER_A|gitleaks|critical|secret.txt'
  ! echo "$output" | grep -qF 'SKIPPED: gitleaks — execution failed'
}

@test "worktree-head diff-scope (Fix 2): Tier-A secret in an UNCHANGED file is dropped, changed file kept" {
  setup_fakes
  # Whole-working-tree scan (worktree_head) surfaces secrets in files this change
  # never touched: gitleaks reports secret.txt, trufflehog reports env.sh.
  # DROP case — neither is in the changed list, so both must be filtered out.
  printf '%s\n' "a.py" >"$CHANGED"
  RC_STATIC_TOOLS="gitleaks,trufflehog" GITLEAKS_MODE=findings TRUFFLEHOG_MODE=findings \
    PATH="$SANDBOX" run --separate-stderr "$SCRIPT" "HEAD" "." "$CHANGED"
  echo "drop-status=$status"
  echo "drop-output=<<$output>>"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'TIER_A|gitleaks|'
  ! echo "$output" | grep -q 'TIER_A|trufflehog|'
  # a dropped-to-zero trufflehog run with no network error is NOT a false degrade
  ! echo "$output" | grep -q 'network-unreachable'

  # KEEP case — both files are now in the changed list, so both findings stay.
  printf '%s\n' "a.py" "secret.txt" "env.sh" >"$CHANGED"
  RC_STATIC_TOOLS="gitleaks,trufflehog" GITLEAKS_MODE=findings TRUFFLEHOG_MODE=findings \
    PATH="$SANDBOX" run --separate-stderr "$SCRIPT" "HEAD" "." "$CHANGED"
  echo "keep-output=<<$output>>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'TIER_A|gitleaks|critical|secret.txt'
  echo "$output" | grep -qF 'TIER_A|trufflehog|critical|env.sh'
}

@test "semgrep changed-hunk filter (Fix 3): finding on a changed line kept, finding far outside dropped" {
  setup_fakes
  REPO="$BATS_TEST_TMPDIR/repo3"
  mkdir -p "$REPO"
  (
    cd "$REPO"
    PATH="$SANDBOX" git init -q
    PATH="$SANDBOX" git config user.email t@e.x
    PATH="$SANDBOX" git config user.name t
    _i=1
    : >a.py
    while [ "$_i" -le 45 ]; do printf 'line%02d\n' "$_i" >>a.py; _i=$(( _i + 1 )); done
    PATH="$SANDBOX" git add a.py
    PATH="$SANDBOX" git commit -qm init
  )
  _base="$(cd "$REPO" && PATH="$SANDBOX" git rev-parse HEAD)"
  # Unstaged edit of line 3 ONLY -> a changed hunk at new-side line 3, and (being
  # unstaged) it forces semgrep's full-scan fallback (baseline-commit aborts).
  (
    cd "$REPO"
    _i=1
    : >a.py
    while [ "$_i" -le 45 ]; do
      if [ "$_i" -eq 3 ]; then printf 'CHANGED_LINE_3\n' >>a.py
      else printf 'line%02d\n' "$_i" >>a.py; fi
      _i=$(( _i + 1 ))
    done
  )
  printf '%s\n' "a.py" >"$CHANGED"
  cd "$REPO"
  RC_STATIC_TOOLS="semgrep" SEMGREP_MODE=samefile PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$_base" "." "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "args=<<$(cat "$ARGS")>>"
  [ "$status" -eq 0 ]
  # fallback path (unstaged changes) -> NO --baseline-commit
  ! grep -qF -- '--baseline-commit' "$ARGS"
  # line 3 is inside the changed hunk (±3) -> kept
  echo "$output" | grep -qF 'TIER_B|semgrep|ERROR|a.py|3|semgrep:r.in|on a changed line'
  # line 40 is far outside any changed hunk -> dropped
  ! echo "$output" | grep -qF 'r.out'
  ! echo "$output" | grep -qF 'far outside'
}

@test "semgrep changed-hunk filter (Fix 3): non-git dir gracefully falls back to FILE-level (both same-file findings kept)" {
  setup_fakes
  # $WORK (cwd) is NOT a git repo -> changed_ranges can't derive line ranges, so
  # filter_changed_hunks degrades to a FILE-level keep rather than erroring: BOTH
  # a.py findings survive (contrast the git case above, which drops line 40).
  printf '%s\n' "a.py" >"$CHANGED"
  RC_STATIC_TOOLS="semgrep" SEMGREP_MODE=samefile PATH="$SANDBOX" \
    run --separate-stderr "$SCRIPT" "$BASE" "$HEAD" "$CHANGED"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  ! grep -qF -- '--baseline-commit' "$ARGS"
  echo "$output" | grep -qF 'TIER_B|semgrep|ERROR|a.py|3|semgrep:r.in|on a changed line'
  echo "$output" | grep -qF 'TIER_B|semgrep|ERROR|a.py|40|semgrep:r.out|far outside any hunk'
}
