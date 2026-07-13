# Configuration Schema

Review Council reads an optional per-repo config file that controls the reviewer roster,
the review lenses, and run settings. Configuration is **declarative data** — it is parsed,
never executed. There are no arbitrary-command reviewers or hooks; a config file can only
select from the built-in providers/lenses and set the documented knobs.

Everything here is optional. With **no config file at all**, the plugin runs on built-in
defaults (plus any `RC_*` environment overrides) — byte-identical to its pre-config
behavior.

## The two files

| File | Committed? | Purpose |
|---|---|---|
| `.review-council/config.yml` | yes (team defaults) | Shared, checked-in configuration for the repo. |
| `.review-council/config.local.yml` | **no — gitignored** | Per-machine overrides. Identical schema; wins over `config.yml`. |

Both live in the **target repo's** `.review-council/` directory (the repo being reviewed),
not the plugin. `config.local.yml` should be added to the repo's `.gitignore` so per-machine
tweaks never get committed.

## Precedence

Applied **per key**, highest wins:

```
env  >  config.local.yml  >  config.yml  >  built-in default
```

- Start from the built-in default, override with `config.yml`, override with
  `config.local.yml`, override with environment variables.
- **Env (`RC_*`) overrides apply to `settings.*` only** (see the settings table). Reviewers
  and lenses are controlled by the files (and defaults) only — there is no env override for
  the roster or lenses.

## `reviewers:` block

Enable/disable each reviewer and optionally pin its model. Disabling a reviewer drops it
from the roster (detection still applies on top — a reviewer must be both *enabled here* and
*available on the machine* to participate).

```yaml
reviewers:
  claude:     { enabled: false }              # drop Claude from the roster
  google:     { model: gemini-2.5-pro }       # pin a model for the Google slot
  perplexity: { enabled: false }
```

