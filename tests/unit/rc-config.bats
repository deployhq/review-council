#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Unit tests for scripts/rc-config.sh — the deterministic config reader.
#
# Each test writes YAML fixtures into a per-test temp config dir and asserts the
# effective `key=value` lines on stdout (and skip-reason notes on stderr). YAML
# is parsed with mikefarah yq v4 (installed locally and in CI).
#
# Run: bats tests/unit/rc-config.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts/rc-config.sh"

setup() {
  CFG="$BATS_TEST_TMPDIR/cfg"
  mkdir -p "$CFG"
}

# has_line <key=value>: assert an exact stdout line is present in $output.
has_line() {
  printf '%s\n' "$output" | grep -qxF "$1" || {
    echo "expected line: $1"
    echo "--- actual output ---"
    printf '%s\n' "$output"
    return 1
  }
}

@test "absent files -> all defaults" {
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "status=$status"
  echo "output=<<$output>>"
  [ "$status" -eq 0 ]
  has_line "reviewer.claude.enabled=true"
  has_line "reviewer.perplexity.model=sonar"
  has_line "lens.dependency.providers=perplexity"
  has_line "lens.security.providers=auto"
  has_line "lens.security.replaces_dedicated=false"
  has_line "settings.run_budget_seconds=600"
  has_line "settings.min_reviewers=2"
  has_line "settings.auto_retry=false"
}

@test "provider enable/disable from config.yml" {
  printf 'reviewers:\n  codex:\n    enabled: false\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.codex.enabled=false"
  # others unaffected
  has_line "reviewer.claude.enabled=true"
}

@test "model bind from config.yml" {
  printf 'reviewers:\n  google:\n    model: gemini-2.5-pro\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.google.model=gemini-2.5-pro"
}

@test "lens pin + security replace-semantics" {
  printf 'lenses:\n  security:\n    providers: [google]\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "lens.security.providers=google"
  has_line "lens.security.replaces_dedicated=true"
}

@test "lens pin with multiple providers joins comma-separated" {
  printf 'lenses:\n  security:\n    providers: [google, claude]\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "lens.security.providers=google,claude"
  has_line "lens.security.replaces_dedicated=true"
}

@test "each settings knob in config.yml is reflected" {
  cat >"$CFG/config.yml" <<'EOF'
settings:
  verify: false
  verify_max_findings: 5
  run_budget_seconds: 300
  min_reviewers: 3
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.verify=false"
  has_line "settings.verify_max_findings=5"
  has_line "settings.run_budget_seconds=300"
  has_line "settings.min_reviewers=3"
}

@test "precedence: config.local.yml > config.yml" {
  printf 'settings:\n  verify: true\n' >"$CFG/config.yml"
  printf 'settings:\n  verify: false\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.verify=false"
}

@test "precedence: env > config.local.yml" {
  printf 'settings:\n  verify: true\n' >"$CFG/config.yml"
  printf 'settings:\n  verify: false\n' >"$CFG/config.local.yml"
  RC_VERIFY=true run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.verify=true"
}

@test "malformed value -> default + stderr note" {
  printf 'settings:\n  min_reviewers: abc\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  has_line "settings.min_reviewers=2"
  printf '%s\n' "$stderr" | grep -q 'min_reviewers'
}

@test "malformed file -> skipped with note, other layer still used" {
  printf ':::not valid yaml:::\n  a: : b\n' >"$CFG/config.yml"
  printf 'settings:\n  verify: false\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  has_line "settings.verify=false"
  printf '%s\n' "$stderr" | grep -qi 'malformed'
}

@test "unknown key ignored, output unaffected" {
  cat >"$CFG/config.yml" <<'EOF'
bogus_top_level: 1
settings:
  not_a_real_key: 9
  verify: false
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.verify=false"
  # still emits the full default roster
  has_line "reviewer.claude.enabled=true"
}

@test "yq-absent fallback: files ignored, defaults + env, yq-not-found note" {
  # Force yq-absent deterministically via RC_YQ pointing at an unresolvable path.
  # (Stripping PATH is unreliable: CI runners may ship yq in /usr/bin.)
  # Config sets min_reviewers:9, but with no usable yq the file is ignored and
  # only the env override should take effect.
  printf 'settings:\n  min_reviewers: 9\n' >"$CFG/config.yml"
  RC_YQ=/nonexistent/yq RC_VERIFY=false run --separate-stderr "$SCRIPT" "$CFG"
  echo "status=$status"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  # file ignored -> min_reviewers stays default (not 9)
  has_line "settings.min_reviewers=2"
  # env still applies
  has_line "settings.verify=false"
  # defaults still emitted
  has_line "reviewer.perplexity.model=sonar"
  printf '%s\n' "$stderr" | grep -q 'yq not found'
}

