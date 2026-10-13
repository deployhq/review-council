#!/usr/bin/env sh
# rc-config.sh — deterministic, tested reader for the Review Council config.
#
# Reconciles the built-in defaults with two optional YAML files and env vars,
# then prints the EFFECTIVE config as `key=value` lines to stdout (one per line,
# no spaces around `=`). Diagnostics/skip-reasons go to stderr. No LLM, no net.
#
# See .superpowers/sdd/task-1a.1-rc-config-brief.md for the full spec.
#
# Usage:
#   rc-config.sh [config_dir]
#
#   config_dir  optional; directory holding config.yml / config.local.yml.
#               Default: .review-council (env RC_CONFIG_DIR is honored as a
#               fallback, but the positional wins).
#
# Precedence (per key): env > config.local.yml > config.yml > built-in default.
#   - Env overrides apply to the `settings.*` and `static_analysis.*` knobs
#     ONLY (see the settings/static_analysis emits).
#   - Reviewers and lenses come from the files (and defaults) only.
#
# YAML is parsed with `yq` (mikefarah v4); the binary is `${RC_YQ:-yq}`. Graceful
# degradation:
#   - yq absent               -> ignore both files; emit defaults + env; one note.
#   - yq present but not mikefarah v4 (e.g. the Python kislyuk/yq) -> treated
#     exactly like yq-absent: ignore both files; emit defaults + env; one note.
#   - a file absent           -> skip it silently.
#   - a file malformed        -> skip that file with a note; use the other layers.
#   - a single key malformed  -> use that key's default with a note.
#   Unknown keys are ignored (including unrecognized sub-keys under
#   `static_analysis:`, e.g. a per-tool `enabled` block — only the four
#   documented static_analysis.* keys are read).
#
# Exit: always 0 (absent files / absent yq degrade gracefully, they aren't errors).

set -eu

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

config_dir="${1:-${RC_CONFIG_DIR:-.review-council}}"
base_file="$config_dir/config.yml"        # committed team defaults
over_file="$config_dir/config.local.yml"  # gitignored per-machine overrides

# ---------------------------------------------------------------------------
# Layer availability
#
# base_ok / over_ok are 1 only when yq is present, the file exists, AND it
# parses. When a layer is unusable, every key from it resolves to null and thus
# falls through to the lower layer / default.
# ---------------------------------------------------------------------------

# The yq binary is resolved once via RC_YQ (default: `yq`). This lets a user
# point at a non-standard yq, and lets tests force the absent path deterministically
# (e.g. RC_YQ=/nonexistent/yq) regardless of any yq preinstalled on PATH.
YQ_BIN="${RC_YQ:-yq}"

yq_present=1
if ! command -v "$YQ_BIN" >/dev/null 2>&1; then
  yq_present=0
  echo "rc-config: yq not found; $config_dir/config*.yml ignored (using defaults + env)" >&2
else
  # Two different tools are named `yq`: mikefarah (Go), whose `yq e '...'` /
  # tag-query syntax this reader relies on, and a Python one (kislyuk) that
  # does NOT support it. If the resolved binary isn't mikefarah v4, treat it
  # exactly like yq-absent rather than letting mikefarah-only queries fail
  # silently and mislabel a valid config as malformed. Kept consistent with
  # the same check in skills/setup/SKILL.md.
  _yq_ver="$("$YQ_BIN" --version 2>/dev/null)" || _yq_ver=""
  if ! printf '%s' "$_yq_ver" | grep -q 'mikefarah' || ! printf '%s' "$_yq_ver" | grep -qE 'version v?4'; then
    yq_present=0
    echo "rc-config: yq present but not mikefarah v4; config files ignored (using defaults + env)" >&2
  fi
fi

# layer_ok <file>: prints 1 if the file is usable, else 0 (with a note when a
# present file fails to parse). Absent files are skipped silently.
layer_ok() {
  _lo_f="$1"
  [ "$yq_present" -eq 1 ] || { echo 0; return; }
  [ -f "$_lo_f" ] || { echo 0; return; }
  if ! "$YQ_BIN" e '.' "$_lo_f" >/dev/null 2>&1; then
    echo "rc-config: $_lo_f is malformed YAML; skipped" >&2
    echo 0
    return
  fi
  echo 1
}

base_ok="$(layer_ok "$base_file")"
over_ok="$(layer_ok "$over_file")"

# over_trusted: config.local.yml is TRUSTED (operator-owned) only while git does
# not track it. Being gitignored is a convention, not a boundary — a reviewed
# repo can simply commit a config.local.yml — so a tracked one is treated as
# untrusted for the security-sensitive keys (resolve_over, custom seats). Its
# ordinary keys still apply, exactly as before. No git / not a repo -> untracked.
#
# The tracked check is CASE-INSENSITIVE (`:(icase)` pathspec magic): on a
# case-folding FS (macOS default) a committed `Config.Local.yml` is the file we
# just opened as config.local.yml, yet a case-sensitive ls-files would call it
# untracked -> trusted. Fail closed: tracked under ANY casing -> untrusted.
# GIT_LITERAL_PATHSPECS is pinned off: inherited as 1 it would disable the
# magic, match nothing, and fail OPEN.
over_trusted=0
if [ "$over_ok" -eq 1 ]; then
  over_trusted=1
  if GIT_LITERAL_PATHSPECS=0 git -C "$(dirname "$over_file")" ls-files --error-unmatch -- ":(icase)$(basename "$over_file")" >/dev/null 2>&1; then
    over_trusted=0
    echo "rc-config: $over_file is tracked by git — treated as untrusted (like config.yml) for security-sensitive keys" >&2
  fi
fi

