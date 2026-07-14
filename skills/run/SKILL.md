---
description: Multi-agent code review for Claude Code. Multiple AI models review your PR, code, or plan independently; a cross-family refutation pass and an active judge then distill the findings into a curated, severity-ranked list of what actually needs changing.
argument-hint: "[PR number | file/directory path | blank for auto-detect]"
allowed-tools: Agent, Bash, Read, Glob, Grep, mcp__codex__codex, mcp__codex__codex-reply
---

# Review Council — Multi-Agent Review

You are the **Orchestrator** of a review council. Your job is to run multiple AI reviewers independently, route their findings through a cross-family refutation pass, and have the judge synthesize a single curated, severity-ranked list of findings.

## Step 0: Read Config & Detect Available Providers

Two independent gates decide the reviewer roster: **configuration** (which reviewers/lenses are *enabled*, from the config files) and **detection** (which reviewers are *available* on this machine). A reviewer participates only if it is **both** enabled and available. Do 0.1 and 0.2, then reconcile in 0.3.

### 0.1 Read the effective configuration

Run the bundled config reader and capture its `key=value` output. It reconciles `.review-council/config.yml`, `.review-council/config.local.yml`, `RC_*` env vars, and built-in defaults — precedence **env > config.local.yml > config.yml > built-in default** — and prints the effective config to stdout (diagnostics to stderr). It always exits `0`: absent files or absent `yq` degrade to defaults. See `rules/config.md` for the full schema.

```bash
# Read from the TARGET repo's .review-council/ (the CWD where the review runs).
# ${CLAUDE_PLUGIN_ROOT} is the plugin's own install dir — must be double-quoted.
RC_NOTES="$(mktemp "${TMPDIR:-/tmp}/rc-config-notes.XXXXXX")"
CONFIG_OUT="$("${CLAUDE_PLUGIN_ROOT}/scripts/rc-config.sh" .review-council 2>"$RC_NOTES")"
printf '%s\n' "$CONFIG_OUT"
# Surface any reader diagnostics (malformed keys, yq-not-found, skipped files):
[ -s "$RC_NOTES" ] && { echo "--- rc-config notes ---"; cat "$RC_NOTES"; }
rm -f "$RC_NOTES"
```

**Echo the effective, reconciled config to the user before applying it.** This printed block is the observable artifact of what the run resolved — show what you resolved, never silently eyeball the YAML. Parse the `key=value` lines (one per line, no spaces around `=`; `#` lines are section comments). The keys are:

- `reviewer.<p>.enabled` / `reviewer.<p>.model` for `p` in `claude`, `codex`, `google`, `perplexity`.
- `lens.<l>.enabled` / `lens.<l>.providers` for `l` in `security`, `correctness`, `cross_file`, `performance`, `design`, `dependency` — plus `lens.security.replaces_dedicated`.
- `settings.<k>` for `personas`, `verify`, `verify_max_findings`, `learn`, `min_reviewers`, `reviewer_timeout_seconds`, `run_budget_seconds`, `auto_retry`.
- `static_analysis.<k>` for `enabled`, `tools`, `timeout_seconds`, `semgrep_config` — the deterministic static-scan layer consumed in **Step 2.5**. (An older reader that does not emit a `# static_analysis` section → fall back to the defaults: `enabled=true`, `tools=gitleaks,trufflehog,osv-scanner,semgrep,ruff,shellcheck,actionlint,hadolint`, `timeout_seconds=60`, `semgrep_config=auto`.)

If `yq` is missing, the reader prints a `yq not found` note and falls back to defaults + env; the run proceeds normally (config files are simply ignored). `rules/config.md` documents the one-time `brew install yq` (mikefarah v4) needed to *use* config files.

### 0.2 Detect available providers

Probe which reviewers are available on this machine. Refer to `rules/providers.md` for detection methods.

**Run this detection command verbatim — do not hand-roll or abbreviate it.** The `agy` probe is the one most often dropped when detection is improvised, which silently collapses the Google slot to a `gemini` that cannot authenticate on Google Workspace accounts (`IneligibleTierError: DASHER_USER`). `agy` is the **default** Google reviewer and MUST be probed explicitly — including its known install path (`~/.local/bin/agy`), in case it isn't on `PATH`:

```bash
# agy: probe PATH first, then common install dirs (a minimal PATH may omit them)
AGY="$(command -v agy 2>/dev/null || true)"
if [ -z "$AGY" ]; then
  for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    [ -x "$d/agy" ] && { AGY="$d/agy"; break; }
  done
fi
GEM="$(command -v gemini 2>/dev/null || true)"
CDX="$(command -v codex 2>/dev/null || true)"
# one key=value per line — never space-join (a $HOME with a space would break parsing)
echo "codex=${CDX:-none}"
if [ -n "$AGY" ]; then
  echo "google=antigravity"
  echo "agy=$AGY"
  echo "gemini_fallback=${GEM:-none}"
elif [ -n "$GEM" ]; then
  echo "google=gemini"
  echo "gemini=$GEM"
else
  echo "google=none"
fi
echo "perplexity=$([ -n "$PERPLEXITY_API_KEY" ] && echo set || echo unset)"
```

Interpret the output (each value is on its own line — read the whole line as the value, so paths containing spaces stay intact):

1. **Claude**: Always available.
2. **Codex**: `codex=<path>` → available (CLI). If `codex=none`, check whether the `mcp__codex__codex` tool is available — if so, available (MCP); otherwise unavailable.
3. **Google (Antigravity / Gemini)** — one slot shared by both Google CLIs (see `rules/providers.md` → "Google-family reviewer"):
   - `google=antigravity` → available as **Google (Antigravity)**. `agy` is primary — invoke it via the resolved `agy=<path>`; `gemini` (from `gemini_fallback=<path>`) is fallback only. Announce it as "Google (Antigravity)", **never** "Gemini", because `agy` is what will actually run.
   - `google=gemini` → available as **Google (Gemini)**. Note that `gemini` is ineligible for Workspace/Dasher Google accounts and may fast-fail auth (`IneligibleTierError`). **If the user's account is a Google Workspace / managed domain, double-check that `agy` truly isn't installed** (e.g. in a dir the probe missed) before accepting a gemini-only slot — a `google=gemini` verdict there usually means the `agy` probe missed it, which is the exact silent collapse this detection is meant to prevent.
   - `google=none` → unavailable.
   Never count this as two reviewers. Pass the resolved primary tool **and its path**, plus the fallback tool **and its path**, to the Google reviewer subagent.
4. **Perplexity**: `perplexity=set` → available; `unset` → unavailable.

### 0.3 Apply the configuration to the roster

Reconcile the config (0.1) with detection (0.2):

- **Roster (reviewers).** Drop any provider whose `reviewer.<p>.enabled=false` — it does not participate even if installed. Of the reviewers that remain enabled, those that detection found available make up the participating roster. Config gates the roster; detection gates availability — **both** must pass.
- **Models.** Where `reviewer.<p>.model` is non-empty, pass that model to that reviewer's invocation (e.g. the Google slot's model, or the Perplexity model — default `sonar`). An empty model means "use the tool's own default" — pass nothing.
- **Lens bindings (record for Round 1).** Record each `lens.<l>.enabled` and `lens.<l>.providers` (`auto`, or a comma-joined provider list). The actual lens dispatch lands in **PR 1b** — here you only **read and record** the bindings. Note `lens.security.replaces_dedicated`: when `true`, the pinned `security.providers` *replace* the dedicated security reviewer (do not run both); when `false`, security stays on its default/`auto` path.
- **Settings.** Load the `settings.*` values for this run and use them wherever the orchestration rules reference a run knob (`min_reviewers`, `reviewer_timeout_seconds`, `run_budget_seconds`, `auto_retry`, etc.). The reader already folded any `RC_*` env override into each value at the correct precedence, so treat each resolved `settings.*` as the **effective** value of its `RC_*` knob. When a later step *consumes* an `RC_*` env var (e.g. the reviewer timeout wrapper), pass that effective value on the invocation — e.g. `RC_REVIEWER_TIMEOUT=<effective settings.reviewer_timeout_seconds> <cli> …` — rather than relying on the ambient environment carrying across separate tool calls. See `rules/orchestration.md` → "Run Settings".
- **Absent config / absent `yq` → today's defaults**, byte-identical to pre-config behavior. Disabling reviewers still honors `settings.min_reviewers`: if too few remain to reach it, the existing min-reviewers handling applies (single-reviewer mode or the usual prompt).

Announce: "**Review Council** — [N] reviewers available: [list]. [Skipped: reason for each unavailable **or config-disabled** provider]". When the Google slot is available, name the actual tool — e.g. "Google (Antigravity)" — so it's clear `agy` (not `gemini`) is the one running.