@test "wrong yq flavor (Python yq, no mikefarah): files ignored, defaults + env, distinct note" {
  # Two different tools are named `yq`: mikefarah (Go — this reader's
  # required tag/query syntax) and a Python one (kislyuk) that prints e.g.
  # "yq 3.4.3" with no "mikefarah". A fake shim simulates the Python yq being
  # first on PATH: `command -v` finds *a* yq, but it's the wrong one. Config
  # sets min_reviewers:9, but since the resolved yq isn't mikefarah v4, the
  # reader must ignore the file entirely (not just fail individual queries)
  # and fall back to defaults + env, exactly like the yq-absent case.
  FAKE_YQ="$BATS_TEST_TMPDIR/yq"
  cat >"$FAKE_YQ" <<'EOF'
#!/usr/bin/env sh
echo "yq 3.4.3"
exit 0
EOF
  chmod +x "$FAKE_YQ"
  printf 'settings:\n  min_reviewers: 9\n' >"$CFG/config.yml"
  RC_YQ="$FAKE_YQ" RC_VERIFY=false run --separate-stderr "$SCRIPT" "$CFG"
  echo "status=$status"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  # file ignored -> min_reviewers stays default (not 9)
  has_line "settings.min_reviewers=2"
  # env still applies
  has_line "settings.verify=false"
  # defaults still emitted
  has_line "reviewer.perplexity.model=sonar"
  printf '%s\n' "$stderr" | grep -q 'not mikefarah'
  printf '%s\n' "$stderr" | grep -q 'config files ignored'
}

@test "static_analysis block present -> ignored, no crash, normal output" {
  cat >"$CFG/config.yml" <<'EOF'
static_analysis:
  semgrep:
    enabled: true
  eslint: true
settings:
  verify: false
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "status=$status"
  [ "$status" -eq 0 ]
  has_line "settings.verify=false"
  has_line "reviewer.claude.enabled=true"
  # no static_analysis.* keys leak into output
  ! printf '%s\n' "$output" | grep -q 'static_analysis'
}

@test "string value with embedded newline -> default + note, no injected stdout line" {
  # A model value with an embedded newline would split into a second, fabricated
  # key=value line, breaking the one-per-line output contract. It must be
  # rejected like any malformed value: default + stderr note.
  cat >"$CFG/config.yml" <<'EOF'
reviewers:
  google:
    model: "abc\ninjected.line=malicious"
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  # crafted value rejected -> model falls back to its default (empty)
  has_line "reviewer.google.model="
  # stderr note names the offending key
  printf '%s\n' "$stderr" | grep -q 'reviewer.google.model'
  # NO fabricated key=value line reached stdout
  ! printf '%s\n' "$output" | grep -q 'injected.line'
  # contract intact: every stdout line is a `# comment` or a `key=value` pair
  ! printf '%s\n' "$output" | grep -vE '^#|='
}

@test "providers entry with embedded newline -> default + note, no injected stdout line" {
  cat >"$CFG/config.yml" <<'EOF'
lenses:
  security:
    providers: ["google\ninjected.line=x"]
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  # rejected pin -> providers falls back to the default (auto), not a partial pin
  has_line "lens.security.providers=auto"
  has_line "lens.security.replaces_dedicated=false"
  printf '%s\n' "$stderr" | grep -q 'lens.security.providers'
  ! printf '%s\n' "$output" | grep -q 'injected.line'
  # contract intact: no fabricated non-key=value stdout line
  ! printf '%s\n' "$output" | grep -vE '^#|='
}

@test "layered-invalid: higher layer invalid keeps lower layer's valid value" {
  # config.yml sets a VALID value; config.local.yml sets an INVALID one for the
  # same key. The higher-precedence-but-invalid value must NOT clobber the lower
  # valid one — the valid config.yml value stands, with a stderr note.
  printf 'settings:\n  min_reviewers: 3\n' >"$CFG/config.yml"
  printf 'settings:\n  min_reviewers: abc\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "status=$status"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  has_line "settings.min_reviewers=3"
  printf '%s\n' "$stderr" | grep -q 'min_reviewers'
}