# The user layer — ~/.review-council/config.yml — lives outside every repo, so
# the reviewed repo cannot write it: TRUSTED. Read ONLY for reviewers.custom.
user_file="${RC_USER_CONFIG:-${HOME:-/nonexistent}/.review-council/config.yml}"
user_ok="$(layer_ok "$user_file")"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# note_bad <key> <raw>: one stderr note for a malformed key that falls back.
note_bad() {
  echo "rc-config: $1: invalid value '$2'; using default" >&2
}

valid_bool() {
  case "$1" in
    true | false) return 0 ;;
    *) return 1 ;;
  esac
}

# positive integer (all digits, > 0)
valid_posint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

# valid_str <val>: a free-form string value is valid only if it contains NO
# control characters (newline, CR, tab, etc.). This is a security guard: the
# output contract is one `key=value` per line, so a value with an embedded
# newline (e.g. model: "abc\ninjected.line=x") would otherwise inject a second,
# fabricated key=value line into stdout. Reject it -> caller falls back to the
# key's default + note, exactly like an out-of-shape bool/int.
valid_str() {
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# valid_modelslug <val>: a reviewer model slug. STRICTER than valid_str because
# a model value is interpolated UNQUOTED into a shell command the orchestrator
# composes (skills/run/SKILL.md's `RC_GOOGLE_MODEL=<model>` template et al.),
# in the orchestrator's own session, OUTSIDE any sandbox. A control-chars-only
# guard let spaces, `;`, `|`, backticks and `$(...)` through, so a repo-committed
# config.yml could reach command position — and double-quoting the template does
# NOT help, since `$(...)` expands inside double quotes. The reader is therefore
# the only real defense: reject anything outside the slug allowlist here.
#
# Allowlist (charset): letters, digits, and . _ : ~ @ / - — admits every real
# OpenRouter/OpenAI/Google slug: gemini-2.5-pro, sonar, moonshotai/kimi-k2.7-code,
# ~moonshotai/kimi-latest, openai/gpt-4o:free. Anchor: the first character must
# be alphanumeric, `~`, or `@`, so a leading `-` (a would-be CLI flag) is
# rejected. Empty is allowed — it means "use the tool's own default", exactly as
# the old `str` kind treated it (so an explicit empty model never regresses).
valid_modelslug() {
  [ -z "$1" ] && return 0
  [ "${#1}" -le 128 ] || return 1
  case "$1" in
    *[!A-Za-z0-9._:~@/-]*) return 1 ;;  # any char outside the allowlist
    [!A-Za-z0-9~@]*) return 1 ;;        # leading char must be alnum / ~ / @
  esac
  return 0
}

# valid_envname <val>: the NAME of an env var (pr_comments.bot_token_env). The
# reader emits this name; a consumer (scripts/rc-post.sh) then reads the env var
# it names via indirect expansion and uses its value as a GitHub token. Because
# the name reaches a shell parameter-expansion / command position, it must be a
# strict POSIX identifier — same reasoning as valid_modelslug, applied to a
# variable name. Empty is allowed: it means "no bot-token var configured" ->
# post as the authenticated user, never a failure.
valid_envname() {
  [ -z "$1" ] && return 0
  [ "${#1}" -le 128 ] || return 1
  case "$1" in
    *[!A-Za-z0-9_]*) return 1 ;;  # only letters, digits, underscore
    [!A-Za-z_]*) return 1 ;;      # must not start with a digit
  esac
  return 0
}

# valid_uint <val>: a non-negative integer (all digits; 0 allowed), ≤ 12 digits.
valid_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 12 ]
}

# valid_enum <val> <comma-separated allowed values>: literal `=` comparisons in
# a loop, so a value carrying glob metacharacters can never pattern-match.
valid_enum() {
  _ve_v="$1"
  _ve_rest="$2,"
  while [ -n "$_ve_rest" ]; do
    _ve_item="${_ve_rest%%,*}"
    _ve_rest="${_ve_rest#*,}"
    [ "$_ve_v" = "$_ve_item" ] && return 0
  done
  return 1
}

# valid_kind <val> <kind>: bool|posint|uint|uint9|posint_le:<max>|enum:<a,b,..>|str|modelslug|envname
valid_kind() {
  case "$2" in
    bool) valid_bool "$1" ;;
    posint) valid_posint "$1" ;;
    uint) valid_uint "$1" ;;
    # ≤ 9 digits: the cap scripts/rc-ocr.sh's is_uint enforces (max_tokens_budget),
    # so a value the reader emits is never one the runner rejects.
    uint9) valid_uint "$1" && [ "${#1}" -le 9 ] ;;
    posint_le:*) valid_posint "$1" && [ "${#1}" -le 6 ] && [ "$1" -le "${2#posint_le:}" ] ;;
    enum:*) valid_enum "$1" "${2#enum:}" ;;
    str) valid_str "$1" ;;
    modelslug) valid_modelslug "$1" ;;
    envname) valid_envname "$1" ;;
  esac
}

# get_raw <file> <yq-path>: echoes the scalar value; returns 1 if the node is
# absent/null (tag !!null) or the query fails. Distinguishes an explicit empty
# string ("" -> tag !!str, empty output, return 0) from an absent key.
get_raw() {
  _gr_tag="$("$YQ_BIN" "$2 | tag" "$1" 2>/dev/null)" || return 1
  [ "$_gr_tag" = "!!null" ] && return 1
  "$YQ_BIN" "$2" "$1" 2>/dev/null
}

# resolve <yq-path> <default> <kind> <key-name>: layers base then over on top of
# the default; a layer that explicitly sets an INVALID value is noted and does
# NOT override (the lower layer / default stands). Prints the effective value.
resolve() {
  _rs_path="$1"
  _rs_val="$2"
  _rs_kind="$3"
  _rs_key="$4"
  for _rs_layer in base over; do
    eval "_rs_ok=\$${_rs_layer}_ok"
    [ "$_rs_ok" -eq 1 ] || continue
    eval "_rs_file=\$${_rs_layer}_file"
    _rs_raw="$(get_raw "$_rs_file" "$_rs_path")" || continue
    if valid_kind "$_rs_raw" "$_rs_kind"; then
      _rs_val="$_rs_raw"
    else
      # Layered-invalid: a higher-precedence layer (over) that sets an INVALID
      # value does NOT clobber a valid value already taken from a lower layer
      # (base) or the default — we note it and keep the last valid value.
      note_bad "$_rs_key" "$_rs_raw"
    fi
  done
  printf '%s' "$_rs_val"
}

