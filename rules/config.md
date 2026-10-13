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

## The files, and which ones are trusted

| File | Committed? | Trusted? | Purpose |
|---|---|---|---|
| `.review-council/config.yml` | yes (team defaults) | **no** — the reviewed repo writes it | Shared, checked-in configuration for the repo. |
| `.review-council/config.local.yml` | **no — gitignored** | **yes, only while git does not track it** | Per-machine overrides. Identical schema; wins over `config.yml`. |
| `~/.review-council/config.yml` | n/a — your home dir | **yes** | The **user layer**. In this release it is read **only** for [`reviewers.custom`](#reviewerscustom-block--custom-reviewer-seats) — every other key in it is ignored. Path override: `RC_USER_CONFIG`. |

The first two live in the **target repo's** `.review-council/` directory (the repo being
reviewed), not the plugin. `config.local.yml` should be added to the repo's `.gitignore` so
per-machine tweaks never get committed.

**Being gitignored is a convention, not a boundary** — a reviewed repo can simply commit a
`config.local.yml`. So when git **tracks** `config.local.yml`, the reader notes
`config.local.yml is tracked by git — treated as untrusted` and handles it like the committed
`config.yml` for the security-sensitive keys (`pr_comments.bot_token_env`, `api_key_env`, a
custom seat's free-form `harness_options`, and a seat's trust `source`). Its ordinary keys
still apply as before. Outside a git repo it counts as untracked. Environment variables are
trusted too (they are yours, not the repo's).

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
- **Custom reviewer seats** (`reviewers.custom`) also read the user layer, per key:
  `config.local.yml` (untracked) > `~/.review-council/config.yml` > `config.yml` (and a
  tracked `config.local.yml`) > default. See the block's own section for the keys that only
  trusted layers may set.

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

## `reviewers.custom:` block — custom reviewer seats

Adds extra Round-1 reviewers, each running a model **you** choose (Qwen, Kimi, GLM, DeepSeek,
a local Ollama model, …) through a borrowed agentic CLI — the **harness**: Alibaba's
OpenCodeReview (`ocr`), `codex`, Claude Code (`claude`) or `opencode`. **Off by default and opt-in:** no seat exists until you name a
`harness` and a `model`, and no model is ever defaulted. With no `custom:` block in any layer,
the reader emits nothing for it and the run is byte-identical to a plugin without the feature.

A seat is a **finder only**: it can add findings, never verify (or refute) anyone else's. Its
behaviour in the council is set by `role` and by the model's **family** (derived from the
slug — see below). Full transport details: `rules/providers.md` → Custom seats.

### Example — a local Ollama seat (user layer, nothing leaves the machine)

```yaml
# ~/.review-council/config.yml — trusted; applies to every repo you review
reviewers:
  custom:
    qwen-local:
      harness: ocr
      provider: ollama
      model: qwen3.6:35b-a3b-coding-nvfp4
      role: signal                  # findings go to a separate "Extra signals" section
      harness_options:
        effort: low
        timeout_minutes: 45         # the seat's own deadline; see Budget below
        env: { OCR_LLM_TIMEOUT: "600" }   # trusted layers only
```

### Example — an OpenRouter seat with its own key variable

```yaml
# ~/.review-council/config.yml, or an UNTRACKED .review-council/config.local.yml
reviewers:
  custom:
    kimi:
      harness: ocr
      provider: openrouter
      model: moonshotai/kimi-k2.7-code
      role: reviewer                # merged into the main list; may count toward min_reviewers
      api_key_env: OPENROUTER_REVIEW_KEY   # the NAME of the env var — never the key itself
      harness_options:
        effort: medium
        concurrency: 4
        max_tokens_budget: 2000000
        flags: ["--max-tools", "80"]       # trusted layers only
```

The key **value** is read from your environment at run time and never appears in config, on a
command line, or in the `ocr` config file the council writes.

### Keys

