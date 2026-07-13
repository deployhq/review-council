# Static Analysis Tool Registry

Reference for the deterministic static-analysis layer (**Step 2.5**, between Step 2 "Gather
Context" and Step 3 "Round 1" in `skills/run/SKILL.md`). This is the CodeRabbit-replacement
piece of Review Council: the same class of linters/secret-scanners/SAST tools CodeRabbit
wraps, run locally and fed to the council **as evidence**, never as a second vote.

**Not a voting reviewer.** Static analysis never counts toward `settings.min_reviewers`, is
never assigned a lens, and is never routed through the Step 4 refutation pass. It is an input
to Step 2 (context) and Step 5/6 (judge synthesis) only — see `rules/orchestration.md` for how
the judge merges tool-origin findings into the same dedup/fingerprint machinery it already
uses for LLM findings.

The runner script (`scripts/rc-static-scan.sh`), its config keys (`static_analysis.*` in
`scripts/rc-config.sh` / `rules/config.md`), and the Step 2.5 wiring (`skills/run/SKILL.md`)
are documented in their own files. **This file is the tool-level reference they all read
from**: which tools, at which tier, how to detect them, how to invoke them scoped to a diff,
how to map their raw output into the shared finding shape, and the security/noise-control
rules that keep the layer safe and quiet. When `static_analysis.enabled` is `false`, none of
this runs — Step 2.5 is a no-op.

## The two-tier evidence model

- **Tier A — verified, high-precision → straight to the report.** Secrets (`gitleaks`,
  `trufflehog --results=verified`) and known-CVE hits (`osv-scanner` against lockfiles). Enter
  the report **pre-verified**, badged `[verified]`, at the tool-assigned severity — the judge
  never downgrades a Tier A finding (severity is **inherited**, not judge-assigned) — and are
  **exempt from the suggestion cap**. Ledger `verdict = TOOL-VERIFIED` (a value that never
  passes through Step 4 refutation at all).
- **Tier B — SAST/lint → context, not a verdict.** `semgrep`, `ruff`, `shellcheck`,
  `actionlint`, `hadolint`. Real false-positive rates, so they're injected into the Step-2
  baseline context package under **"PRE-EXISTING STATIC-ANALYSIS SIGNALS — corroborate or
  dismiss"** — every Round-1 reviewer sees them. A reviewer's own finding landing on the same
  (judge-computed) fingerprint promotes the tool hit to `[verified]`; an uncorroborated Tier-B
  hit survives only as a low-severity `[tool-only:<rule>]` **Suggestion**, subject to the
  normal suggestion cap — never Critical/Important on tool say-so alone.

## Tool registry

| Tool | Tier | Install (macOS/brew) | Probe | Diff-scoped invocation | Output format | Domain trigger (run only if diff touches…) |
|---|---|---|---|---|---|---|
| **gitleaks** | A — secrets | `brew install gitleaks` | `command -v gitleaks` | `gitleaks git --log-opts="<base>..<head>" -f json -r <out>.json .` (a) | `-f json` (also `sarif` / `csv` / `junit`) | always — secrets can appear in any changed file, incl. non-code |
| **trufflehog** | A — secrets, live-verified | `brew install trufflehog` (or the official install script) | `command -v trufflehog` | `trufflehog git file://. --since-commit <base> --branch <head> --results=verified --json` (b) | `--json` (verbose per-finding JSON) | always — see the **outbound-network caveat** below before enabling anywhere network-restricted |
| **osv-scanner** | A — known CVEs | `brew install osv-scanner` | `command -v osv-scanner` | `osv-scanner scan source --lockfile=<changed-lockfile-path> --format json` (repeat `--lockfile=` per changed lockfile) (c) | `--format json` (also `sarif` / `markdown`) | a dependency manifest/lockfile is present in the diff (`package-lock.json`, `yarn.lock`, `Gemfile.lock`, `go.sum`, `requirements.txt`, `Cargo.lock`, etc.) |
| **semgrep** | B — SAST | `brew install semgrep` (or `pipx install semgrep`) | `command -v semgrep` | `semgrep scan --config <config> --baseline-commit <base> --json --output <out>.json --metrics=off .` (d) | `--json` (primary; `--sarif` also available) | always (broadest rule coverage; fast enough at diff scale) |
| **ruff** | B — Python lint | `brew install ruff` (or `pipx install ruff` / `uvx ruff`) | `command -v ruff` | `ruff check --output-format json --exit-zero <changed *.py files>` (no native diff flag — scope by file list) | `--output-format json` (also `sarif`, `github`, `gitlab`, others) | `*.py` files changed |
| **shellcheck** | B — shell lint | `brew install shellcheck` | `command -v shellcheck` | `shellcheck --format json1 <changed *.sh files / shebang-detected scripts>` (scope by file list) | `--format json1` (no SARIF) | `*.sh` (or a `#!/…sh` / `#!/…bash` shebang-detected file) changed |
| **actionlint** | B — CI workflow lint | `brew install actionlint` | `command -v actionlint` | `actionlint -format '{{json .}}' <changed .github/workflows/*.yml>` (e) | JSON via Go-template (`-format '{{json .}}'`) | `.github/workflows/*.yml` / `*.yaml` changed |
| **hadolint** | B — Dockerfile lint | `brew install hadolint` | `command -v hadolint` | `hadolint --format json <changed Dockerfile*>` (scope by file list) | `--format json` (also `sarif`, `checkstyle`, `codeclimate`, `gnu`) | `Dockerfile*` changed |

**(a) gitleaks CLI shape.** As of **v8.19.0** the top-level subcommands are `git` / `dir` /
`stdin` (`detect`/`protect` are deprecated — still work, but hidden from `--help`; older
tutorials referencing them are now stale). Use `git` for a repo, `dir` for a plain directory
scan. Config: `-c .gitleaks.toml` (repo-owned only) and `-i .gitleaksignore` — never a
PR-supplied path (see Security, below).

**(b) trufflehog live verification.** `--results=verified` makes real outbound network calls
to confirm a found credential is currently live. Read the **prominent caveat** near the end of
this file before relying on this in any network-restricted or air-gapped environment.

**(c) osv-scanner is not line-diff-scoped.** It evaluates the full resolved dependency graph
in the lockfile present in the diff and reports every CVE hit for that manifest — there is no
"only CVEs newly introduced by this diff" mode. Its CLI has **recently reshaped** around
`scan source` / `scan image` subcommands (v2), while a bare `osv-scanner -L <lockfile>` /
`scan --lockfile=...` form is documented for v1.x-era usage. **Probe `osv-scanner --version`
at run time and branch on the installed CLI shape** — do not hardcode one form (same lesson as
gitleaks' `detect`→`git` rename, and the existing "do not hardcode flags" rule already applied
to Codex/Google in `rules/providers.md`).

**(d) semgrep baseline-commit fallback.** `--baseline-commit` **aborts** if the working tree
has unstaged changes or isn't a git dir — which collides with Review Council's own
"review my unstaged working changes" mode. When `--baseline-commit` can't be used, drop it,
run a **full scan**, and apply the **changed-hunk post-filter** instead (Noise Control, lever
3, below). `<config>` comes from `static_analysis.semgrep_config`: `auto` (default) uses
semgrep's own registry auto-config; `off` skips semgrep unconditionally regardless of the
domain trigger; any other value is a **repo-owned local ruleset path**, passed verbatim as
`--config <path>` — never a PR-supplied path (see Security, below).

**(e) actionlint has no turnkey SARIF output** — only a hand-written Go-template mapping,
which its own maintainers call nontrivial. Its JSON template output (`-format '{{json .}}'`)
is used instead; if a later phase wants to unify all eight tools on SARIF, actionlint is the
one tool that needs bespoke template work to get there.

### Non-interactive, machine-readable, exit-code convention

None of these eight tools prompt interactively in a plain CLI invocation, and all have a
structured (JSON/SARIF) output flag. Adopted convention for every invocation:

- **Always parse the tool's structured output file — never gate on exit code.** Several of
  these tools exit **non-zero when they find something** (gitleaks' default, osv-scanner,
  semgrep with `--error`, ruff by default) — a normal outcome here, not a script failure.
- Every invocation runs through `run_capped` (`scripts/rc-lib-timeout.sh`) with
  `static_analysis.timeout_seconds` as the per-tool cap. `run_capped`'s own timeout
  classification (124/143/137) is unaffected by the point above — it only cares about the
  timeout-kill codes; a lint tool's "findings present" exit code becomes an ordinary `$?` the
  wrapper ignores once the decision is "always read the output file."

## Tier A — severity map (inherited, not judge-assigned)

| Tool | Condition | Final report severity |
|---|---|---|
| gitleaks | any hit | Critical |
| trufflehog | any `--results=verified` hit | Critical |
| osv-scanner | CVSS/OSV `CRITICAL` or `HIGH` | Critical |
| osv-scanner | CVSS/OSV `MEDIUM` | Important |
| osv-scanner | CVSS/OSV `LOW` or unset | Suggestion |

This **is** the final report severity — no LLM step recalibrates it further. Tier A is exempt
from the suggestion cap (moot in practice, since Tier A findings are rarely `suggestion`), and
the judge **never** downgrades a Tier A finding for lack of a second opinion — it's pre-
verified evidence, not an opinion subject to corroboration.

## Tier B — severity map (context weight, not final severity)

Each tool's own severity vocabulary orders/weights what reviewers see — it is **not** the
final report severity:

| Tool | Native severity vocabulary |
|---|---|
| semgrep | `ERROR` / `WARNING` / `INFO` |
| hadolint | `error` / `warning` / `info` / `style` |
| shellcheck | `error` / `warning` / `info` / `style` (baked into each `SC####` code) |
| ruff | no native severity field — the rule-code prefix is the only weight signal (e.g. `F` = Pyflakes correctness, generally weightier than a bare style `E`/`W` code); treat all ruff hits as flat context signal unless a future refinement adds prefix-based weighting |
| actionlint | no native severity field — treat as flat context signal |

Final severity for a Tier-B-origin finding is always **judge-assigned** at Step 5, per the
corroboration gate:
- **Tool-only** (no LLM match on the same fingerprint) → stays a `suggestion`, badged
  `[tool-only:<rule>]`, subject to the normal suggestion cap.
- **Tool + LLM agreement** on the same fingerprint → promoted to `[verified]`, at the
  **higher** of the tool's context-weight and the LLM's self-rated severity.

## Badge semantics for tool-origin findings

- **`[verified]`** — every Tier A finding (always), plus any Tier B finding an LLM reviewer
  independently corroborated on the same judge-computed fingerprint. Badge precedence when
  multiple could apply: `[verified]` > `[cross-reviewed]` > `[1 reviewer · unverified]` >
  `[unverified]` — show the strongest, mention others in prose if relevant. `[verified]` and
  `[cross-reviewed]` can legitimately coexist (a finding can be both tool-grounded and
  cross-family-corroborated) — badge it `[verified]` primarily.
- **`[tool-only:<rule>]`** — a Tier B finding with no LLM match. Always `suggestion` severity,
  never Critical/Important on tool say-so alone. Counts against the normal suggestion cap.
- Ledger `verdict = TOOL-VERIFIED` marks a Tier A finding specifically — it signals the
  finding **never went through Step 4 refutation** (unlike UPHELD/REFUTED/INCONCLUSIVE, which
  are refutation outcomes).

## Normalize → §3.1 (candidate finding shape)

A raw tool hit becomes a §3.1-shaped candidate finding (the same finding schema every LLM
reviewer emits — see `rules/delegation-format.md`'s OUTPUT FORMAT) with this mapping:

| §3.1 field | Value for a tool-origin finding |
|---|---|
| `location` | `<relpath>:<line>` straight from the tool's own report |
| `symbol` | the enclosing construct if the tool's output names one; `N/A` otherwise |
| `concern` | `<tool-name>:<tool's-own-rule-id>`, lowercased — e.g. `semgrep:python.lang.security.audit.subprocess-shell-true`, `ruff:F401`, `shellcheck:SC2086`, `gitleaks:<rule>`, `trufflehog:<detector-name>`, `osv-scanner:<CVE-or-GHSA-id>`, `hadolint:DL3008`, `actionlint:<rule-kind>` |
| `source` | `<tool-name>` |
| `confidence` | `high` for Tier A; `medium` for Tier B |
| `issue` / `why_it_matters` / `recommendation` / `how_to_verify` | synthesized deterministically from the tool's own message/rule metadata (fixed per-tool templates — never LLM-authored), so a Tier A finding can reach the judge without ever passing through a reviewer prompt |

**The judge still computes the canonical fingerprint for tool findings** — the *same* semantic
reduction it already applies to LLM findings (`rules/orchestration.md` → Deduplication), **not**
a literal string match between a rule id and an LLM's free-form `concern` slug. A semgrep rule
id and a Codex free-text concern will never be string-identical; the judge recognizes them as
the same underlying issue by file/line proximity plus semantic reading of the `issue` text —
exactly as it already does for two differently-worded LLM findings on the same bug.

### `rc-static-scan.sh` wire format (stdout contract)

`scripts/rc-static-scan.sh` emits a `TIER_A` block, then a `TIER_B` block, each a list of
pipe-delimited lines in this order: `tier|tool|severity_raw|file|line|rule|message` — the
compact form that gets expanded into the full table above once it reaches Step 2.5 / the
judge. `severity_raw` is the tool's own vocabulary (Tier A/B tables above), not yet mapped to
Critical/Important/Suggestion.

Skipped tools get one `SKIPPED: <tool> — <reason>` line each, with a fixed reason vocabulary
(the Step 2.5 orchestrator, `skills/run/SKILL.md`, keys its "missing configured tool" ask flow
off this exact set — do not invent new reason strings):

| Reason | Meaning |
|---|---|
| `not installed` | `command -v` probe found nothing. The one reason the orchestrator surfaces to the user (with this file's install command) and asks whether to pause-and-install or proceed without it. |
| `not triggered` | tool present, but no changed file matched its domain-trigger column — nothing to install, quiet skip. |
| `disabled` | tool present and triggered, but not in the configured `static_analysis.tools` list. |
| `semgrep off` | `static_analysis.semgrep_config=off` (semgrep-only reason). |
| `network-unreachable` | trufflehog present + triggered, but the live-verification network call couldn't complete — treated as "ran, 0 findings," never an error (see the outbound-network caveat below). |
| `timeout` | `run_capped` killed the tool past `static_analysis.timeout_seconds`; the rest of the batch still runs. |

## Noise control

Five levers keep this layer signal, not spam:

1. **Diff-scoping** — the domain-trigger column above: a tool never runs against files
   outside its domain (no `ruff` when no `*.py` changed, no `hadolint` when no `Dockerfile*`
   changed, etc.).
2. **Verified-only secrets** — trufflehog's `--results=verified` only reports secrets it
   confirmed are currently live. **gitleaks is pattern/entropy-based, not live-verified** —
   see the precision caveat below; it is still high-precision by rule quality, just via a
   different mechanism than trufflehog's.
3. **Changed-hunk post-filter** — drop Tier B findings whose line falls outside the diff's
   changed-line ranges (± a small context window). This is the required fallback whenever
   semgrep's `--baseline-commit` can't be used (footnote (d) above), and a belt-and-suspenders
   filter even when it can.
4. **LLM triage** — Tier B never escalates to Critical/Important without reviewer
   corroboration on the same fingerprint; a tool-only hit stays a capped Suggestion.
5. **Per-tool severity map + corroboration gate** — the Tier A/B severity maps above, plus the
   badge rule: Tier B tool-only → Suggestion, subject to the same cap as any other suggestion;
   Tier A is exempt from the suggestion cap since it is pre-verified evidence, not a
   suggestion in the first place.

## Security — repo-owned configs only

Every tool invocation may use **only** a config file already committed to the target repo —
`.gitleaks.toml` / `.gitleaksignore`, a local semgrep ruleset path (when
`static_analysis.semgrep_config` names one), `.shellcheckrc`, `.hadolint.yaml`/`.hadolint.yml`,
`.github/actionlint.yaml`, and similar. This is the direct lesson from the CodeRabbit RCE
precedent this whole evolution explicitly refuses to repeat — CodeRabbit's "run whatever
config the PR author supplies" design is exactly the failure mode this rule prevents.

- **Allowed:** a committed, repo-owned config/ruleset file. `semgrep --config auto`'s network
  fetch of *rules* from semgrep's registry is fine — rules are data, not arbitrary executable
  code.
- **Forbidden, full stop:** fetching or executing a PR-supplied tool config, ruleset, or
  plugin — a `.semgrep.yml`/`.gitleaks.toml`/ruleset/ast-grep-style scriptable rule pack
  sourced from the diff itself. Never resolve a tool config path from anything the diff under
  review supplies.

---

> ### ⚠️ Outbound-network caveat — trufflehog
>
> `trufflehog --results=verified` makes **live outbound network calls** using the credential
> it found — to confirm e.g. that an AWS key is real, it authenticates *to AWS* with it. This
> is what makes trufflehog's Tier A designation strong (verified, not just pattern-matched),
> but it has real implications:
>
> - It requires **network egress** from the machine running the review — a "local,
>   report-only" tool now reaches out to third-party services.
> - The verification call itself could trip the **credential owner's own anomaly detection**
>   ("unusual API call from a new location") even though the intent is entirely benign.
> - In a fully offline/air-gapped review environment, this degrades gracefully: `command -v
>   trufflehog` present but the network call unreachable is treated as **"ran, 0 findings"**
>   (`SKIPPED: trufflehog — network-unreachable` in Tier-B-style bookkeeping, or simply no
>   findings on that run) — **never** an error that aborts the Step 2.5 batch.
>
> **`trufflehog` is DEFAULT-ON.** The default `static_analysis.tools` list is all eight tools
> (`gitleaks, trufflehog, osv-scanner, semgrep, ruff, shellcheck, actionlint, hadolint`).
> **One-line opt-out:** drop `trufflehog` from `static_analysis.tools` (in
> `.review-council/config.yml`, or via the `RC_STATIC_TOOLS` env override) if outbound network
> calls from the review environment are unacceptable.

---

> ### Precision caveat — gitleaks (not live-verified)
>
> Despite sharing Tier A with trufflehog, **gitleaks is not live-verified**. It's a tuned
> regex + entropy engine — high precision by **rule quality**, not by confirming the secret is
> **currently live**. Its Tier A "straight to report, no LLM corroboration needed" design
> rests on rule precision, not on the live-verification guarantee trufflehog provides — a
> future maintainer should not assume a gitleaks hit is confirmed-live the way a trufflehog hit
> is. If a repo's gitleaks ruleset is loose (custom rules, no allowlist tuning), false
> positives are possible; the repo-owned `.gitleaksignore` / `.gitleaks.toml` remains the
> intended tuning lever, not a Review Council feature.

---

## Availability, `setup`, and missing configured tools

`/review-council:setup` is **print-only** for these eight tools: it detects each (`command -v
<tool> && <tool> --version`) and, for anything missing, prints that tool's install command
from the table above — it never installs on the user's behalf, unlike the `yq` config-reader
flow (`rules/config.md`). There is no consent-to-install path here, by design.

At **review-run time** (Step 2.5, `skills/run/SKILL.md`), the story is different: a tool that
is in the *configured* `static_analysis.tools` list (the user expects it) but comes back
`SKIPPED: <tool> — not installed` is surfaced to the user with its install command from this
file, and the orchestrator asks whether to pause for install-then-rerun or proceed without it
for this run. A tool skipped for any other reason (`not triggered`, `disabled`, `semgrep off`,
`network-unreachable`, `timeout`) is a quiet, expected skip — nothing to install, no ask.