# resolve_over <yq-path> <default> <kind> <key-name>: like resolve() but reads
# ONLY the config.local.yml (over) layer — never the committed config.yml (base).
# For values whose meaning is security-sensitive because the reviewed repo could
# weaponize them: pr_comments.bot_token_env NAMES the env var whose value is read
# and sent to GitHub as a bearer token, so a committed (untrusted) config must not
# be able to point it at an arbitrary local secret (e.g. AWS_SECRET_ACCESS_KEY).
# config.local.yml is gitignored and operator-owned, hence trusted. If base tries
# to set it, note that it was ignored.
resolve_over() {
  _ro_path="$1"
  _ro_val="$2"
  _ro_kind="$3"
  _ro_key="$4"
  if [ "$base_ok" -eq 1 ] && get_raw "$base_file" "$_ro_path" >/dev/null 2>&1; then
    echo "rc-config: $_ro_key ignored in the committed config.yml (untrusted); set it in config.local.yml or via its env override" >&2
  fi
  if [ "$over_ok" -eq 1 ] && [ "$over_trusted" -eq 0 ] && get_raw "$over_file" "$_ro_path" >/dev/null 2>&1; then
    echo "rc-config: $_ro_key ignored in the git-tracked config.local.yml (untrusted); untrack it or use its env override" >&2
  fi
  if [ "$over_trusted" -eq 1 ]; then
    if _ro_raw="$(get_raw "$over_file" "$_ro_path")"; then
      if valid_kind "$_ro_raw" "$_ro_kind"; then
        _ro_val="$_ro_raw"
      else
        note_bad "$_ro_key" "$_ro_raw"
      fi
    fi
  fi
  printf '%s' "$_ro_val"
}

# ---------------------------------------------------------------------------
# Reviewers (roster) — files only, no env override
# ---------------------------------------------------------------------------

emit_reviewer() {
  # $1 = provider name, $2 = default model
  _er_p="$1"
  _er_defmodel="$2"
  _er_enabled="$(resolve ".reviewers.$_er_p.enabled" "true" bool "reviewer.$_er_p.enabled")"
  _er_model="$(resolve ".reviewers.$_er_p.model" "$_er_defmodel" modelslug "reviewer.$_er_p.model")"
  printf 'reviewer.%s.enabled=%s\n' "$_er_p" "$_er_enabled"
  printf 'reviewer.%s.model=%s\n' "$_er_p" "$_er_model"
}

echo "# reviewers"
emit_reviewer claude ""
emit_reviewer codex ""
emit_reviewer google ""
emit_reviewer perplexity "sonar"

# ---------------------------------------------------------------------------
# Lenses — files only, no env override
#
# `providers` is always a YAML list; print it comma-joined. Omitted -> `auto`.
# For `security` only, ALSO emit `lens.security.replaces_dedicated`: true when
# providers is explicitly pinned to a list (the pin replaces the dedicated
# security subagent), false when it stays `auto`.
# ---------------------------------------------------------------------------

# resolve_providers <lens> <default>: sets globals PROVIDERS_VALUE (effective
# comma-joined value) and PROVIDERS_EXPLICIT (1 if a layer pinned it to a real
# list, else 0). Sets globals directly — must NOT run in a command substitution
# subshell, or PROVIDERS_EXPLICIT wouldn't reach the caller.
resolve_providers() {
  _rp_lens="$1"
  PROVIDERS_VALUE="$2"
  PROVIDERS_EXPLICIT=0
  for _rp_layer in base over; do
    eval "_rp_ok=\$${_rp_layer}_ok"
    [ "$_rp_ok" -eq 1 ] || continue
    eval "_rp_file=\$${_rp_layer}_file"
    _rp_tag="$("$YQ_BIN" ".lenses.$_rp_lens.providers | tag" "$_rp_file" 2>/dev/null)" || continue
    case "$_rp_tag" in
      '!!null')
        continue
        ;;
      '!!seq')
        _rp_joined="$("$YQ_BIN" ".lenses.$_rp_lens.providers | join(\",\")" "$_rp_file" 2>/dev/null)" || continue
        # Guard the joined value against control chars (a list entry containing
        # a newline would inject a second key=value line into stdout, breaking
        # the one-per-line contract). If any entry is unsafe, treat the pin as
        # malformed: note and keep the prior value (default / lower layer).
        if valid_str "$_rp_joined"; then
          PROVIDERS_VALUE="$_rp_joined"
          PROVIDERS_EXPLICIT=1
        else
          note_bad "lens.$_rp_lens.providers" "$_rp_joined"
        fi
        ;;
      *)
        # present but not a list — malformed; keep the prior value.
        echo "rc-config: lens.$_rp_lens.providers: not a list; using '$PROVIDERS_VALUE'" >&2
        ;;
    esac
  done
}

emit_lens() {
  # $1 = lens name, $2 = default providers
  _el_lens="$1"
  _el_defprov="$2"
  _el_enabled="$(resolve ".lenses.$_el_lens.enabled" "true" bool "lens.$_el_lens.enabled")"
  resolve_providers "$_el_lens" "$_el_defprov"
  printf 'lens.%s.enabled=%s\n' "$_el_lens" "$_el_enabled"
  printf 'lens.%s.providers=%s\n' "$_el_lens" "$PROVIDERS_VALUE"
  if [ "$_el_lens" = "security" ]; then
    if [ "$PROVIDERS_EXPLICIT" -eq 1 ]; then
      echo "lens.security.replaces_dedicated=true"
    else
      echo "lens.security.replaces_dedicated=false"
    fi
  fi
}

