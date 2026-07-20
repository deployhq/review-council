# Configuration Schema

Review Council reads an optional per-repo config file that controls the reviewer roster,
the review lenses, and run settings. Configuration is **declarative data** — it is parsed,
never executed. There are no arbitrary-command reviewers or hooks; a config file can only
select from the built-in providers/lenses and set the documented knobs. It is read from the
**reviewed repo's** directory, so treat every value as untrusted: any value that can reach a
command line or query expression is charset-validated at the reader before it is emitted (see
`valid_modelslug` and CLAUDE.md → Security Invariants). *Parsed, never executed* is enforced
there.

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
- **Env (`RC_*`) overrides apply to `settings.*` and `static_analysis.*` only** (see their
  respective tables). Reviewers and lenses are controlled by the files (and defaults) only —
  there is no env override for the roster or lenses.

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
- **Omitting `providers` = `auto`** (except `dependency`, which defaults to `perplexity`) —
  the orchestrator picks providers diff-aware in Step 3 (Lens Assignment); an explicit
  `providers` list pins the lens to exactly those providers instead.
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
| `settings.learn` | `true` | `RC_LEARN` | Enable learnings recall (Step 0.5) and capture (Step 7) — see [Learnings](#learnings) below. |
| `settings.min_reviewers` | `2` | `RC_MIN_REVIEWERS` | Minimum participating reviewers for council mode. |
| `settings.reviewer_timeout_seconds` | `600` | `RC_REVIEWER_TIMEOUT` | Per-invocation wall-clock cap (seconds) for CLI/API reviewers. |
| `settings.run_budget_seconds` | `600` | `RC_RUN_BUDGET` | Total wall-clock budget (seconds) for the whole run. |
| `settings.auto_retry` | `false` | `RC_AUTO_RETRY` | Retry failed reviewers without prompting (CI-friendly). |
| `settings.health_probe` | `false` | `RC_HEALTH_PROBE` | Opt-in Step-0 health probe (Codex + Google slots) so `available`/`min_reviewers` reflect *usable*, not merely installed. Default off; a provider is dropped only on positive hard-fail evidence (auth/quota/overload), fail-open otherwise. |
| `settings.health_probe_timeout_seconds` | `20` | `RC_HEALTH_PROBE_TIMEOUT` | Short wall-clock cap (seconds) for each health probe. |
| `settings.claude_max_turns` | `100` | `RC_CLAUDE_MAX_TURNS` | Turn budget (`maxTurns`) for the native Claude and Security reviewer subagents. Default 100 (lenient); lower it to cap local review cost. |

Booleans must be `true`/`false`; numeric knobs must be positive integers.

## `static_analysis:` block

Controls the deterministic static-analysis layer (Phase 2) — the tool runner that scans
the diff with `gitleaks`, `trufflehog`, `osv-scanner`, `semgrep`, `ruff`, `shellcheck`,
`actionlint`, and `hadolint` before the council reviews it. Despite reading visually like
its own top-level block (a sibling of `reviewers:`/`lenses:`/`settings:`), it behaves
exactly like `settings:` — files **and** env, env wins.

```yaml
static_analysis:
  tools: [gitleaks, semgrep, ruff]   # narrow the default 8-tool list
  timeout_seconds: 90
```

| Key | Default | Env override | Purpose |
|---|---|---|---|
| `static_analysis.enabled` | `true` | `RC_STATIC_ANALYSIS` | Turn the whole static-analysis layer on/off. |
| `static_analysis.tools` | `gitleaks,trufflehog,osv-scanner,semgrep,ruff,shellcheck,actionlint,hadolint` | `RC_STATIC_TOOLS` | Which tools run (comma-separated when set via env). |
| `static_analysis.timeout_seconds` | `60` | `RC_STATIC_TIMEOUT` | Per-tool wall-clock cap (seconds). |
| `static_analysis.semgrep_config` | `p/default` | `RC_SEMGREP_CONFIG` | A registry pack ref (`p/default`, `p/ruby`, …), `off` (skip semgrep), or a repo-owned ruleset path. `auto` is unsupported (it uploads project metadata and requires metrics, which we disable) and is skipped with guidance. |

- **`tools` is a list**, like `lenses.<lens>.providers` — but unlike lenses, it **does**
  have an env override: `RC_STATIC_TOOLS` (comma-separated) fully replaces the
  files-derived list when set, it does not merge with it.
- Each entry in `tools` is validated against the known set of eight names above; an
  unrecognized entry is **dropped with a stderr note**, not a hard failure — the rest of
  the list still takes effect.
- `trufflehog` is **default-on**. Its `--results=verified` mode makes live outbound
  network calls that authenticate with any credential it finds, to confirm it's real. Drop
  `trufflehog` from `tools` to opt out if that outbound call is undesirable in your
  environment (see `rules/static-analysis.md`).
- `semgrep_config: off` skips semgrep unconditionally, regardless of `tools`.
- `semgrep_config` defaults to the **`p/default`** registry pack. `auto` is **not** usable
  here — it uploads project metadata and requires semgrep metrics, which Review Council
  disables (`--metrics=off`); setting it to `auto` skips semgrep with a note pointing at
  `p/default`. Use a `p/…`/`r/…` registry ref or a committed, repo-owned ruleset path.

## Learnings

`.review-council/learnings.md` is a **committed, team-shared** file (unlike `config.local.yml`,
it is **not** gitignored) that persists confirmed review outcomes across runs. It has a read
side (Step 0.5 — recall) and a write side (Step 7 — capture); both are gated on the single
`settings.learn` knob (`RC_LEARN`, default `true`) — turn it `false` and the file is neither
read nor written.

### Format (§3.6)

Two sections, always both present (even when empty). `scripts/rc-learn.sh` creates this exact
skeleton the first time it writes, if the file doesn't already exist:

```markdown
# Review Council — Learnings   (committed; team-shared; edit freely)

## Conventions   (injected once into the Step-2 baseline context package)

- <one-line rule, e.g. "Migrations are auto-generated; do not flag missing down-migrations">

## Suppressions   (known false positives — judge down-weights/skips matches by fingerprint)

- fingerprint: <path>::<symbol-or-hunk>::<concern> | reason: <one-line reason> | added: <YYYY-MM-DD>
```

- **Conventions** — a bare `- <text>` bullet: a project-specific rule about what *not* to flag.
- **Suppressions** — a `- fingerprint: … | reason: … | added: …` bullet, one per known false
  positive. The `fingerprint` is the judge's **canonical** fingerprint (`skills/run/SKILL.md`
  §5.1, `<relpath>::<normalized-symbol-or-hunk>::<normalized-concern>`) — always copied
  verbatim from the ledger, never hand-authored. `reason` and `fingerprint` may not contain
  `|` (the field delimiter); `added` is `YYYY-MM-DD`.