If only Claude-family reviewers (Claude + the dedicated Security reviewer) are available — i.e. no different-family reviewer to cross-verify against — proceed in **single-reviewer mode** and note it in the output. Suggest running `/review-council:setup` to see how to add more reviewers.

## Step 0.5: Recall Learnings

Recall the team's shared learnings so past decisions shape this run. **Gated on `settings.learn`** (resolved in Step 0): if `settings.learn` is **false**, skip this step entirely.

If `settings.learn` is **true**, read `.review-council/learnings.md` from the **target repo** (the CWD where the review runs, alongside `.review-council/config.yml`). **If the file is absent, skip silently** — no warning, no error. A missing file is the normal case. The file has two sections (format in `rules/config.md` → learnings):

- **Conventions** — project-specific rules about what not to flag (e.g. "Migrations are auto-generated; do not flag missing down-migrations"). Fold this section **into the Step-2 baseline context package** (see Step 2) under a clear "Team Learnings — Conventions" heading. Because it rides the shared package, it is injected **once** and reaches **every** reviewer — do NOT paste it separately into each dispatch.
- **Suppressions** — known false positives keyed by fingerprint. **Hold** this section for the judge synthesis step (Step 5). It is **not** injected into reviewer prompts; carry it forward so the judge can suppress matching findings (see Step 5, §recalibration).

## Step 1: Detect Review Target

Analyze the user's input: `$ARGUMENTS`

**Auto-detection rules (in order):**

1. **Number** (e.g., `42`, `#42`) — PR review. Fetch with `gh pr view <number> --json title,body,baseRefName,headRefName,changedFiles,additions,deletions,reviewDecision,comments,reviews` and `gh pr diff <number>`.
2. **Path to `.md` file** inside `docs/`, `plans/`, `adr/`, or similar documentation directory — Plan/document review. Read the file and any documents it references.
3. **Path to source code** (file or directory) — Code review. Read the files. If a directory, identify the key files (skip node_modules, dist, etc.).
4. **No argument** — Auto-detect:
   a. Check for open PR on current branch: `gh pr view --json number,title,body,baseRefName,headRefName,changedFiles 2>/dev/null`
   b. If PR found — PR review
   c. If no PR — check for staged changes: `git diff --cached --stat`
   d. If staged changes — Code review of staged diff
   e. If nothing staged — check unstaged: `git diff --stat`
   f. If unstaged changes — Code review of working changes
   g. If nothing — ask the user what to review

Announce your detection: "**Review Council** — Reviewing [PR #42: title | plan: path | code: path | staged changes]"

## Step 2: Gather Context — Baseline Context Package

Collect context appropriate to the detected type. This becomes the **baseline context package** — the identical context every reviewer receives. Gather mechanically using exact commands; do not summarize or interpret.

**PR review:**
- PR metadata: `gh pr view <number> --json title,body,baseRefName,headRefName,changedFiles,additions,deletions,reviewDecision,comments,reviews`
- Full diff: `gh pr diff <number>`
- List of changed files with additions/deletions
- Git log for changed files: `git log --oneline -10 -- <changed_files>`
- Git blame for changed hunks: `git blame -L <start>,<end> -- <file>` for each changed hunk
- Any existing review comments or discussions
- Project conventions: raw contents of CLAUDE.md, CONTRIBUTING.md, README (if present)

**Plan/document review:**
- Full document content
- Any documents referenced or linked (ADRs, related plans)
- Project conventions: raw contents of CLAUDE.md, CONTRIBUTING.md, README (if present)

**Code review:**
- Full file contents (or diff if reviewing changes)
- Git log for changed files: `git log --oneline -10 -- <files>`
- Git blame for changed hunks
- Project conventions: raw contents of CLAUDE.md, CONTRIBUTING.md, README (if present)

**Team Learnings — Conventions (from Step 0.5).** If Step 0.5 recalled a **Conventions** section, append it here under a "Team Learnings — Conventions" heading. Folding it into this shared package (rather than each dispatch) injects it **once** yet reaches every reviewer. (The **Suppressions** section is NOT included here — it is held for the judge synthesis step, Step 5.)

Package this as a structured text block. You will send this same package to each reviewer — this is the shared baseline. Reviewers may explore further using their own tools, but the baseline ensures equal starting context. **If Step 2.5 runs the static scan, its Tier B signals are appended to this same package** (under a "PRE-EXISTING STATIC-ANALYSIS SIGNALS — corroborate or dismiss" heading) so every reviewer sees them once — hold that step's output and fold it in before dispatching Round 1.

## Step 2.5: Deterministic Static Scan

**Gated on `static_analysis.enabled` (resolved in Step 0).** If it is **false**, skip this step entirely — run no scan, and note `static analysis: off` in the Step-6 Pipeline header. A missing or erroring script is **never** a reason to abort (see 2.5.3): the run always continues.

When enabled, run the deterministic scanners **once per run** (never per reviewer) and split their output into the two-tier evidence model:
- **Tier A** (verified secrets, known CVEs) → carried forward **untouched** to the judge (Step 5) as pre-`[verified]` findings. Tier A **never enters Round 1** and is never sent through a reviewer prompt.
- **Tier B** (SAST/lint signals) → folded into the **Step-2 baseline context package** so every Round-1 reviewer sees it and either corroborates or dismisses it.

Static analysis is **not a voting reviewer** — it never counts toward `settings.min_reviewers`, gets no lens, and is never refuted in Step 4. See `rules/static-analysis.md` for the tool registry, tier map, per-tool install commands, and the normalize→§3.1 mapping.

### 2.5.1 Dispatch the scan (one general-purpose subagent)

Reuse the BASE ref and changed-file list **already computed in Step 1/2** — do NOT re-derive the diff. Determine the two refs and the changed-file list from the detected target type:
- **PR review** → base = the PR base branch (`baseRefName`), head = the PR head branch (`headRefName`); changed files = the `changedFiles` set from `gh pr view` (or `gh pr diff --name-only`).
- **Staged code review** → base = `HEAD`, head = the working tree (pass the worktree path, e.g. `.`); changed files = `git diff --cached --name-only`.
- **Unstaged working changes** → base = `HEAD`, head = the working tree; changed files = `git diff --name-only`.
- **Plan/document review** → there is no code diff; **skip Step 2.5 entirely** (nothing for the scanners to scope to) and note `static analysis: off (no code diff)`.