echo "# lenses"
emit_lens security "auto"
emit_lens correctness "auto"
emit_lens cross_file "auto"
emit_lens performance "auto"
emit_lens design "auto"
emit_lens dependency "perplexity"

# ---------------------------------------------------------------------------
# Settings — files AND env (env wins). Env applies to these keys ONLY.
# ---------------------------------------------------------------------------

emit_setting() {
  # $1 key, $2 yq-path, $3 default, $4 kind, $5 env-var name
  _es_key="$1"
  _es_eff="$(resolve "$2" "$3" "$4" "$1")"
  eval "_es_env=\${$5:-}"
  if [ -n "$_es_env" ]; then
    if valid_kind "$_es_env" "$4"; then
      _es_eff="$_es_env"
    else
      echo "rc-config: $_es_key: invalid $5='$_es_env'; ignoring env override" >&2
    fi
  fi
  printf '%s=%s\n' "$_es_key" "$_es_eff"
}

echo "# settings"
emit_setting settings.personas ".settings.personas" "true" bool RC_PERSONAS
emit_setting settings.verify ".settings.verify" "true" bool RC_VERIFY
emit_setting settings.verify_max_findings ".settings.verify_max_findings" "12" posint RC_VERIFY_CAP
emit_setting settings.learn ".settings.learn" "true" bool RC_LEARN
emit_setting settings.min_reviewers ".settings.min_reviewers" "2" posint RC_MIN_REVIEWERS
emit_setting settings.reviewer_timeout_seconds ".settings.reviewer_timeout_seconds" "600" posint RC_REVIEWER_TIMEOUT
emit_setting settings.run_budget_seconds ".settings.run_budget_seconds" "600" posint RC_RUN_BUDGET
emit_setting settings.auto_retry ".settings.auto_retry" "false" bool RC_AUTO_RETRY
emit_setting settings.health_probe ".settings.health_probe" "false" bool RC_HEALTH_PROBE
emit_setting settings.health_probe_timeout_seconds ".settings.health_probe_timeout_seconds" "20" posint RC_HEALTH_PROBE_TIMEOUT
emit_setting settings.claude_max_turns ".settings.claude_max_turns" "100" posint RC_CLAUDE_MAX_TURNS

# ---------------------------------------------------------------------------
# Static analysis — files AND env (env wins), its own top-level section
# (sibling to reviewers/lenses/settings). Previously a `static_analysis:`
# block was parsed-but-ignored; these four keys are now read and emitted.
# ---------------------------------------------------------------------------

# is_known_tool <token>: true if <token> is one of the eight recognized
# static-analysis tool names. Uses literal `=` comparisons in a loop (not a
# glob-pattern substring test) so a token containing shell glob metacharacters
# (e.g. `*`) can never falsely match.
is_known_tool() {
  for _ikt_known in gitleaks trufflehog osv-scanner semgrep ruff shellcheck actionlint hadolint; do
    [ "$1" = "$_ikt_known" ] && return 0
  done
  return 1
}

# filter_tools <comma-separated tokens>: trims whitespace around each token,
# drops empty tokens, and drops any token not in KNOWN_STATIC_TOOLS (with a
# stderr note per dropped token) — a graceful per-token degradation rather
# than rejecting the whole list for one typo. Prints the comma-joined result
# (order preserved; may be empty if every token was invalid).
filter_tools() {
  _ft_out=""
  _ft_old_ifs="$IFS"
  IFS=','
  # `for tok in $1` (unquoted, required for IFS word-splitting on commas) also
  # triggers pathname expansion — an input token like `*` or `?` would
  # otherwise be silently replaced with a listing of CWD's files instead of
  # being split/validated as a literal string. Disable globbing for the
  # duration of the loop and restore it after (the rest of this script never
  # relies on pathname expansion, so this is safe to scope narrowly here).
  set -f
  for _ft_tok in $1; do
    IFS="$_ft_old_ifs"
    _ft_tok="$(printf '%s' "$_ft_tok" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -z "$_ft_tok" ]; then
      :
    elif is_known_tool "$_ft_tok"; then
      if [ -z "$_ft_out" ]; then
        _ft_out="$_ft_tok"
      else
        _ft_out="$_ft_out,$_ft_tok"
      fi
    else
      echo "rc-config: static_analysis.tools: unknown tool '$_ft_tok'; dropped" >&2
    fi
    IFS=','
  done
  set +f
  IFS="$_ft_old_ifs"
  printf '%s' "$_ft_out"
}

# resolve_static_tools <default>: sets global STATIC_TOOLS_VALUE. Layers
# `.static_analysis.tools` from base/over as a YAML seq (comma-joined, same
# `!!seq` tag-check pattern as resolve_providers), then — unlike lenses'
# providers, which have no env override at all — lets RC_STATIC_TOOLS
# (comma-separated) win over both files if set. Every source is passed
# through filter_tools for known-token validation.
resolve_static_tools() {
  STATIC_TOOLS_VALUE="$1"
  for _rst_layer in base over; do
    eval "_rst_ok=\$${_rst_layer}_ok"
    [ "$_rst_ok" -eq 1 ] || continue
    eval "_rst_file=\$${_rst_layer}_file"
    _rst_tag="$("$YQ_BIN" '.static_analysis.tools | tag' "$_rst_file" 2>/dev/null)" || continue
    case "$_rst_tag" in
      '!!null')
        continue
        ;;
      '!!seq')
        _rst_joined="$("$YQ_BIN" '.static_analysis.tools | join(",")' "$_rst_file" 2>/dev/null)" || continue
        if valid_str "$_rst_joined"; then
          STATIC_TOOLS_VALUE="$(filter_tools "$_rst_joined")"
        else
          note_bad "static_analysis.tools" "$_rst_joined"
        fi
        ;;
      *)
        echo "rc-config: static_analysis.tools: not a list; using '$STATIC_TOOLS_VALUE'" >&2
        ;;
    esac
  done
  _rst_env="${RC_STATIC_TOOLS:-}"
  if [ -n "$_rst_env" ]; then
    if valid_str "$_rst_env"; then
      STATIC_TOOLS_VALUE="$(filter_tools "$_rst_env")"
    else
      echo "rc-config: static_analysis.tools: invalid RC_STATIC_TOOLS='$_rst_env'; ignoring env override" >&2
    fi
  fi
}