### Recall (Step 0.5 — read side)

If `settings.learn` is true, Step 0.5 reads the file from the **target repo** (the repo being
reviewed, alongside `.review-council/config.yml`). A missing file is skipped silently — it is
the normal case, not a warning. Once read, the two sections travel different paths:

- **Conventions** fold into the Step-2 baseline context package, under a "Team Learnings —
  Conventions" heading — injected **once**, so every reviewer sees it (not re-pasted per
  dispatch).
- **Suppressions** are **held**, not injected into any reviewer prompt — they travel forward to
  the Step-5 judge, which suppresses any surviving finding whose canonical fingerprint matches
  one and reports `Suppressions applied: N` in the ledger.

### Capture (Step 7 — write side)

After the Step-6 report, if `settings.learn` is true, Step 7 runs a human-confirmed **capture
gate**: it walks the surviving findings (driven off the Step-5 ledger) and asks the author to
mark each **tackle** (fixing it — captures nothing), **skip** (with a one-line reason), or
**skip all**. Only a skip with a **generalizable** reason becomes a learning — a one-off skip
("not now / out of scope") captures nothing:

- *"this specific finding is a known false positive here"* → a **Suppression**, keyed by the
  finding's ledger fingerprint (used verbatim).
- *"we never flag X in this repo"* (a general rule) → a **Convention**.
- Several skips sharing one general reason this run → propose a single Convention rather than N
  Suppressions.

