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

# valid_kind <val> <kind>: bool|posint|str
valid_kind() {
  case "$2" in
    bool) valid_bool "$1" ;;
    posint) valid_posint "$1" ;;
    str) valid_str "$1" ;;
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

# ---------------------------------------------------------------------------
# Reviewers (roster) — files only, no env override
# ---------------------------------------------------------------------------

emit_reviewer() {
  # $1 = provider name, $2 = default model
  _er_p="$1"
  _er_defmodel="$2"
  _er_enabled="$(resolve ".reviewers.$_er_p.enabled" "true" bool "reviewer.$_er_p.enabled")"
  _er_model="$(resolve ".reviewers.$_er_p.model" "$_er_defmodel" str "reviewer.$_er_p.model")"
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

exit 0