echo "# static_analysis"
emit_setting static_analysis.enabled ".static_analysis.enabled" "true" bool RC_STATIC_ANALYSIS
resolve_static_tools "gitleaks,trufflehog,osv-scanner,semgrep,ruff,shellcheck,actionlint,hadolint"
printf 'static_analysis.tools=%s\n' "$STATIC_TOOLS_VALUE"
emit_setting static_analysis.timeout_seconds ".static_analysis.timeout_seconds" "60" posint RC_STATIC_TIMEOUT
emit_setting static_analysis.semgrep_config ".static_analysis.semgrep_config" "p/default" str RC_SEMGREP_CONFIG

# ---------------------------------------------------------------------------
# PR comments — files AND env for `enabled` (env wins); its own top-level
# section (sibling to reviewers/lenses/settings/static_analysis). Gates the
# optional PR-digest posting engine (scripts/rc-post.sh). Default OFF so an
# absent block is byte-identical to today's report-only behavior.
#
# bot_token_env names the env var that (optionally) holds a GitHub token used to
# post as a distinct bot identity. When that var is unset/empty at post time the
# engine posts as the authenticated `gh` user; the token VALUE never touches
# config. Crucially, the NAME selects which local env var is read and egressed to
# GitHub, so it is resolved from TRUSTED layers only — config.local.yml (over) or
# the RC_PR_BOT_TOKEN_ENV env override — NEVER the committed config.yml (which is
# attacker-controlled when reviewing an untrusted repo). The default names
# RC_PR_BOT_TOKEN. `enabled` stays file+env (a committed team default is fine —
# posting is human-gated and, absent a bot token, posts as the operator).
# ---------------------------------------------------------------------------

echo "# pr_comments"
emit_setting pr_comments.enabled ".pr_comments.enabled" "false" bool RC_PR_COMMENTS
_pc_tokenenv="$(resolve_over ".pr_comments.bot_token_env" "RC_PR_BOT_TOKEN" envname "pr_comments.bot_token_env")"
_pc_env="${RC_PR_BOT_TOKEN_ENV:-}"
if [ -n "$_pc_env" ]; then
  if valid_kind "$_pc_env" envname; then
    _pc_tokenenv="$_pc_env"
  else
    echo "rc-config: pr_comments.bot_token_env: invalid RC_PR_BOT_TOKEN_ENV='$_pc_env'; ignoring env override" >&2
  fi
fi
printf 'pr_comments.bot_token_env=%s\n' "$_pc_tokenenv"

# ---------------------------------------------------------------------------
# Custom reviewer seats — reviewers.custom.<name>.* (files only, no env).
#
# Emitted ONLY when at least one valid seat survives: with no `custom:` block in
# any layer, not one byte of this section appears (config invariance).
#
# Four layers, lowest -> highest precedence:
#   base   .review-council/config.yml             UNTRUSTED (the reviewed repo)
#   overu  .review-council/config.local.yml, when git TRACKS it   UNTRUSTED
#   user   ~/.review-council/config.yml           trusted (outside every repo)
#   over   .review-council/config.local.yml, untracked            trusted
# Typed keys resolve across all four. Keys that select a secret or shape the
# harness's argv/env freely — api_key_env, harness_options.flags/env — are read
# from the trusted layers only; set in an untrusted layer they are ignored with
# a note. Harnesses: ocr | codex | claude | opencode. Each typed harness option
# applies to the harnesses listed at its resolve below (set on another, it is
# dropped with a note); free-form flags/env are ocr-only — every agent harness
# has isolation-critical flags/env, so none of them gets a free-form surface.
# A seat that ONLY an untrusted layer defines and that sends code off
# the machine gets a `confirm.<n>=` line: the orchestrator asks the human once
# before running it (skills/run/SKILL.md, Step 0).
#
# Ordering is part of the guard: names are DISCOVERED by `yq keys`, so each is
# validated against ^[A-Za-z0-9_-]{1,32}$ BEFORE it is ever interpolated into a
# yq expression or an emitted key.
# ---------------------------------------------------------------------------

# shellcheck source-path=SCRIPTDIR source=rc-lib-family.sh
. "$(dirname "$0")/rc-lib-family.sh"

cs_layer_file() {
  case "$1" in
    base) printf '%s' "$base_file" ;;
    overu | over) printf '%s' "$over_file" ;;
    user) printf '%s' "$user_file" ;;
  esac
}

# cs_layer_on <layer>: is this layer usable in its trust role?
cs_layer_on() {
  case "$1" in
    base) [ "$base_ok" -eq 1 ] ;;
    overu) [ "$over_ok" -eq 1 ] && [ "$over_trusted" -eq 0 ] ;;
    user) [ "$user_ok" -eq 1 ] ;;
    over) [ "$over_trusted" -eq 1 ] ;;
  esac
}

cs_layer_trusted() {
  case "$1" in
    user | over) return 0 ;;
    *) return 1 ;;
  esac
}

cs_layer_label() {
  case "$1" in
    base) printf 'the committed config.yml' ;;
    overu) printf 'the git-tracked config.local.yml' ;;
    user) printf '%s' "$user_file" ;;
    over) printf 'config.local.yml' ;;
  esac
}