Nothing is written until the human explicitly approves the exact entry text. On approval, the
orchestrator appends one entry per confirmed call via the bundled writer — never by
hand-formatting the file itself:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/rc-learn.sh" add-suppression "<ledger-fingerprint>" "<reason>"
"${CLAUDE_PLUGIN_ROOT}/scripts/rc-learn.sh" add-convention  "<one-line rule>"
```

`rc-learn.sh` creates the file (the skeleton above) if it's absent, appends under the right
section in the exact format above, and is **idempotent** — re-approving a suppression whose
fingerprint already exists, or a convention whose normalized (trim + collapse-whitespace +
lowercase) text already exists, is a safe no-op (stderr note, exit 0). Declining, or
`settings.learn` being off, writes nothing.

These captured entries are exactly what the **next** run's Step 0.5 recalls — Step 7 writes,
Step 0.5 reads, closing the loop.

## Validation & graceful degradation

The reader (`scripts/rc-config.sh`) is defensive by design — a broken config never aborts a
review, it degrades to the next layer down:

- **Unknown keys** are ignored.
- **A malformed value** (e.g. `min_reviewers: abc`, or a boolean that isn't `true`/`false`)
  falls back to that key's default, with a note on **stderr**.
- **A malformed file** (YAML parse error) is skipped with a stderr note; the other layers
  still apply.
- **Unrecognized `static_analysis:` sub-keys** (e.g. a per-tool `enabled:` block, or any
  key other than the four documented ones) are ignored like any other unknown key — they
  do not error, and the four real keys still resolve normally.

The reader prints the **effective config** as `key=value` lines to **stdout** and all
diagnostics to **stderr**, and always exits `0`.

## `yq` requirement

Config files are parsed with **[mikefarah/yq](https://github.com/mikefarah/yq) v4** (the Go
YAML processor). It must be on `PATH`. To use a `yq` at a non-standard location, set the
`RC_YQ` env var to its path (default: `yq`).

> **Note — the right `yq`.** There is a *different* Python tool also named `yq` (a `jq`
> wrapper). Review Council needs **mikefarah/yq** — its `yq --version` prints a
> `https://github.com/mikefarah/yq` URL. Install: `brew install yq` (macOS) or see
> <https://github.com/mikefarah/yq#install>.

**Without `yq` installed, the config files are ignored** and the plugin runs on built-in
defaults + `RC_*` env overrides (still fully functional, with one stderr note that `yq` was
not found). `yq` is therefore **optional** — it is only needed to *use* config files.

Run `/review-council:setup` to check for `yq` — it will detect the right binary and, with
your explicit consent, install mikefarah/yq v4 for you (`brew install yq`, or a direct
binary fetch on Linux without Homebrew). Decline and it just prints the manual command
above and moves on.

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

# static_analysis:
#   tools: [gitleaks, semgrep, ruff]   # narrow the default 8-tool list
```

### (2) Full reference — every option, with defaults

```yaml
# ── Review Council — full configuration reference ────────────────────────────
# Every key below is shown with its built-in default. All keys are optional;
# delete or comment any you don't need. `.review-council/config.local.yml` uses
# this IDENTICAL schema and overrides config.yml per key. RC_* env vars win over
# both files (settings.* and static_analysis.* only). An all-commented file = pure defaults.

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
#   personas:                     true     # RC_PERSONAS
#   verify:                       true     # RC_VERIFY
#   verify_max_findings:          12       # RC_VERIFY_CAP
#   learn:                        true     # RC_LEARN
#   min_reviewers:                2        # RC_MIN_REVIEWERS
#   reviewer_timeout_seconds:     600      # RC_REVIEWER_TIMEOUT
#   run_budget_seconds:           600      # RC_RUN_BUDGET
#   auto_retry:                   false    # RC_AUTO_RETRY
#   health_probe:                 false    # RC_HEALTH_PROBE
#   health_probe_timeout_seconds: 20       # RC_HEALTH_PROBE_TIMEOUT
#   claude_max_turns:             100      # RC_CLAUDE_MAX_TURNS

# static_analysis:               # deterministic tool layer (each also settable via its RC_* env var, which wins)
#   enabled: true                    # RC_STATIC_ANALYSIS
#   tools: [gitleaks, trufflehog, osv-scanner, semgrep, ruff, shellcheck, actionlint, hadolint]   # RC_STATIC_TOOLS (comma-separated)
#   timeout_seconds: 60              # RC_STATIC_TIMEOUT
#   semgrep_config: p/default        # RC_SEMGREP_CONFIG — a registry pack (p/…) | off | a repo-owned ruleset path (auto is skipped: needs metrics)
```

See `skills/run/SKILL.md` Step 0 for how the orchestrator reads and applies this, and
`rules/orchestration.md` for the run-settings precedence.