Write the changed-file list (one repo-relative path per line) to a temp file **with `Bash`** (e.g. `printf '%s\n' path/a path/b … > "$CF"`), then dispatch **one** `general-purpose` Agent with the prompt below. Pass the effective `static_analysis.*` values resolved in Step 0 as env vars **on the invocation** (the script reads them via env, matching `rc-config.sh`'s output; do not rely on ambient env carrying across separate tool calls):

> You are running the Review Council deterministic static scan. Run the bundled scanner script **once** and return its output verbatim. Do NOT interpret, summarize, re-run individual tools, or add commentary.
>
> Run exactly (substitute the effective values and paths given to you):
> ```bash
> RC_STATIC_ANALYSIS=<effective static_analysis.enabled> \
> RC_STATIC_TOOLS=<effective static_analysis.tools, comma-joined> \
> RC_STATIC_TIMEOUT=<effective static_analysis.timeout_seconds> \
> RC_SEMGREP_CONFIG=<effective static_analysis.semgrep_config> \
> "${CLAUDE_PLUGIN_ROOT}/scripts/rc-static-scan.sh" "<base-ref>" "<head-ref-or-worktree>" "<changed-files-list-file>"
> ```
> The script probes each configured tool (`command -v`), checks its domain trigger against the changed files, runs the present + triggered ones under a per-tool timeout, and prints a `TIER_A` block, a `TIER_B` block, and one `SKIPPED: <tool> — <reason>` line per skipped tool. It **always** exits cleanly — a tool's own non-zero "found something" exit is a normal outcome, not a script failure.
>
> **If the script is missing, non-executable, or errors out before producing its blocks**, do NOT abort — return exactly `STATIC-SCAN-UNAVAILABLE: <one-line reason>` and nothing else. The orchestrator treats that as "all tools skipped."
>
> On success, return the script's **stdout verbatim** (the `TIER_A`, `TIER_B`, and `SKIPPED:` lines) — nothing added, nothing removed. The output is already compact (normalized pipe lines `tier|tool|severity_raw|file|line|rule|message`), so return it whole.

### 2.5.2 Missing CONFIGURED tools — inform + ASK (never silently drop)

Before consuming the results, scan the `SKIPPED:` lines for any tool skipped with reason **`not installed`** that is in the configured `static_analysis.tools` list. The user *expects* these tools, so they must **never** be silently dropped.

- **Domain-not-triggered skips stay quiet** (`SKIPPED: <tool> — not triggered (no matching files)`): nothing to install, so just fold them into the status line. Same for `disabled`, `semgrep off`, and `network-unreachable` (trufflehog's live-verification egress absent → treated as "ran, 0 findings"; not a missing tool).
- **For each tool skipped as `not installed`:** TELL the user which configured tools are missing and **how to install each** — look up the per-tool install command in `rules/static-analysis.md` (the tool registry; e.g. `brew install gitleaks`). Then **ASK**, conversationally:
  > *"These configured static-analysis tools aren't installed: [tool → install cmd, one per line]. Install them first (I'll pause and re-run the scan once you've installed them), or proceed without them for this run?"*
  - **Proceed** → continue with the tools that did run; note the missing ones in the status line (`skipped: not installed — proceeding`).
  - **Install / wait** → pause. After the user confirms they're installed, **re-dispatch the same subagent** (2.5.1) — the newly-present tools are picked up automatically by the script's `command -v` probe, no restart needed. Re-check the `SKIPPED:` lines and repeat the ASK if anything is still missing.

This is still non-blocking — the user can always choose *proceed* — it just never *silently* drops an expected tool. (`setup` is print-only; this interactive proceed/pause ASK lives here, at review-run time, where a real run is about to skip a tool the user configured.)

### 2.5.3 Route the results

- **Tier A → to the judge (Step 5), pre-`[verified]`.** For each `TIER_A` line, build a §3.1-shaped candidate: `location` = `<file>:<line>`; `symbol` = the enclosing construct if the line names one, else `N/A`; `concern` = the wire `rule` field **as-is** (it already carries the tool prefix — e.g. `gitleaks:<rule>`, `osv-scanner:<id>`, `trufflehog:<detector>`), lowercased — do NOT re-compose `<tool>:<rule>` from `source` + `rule`, which would double-prefix (`osv-scanner:osv-scanner:<id>`); `source` = `<tool>`; `confidence` = `high`; `severity` = the **inherited** Tier A severity (secrets → Critical; osv-scanner → its CVSS→severity map, per `rules/static-analysis.md`). Carry these to Step 5 **untouched** — they do not enter Round 1, are exempt from the suggestion cap, and the judge does **not** downgrade them (severity is inherited, not judge-assigned). (gitleaks caveat: precision-by-rule, not live-verified — trufflehog is the live-verified secret scanner.)
- **Tier B → into the Step-2 baseline package _and_ forward the raw list to the judge (Step 5).** Append the `TIER_B` lines to the shared context package under a new heading **"PRE-EXISTING STATIC-ANALYSIS SIGNALS — corroborate or dismiss"**, one line per finding (`tool · rule · file:line · message`). Do **not** editorialize severity here — that's the judge's call at Step 5. Because it rides the shared package, it is injected **once** and reaches **every** reviewer (do NOT paste it separately into each dispatch). **Also carry the same raw `TIER_B` candidates forward to Step 5 as tool candidates**, exactly as Tier A is carried — the judge needs them **directly**, not only via a reviewer echo. A Tier B signal that no reviewer corroborates would otherwise never reach the judge, making the `TOOL-ONLY` verdict / `[tool-only:<rule>]` badge (§5.3, §5.5) unreachable: corroborated signals dedup into the reviewer's finding (§5.2), uncorroborated ones survive as capped `[tool-only:<rule>]` suggestions.
- **Script unavailable** → if the subagent returned `STATIC-SCAN-UNAVAILABLE:` (or nothing usable), treat it as **all tools skipped**: no Tier A, no Tier B, status line reads `Static analysis: unavailable (<reason>)`. Never abort the run.

### 2.5.4 Print the status line

Print a compact status line (same observable-artifact spirit as the Phase-1 lens map / routing table), one entry per configured tool — `ok, <count>` for a tool that ran, or `skipped: <reason>` otherwise:
```
Static analysis: gitleaks (ok, 0), osv-scanner (ok, 2 CVEs), semgrep (ok, 5 signals), ruff (skipped: no *.py in diff), shellcheck (skipped: not installed — proceeding), actionlint (skipped: no workflow changes), hadolint (skipped: no Dockerfile changes)
```
Carry this line into the Step-6 report header. If Step 2.5 was skipped (disabled, or a plan/document review), the header notes `static analysis: off`.

## Step 3: Round 1 — Independent Review (Parallel)

Launch **all available reviewers in parallel** — emit **every** reviewer's `Agent` call in a **single message** so they all run concurrently. Do **NOT** dispatch a subset and add the rest in a later message: partial batching serializes the fan-out and throws away the wall-clock savings (the slow reviewer, e.g. `agy`'s cold start, should overlap the others, not follow them). The whole fleet goes out at once. They must not see each other's output — this ensures truly independent perspectives.

### Lens Assignment (before dispatching)

Before launching the reviewers, assign each one a **lens** — an emphasis that diversifies coverage. Assignment is deterministic and diff-aware. This step decides *which* lens each reviewer gets; `rules/delegation-format.md` supplies the exact per-reviewer lens block text to prepend.

**If `settings.personas` is `false`:** skip lens assignment. Every reviewer gets the identical non-lens prompt (legacy behavior) — omit the `## LENS` section from each dispatch. The dedicated `reviewer-security` still runs. Then go straight to the dispatch blocks below.

**Otherwise, assign lenses:**

1. **Invariants (fixed, not diff-driven):**
   - `reviewer-security` → **Security** (dedicated, always).
   - **Correctness & concurrency → CORE** for every repo-capable frontier reviewer: `reviewer-claude`, Codex, and Google. They always carry Correctness; the specialist overlay below layers on top.
   - Perplexity → **Dependency / CVE / best-practices** (diff-only — it has no repo tools).

2. **Classify the diff → specialist overlays.** Scan the changed files/hunks (from Step 2) against the signal table and collect the overlays whose signals are present:

   | Diff signal | Overlay to hoist |
   |---|---|
   | Migrations, schema, SQL, constraints, ORM models | Data-integrity & migration |
   | New endpoints/routes, request parsing, auth/crypto | (Security — dedicated) + boost input-validation + Cross-file |
   | Exported signatures, response shapes, serializers, protobuf/OpenAPI | Cross-file / API-contract |
   | Hot paths, loops, queries, caching, concurrency | Performance & reliability / concurrency |
   | Dependency manifests / lockfiles | Dependency/CVE → Perplexity |
   | `.github/workflows/`, CI config, Dockerfiles, IaC | Config/workflow correctness |
   | Frontend components / state / styles | UI-state & accessibility |
   | Broad multi-file refactor | Cross-file impact |

3. **Assign ONE specialist overlay per frontier reviewer** (Claude, Codex, Google — on top of CORE Correctness), drawing from the overlays present in the diff in this **deterministic tie-break order** (signals outrank slots): **Data-integrity → Cross-file → Performance → Config → UI → Design.** Walk the order and hand each present overlay to the next frontier reviewer that has none yet. Iterate the repo-capable frontier reviewers in the order **Claude, Codex, Google** when assigning overlays, so the reviewer↔overlay pairing is reproducible. If reviewers remain after the present overlays run out, give them **Design & maintainability** (the always-useful default). If overlays outnumber reviewers, the earliest in the order win.

4. **Config pins override the diff-aware default.** For each lens `l` in {`security`, `correctness`, `cross_file`, `performance`, `design`, `dependency`}, Step 0 resolved `lens.<l>.enabled` and `lens.<l>.providers`:
   - `lens.<l>.enabled=false` → that lens is not assigned this run.
   - `lens.<l>.providers` = an explicit provider list → **pin** that lens to exactly those providers (overriding the diff-aware pick). `auto` or empty → use the diff-aware assignment above.
   - **`lens.security.replaces_dedicated=true`** together with a pinned `lens.security.providers` → the pinned provider(s) take the **Security** lens **in place of** the dedicated `reviewer-security` (do NOT run both). When it is `false` (default), the dedicated `reviewer-security` runs and any `security.providers` pin is layered as an additional security emphasis on those providers.

5. **Print the chosen lens map** so the assignment is observable, and carry it into the Step 6 report header. Example:
   ```
   Lens map (personas on):
     reviewer-security   Security (dedicated)
     reviewer-claude     Correctness + Data-integrity & migration
     Codex               Correctness + Cross-file / API-contract
     Google              Correctness + Performance & reliability
     Perplexity          Dependency / CVE / best-practices
   ```

6. **Prepend each reviewer's lens block** to its dispatch prompt — the `## LENS` section for the native subagents (Claude, Security), and the delegation prompt written to the temp file for the CLI/API wrappers (Codex, Google, Perplexity). Every lens block states the emphasis **and** the floor obligation: *lens = emphasis, not blinders — still flag any critical you see outside your lens.*

### Reviewer: Claude (native subagent) — Always

Use the `Agent` tool with `subagent_type: "reviewer-claude"`.

If the `RC_CLAUDE_MAX_TURNS` environment variable is set, override the default maxTurns by passing it to the Agent tool.

**IMPORTANT:** Embed the full baseline context package and delegation prompt directly in the Agent tool's `prompt` parameter. Use this exact template — fill in the bracketed sections with the actual content:

> ## TASK
> [Review type]: Review the following [PR/plan/code] as one member of a multi-agent review council. Other AI models are reviewing the same material simultaneously.
>
> ## LENS
> [If `settings.personas` is true, prepend the per-reviewer **lens block** assigned in Step 3 (Lens Assignment) — use the exact block text from `rules/delegation-format.md`. The lens names your emphasis (Correctness & concurrency as CORE, plus one specialist overlay). **Lens = emphasis, not blinders** — still flag any *critical* issue you see outside your lens. If `settings.personas` is false, omit this section: every reviewer gets the identical non-lens prompt.]
>
> ## REVIEW PROCESS
> Follow these steps in order:
> 1. **Understand intent** — What is this PR/code/plan trying to achieve? Read carefully before judging.
> 2. **Evaluate correctness** — Does it achieve its stated goal? Are there logic errors, missed edge cases, or incorrect assumptions?
> 3. **Identify risks** — What could go wrong in production? Consider security, performance, reliability, data integrity, and failure modes.
> 4. **Check completeness** — What's missing? Error handling, tests, documentation, migration steps, rollback plans.
> 5. **Assess design** — Is this the right approach? Is there a simpler way? Will this be maintainable in 6 months?
>
> ## CONTEXT
> [Paste the COMPLETE baseline context package here — full diff, file contents, git log, git blame, project conventions. Do NOT summarize or truncate.]
>
> ## CONSTRAINTS
> - For PRs: focus on what the change introduces, what it might break, and whether it achieves its stated goal
> - For plans: focus on feasibility, completeness, risks, and missing considerations
> - For code: focus on correctness, security, performance, error handling, and maintainability
> - You have Read, Glob, and Grep tools available. Review the provided context and produce your structured findings FIRST. Then use tools to verify concerns and explore for issues the context may have missed (e.g., check callers of a changed function, look for side effects). Always produce your structured output — exploration supplements the review, it does not replace it.
>
> ## MUST DO
> - Provide specific file:line or section references, and explain WHY each finding matters — the impact, not just the symptom.
> - Suggest a concrete fix for each finding.
> - Also assess test adequacy: are the change's new/changed behaviors covered by tests, and are the important edge cases tested? Flag material gaps (not trivial coverage).
> - Quality over quantity — a few well-substantiated findings beat a long list of nitpicks.
> - Explore only after reviewing the provided context and producing your findings — exploration supplements the review, it does not replace it.
>
> ## WHAT NOT TO FLAG
> - Theoretical risks requiring unlikely preconditions.
> - Defense-in-depth when the primary defense is already adequate.
> - Pure style / formatting / naming preference.
> - Pre-existing issues outside the change's blast radius (review what the change *affects*, including unshown callers — not unrelated legacy).
> - Speculative "could be a problem" with no concrete trigger.
> - Anything matching a recalled learnings suppression (unless you argue the context changed).
>
> ## FINDINGS CAP
> Cap **suggestions** at ~5. **NEVER** cap critical or important findings — report every one you find. (The single judge does final curation in a later pass.)
>
> ## OUTPUT FORMAT
> You MUST produce output with these exact sections:
>
> ### Findings
> For **each** finding, emit every field below (these exact field names):
> - **severity:** critical | important | suggestion
> - **confidence:** high | medium | low   — your own, pre-synthesis
> - **location:** <relpath>:<line>
> - **symbol:** <enclosing function/class/section, if any>
> - **concern:** <free-form kebab slug, e.g. missing-null-check>   — HINT ONLY; do NOT author a fingerprint (the single judge computes the canonical one)
> - **issue:** one sentence — what's wrong
> - **why_it_matters:** impact if unaddressed
> - **recommendation:** concrete fix / alternative
> - **how_to_verify:** a concrete HUMAN-runnable check (command/input/trace) + expected observation — nothing executes it in this phase
> - **source:** <reviewer-id>
>
> If no issues: write "No issues found."
>
> ### What's Good
> Brief list of things done well.
>
> ### Overall Assessment
> One paragraph: readiness, biggest risk, most important thing to address.

### Reviewer: Security (native subagent) — Always

Use the `Agent` tool with `subagent_type: "reviewer-security"`. This dedicated security reviewer is **always** dispatched — in parallel with Claude and every available frontier reviewer, independent of which external providers are present. Its lens is fixed to **Security** (authz/authn, injection, secrets/PII, SSRF, path traversal, unsafe deserialization, missing input validation, insecure defaults, session handling, supply-chain).

Use the **same inline template as the Claude reviewer above** (TASK / LENS / REVIEW PROCESS / CONTEXT / CONSTRAINTS / MUST DO / WHAT NOT TO FLAG / FINDINGS CAP / OUTPUT FORMAT) — including the §3.1 finding schema, the what-not-to-flag + cap policy, and the test-adequacy line — with the **Security** lens block prepended in the `## LENS` section. Embed the full baseline context package the same way.

If `RC_CLAUDE_MAX_TURNS` is set, pass it to the Agent tool as maxTurns, same as the Claude reviewer.

**Exception — a security pin replaces the dedicated reviewer.** If Step 0 resolved `lens.security.replaces_dedicated=true` **and** `lens.security.providers` names one or more providers, do **NOT** dispatch `reviewer-security`. Instead assign the Security lens to those pinned provider(s) and dispatch them with it (see Lens Assignment, step 4). Otherwise the dedicated `reviewer-security` always runs.

### Reviewer: Codex — If Available

**IMPORTANT:** Use an `Agent` subagent to invoke Codex. This keeps the full review response out of the orchestrator's context window — only the structured findings return.

Dispatch a `general-purpose` Agent with this prompt:

> You are invoking the Codex reviewer for a Review Council review. Your job is to call the Codex CLI, collect its response, and return the structured findings.
>
> **Step 1: Discover CLI syntax.** Run `codex --help` and `codex exec --help` to learn the available subcommands and flags. Do NOT assume any specific flags exist — always derive the correct invocation from the help output.
>
> **Step 2: Invoke Codex.** Write the delegation prompt to `/tmp/rc-codex-prompt.md`, then use the syntax you discovered to run Codex in non-interactive/full-auto mode with the prompt content.
>
> **Reliability rules — apply to every CLI call (see `rules/orchestration.md` → "Reviewer Timeouts & Fast-Fail"):**
> - Cap each invocation so it can never hang forever. Resolve the binary first (it may be `timeout` or, on macOS, `gtimeout`, or absent), then use a portable `if`/`else` (works in bash, sh, and zsh): `TO="$(command -v timeout || command -v gtimeout || true)"` then `if [ -n "$TO" ]; then "$TO" "${RC_REVIEWER_TIMEOUT:-600}" codex …; else <pure-shell watchdog>; fi`. Do NOT use `${TO:+$TO 600}` — it word-splits in bash but not zsh. If **neither** `timeout` nor `gtimeout` exists, do NOT run bare — use the pure-shell watchdog from `rules/orchestration.md` § Reviewer Timeouts (background the call, `kill` it after the budget) so the invocation is still bounded. A non-zero exit (124 timeout / 143 SIGTERM / provider error) = failure.
> - Do NOT loop with compounding retries. At most ONE retry, and only for a single clearly-transient blip (e.g. one network hiccup).
> - Fast-fail immediately (return the SKIPPED sentinel, no further retries) when the output or error shows an auth failure (`not authenticated`, login/OAuth errors), a quota/rate cap (HTTP 429, `exhausted your … quota`, `rate limit`), or persistent overload (HTTP 503 / `high demand` past the timeout). A dead provider must fail in minutes, not tens of minutes.
>
> **MCP fallback:** If the CLI call fails for a non-fatal reason (not an auth/quota fast-fail), use the `mcp__codex__codex` tool with the delegation prompt instead.
>
> **If both fail**: Return "SKIPPED: Codex unavailable — [error details]"
>
> **Output contract (the delegation prompt you write in Step 2 already specifies this — preserve it):** Codex's review must have a `Findings` section where **every finding carries all of these fields, by these exact names** — `severity` (critical|important|suggestion), `confidence` (high|medium|low), `location` (`<relpath>:<line>`), `symbol`, `concern` (free-form kebab slug — a HINT only; no fingerprint), `issue`, `why_it_matters`, `recommendation`, `how_to_verify` (a human-runnable check + expected observation), `source` — plus the `What's Good` and `Overall Assessment` sections. Same **what-not-to-flag** rules and **cap policy** (cap suggestions at ~5; **never** cap critical/important), and include the **test-adequacy** line: "Also assess test adequacy: are the change's new/changed behaviors covered by tests, and are the important edge cases tested? Flag material gaps (not trivial coverage)." If a **lens block** was assigned in Step 3, it is already prepended to the delegation prompt — keep it (lens = emphasis, not blinders; still flag any critical outside the lens).
>
> Return Codex's full structured review output verbatim (Findings with all the fields above, What's Good, Overall Assessment).

### Reviewer: Google (Antigravity / Gemini) — If Available

**IMPORTANT:** Use an `Agent` subagent to invoke the Google-family reviewer, same pattern as Codex — keeps the response out of the orchestrator's context. `agy` (Antigravity) and `gemini` share one slot; try `agy` first, fall back to `gemini`.

Dispatch a `general-purpose` Agent with this prompt. Pass the ordered tool list resolved in Step 0 — `agy` then `gemini` if both are installed, or whichever single tool is available — **using the resolved paths** from Step 0's detection output (`agy=<path>` and `gemini_fallback=<path>`), not bare command names, so the subagent can invoke each even if its dir isn't on the subagent's `PATH`:

> You are invoking the Google-family reviewer (Antigravity `agy`, with Gemini `gemini` as fallback) for a Review Council review. Your job is to call the CLI, collect its response, and return the structured findings. Try the tools in this order: **[ordered tool list with resolved full paths, e.g. `/Users/you/.local/bin/agy`, then `/Users/you/.nvm/.../bin/gemini`]**. Invoke each tool by the exact full path given here — if a tool isn't found on `PATH`, use the full path provided rather than declaring it unavailable.
>
> For each tool in order:
>
> **Step 1: Discover CLI syntax.** Run `<tool> --help` to learn the available subcommands and flags. Do NOT assume any specific flags exist — always derive the correct invocation from the help output. (Hints verified against agy 1.0.16–1.1.0: `agy -p "<prompt>"` runs one prompt non-interactively and prints the response; optional `--add-dir <repo>`, `--model <name>`, and `--dangerously-skip-permissions` to avoid blocking on approvals in a non-TTY. `gemini` uses `gemini -p "<prompt>"` and may need `--skip-trust` or `GEMINI_CLI_TRUST_WORKSPACE=true` for headless/non-TTY runs.)
>
> **Give `agy` room for a cold start — this is the "more time" it needs.** `agy`'s **first** `-p` call in a session pays a cold-start cost (model load, auth handshake, update check) and can legitimately take **several minutes** (a warm call is ~10s). Two caps apply to it and BOTH must cover the budget, or the cold start is truncated:
> - The outer wrapper cap = `${RC_REVIEWER_TIMEOUT:-600}` (10 min default).
> - agy's **own** `--print-timeout`, which defaults to **just 5 minutes**. You MUST pass it sized to the budget — but its value is a **Go duration string that needs a unit suffix**: a bare integer is rejected (`agy --print-timeout 600` → exit 2, `missing unit in duration "600"`, which kills the primary Google reviewer instantly). `RC_REVIEWER_TIMEOUT` is in **seconds**, so append `s`: `--print-timeout "${RC_REVIEWER_TIMEOUT:-600}s"` (or a literal like `10m`) — never a bare `--print-timeout 600`. Not optional: without it agy cuts itself off at 5m before the wrapper and a slow cold start looks like a failure.
>
> Treat multi-minute latency on the first `agy` call as **normal, not a hang** — do not fast-fail it for being slow. (Only auth/quota errors fast-fail; see below.)
>
> **Step 2: Invoke the tool.** Write the delegation prompt to `/tmp/rc-google-prompt.md`, then use the syntax you discovered to run the tool in non-interactive mode with the prompt content and text output.
>
> **Reliability rules — apply to every CLI call (see `rules/orchestration.md` → "Reviewer Timeouts & Fast-Fail"):**
> - Cap each invocation so it can never hang forever. Resolve the binary first (it may be `timeout` or, on macOS, `gtimeout`, or absent), then use a portable `if`/`else` (works in bash, sh, and zsh): `TO="$(command -v timeout || command -v gtimeout || true)"` then `if [ -n "$TO" ]; then "$TO" "${RC_REVIEWER_TIMEOUT:-600}" <tool> …; else <pure-shell watchdog>; fi`. Do NOT use `${TO:+$TO 600}` — it word-splits in bash but not zsh. If **neither** `timeout` nor `gtimeout` exists, do NOT run bare — use the pure-shell watchdog from `rules/orchestration.md` § Reviewer Timeouts (background the call, `kill` it after the budget) so the invocation is still bounded. A non-zero exit (124 timeout / 143 SIGTERM / provider error) = failure.
> - Do NOT loop with compounding retries. At most ONE retry per tool, and only for a single clearly-transient blip (e.g. one network hiccup). Do NOT chase a provider's own model auto-fallback across many backoff attempts.
> - Fast-fail a tool immediately (move to the next tool, no further retries) when the output or error shows an auth failure (`no longer supported`, `not authenticated`, `please migrate to the Antigravity`, `secret keyring is locked`), a quota/rate cap (HTTP 429, `exhausted your daily quota`, `TerminalQuotaError`, `rate limit`), or persistent overload (HTTP 503 / `high demand` past the timeout). A dead provider must fail in minutes, not tens of minutes.
>
> **Step 3: Validate the output before accepting it.** A tool counts as successful ONLY if it returned **non-empty** text containing a real `Findings` section (and `Overall Assessment`). Note: `agy -p` can exit **0 while printing nothing** in a non-TTY subprocess — so a zero exit code is not sufficient. Empty or malformed output is a **failure**, not a clean review.
>
> **Step 4: Retry `agy` once (only if it failed *fast*), THEN fall back — this ordering is the whole point.** A transient `agy` blip must never be masked by a `gemini` that cannot succeed, but the retry must never turn into a runaway. Concretely:
> - Retry `agy` ONCE **only when the empty/malformed result came back quickly** — as a rule of thumb, in under ~⅓ of the budget (e.g. < ~2 min of a 10 min cap). That fast-empty is the exit-0-no-stdout cold-start quirk, and the warm retry almost always succeeds. **Time-box the retry to the *remaining* budget, not a fresh `RC_REVIEWER_TIMEOUT`**, so first-try + retry together can never exceed one budget. This is the single allowed retry for `agy`.
> - Do **NOT** retry — move straight to the fallback — when the empty result arrived **near the cap** (a slow call that completed but printed nothing: treat it exactly like a timeout — a second full attempt would nearly double the wall-clock), or when `agy` **timed out** (rc 124/143), is **absent**, or **hard-failed** (auth/quota fast-fail — retrying won't help). Never retry a tool that hard-failed on auth/quota.
> - **This is a terminal outcome for the slot.** Once you've done the one allowed `agy` retry (or skipped it per the rule above) and, if needed, tried `gemini`, the Google reviewer's result — success or `SKIPPED` — is **final for this round**. Do not let the orchestrator's Step 3.5 reviewer-level retry re-run it (see Step 3.5: the Google slot is not eligible for external retry once its internal retry/fallback is exhausted).
> - **`gemini` is a dead end for Workspace/Dasher accounts:** `gemini -p` fast-fails near-instantly with `IneligibleTierError` (`reasonCode: DASHER_USER`, "not eligible for Gemini Code Assist for individuals") for any Google Workspace-domain account and any account without a `GEMINI_API_KEY`/Vertex/enterprise license. Treat that as the slot being unavailable — it is expected, not a bug to retry.
>
> **Output contract (the delegation prompt you write in Step 2 already specifies this — preserve it):** the review must have a `Findings` section where **every finding carries all of these fields, by these exact names** — `severity` (critical|important|suggestion), `confidence` (high|medium|low), `location` (`<relpath>:<line>`), `symbol`, `concern` (free-form kebab slug — a HINT only; no fingerprint), `issue`, `why_it_matters`, `recommendation`, `how_to_verify` (a human-runnable check + expected observation), `source` — plus the `What's Good` and `Overall Assessment` sections. Same **what-not-to-flag** rules and **cap policy** (cap suggestions at ~5; **never** cap critical/important), and include the **test-adequacy** line: "Also assess test adequacy: are the change's new/changed behaviors covered by tests, and are the important edge cases tested? Flag material gaps (not trivial coverage)." If a **lens block** was assigned in Step 3, it is already prepended to the delegation prompt — keep it (lens = emphasis, not blinders; still flag any critical outside the lens).
>
> **On success:** Return the full structured review output (Findings with all the fields above, What's Good, Overall Assessment), and note which tool produced it — prefix your answer with `TOOL: Antigravity` (for `agy`) or `TOOL: Gemini` (for `gemini`).
>
> **If every tool fails**: Return a SKIPPED message attributed to the **primary** tool, with a per-tool status — e.g. "SKIPPED: Google (Antigravity) unavailable — agy: empty output after retry; gemini fallback: ineligible (Workspace/Dasher account, IneligibleTierError)". Lead with `agy` whenever it was installed. Do **NOT** report the slot as a bare "Gemini auth failure" when `agy` was the intended reviewer — that misleads a user whose `agy` works fine interactively.

### Reviewer: Perplexity — If Available

**IMPORTANT:** Use an `Agent` subagent to invoke Perplexity, same pattern — keeps the API response out of the orchestrator's context.

Dispatch a `general-purpose` Agent with this prompt:

> You are invoking the Perplexity reviewer for a Review Council review. Your job is to call the Sonar API, collect its response, and return the structured findings.
>
> **Step 1: Build the JSON payload** using `jq` to avoid manual escaping:
> ```bash
> PROMPT="[the full delegation prompt text]"
> jq -n --arg model "sonar" --arg prompt "$PROMPT" \
>   '{model: $model, messages: [{role: "user", content: $prompt}]}' \
>   > /tmp/rc-perplexity-payload.json
> ```
>
> **Step 2: Call the API:**
> ```bash
> curl -fsS --max-time "${RC_REVIEWER_TIMEOUT:-600}" https://api.perplexity.ai/v1/chat/completions \
>   -H "Authorization: Bearer $PERPLEXITY_API_KEY" \
>   -H "Content-Type: application/json" \
>   -d @/tmp/rc-perplexity-payload.json \
>   -o /tmp/rc-perplexity-response.json
> ```
> Note: `-f` makes `curl` exit non-zero (22) on any HTTP 4xx/5xx without exposing the status code. Treat any such failure as terminal — fast-fail (return SKIPPED, no retry), do not loop. Perplexity has no fallback tool, so there's nothing to gain from distinguishing 401/403/429 from other errors. (If you ever need the exact status, capture it with `-w '%{http_code}'` and drop `-f`.)
>
> **Step 3: Parse the response:**
> ```bash
> jq -er '.choices[0].message.content' /tmp/rc-perplexity-response.json
> ```
>
> **If curl or jq fails**: Return "SKIPPED: Perplexity unavailable — [error details]"
>
> **Output contract (the `$PROMPT` delegation text in Step 1 already specifies this — preserve it):** the review must have a `Findings` section where **every finding carries all of these fields, by these exact names** — `severity` (critical|important|suggestion), `confidence` (high|medium|low), `location` (`<relpath>:<line>`), `symbol`, `concern` (free-form kebab slug — a HINT only; no fingerprint), `issue`, `why_it_matters`, `recommendation`, `how_to_verify` (a human-runnable check + expected observation), `source` — plus the `What's Good` and `Overall Assessment` sections. Same **what-not-to-flag** rules and **cap policy** (cap suggestions at ~5; **never** cap critical/important), and include the **test-adequacy** line: "Also assess test adequacy: are the change's new/changed behaviors covered by tests, and are the important edge cases tested? Flag material gaps (not trivial coverage)." As the diff-only **Dependency / CVE / best-practices** reviewer, Perplexity's lens block is already prepended to `$PROMPT` (lens = emphasis, not blinders; still flag any critical outside the lens).
>
> Return the full structured review output verbatim (Findings with all the fields above, What's Good, Overall Assessment).

### Delegation Prompt

For **all** reviewers (including Claude and Security), use the delegation format from `rules/delegation-format.md` — which carries the §3.1 finding schema, the what-not-to-flag + cap policy, and the test-adequacy line. The prompt structure and review criteria are identical for every provider — only the transport and the prepended **lens block** differ. When `settings.personas` is true, prepend each reviewer's assigned lens block (from Lens Assignment) to its delegation prompt; when it is false, send every reviewer the identical non-lens prompt. The baseline context package from Step 2 (including any recalled Team Learnings — Conventions) goes into the CONTEXT section.

## Step 3.5: Well-formed Check & Recover

**Join barrier — wait for the whole fleet before proceeding.** First, wait until **every** reviewer dispatched in Step 3 has **returned** (each is bounded by `RC_REVIEWER_TIMEOUT`, so a stuck reviewer times out rather than blocking forever — a reviewer *still running* is not the same as one that *failed*). Do NOT begin the well-formed check, and do NOT proceed to the refutation pass, with only a subset of reviewers back. Collect all Round-1 results first, then run the checks below over the full set.

Before the refutation pass, validate that each reviewer's output is **well-formed** — a **structural** check (required sections present; finding fields present and in-enum), NOT a truth check of whether any finding is correct. Refer to `rules/orchestration.md` → Output Validation for full rules.

### Validate

For each reviewer's response:
1. Check for `## Findings` (or `### Findings`) section — present?
2. Check for `## Overall Assessment` (or `### Overall Assessment`) section — present?
3. If Findings section exists and contains findings, check each finding carries all required fields from `rules/orchestration.md` → Field-Level Validation (the §3.1 schema: `severity`, `confidence`, `location`, `symbol`, `concern`, `issue`, `why_it_matters`, `recommendation`, `how_to_verify`, `source`)
4. If Findings section says "No issues found" or equivalent — mark as CLEAN
5. If sections are missing or findings lack required fields — mark as FAILED

### Report & Recover

Count VALID, CLEAN, and FAILED results.

**If all VALID or CLEAN:** Announce results and proceed to Step 4.

```
Round 1 complete. All N reviewers produced valid output:
  Claude        [ok]  3 findings
  Codex         [ok]  5 findings
  Antigravity   [clean]  no issues found
```

**If any FAILED but enough remain (>= RC_MIN_REVIEWERS, default 2):**

Report the status and ask the user conversationally:

"Round 1 complete: [list results]. N of M reviewers succeeded. Should I retry the failed reviewer(s) (will use additional tokens), proceed with the N successful reviews, or abort?"

If `RC_AUTO_RETRY` is set to `true`, skip the prompt and retry automatically.

**If any FAILED and not enough remain (< RC_MIN_REVIEWERS):**

"Round 1 complete: [list results]. Only N reviewer(s) succeeded — council mode requires RC_MIN_REVIEWERS. Should I retry the failed reviewer(s) (will use additional tokens), or abort? Proceeding without retry means single-reviewer mode."

**If all FAILED:** Report the failure and abort.

### Retry

If retrying:
- Re-dispatch only the FAILED reviewers using the same dispatch method as Round 1
- Validate the retry results using the same checks
- **One retry max per reviewer** — if it fails again, mark as unavailable
- Merge all validated results (first-pass and retried) into a single pool
- Proceed to Step 4 with the merged pool

## Step 4: Refutation Pass

Round 1 produced independent findings. Instead of asking reviewers to revise toward a shared synthesis (the old anchoring Round 2 — **deleted**), this step tries to **refute** each candidate finding with a **fresh, cross-family** verifier that has never seen the other reviewers' output. An UPHELD is then independent corroboration; a REFUTED (with counter-evidence) is a genuine counter-finding. Verdicts feed the judge (Step 5). Use the **Refutation Template** in `rules/delegation-format.md`.

**Gated on `settings.verify` (resolved in Step 0).** If `settings.verify` is **false**, skip this step entirely: carry every Round-1 finding forward tagged `[unverified]`, and go straight to the judge (Step 5).

If `settings.verify` is true, apply these gates and rules **in order**.

### 4.0 Skip gates (check first, before any routing)

1. **Solo-Claude mode** — if only Claude-family reviewers (Claude + the dedicated Security reviewer) are available — i.e. no different-family reviewer to cross-verify against — **skip refutation entirely**. Tag every finding `[1 reviewer · unverified]` and go to Step 5. Do NOT self-verify with another Claude spawn — one model refuting itself is correlated-error theatre, not cross-family evidence.
2. **Budget check FIRST (see `rules/orchestration.md` → Budget).** Because Round-1 reviewers run **concurrently**, the elapsed cost so far is the **long pole** — the **maximum** measured elapsed any single Round-1 CLI invocation reported (e.g. `agy`'s cold start) — **not** the arithmetic sum of all of them (they overlapped in wall-clock), and not a stopwatch you watch. *(Native subagents don't report CLI-measured elapsed yet — that wiring lands in Phase 4; until then treat their time as covered by the CLI long pole rather than adding a guessed number.)* If that long-pole elapsed has already reached `settings.run_budget_seconds`, **skip refutation**: tag all findings `[unverified]`, print `stopped at budget: <n>s`, and go straight to Step 5. Never hard-abort — degrade.

If neither gate fires, run the pass.

### 4.1 Select candidates

1. **Merge** all Round-1 findings into one pool. To detect cross-family agreement, cluster them provisionally by `(location, concern-slug)` — a lightweight grouping; the judge computes the authoritative fingerprint in Step 5.
2. **Skip findings already raised by ≥2 different families** — they are already corroborated, so no verification is needed. They pass to the judge as cross-family-corroborated (eligible for the +1-tier promotion) without consuming a verifier slot.
3. From the remaining (single-family) findings, take the **top `settings.verify_max_findings`** (default 12) by severity (critical > important > suggestion, then confidence). Any beyond the cap ship to the judge tagged `[unverified]`.

### 4.2 Route (print the routing table)

Assign each selected candidate to a verifier that is **repo-capable** and from a **DIFFERENT family** than the finding's origin (families: **Claude-fresh / Codex / Google**). Rules:

- **NEVER route a code-tracing finding to Perplexity** — it is diff-only and tool-less; it cannot Read/Grep/trace, so it can neither uphold nor refute a code claim.
- The verifier family must differ from the finding's origin family (a model does not verify its own finding).
- If no different repo-capable family is available for a given finding (e.g. only Claude is repo-capable this run), that finding cannot be cross-verified — ship it to the judge `[unverified]` rather than self-verifying.

**Print the routing table** so the assignment is observable. Example:
```
Refutation routing (verify cap 12):
  finding                            origin      → verifier
  auth.ts:42 missing-authz           Codex       → Claude-fresh
  db.ts:88 n-plus-one                Claude      → Google
  api.ts:20 unvalidated-input        Google      → Codex
  [skipped: raised by ≥2 families]   payment.ts:5 race  (Claude+Codex)
  [unverified: over cap]             util.ts:9 minor-leak
```

### 4.3 Dispatch — ONE fresh subagent per verifier family

**Batch by verifier family:** spawn exactly **one fresh Agent per verifier family**, handing it **all** the findings routed to that family (isolation only requires hiding the synthesis, not a spawn per finding). Each subagent gets the **Refutation Template** (`rules/delegation-format.md`) with its assigned findings pasted in and the baseline context — but **NOT** any other reviewer's output or any synthesis.

- **Claude-fresh** → a new `reviewer-claude` Agent (Read/Glob/Grep), refutation prompt only.
- **Codex** → a `general-purpose` Agent that invokes the Codex CLI with the refutation prompt (same transport + reliability rules as Round 1).
- **Google** → a `general-purpose` Agent that invokes `agy`→`gemini` with the refutation prompt (same transport + reliability rules as Round 1).

**Hard rule: a verdict is only valid from a fresh Agent spawn.** If no verifier subagent actually ran for a finding (over the cap, no eligible different family, a verifier that SKIPPED/failed, or budget-degraded), that finding is **`[unverified]`** — it is **NOT** refuted. Absence of a spawn never means REFUTED.

### 4.4 Collect verdicts

Each verifier returns a 3-way verdict per assigned finding — **UPHELD** / **REFUTED** (with cited counter-evidence) / **INCONCLUSIVE**. Carry the verdicts (plus the ≥2-family corroboration status from 4.1) into the judge. Remember: **INCONCLUSIVE is not REFUTED** — a finding only drops on positive counter-evidence.

## Step 5: Judge Synthesis

A single **active judge** (you, the orchestrator) makes one pass over the Round-1 findings plus the Step-4 verdicts. It does not re-review the code — it dedups, recalibrates, suppresses, and emits a ledger.

### 5.1 Compute the canonical fingerprint

For each finding, compute `fingerprint = <relpath>::<normalized-symbol-or-hunk>::<normalized-concern>`. The **judge** computes it — reviewers never author it (their `concern` slug is a hint only). Normalize: repo-relative path; symbol lowercased/trimmed (or the hunk range if no symbol); concern reduced to its core kebab phrase.

**Tool findings included.** The Tier A candidates and the raw Tier B candidates both carried from Step 2.5 (§2.5.3) are fingerprinted the **same way** — a *semantic* reduction, **not** a string match between a tool's rule id and an LLM's `concern` slug (a `semgrep:<rule>` id and a Codex free-text concern are never string-identical; the judge recognizes them as the same issue by file/line proximity + semantic reading, exactly as it already does for two differently-worded LLM findings). No new machinery — tool findings flow through the existing fingerprint/dedup path.

### 5.2 Semantic cross-model dedup

Collapse findings with the **same fingerprint** into one. Keep the most specific/actionable text and **union** their origin-families (so a finding raised by Claude and Codex records both). This is the authoritative dedup — the Step-4 provisional clustering was only for corroboration detection.

**When a Tier B tool signal and an LLM finding share a fingerprint, they collapse into one finding**; record the tool name(s) on the merged finding (this populates the ledger's `tool?` column, §5.5) and mark it tool-corroborated for §5.3. Tier A candidates also participate in dedup, but a Tier A hit is never *downgraded* by merging — see §5.3.

### 5.3 Recalibrate (§recalibration)

- **+1 tier (severity or confidence)** when a finding has **cross-family corroboration** — it was raised by **≥2 different families**, **or** it was **UPHELD** in Step 4 by a **different family** (these are the two `[cross-reviewed]` paths). A same-family-only pile-up is **NOT** a promotion signal.
- **Drop a finding ONLY if it was REFUTED with positive counter-evidence.** Never drop on absence of proof.
- **Keep and tag `[unverified]`** if the verdict was **INCONCLUSIVE**, or the finding was never verified at all (over the cap, or budget-degraded) — in a **multi-reviewer** run. Solo-Claude findings are already tagged `[1 reviewer · unverified]` in Step 4.0; they do not additionally get the plain `[unverified]` badge.
- **Never demote a `critical` out of Critical** for being single-reviewer. Tag it `[1 reviewer · unverified]` and keep it Critical.
- **Suppress** any finding whose fingerprint matches a **learnings Suppression** entry recalled in Step 0.5. **Count the suppressions.**
- **Tier A tool finding (from Step 2.5)** → enters at its **inherited** severity (secrets → Critical; osv-scanner → its CVSS→severity map), badge **`[verified]`**, ledger `verdict = TOOL-VERIFIED` (it never went through Step-4 refutation). It is **exempt from the suggestion cap** (moot in practice — Tier A is rarely a `suggestion` — but state it for completeness) and the judge **never downgrades** it: severity is inherited, not judge-assigned. It is pre-verified evidence, not an opinion.
- **Tier B tool finding, no LLM match on its fingerprint** → stays a `suggestion`, badge **`[tool-only:<rule>]`**, subject to the normal suggestion cap.
- **Tier B tool finding, LLM match on the same fingerprint** → promote to **`[verified]`** at the **higher** of the tool's context-weight and the LLM's self-rated severity. This is the one place `[verified]` and `[cross-reviewed]` can coexist — a finding can be both tool-grounded and cross-family-corroborated; badge it `[verified]` (the stronger badge, see Step 6 precedence) and note the cross-review in prose.

### 5.4 Apply the what-not-to-flag filter

Drop any surviving finding that matches the **WHAT NOT TO FLAG** list (the same policy the reviewers were given: theoretical/precondition-heavy risks, redundant defense-in-depth, pure style, out-of-blast-radius legacy, speculative-with-no-concrete-trigger).

### 5.5 Emit the ledger (BEFORE the prose report)

Print one row per surviving finding, then the suppression count:
```
Judge ledger:
fingerprint                          | origin-families | verdict      | suppression? | tool?     | final-severity | final-confidence
config.yml::_::hardcoded-secret      | —               | TOOL-VERIFIED| no           | gitleaks  | critical       | high
auth.ts::checkauth::missing-authz    | codex,claude    | UPHELD       | no           | semgrep   | critical       | high
db.ts::listrows::n-plus-one          | claude          | INCONCLUSIVE | no           | —         | important      | medium
api.ts::handler::unvalidated-input   | google          | REFUTED      | (dropped)    | —         | —              | —
run.sh::deploy::sc2086-word-split    | —               | TOOL-ONLY    | no           | shellcheck| suggestion     | medium
Suppressions applied: 1
```
The `tool?` column (was always `—` in Phase 1) now carries the tool name(s) whose finding hit the same fingerprint, or `—` if none did. Two verdict values are specific to static analysis: **`TOOL-VERIFIED`** for a Tier A finding (never went through Step-4 refutation) and **`TOOL-ONLY`** for a Tier B tool-only signal no reviewer corroborated (badge `[tool-only:<rule>]`). A Tier B signal a reviewer *did* corroborate merges into that reviewer's row (its `verdict` stays UPHELD/INCONCLUSIVE from Step 4, `tool?` records the tool, and it is `[verified]`). Emit the ledger **before** the Step-6 prose so the judge's reasoning is auditable.

## Step 6: Report

Produce the final curated output, **grouped by severity FIRST**. Agreement is a per-finding **badge**, never the sort key.

**Badges:**
- `[verified]` — tool-grounded: a Tier A deterministic finding (secrets/CVE), or a Tier B tool signal an LLM reviewer corroborated on the same fingerprint (§5.3).
- `[cross-reviewed]` — UPHELD by a different family, or raised by ≥2 different families.
- `[1 reviewer · unverified]` — a single reviewer, not cross-verified (a single-reviewer `critical` keeps Critical severity **and** carries this badge).
- `[unverified]` — verification was skipped / inconclusive / over-cap / budget-degraded, or `settings.verify` was off.
- `[tool-only:<rule>]` — a Tier B tool signal no reviewer corroborated (stays a Suggestion, §5.3).

**Badge precedence** when more than one could apply — show the **strongest**, mention the rest in prose: `[verified]` > `[cross-reviewed]` > `[1 reviewer · unverified]` > `[unverified]`. (A finding that is both tool-grounded and cross-family-corroborated shows `[verified]` and notes the cross-review in prose.)

The judge ledger from Step 5 is printed **before** this prose report. Then emit this format:

---

## Review Council Report

**Target:** [what was reviewed — PR #N, file path, etc.]
**Type:** [PR | Plan/Document | Code]
**Reviewers:** [reviewers that participated] ([N] participating — [skipped: reasons])
**Lens map:** [the per-reviewer lens assignment printed in Step 3 — e.g. `reviewer-security: Security · reviewer-claude: Correctness + Data-integrity · Codex: Correctness + Cross-file · Perplexity: Dependency`. If `settings.personas` is false, note "personas off (legacy prompt)".]
**Pipeline:** [prepend `static scan → ` when Step 2.5 ran] Round 1 → well-formed check → refutation → judge → report  [append `· stopped at budget: <n>s` if the run degraded on budget; note `· refutation skipped (solo-Claude)` or `· refutation off (verify=false)` when applicable, and `· static analysis: off` when Step 2.5 was disabled/skipped — these are the pipeline stages actually run]. Append the Step-2.5 status line (Static analysis: …) beneath this when the scan ran.

**Badge legend** — each finding carries a badge for **how much corroboration it has** (strongest → weakest; when several apply, the strongest is shown and the rest noted in prose). Print this block verbatim in every report so the labels are self-explanatory; include only the rows for badges that actually appear, or the whole list — your call, but never leave a badge unexplained:
> - `[verified]` — **tool-grounded**: a Tier A deterministic hit (secret/CVE), or a Tier B tool signal an LLM reviewer confirmed on the same fingerprint.
> - `[cross-reviewed]` — **corroborated across model families**: raised by ≥2 different families, or UPHELD by a different family in the refutation pass.
> - `[1 reviewer · unverified]` — **one reviewer, no cross-check available** (solo-Claude runs, where no different family exists to verify against). Severity is kept as-is — a single-reviewer `critical` stays Critical.
> - `[unverified]` — **not cross-verified**: the refutation pass was inconclusive, skipped (over the cap or budget-degraded), or turned off. Not a knock on the finding — just uncorroborated.
> - `[tool-only:<rule>]` — a **static-analysis (Tier B) signal no reviewer corroborated**; kept as a low-priority Suggestion.

### Critical Issues
[Every `critical` finding, each with its badge. Single-reviewer criticals stay here, tagged `[1 reviewer · unverified]`.]

*If none: "No critical issues identified."*

### Important Findings
[Every `important` finding, each with its badge.]

*If none: "No important findings."*

### Suggestions
[Every `suggestion` finding, each with its badge.]

*If none: "No additional suggestions."*

### Dissenting Opinions
[Genuinely unresolved disagreement the judge could not reconcile — e.g. one family UPHELD and another REFUTED the same fingerprint. Record both perspectives. This is a report **section**, not a round.]

*If none: omit this section entirely.*

### What's Done Well
[Brief — things reviewers praised. Keep to 2-3 bullet points max.]

---

## Step 7: Capture Gate (learning capture)

**Gated on `settings.learn` (resolved in Step 0).** If `settings.learn` is **false**, skip this step entirely — no gate, no prompt, no writes. (Symmetric with Step 0.5's recall gate: the one knob turns both the read and write sides off.)

When `settings.learn` is true, after the Step-6 report, run a short **capture gate** that distills this run's *skips* into persisted learnings — the write side of the loop whose read side ran in Step 0.5. It mirrors `reply-pr`'s human gate: **propose, then stop and wait, then write only what the human confirms.** It is **record-only** — it never edits code, never re-runs a reviewer, never changes the report already emitted.

### 7.1 Walk the findings
Drive off the **Step-5 ledger** (its rows already carry the judge's canonical fingerprint) and the Step-6 grouping. Present the surviving findings as a compact list and, for each, ask the author to mark one of:
- **tackle** — they'll fix it → capture **nothing** (a real finding they're acting on is not a false positive).
- **skip** — they're not acting on it, with a **one-line reason**.
- **skip all** — blanket-skip the remainder.

Show it as an editable proposal (a sensible default per finding is fine), never auto-applied.

### 7.2 Distill a skip into a learning
Only a **skip with a generalizable reason** becomes a learning; a one-off skip (*"not now / out of scope"*) captures **nothing**.
- Reason framed as *"this specific finding is a known false positive here"* → a **Suppression**, keyed by the finding's **ledger fingerprint** (§5.1 — use it **verbatim**; never re-author a fingerprint by hand).
- Reason framed as a **general rule** (*"we never flag X in this repo"*) → a **Convention** (a one-line rule).
- If several skips this run share one general reason, propose a **single Convention** rather than N Suppressions (one confirmation, less noise).

### 7.3 Confirm, then write (human-confirmed only — D7)
Before writing anything, show the **exact** entries that would be appended:
- Suppression → `- fingerprint: <fp> | reason: <reason> | added: <today>`
- Convention → `- <one-line rule>`

**Wait for explicit approval.** On approval, append each via `Bash` — one call per entry (the script writes the `§3.6` format; you never hand-format `learnings.md`):
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/rc-learn.sh" add-suppression "<ledger-fingerprint>" "<reason>"
"${CLAUDE_PLUGIN_ROOT}/scripts/rc-learn.sh" add-convention  "<one-line rule>"
```
The script creates `.review-council/learnings.md` (canonical §3.6 skeleton) if absent, appends under the right section, and is **idempotent** — re-approving an existing learning is a safe no-op, so the gate never has to dedupe against the file. Decline (or `settings.learn` off) → write nothing; no confirmation for a given entry → skip just that entry.

**Check each call's exit status before summarizing.** `rc-learn.sh` exits **0** on a successful (or idempotent no-op) write and **2** on a validation failure — a `|` or control character in the fingerprint/reason/convention, an empty field, a malformed date — printing the reason on stderr and writing **nothing**. If a call exits non-zero, **surface its stderr message to the user** and do **not** count that entry as captured (the rest still write; the run isn't blocked). Count only the entries that actually landed.

Print a one-line summary of **what actually wrote** (e.g. `Captured: 1 suppression, 1 convention → .review-council/learnings.md`; note any failures, e.g. `1 skipped: reason contained "|"`), the same observable-artifact spirit as the lens map / ledger — the summary must never report a capture that didn't happen. These entries feed **Step 0.5 recall** and **Step 5 suppression** on the next run.

## Step 8: Cleanup

Remove any temporary files created during the review:

```bash
rm -f /tmp/rc-*-prompt.* /tmp/rc-perplexity-payload.json /tmp/rc-perplexity-response.json
```

Note: Subagents handle their own temp files, so this is a belt-and-suspenders cleanup for anything that leaked.

## Orchestration Rules

- **No debate rounds.** The pipeline is Round 1 → well-formed check (3.5) → refutation (4) → judge (5) → report (6). There is no Round 2/Round 3 and no revise-toward-consensus; unresolved disagreement is a **Dissenting Opinions** report section, not another round.
- **Substance over style.** Aggressively filter out nitpicks, formatting opinions, and subjective preferences.
- **Severity is decoupled from agreement.** Agreement is a per-finding **badge** (`[cross-reviewed]` / `[1 reviewer · unverified]` / `[unverified]`), not the sort key. Cross-family corroboration (≥2 different families, or an UPHELD from a different family) can *raise* a finding one tier; a single-reviewer `critical` stays Critical. Same-family-only agreement promotes nothing.
- **Be actionable.** Every finding must say what to do, not just what's wrong.
- **Respect the user's time.** The output is a curated, prioritized list — not a dump of everything all reviewers said. Fewer high-quality findings > many low-quality ones.
- **Severity definitions:**
  - **Critical** — Will cause bugs, security vulnerabilities, data loss, or system failures. Blocks merge/ship.
  - **Important** — Significant quality, performance, or maintainability concern. Should fix.
  - **Suggestion** — Minor improvement opportunity. Nice to have.