valid_slotname() {
  [ "${#1}" -ge 1 ] && [ "${#1}" -le 32 ] || return 1
  case "$1" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# A free-form harness flag token (trusted layers only): no shell metacharacters
# or control characters (glob `*`/`?` allowed, for --exclude patterns), bounded
# length. Reaches the harness argv as ONE quoted element, never a command line.
valid_flagtoken() {
  [ "${#1}" -ge 1 ] && [ "${#1}" -le 256 ] || return 1
  case "$1" in
    *[!A-Za-z0-9._:/@=,+%*?-]*) return 1 ;;
  esac
  return 0
}

# Flags that would undo the seat's isolation or its output contract. Never
# settable, from any layer. Mirrors scripts/rc-ocr.sh's reserved_flag EXACTLY,
# so the reader is never laxer than the runner: the long forms bare or with
# `=value`, and ANY single-dash token touching -c -f -o -p (a shorthand cluster
# such as -cv, or an attached value such as -o/x or -p1).
reserved_flag() {
  case "$1" in
    --rule | --rule=* | --repo | --repo=* | --from | --from=* | --to | --to=* | \
      --commit | --commit=* | --tools | --tools=* | --provider | --provider=* | \
      --model | --model=* | --output | --output=* | --format | --format=* | \
      --audience | --audience=* | --resume | --resume=* | --preview | --preview=*)
      return 0
      ;;
    --*) return 1 ;;
    -*[cfop]*) return 0 ;;
  esac
  return 1
}

# A seat's env extras may not touch the isolation (HOME, PATH, TMPDIR), the
# update switch, or any provider key.
reserved_env() {
  case "$1" in
    HOME | PATH | TMPDIR | OCR_NO_UPDATE | OPENROUTER_API_KEY | "$2") return 0 ;;
  esac
  return 1
}

# cs_resolve <slot> <subpath> <default> <kind> <trusted-only:0|1>: per-key,
# layered like resolve(); an invalid value never overrides a lower valid one.
cs_resolve() {
  _cr_slot="$1"
  _cr_path=".reviewers.custom[\"$1\"]$2"
  _cr_val="$3"
  _cr_key="reviewer.custom.$1$2"
  for _cr_layer in base overu user over; do
    cs_layer_on "$_cr_layer" || continue
    _cr_raw="$(get_raw "$(cs_layer_file "$_cr_layer")" "$_cr_path")" || continue
    if [ "$5" -eq 1 ] && ! cs_layer_trusted "$_cr_layer"; then
      echo "rc-config: $_cr_key ignored in $(cs_layer_label "$_cr_layer") (untrusted); set it in ~/.review-council/config.yml or an untracked config.local.yml" >&2
      continue
    fi
    if valid_kind "$_cr_raw" "$4"; then
      _cr_val="$_cr_raw"
    else
      note_bad "$_cr_key" "$_cr_raw"
    fi
  done
  printf '%s' "$_cr_val"
}

# cs_set_anywhere <slot> <subpath>: does ANY usable layer (trusted or not) set
# <subpath> for <slot>?
cs_set_anywhere() {
  for _ca_layer in base overu user over; do
    cs_layer_on "$_ca_layer" || continue
    _ca_tag="$("$YQ_BIN" ".reviewers.custom[\"$1\"]$2 | tag" "$(cs_layer_file "$_ca_layer")" 2>/dev/null)" || continue
    [ "$_ca_tag" = "!!null" ] || return 0
  done
  return 1
}

# cs_opt <slot> <harness> <option> <default> <kind> <applies-to>: a typed
# harness option (safe from any layer). Resolved only when <harness> is
# <applies-to> or <applies-to> is `all`; otherwise it is never validated, only
# noted once if set, and returns 1 so the caller emits no opt line for it.
cs_opt() {
  if [ "$6" = all ] || [ "$2" = "$6" ]; then
    cs_resolve "$1" ".harness_options.$3" "$4" "$5" 0
    return 0
  fi
  if cs_set_anywhere "$1" ".harness_options.$3"; then
    echo "rc-config: reviewer.custom.$1.harness_options.$3 applies only to harness $6; ignored" >&2
  fi
  return 1
}

# cs_names <layer>: the valid slot names a layer defines, one per line, in
# document order. Invalid names are noted and dropped HERE, before any of them
# can reach a yq expression.
cs_names() {
  _cn_f="$(cs_layer_file "$1")"
  _cn_tag="$("$YQ_BIN" '.reviewers.custom | tag' "$_cn_f" 2>/dev/null)" || return 0
  case "$_cn_tag" in
    '!!null') return 0 ;;
    '!!map') ;;
    *)
      echo "rc-config: reviewers.custom in $(cs_layer_label "$1") is not a map; ignored" >&2
      return 0
      ;;
  esac
  "$YQ_BIN" '.reviewers.custom | keys | .[]' "$_cn_f" 2>/dev/null | while IFS= read -r _cn_n; do
    if valid_slotname "$_cn_n"; then
      printf '%s\n' "$_cn_n"
    else
      echo "rc-config: reviewers.custom: invalid seat name '$_cn_n' (allowed: A-Z a-z 0-9 _ -, max 32); dropped" >&2
    fi
  done
}

# cs_trusted_layer_with <slot> <subpath>: prints the highest-precedence TRUSTED
# layer that sets <subpath> for <slot> (or nothing).
cs_trusted_layer_with() {
  _ct_hit=""
  for _ct_layer in user over; do
    cs_layer_on "$_ct_layer" || continue
    _ct_tag="$("$YQ_BIN" ".reviewers.custom[\"$1\"]$2 | tag" "$(cs_layer_file "$_ct_layer")" 2>/dev/null)" || continue
    [ "$_ct_tag" = "!!null" ] || _ct_hit="$_ct_layer"
  done
  printf '%s' "$_ct_hit"
}

