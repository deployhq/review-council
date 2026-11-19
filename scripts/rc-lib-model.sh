# shellcheck shell=bash
# rc-lib-model.sh — the model-ID check shared by the CI action's run-review.sh
# and scripts/rc-recheck.sh. Source it; needs bash ([[ =~ ]]).
#
# check_model <input> <value> [allow-1m|allow-slash]: a model ID from a
# workflow input. Whole-string match ([[ =~ ]], not grep -x, which passes a
# multi-line value). The charset keeps it safe on a command line and inside a
# TOML string. allow-slash is for OpenRouter IDs (vendor/model). An empty value
# passes (= the tool's default). On a bad value: a ::error:: line that names
# the input (never echoes the value: a multi-line one could forge log
# commands), then exit 1.
check_model() {
  local re='^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}' extra=""
  case "${3:-}" in
    allow-1m)
      re+='(\[[A-Za-z0-9]{1,8}\])?'
      extra=" and an optional [1m] suffix"
      ;;
    allow-slash)
      re='^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}'
      extra=" /"
      ;;
  esac
  re+='$'
  if [ -n "$2" ] && ! [[ "$2" =~ $re ]]; then
    echo "::error::Invalid $1 (allowed: letters, digits, . _ : -$extra)."
    exit 1
  fi
}