| Key (`reviewers.custom.<slot>.…`) | Default | Validation / notes |
|---|---|---|
| *(slot name)* | — | `^[A-Za-z0-9_-]{1,32}$`, checked **before** it is ever used in a query; an invalid name drops the seat with a note. |
| `enabled` | `true` | bool |
| `harness` | *(none — required)* | enum: `ocr` \| `codex` \| `claude` \| `opencode`. Missing/invalid → seat dropped with a note. See [Which harness](#which-harness). |
| `provider` | `openrouter` | `openrouter` \| `ollama`, for every harness. Invalid → seat dropped. |
| `model` | *(empty → seat off)* | required; the `modelslug` charset (`^[A-Za-z0-9~@][A-Za-z0-9._:~@/-]{0,127}$`, no leading `-`). Decides the family. |
| `role` | `signal` | `signal` \| `reviewer` — see [Role](#role). |
| `api_key_env` | `OPENROUTER_API_KEY` (OpenRouter); empty (Ollama) | **Trusted layers only.** A POSIX identifier (`envname`), re-checked by the dispatch script. Ignored for Ollama. |
| `harness_options.effort` | `low` | **`ocr` only.** `low` \| `medium` \| `high` — `ocr`'s review rounds (1/2/3). |
| `harness_options.concurrency` | *(ocr's own)* | **`ocr` only.** integer 1–32 |
| `harness_options.max_tokens_budget` | `0` (= ocr's default) | **`ocr` only.** positive integer, at most 9 digits; `ocr` stops and publishes partial results when it is spent. |
| `harness_options.timeout_minutes` | `ocr`: derived from the run budget; others: `settings.reviewer_timeout_seconds` | integer 1–180, every harness — see [Budget](#budget-for-a-seat). |
| `harness_options.max_turns` | `settings.claude_max_turns` | **`claude` only.** integer 1–200 — Claude Code's `--max-turns`. |
| `harness_options.flags` | *(none)* | **`ocr` only, trusted layers only.** A YAML list of extra `ocr review` argv tokens. Each token: letters, digits, `._:/@=,+%-` and the glob characters `*`/`?`, ≤ 256 chars; it reaches `ocr` as one quoted argv element, never through a command line. |
| `harness_options.env` | *(none)* | **`ocr` only, trusted layers only.** A map `NAME: value` added to `ocr`'s environment. `NAME` is a POSIX identifier; values may not contain control characters. |

**Options per harness.** An option set on a harness it does not apply to is dropped with a
note. `codex`, `claude` and `opencode` take **no** free-form `flags`/`env` from any layer: each has
isolation-critical flags (`--sandbox`, `--tools`, `--pure`, …) and environment variables
(`CODEX_HOME`, `ANTHROPIC_BASE_URL`, `OPENCODE_DISABLE_PROJECT_CONFIG`, …) that must never be
overridable.

**Typed vs free-form options.** The typed `harness_options` are validated and accepted
from **any** layer, including the committed `config.yml`. `flags` and `env` can shape `ocr`'s
argv and environment freely, so they are honoured **only** from trusted layers; in the
committed `config.yml` (or a tracked `config.local.yml`) they are ignored with a stderr note.

**Reserved — never settable, from any layer.** Flags that would undo the seat's isolation or
its output contract are dropped with a note: `--rule --repo --from --to --commit -c --tools
--provider --model -o --output --format -f --audience --resume --preview -p` (also their
`--flag=value` forms, and any single-dash cluster or attached value touching `-c -f -o -p`, e.g.
`-o/x` or `-cv`). Reserved env names: `HOME`, `PATH`, `TMPDIR`, `OCR_NO_UPDATE`, and the
provider key variable.

**Don't put secrets in `harness_options.env`** — the effective config (including these lines)
is echoed at the start of every run.

### Trust: where a seat comes from

Per key, `config.local.yml` (untracked) > `~/.review-council/config.yml` > the committed
`config.yml` (and a tracked `config.local.yml`) > default. The reader reports each seat's
`source`: `local` or `user` when a trusted layer names the seat, `committed` when **only** the
repo's own config does. Note that a committed `config.yml` can still fill a typed key that no
trusted layer sets — but never `api_key_env`, `flags` or `env`.

**The confirm gate.** A legitimate-but-risky choice that comes **only** from the committed
config makes the reader emit `confirm.<n>=<plain-language reason>`. The orchestrator asks you
**once** at Step 0 and skips the seat for this run on "no" or no answer. In this release the
trigger is a seat defined only in the committed `config.yml` that sends code off the machine
(`provider: openrouter`): a repo you review cannot make the council send its code to OpenRouter
on your key without your say-so. Values that are never legitimate from committed config
(`api_key_env`, `flags`, `env`) are ignored with a note — no question asked.

### Role

`role` is the only knob for how a seat behaves in the council:

| | `signal` (default) | `reviewer` |
|---|---|---|
| Seat-only findings land in | a separate **"Extra signals (<slot> via ocr)"** report section | the main severity lists |
| Counts toward `settings.min_reviewers` | never | only if the family is **distinct** (as re-checked after the run) **and** its coverage ends **complete** — otherwise it is demoted to `signal` for that run (with a note) |

Either role: never a refutation verifier; no lens; no severity cap (`ocr` `critical` →
critical, `high` → important, anything else → suggestion); never lifts solo-Claude mode for
the native reviewers' findings.

### Family

Computed by the reader from the model slug — never configured. Strip leading `~`, lowercase,
then match a prefix at a boundary (end, `/`, `-`, `.`, `:` or a digit):

| Prefix | Family | Distinct? |
|---|---|---|
| `qwen` | `Qwen` | yes |
| `moonshotai/kimi` | `Moonshot` | yes |
| `z-ai/glm` | `Zhipu` | yes |
| `deepseek` | `DeepSeek` | yes |
| `anthropic/claude` | `Claude` | no — same as native Claude |
| `openai/gpt` | `OpenAI` | no — same as Codex |
| `google/gemini` | `Google` | no — same as the Google slot |
| anything else (`x-ai/grok-4`, `openrouter/fusion`, `@preset/x`, …) | `unknown` | no |

A **distinct** seat's findings go through the refutation pass like any single-family finding
and can corroborate another family's. A **non-distinct** seat is allowed (you may run a Claude
or GPT model through `ocr`), but its findings skip refutation, stay `[unverified]`, and
**never** count as cross-family corroboration. The family is re-derived from the model `ocr`
reports it actually ran; a mismatch makes it `unknown` for that run, with a note.

### Budget for a seat

**`codex`, `claude`, `opencode`:** the cap is `harness_options.timeout_minutes`, else
`settings.reviewer_timeout_seconds` (10 minutes by default) — the same limit as a native
reviewer. Like every seat, they run on their own clock. **`ocr`:**

`ocr` is usually the run's long pole, so its deadline comes from `settings.run_budget_seconds`,
not `reviewer_timeout_seconds`: ⅓ of the budget is reserved for refutation and the judge, and
`deadline_min = max(1, floor((run_budget_seconds − reserve) / 60))`, clamped to 180 — 6 minutes
at the 600 s default, so **expect partial coverage** unless you raise the budget.
`harness_options.timeout_minutes` replaces the derived value. `ocr` multiplies its deadline by
its rounds (`effort` medium ×2, high ×3). The seat runs on **its own clock**: its elapsed
time never counts toward the run's budget check, so a long `timeout_minutes` never skips the
refutation pass for the other reviewers' findings — the run simply lasts as long as the seat.
To give only this seat more time, set its `timeout_minutes`; there is no need to raise
`run_budget_seconds`.

### Other rules

- **Several seats per run.** Every available seat runs, in `reviewer.custom_slots` order. The
  reader lists **trusted seats first** — untracked `config.local.yml`, then the user file, then
  the tracked local file and committed `config.yml` (document order within each). **Families,
  not seats, count:** two seats on one vendor are one family for `min_reviewers` and for
  cross-family corroboration.
- **Availability:** the harness binary installed (`ocr` also needs `jq`); for OpenRouter, the
  variable `api_key_env` names is set and non-empty. An `ocr` seat also needs a target with a
  diff (a plan/document review skips it); the other harnesses review any target.
- **Egress:** OpenRouter seats send review context to OpenRouter and the model's host, with
  `data_collection: deny` hard-coded on every request (never read from any config) — **except
  `codex`**, which has no way to send it: for a `codex` seat, set a data policy on the
  OpenRouter key itself. Ollama seats talk to `127.0.0.1:11434` only. Endpoints are council
  literals — there is no URL key.

### Which harness

| `harness` | Read-only boundary | Takes the council prompt / lens | Best for |
|---|---|---|---|
| `codex` | **OS kernel** sandbox (`--sandbox read-only`) | yes | The default general-purpose choice; the strongest boundary. No `data_collection: deny` on OpenRouter. |
| `claude` | tool list (`--tools=Read,Grep,Glob`) | yes | Any model behind an Anthropic-compatible endpoint (OpenRouter, Ollama); real turn limit (`max_turns`). |
| `opencode` | council-written deny-by-default config + two guards | yes | Pinned to the tested release (`1.19.0`); any other version is skipped. |
| `ocr` | fixed four-tool set | no (own review pipeline, no lens) | Whole-diff review with a coverage manifest; slow. |

Details and the evidence behind each boundary: `rules/providers.md` → Custom seats.

Reader output (the `# custom reviewers` section): `reviewer.custom_slots=<a,b>`, then per
seat `reviewer.custom.<s>.enabled|source|needs_confirm|harness|provider|model|role|api_key_env|family|distinct`,
`reviewer.custom.<s>.opt.<option>`, and — `ocr` seats only — `reviewer.custom.<s>.flag.<n>`,
`reviewer.custom.<s>.env.<NAME>`; plus any `confirm.<n>=` lines.

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

## `pr_comments:` block

Gates the optional PR-digest posting engine (Step 6.6 of `skills/run/SKILL.md`, plumbed
by `scripts/rc-post.sh`). Off by default, so an absent block is byte-identical to today's
report-only behavior.

```yaml
pr_comments:
  enabled: false            # master switch. Env override: RC_PR_COMMENTS
  bot_token_env: RC_PR_BOT_TOKEN  # NAME of an env var holding a bot token (optional).
                                  # TRUSTED layers only — an untracked config.local.yml or
                                  # the RC_PR_BOT_TOKEN_ENV env override, NOT config.yml.
```

- `enabled` (bool, default `false`) — when true, after the report Review Council offers to
  post a single review-digest comment to the PR (always human-confirmed, never automatic).
  `RC_PR_COMMENTS` overrides it (env wins), so CI can force it on.
- `bot_token_env` (string, default `RC_PR_BOT_TOKEN`) — the **name** of an environment
  variable that (optionally) holds a GitHub token. When that variable is set and non-empty
  at post time, the comment is posted as the identity that token authenticates (a bot user
  for a PAT, `review-council[bot]` for a GitHub App token); when it is unset/empty the
  comment posts as the authenticated `gh` user, clearly marked automated. The token
  **value** never lives in config — only the variable's name does.
- **Security.** `bot_token_env` is charset-validated as a strict POSIX identifier
  (`[A-Za-z_][A-Za-z0-9_]*`) at the reader — it is read via indirect expansion downstream,
  so anything outside that charset is rejected to the default with a note (the same
  reader-side discipline as `reviewers.*.model`; see "Security Invariants" in `CLAUDE.md`).
  An explicit empty value is honored (means "no bot token → post as the `gh` user"). Because
  the **name** selects which local env var is read and sent to GitHub as a bearer token,
  `bot_token_env` is honored **only from trusted layers** — an **untracked** `config.local.yml`
  (operator-owned) or the `RC_PR_BOT_TOKEN_ENV` env override — and is **ignored (with a note)
  if set in the committed `config.yml` or in a `config.local.yml` that git tracks**, both of
  which are attacker-controlled when reviewing an untrusted repo. Otherwise a reviewed repo could point it at a local secret
  (e.g. `AWS_SECRET_ACCESS_KEY` — a perfectly valid identifier). The destination PR is always
  taken from local git, never from config.

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
- **A custom seat** with an invalid name, harness, provider or model (or an empty model) is
  dropped with a stderr note and not emitted; an invalid option falls back to its default; a
  trusted-only key set in an untrusted layer is ignored with a note.

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
#   custom:                      # opt-in extra seat, OFF unless harness + model are set (rules/config.md → reviewers.custom)
#     qwen:                      # slot name: A-Z a-z 0-9 _ -  (max 32)
#       harness: ocr             # required
#       provider: openrouter     # openrouter | ollama
#       model: qwen/qwen3.8-max-0902   # required; no default model
#       role: signal             # signal | reviewer
#       # api_key_env and harness_options.flags/env: trusted layers only (~/.review-council/config.yml, untracked config.local.yml)

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