# cs_note_untrusted <slot> <subpath>: note when an untrusted layer sets a
# trusted-only key (ignored).
cs_note_untrusted() {
  for _cu_layer in base overu; do
    cs_layer_on "$_cu_layer" || continue
    _cu_tag="$("$YQ_BIN" ".reviewers.custom[\"$1\"]$2 | tag" "$(cs_layer_file "$_cu_layer")" 2>/dev/null)" || continue
    [ "$_cu_tag" = "!!null" ] && continue
    echo "rc-config: reviewer.custom.$1$2 ignored in $(cs_layer_label "$_cu_layer") (untrusted); set it in ~/.review-council/config.yml or an untracked config.local.yml" >&2
  done
}

# Enumerate: union of every layer's valid names, TRUSTED layers first (over,
# user, then overu, base), document order within a layer; a name takes the
# position of its first appearance in that order. The order matters: the
# orchestrator's one-seat cap takes the first available entry of
# reviewer.custom_slots, so a committed seat must never displace a trusted one.
CS_ALL=""
if [ "$yq_present" -eq 1 ]; then
  for _cs_layer in over user overu base; do
    cs_layer_on "$_cs_layer" || continue
    for _cs_n in $(cs_names "$_cs_layer"); do
      case ",$CS_ALL," in
        *",$_cs_n,"*) ;;
        *) CS_ALL="${CS_ALL:+$CS_ALL,}$_cs_n" ;;
      esac
    done
  done
fi

CS_OUT=""
CS_SLOTS=""
CS_CONFIRM=0
CS_CONF_OUT=""