| Key | Default |
|---|---|
| `reviewer.claude.enabled` | `true` |
| `reviewer.claude.model` | *(empty — use the tool's own default)* |
| `reviewer.codex.enabled` | `true` |
| `reviewer.codex.model` | *(empty)* |
| `reviewer.google.enabled` | `true` |
| `reviewer.google.model` | *(empty)* |
| `reviewer.perplexity.enabled` | `true` |
| `reviewer.perplexity.model` | `sonar` |

An empty model means "let the reviewer use its own default model" — nothing is passed. The
council still needs `settings.min_reviewers` participants after disabling; if too few remain
(also after availability detection), the existing min-reviewers handling applies (single-
reviewer mode or a prompt).

## `lenses:` block

Lenses are review perspectives. Each lens has an `enabled` toggle and a `providers` binding.

```yaml
lenses:
  security:    { providers: [google] }        # pin who runs the security lens
  performance: { enabled: false }             # turn a lens off
```

| Key | Default |
|---|---|
| `lens.<lens>.enabled` | `true` |
| `lens.<lens>.providers` | `auto` for every lens **except** `lens.dependency.providers` = `perplexity` |

Lenses: `security`, `correctness`, `cross_file`, `performance`, `design`, `dependency`.

- **`providers` is ALWAYS a YAML list** (e.g. `[google]` or `[google, claude]`). It is printed
  comma-joined (`lens.security.providers=google,claude`).
- **Omitting `providers` = `auto`** — the orchestrator picks providers diff-aware (which
  providers actually run this lens is chosen in a later PR; today the binding is recorded).
- **Pinning `security.providers` REPLACES the dedicated security subagent.** When you set
  `lenses.security.providers` to an explicit list, that list *becomes* the security review —
  it does **not** add a second security pass on top of the dedicated one. The reader signals
  this with an extra key, emitted only for `security`:
  - `lens.security.replaces_dedicated=true` when `security.providers` is explicitly pinned.
  - `lens.security.replaces_dedicated=false` when it stays `auto` (the default).

## `settings:` block

Run knobs. These are the only keys with an `RC_*` environment override (env wins).

```yaml
settings:
  verify: false
  run_budget_seconds: 300
  min_reviewers: 3
```

| Key | Default | Env override | Purpose |
|---|---|---|---|
| `settings.personas` | `true` | `RC_PERSONAS` | Use reviewer personas when prompting reviewers. |
| `settings.verify` | `true` | `RC_VERIFY` | Run the verification pass over findings. |
| `settings.verify_max_findings` | `12` | `RC_VERIFY_CAP` | Cap on findings sent to the verification pass. |
| `settings.learn` | `true` | `RC_LEARN` | Enable the learning/memory mechanism. |
| `settings.min_reviewers` | `2` | `RC_MIN_REVIEWERS` | Minimum participating reviewers for council mode. |
| `settings.reviewer_timeout_seconds` | `600` | `RC_REVIEWER_TIMEOUT` | Per-invocation wall-clock cap (seconds) for CLI/API reviewers. |
| `settings.run_budget_seconds` | `600` | `RC_RUN_BUDGET` | Total wall-clock budget (seconds) for the whole run. |
| `settings.auto_retry` | `false` | `RC_AUTO_RETRY` | Retry failed reviewers without prompting (CI-friendly). |

Booleans must be `true`/`false`; the four numeric knobs must be positive integers.

## Validation & graceful degradation

The reader (`scripts/rc-config.sh`) is defensive by design — a broken config never aborts a
review, it degrades to the next layer down:

- **Unknown keys** are ignored.
- **A malformed value** (e.g. `min_reviewers: abc`, or a boolean that isn't `true`/`false`)
  falls back to that key's default, with a note on **stderr**.
- **A malformed file** (YAML parse error) is skipped with a stderr note; the other layers
  still apply.
- **A `static_analysis:` block** (a Phase 2 feature) is ignored — it does not error.

The reader prints the **effective config** as `key=value` lines to **stdout** and all
diagnostics to **stderr**, and always exits `0`.

## `yq` requirement

Config files are parsed with **[mikefarah/yq](https://github.com/mikefarah/yq) v4** (the Go
YAML processor). It must be on `PATH`.

> **Note — the right `yq`.** There is a *different* Python tool also named `yq` (a `jq`
> wrapper). Review Council needs **mikefarah/yq** — its `yq --version` prints a
> `https://github.com/mikefarah/yq` URL. Install: `brew install yq` (macOS) or see
> <https://github.com/mikefarah/yq#install>.

**Without `yq` installed, the config files are ignored** and the plugin runs on built-in
defaults + `RC_*` env overrides (still fully functional, with one stderr note that `yq` was
not found). `yq` is therefore **optional** — it is only needed to *use* config files.

## Reference blocks

Two ready-to-use templates. Because every key is optional and defaults to the built-in
value, **an all-commented file behaves exactly like no file at all (pure defaults)** —
uncomment only what you want to change.

### (1) Quick-start — minimal overrides

```yaml
# .review-council/config.yml — Review Council configuration (team defaults).
# Everything is optional. An all-commented file = built-in defaults.
# Uncomment and edit only what you want to change.

# reviewers:
#   perplexity:
#     enabled: false          # drop a reviewer from the roster
#   google:
#     model: gemini-2.5-pro   # pin a specific model

# settings:
#   verify: false             # skip the verification pass
#   min_reviewers: 3          # require 3 participating reviewers
```

### (2) Full reference — every option, with defaults

```yaml
# ── Review Council — full configuration reference ────────────────────────────
# Every key below is shown with its built-in default. All keys are optional;
# delete or comment any you don't need. `.review-council/config.local.yml` uses
# this IDENTICAL schema and overrides config.yml per key. RC_* env vars win over
# both files (settings.* only). An all-commented file = pure defaults.

# reviewers:                     # enable/disable + optional model per reviewer
#   claude:     { enabled: true,  model: "" }        # "" = the tool's own default model
#   codex:      { enabled: true,  model: "" }
#   google:     { enabled: true,  model: "" }
#   perplexity: { enabled: true,  model: sonar }

# lenses:                        # review perspectives
#   # `providers` is ALWAYS a list; OMIT it for `auto` (diff-aware selection).
#   # Pinning security.providers REPLACES the dedicated security reviewer (not additive).
#   security:
#     enabled: true
#     # providers: [google, claude]     # omit -> auto
#   correctness:
#     enabled: true
#     # providers: [claude]             # omit -> auto
#   cross_file:
#     enabled: true
#     # providers: [codex]              # omit -> auto
#   performance:
#     enabled: true
#     # providers: [google]             # omit -> auto
#   design:
#     enabled: true
#     # providers: [claude]             # omit -> auto
#   dependency:
#     enabled: true
#     # providers: [perplexity]         # default when omitted -> [perplexity]

# settings:                      # run knobs (each also settable via its RC_* env var, which wins)
#   personas:                 true     # RC_PERSONAS
#   verify:                   true     # RC_VERIFY
#   verify_max_findings:      12       # RC_VERIFY_CAP
#   learn:                    true     # RC_LEARN
#   min_reviewers:            2        # RC_MIN_REVIEWERS
#   reviewer_timeout_seconds: 600      # RC_REVIEWER_TIMEOUT
#   run_budget_seconds:       600      # RC_RUN_BUDGET
#   auto_retry:               false    # RC_AUTO_RETRY
```

See `skills/run/SKILL.md` Step 0 for how the orchestrator reads and applies this, and
`rules/orchestration.md` for the run-settings precedence.