_cs_old_ifs="$IFS"
IFS=','
set -f
for _cs in $CS_ALL; do
  IFS="$_cs_old_ifs"
  _harness="$(cs_resolve "$_cs" .harness "" enum:ocr,codex,claude,opencode 0)"
  if [ -z "$_harness" ]; then
    echo "rc-config: reviewer.custom.$_cs: no valid harness (supported: ocr, codex, claude, opencode); seat skipped" >&2
    IFS=','
    continue
  fi
  _model="$(cs_resolve "$_cs" .model "" modelslug 0)"
  if [ -z "$_model" ]; then
    echo "rc-config: reviewer.custom.$_cs: no valid model; seat skipped" >&2
    IFS=','
    continue
  fi
  _enabled="$(cs_resolve "$_cs" .enabled true bool 0)"
  _provider="$(cs_resolve "$_cs" .provider openrouter enum:openrouter,ollama 0)"
  _role="$(cs_resolve "$_cs" .role signal enum:signal,reviewer 0)"
  _family="$(rc_family "$_model")"
  if rc_family_distinct "$_family"; then _distinct=true; else _distinct=false; fi

  # source: which trust tier named the seat. "committed" iff NO trusted layer
  # mentions it at all — then nobody who owns this machine opted in.
  _source="$(cs_trusted_layer_with "$_cs" "")"
  case "$_source" in
    over) _source=local ;;
    user) _source=user ;;
    *) _source=committed ;;
  esac

  if [ "$_provider" = "ollama" ]; then
    _keyenv=""
  else
    _keyenv="$(cs_resolve "$_cs" .api_key_env OPENROUTER_API_KEY envname 1)"
    [ -n "$_keyenv" ] || _keyenv=OPENROUTER_API_KEY
  fi

  # Typed harness options: safe from any layer, each only for the harness(es)
  # it applies to — an opt line is emitted only for an applicable option.
  _opt_lines=""
  _cs_optl() { _opt_lines="${_opt_lines}reviewer.custom.$_cs.opt.$1=$2
"; }
  if _v="$(cs_opt "$_cs" "$_harness" effort low enum:low,medium,high ocr)"; then _cs_optl effort "$_v"; fi
  if _v="$(cs_opt "$_cs" "$_harness" concurrency "" posint_le:32 ocr)"; then _cs_optl concurrency "$_v"; fi
  if _v="$(cs_opt "$_cs" "$_harness" max_tokens_budget 0 uint9 ocr)"; then _cs_optl max_tokens_budget "$_v"; fi
  if _v="$(cs_opt "$_cs" "$_harness" timeout_minutes "" posint_le:180 all)"; then _cs_optl timeout_minutes "$_v"; fi
  if _v="$(cs_opt "$_cs" "$_harness" max_turns "" posint_le:200 claude)"; then _cs_optl max_turns "$_v"; fi

  # The human gate: a seat that only the reviewed repo's config switches on,
  # and that sends code off this machine on the operator's key. Emitted per
  # seat (needs_confirm) for the script-side confirm lock, and as a confirm.<n>
  # line for the orchestrator's one question.
  if [ "$_enabled" = true ] && [ "$_source" = committed ] && [ "$_provider" != ollama ]; then
    _needs_confirm=true
  else
    _needs_confirm=false
  fi

  _slot_lines=""
  _slot_line() { _slot_lines="$_slot_lines$1
"; }
  _slot_line "reviewer.custom.$_cs.enabled=$_enabled"
  _slot_line "reviewer.custom.$_cs.source=$_source"
  _slot_line "reviewer.custom.$_cs.needs_confirm=$_needs_confirm"
  _slot_line "reviewer.custom.$_cs.harness=$_harness"
  _slot_line "reviewer.custom.$_cs.provider=$_provider"
  _slot_line "reviewer.custom.$_cs.model=$_model"
  _slot_line "reviewer.custom.$_cs.role=$_role"
  _slot_line "reviewer.custom.$_cs.api_key_env=$_keyenv"
  _slot_line "reviewer.custom.$_cs.family=$_family"
  _slot_line "reviewer.custom.$_cs.distinct=$_distinct"
  _slot_lines="$_slot_lines$_opt_lines"

  # Free-form flags/env are ocr-only. For an agent harness they are ignored
  # from EVERY layer — one note per key, and not the "set it in a trusted
  # layer" advice, which would be wrong for these harnesses.
  _ff_ocr=1
  if [ "$_harness" != ocr ]; then
    _ff_ocr=0
    for _ff_k in flags env; do
      if cs_set_anywhere "$_cs" ".harness_options.$_ff_k"; then
        echo "rc-config: reviewer.custom.$_cs.harness_options.$_ff_k: free-form flags/env are supported only for harness ocr; ignored" >&2
      fi
    done
  fi

  # Free-form flags: trusted layers only; the highest trusted layer that sets
  # the list wins wholesale. One bad or reserved token drops the whole list
  # (fail closed — a half-applied flag list could shift a value onto a flag).
  _fl_layer=""
  if [ "$_ff_ocr" -eq 1 ]; then
    cs_note_untrusted "$_cs" .harness_options.flags
    _fl_layer="$(cs_trusted_layer_with "$_cs" .harness_options.flags)"
  fi
  if [ -n "$_fl_layer" ]; then
    _fl_f="$(cs_layer_file "$_fl_layer")"
    _fl_p=".reviewers.custom[\"$_cs\"].harness_options.flags"
    if [ "$("$YQ_BIN" "$_fl_p | tag" "$_fl_f" 2>/dev/null)" != "!!seq" ]; then
      echo "rc-config: reviewer.custom.$_cs.harness_options.flags: not a list; ignored" >&2
    else
      _fl_n="$("$YQ_BIN" "$_fl_p | length" "$_fl_f" 2>/dev/null)" || _fl_n=0
      valid_uint "$_fl_n" || _fl_n=0
      _fl_i=0
      _fl_lines=""
      _fl_bad=""
      while [ "$_fl_i" -lt "$_fl_n" ]; do
        _fl_tok="$(get_raw "$_fl_f" "${_fl_p}[$_fl_i]")" || _fl_tok=""
        if ! valid_flagtoken "$_fl_tok"; then
          _fl_bad="invalid token '$_fl_tok'"
          break
        fi
        if reserved_flag "$_fl_tok"; then
          _fl_bad="'$_fl_tok' is reserved by the council (it would undo the seat's isolation)"
          break
        fi
        _fl_i=$((_fl_i + 1))
        _fl_lines="${_fl_lines}reviewer.custom.$_cs.flag.$_fl_i=$_fl_tok
"
      done
      if [ -n "$_fl_bad" ]; then
        echo "rc-config: reviewer.custom.$_cs.harness_options.flags: $_fl_bad; whole list ignored" >&2
      else
        _slot_lines="$_slot_lines$_fl_lines"
      fi
    fi
  fi

  # Free-form env: trusted layers only; highest trusted layer wins wholesale;
  # each entry validated on its own (a bad entry is dropped, others kept).
  _ev_layer=""
  if [ "$_ff_ocr" -eq 1 ]; then
    cs_note_untrusted "$_cs" .harness_options.env
    _ev_layer="$(cs_trusted_layer_with "$_cs" .harness_options.env)"
  fi
  if [ -n "$_ev_layer" ]; then
    _ev_f="$(cs_layer_file "$_ev_layer")"
    _ev_p=".reviewers.custom[\"$_cs\"].harness_options.env"
    if [ "$("$YQ_BIN" "$_ev_p | tag" "$_ev_f" 2>/dev/null)" != "!!map" ]; then
      echo "rc-config: reviewer.custom.$_cs.harness_options.env: not a map; ignored" >&2
    else
      for _ev_k in $("$YQ_BIN" "$_ev_p | keys | .[]" "$_ev_f" 2>/dev/null); do
        if [ -z "$_ev_k" ] || ! valid_envname "$_ev_k"; then
          echo "rc-config: reviewer.custom.$_cs.harness_options.env: invalid name '$_ev_k'; dropped" >&2
          continue
        fi
        if reserved_env "$_ev_k" "$_keyenv"; then
          echo "rc-config: reviewer.custom.$_cs.harness_options.env: '$_ev_k' is reserved by the council; dropped" >&2
          continue
        fi
        _ev_v="$(get_raw "$_ev_f" "${_ev_p}[\"$_ev_k\"]")" || continue
        if ! valid_str "$_ev_v" || [ "${#_ev_v}" -gt 1024 ]; then
          echo "rc-config: reviewer.custom.$_cs.harness_options.env.$_ev_k: invalid value; dropped" >&2
          continue
        fi
        _slot_line "reviewer.custom.$_cs.env.$_ev_k=$_ev_v"
      done
    fi
  fi

  CS_OUT="$CS_OUT$_slot_lines"
  CS_SLOTS="${CS_SLOTS:+$CS_SLOTS,}$_cs"

  if [ "$_needs_confirm" = true ]; then
    CS_CONFIRM=$((CS_CONFIRM + 1))
    # codex has no per-request OpenRouter provider preferences, so the council's
    # `data_collection: deny` cannot be sent for it — say so in the one question.
    _cf_note=""
    [ "$_harness" != codex ] || _cf_note=" Note: the codex harness cannot ask OpenRouter to deny data collection."
    CS_CONF_OUT="${CS_CONF_OUT}confirm.$CS_CONFIRM=Seat '$_cs' is enabled only by the repo's committed config, and sends code to OpenRouter (model $_model), billed to your $_keyenv.$_cf_note
"
  fi
  IFS=','
done
set +f
IFS="$_cs_old_ifs"

if [ -n "$CS_SLOTS" ]; then
  echo "# custom reviewers"
  printf 'reviewer.custom_slots=%s\n' "$CS_SLOTS"
  printf '%s' "$CS_OUT"
  printf '%s' "$CS_CONF_OUT"
fi

exit 0
