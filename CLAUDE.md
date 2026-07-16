# Review Council

<!-- rc:description:start -->
Multi-agent code review for Claude Code. Multiple AI models review your PR, code, or plan independently; a cross-family refutation pass and an active judge then distill the findings into a curated, severity-ranked list of what actually needs changing.
<!-- rc:description:end -->

## Commands

- `/review-council:run [target]` — Run a multi-agent review (auto-detects target type and available providers)
- `/review-council:setup` — Show provider status and prerequisites
- `/review-council:uninstall` — Remove configuration

## How It Works

Everything below is orchestrated locally inside a single Claude Code session and ends in a printed report — Review Council never pushes commits, opens PRs, or posts PR comments on its own (see `README.md` → GitHub Actions (Roadmap) for a possible future CI mode). Note the data egress this implies: when Codex, Google, or Perplexity are enabled, the gathered review context (diff, file contents, etc.) is sent to those third-party tools/APIs — only Claude (the native subagent) stays fully local.

1. **Detect providers + read config** — Auto-detects which reviewers are available (CLI first, MCP fallback) and reads `.review-council/config.yml` / `config.local.yml` (via `scripts/rc-config.sh`) for the reviewer roster, lens bindings, and run settings — precedence `env > config.local.yml > config.yml > built-in default`.
2. **Recall learnings** — If `settings.learn`, reads `.review-council/learnings.md` (if present). Its Conventions fold into the shared baseline context (the Gather step below); its Suppressions are held for the judge. Absent file → skip silently.
3. **Detect target** — Auto-detects if you're reviewing a PR, source code, or plan/document.
4. **Gather** — Collects relevant context (diff, files, related docs, recalled Conventions) shared identically with every reviewer.
5. **Static analysis** (Step 2.5, gated on `static_analysis.enabled`) — One subagent runs up to eight external tools (`gitleaks`, `trufflehog`, `osv-scanner`, `semgrep`, `ruff`, `shellcheck`, `actionlint`, `hadolint`) against the diff. **Tier A** (verified secrets/CVEs) is carried straight to the judge, pre-`[verified]`; **Tier B** (SAST/lint) is folded into the shared context above as signals for reviewers to corroborate or dismiss. Not a voting reviewer — no lens, doesn't count toward `min_reviewers`, never refuted in the refutation pass. See "Static Analysis" below.
6. **Round 1 — lens-differentiated review** — Sends the identical context to all available reviewers in parallel, each assigned a lens (Correctness & concurrency as the shared core, plus one diff-aware specialist overlay), plus an always-on dedicated **Security** reviewer.
7. **Well-formed check** — Validates each reviewer's output structurally (required §3.1 fields/sections present); retries once, then degrades or asks the user.
8. **Refutation pass** — Gated on `settings.verify` and budget-bounded: candidate findings are routed to an isolated, different-family verifier that returns UPHELD / REFUTED (counter-evidence) / INCONCLUSIVE. Skipped in solo-Claude mode or once `run_budget_seconds` is spent — findings are tagged `[1 reviewer · unverified]` (solo-Claude) or `[unverified]` (budget/over-cap) instead, never dropped.
9. **Judge** — Computes a canonical fingerprint per finding (LLM and tool findings alike), deduplicates across models, recalibrates severity/confidence (promote on cross-family UPHELD, drop only on REFUTED, suppress known false positives from learnings), merges in the Tier A/B static-analysis findings, and emits a per-finding ledger.
10. **Report** — Outputs a severity-first curated list (Critical / Important / Suggestions) with confidence badges (`[verified]` > `[cross-reviewed]` > `[1 reviewer · unverified]` > `[unverified]` > `[tool-only:<rule>]`), dissenting opinions where genuinely unresolved, and the lens map.
11. **Capture Gate** (Step 7, gated on `settings.learn`) — Record-only: after the report, walks the surviving findings with the author (tackle / skip / skip-all), distills a *skip with a generalizable reason* into a Suppression (keyed by the judge's canonical fingerprint) or a Convention, and — human-confirmed only — appends it to `.review-council/learnings.md` via `scripts/rc-learn.sh`. This is the write side of the learnings loop; what it writes here, step 2 (Recall learnings) reads on the next run.

## Static Analysis (Step 2.5)

A deterministic layer that gives the council grounded evidence, not a second vote — never a reviewer itself (no lens, doesn't count toward `min_reviewers`, never refuted in the refutation pass):

- **Tier A — verified / high-precision** (`gitleaks`, `trufflehog`, `osv-scanner`): secrets and known-CVE hits go straight into the report, pre-verified, badge `[verified]`, exempt from the suggestion cap, never downgraded by the judge (severity is **inherited**, not judge-assigned). `gitleaks` is precision-by-rule (regex/entropy), not live-verified like `trufflehog` — see `rules/static-analysis.md`.
- **Tier B — SAST / lint** (`semgrep`, `ruff`, `shellcheck`, `actionlint`, `hadolint`): folded into Round 1's shared context as "PRE-EXISTING STATIC-ANALYSIS SIGNALS — corroborate or dismiss." A reviewer match on the same (judge-computed) fingerprint promotes the finding to `[verified]`; a tool-only hit stays a capped `suggestion` badged `[tool-only:<rule>]`.

Configured via `static_analysis.*` in `.review-council/config.yml` (`enabled`, `tools`, `timeout_seconds`, `semgrep_config` — see `rules/config.md`). `/review-council:setup` prints tool availability and install commands but never installs one itself (print-only, unlike the `yq` flow). **Caveat:** `trufflehog`'s verified mode makes live outbound network calls to confirm a found credential is real — it's default-on; drop it from `static_analysis.tools` (or `RC_STATIC_TOOLS`) to opt out. If a tool listed in `static_analysis.tools` isn't installed, Step 2.5 doesn't skip it silently — it tells the user and asks whether to install-and-rerun, **run it via its official Docker image for this run** (no local install; the four core scanners `gitleaks`/`trufflehog`/`semgrep`/`osv-scanner` only, opt-in per-run via `RC_STATIC_DOCKER_TOOLS`, native-install-always-wins, config-invariant when unset), or proceed without it.

## Reviewers

| Reviewer | Transport | Detection |
|----------|-----------|-----------|
| Claude | Native subagent | Always available |
| Security | Native subagent (dedicated) | Always available — runs regardless of which external providers are present |
| Codex | CLI (`codex exec`) / MCP fallback | `which codex` or MCP tool |
| Google (Antigravity / Gemini) | CLI — `agy` preferred, `gemini` fallback | `which agy` or `which gemini` |
| Perplexity | Sonar API (`curl`) | `PERPLEXITY_API_KEY` env var |

Minimum 2 reviewers needed for council mode (`settings.min_reviewers`, default 2). Claude and the dedicated Security reviewer are both native and always run, but they are the **same model family (Claude)** — council mode and the refutation pass need at least one reviewer from a **different family** (Codex, Google, or Perplexity) to cross-verify against. With only Claude-family reviewers available, the run proceeds in single-reviewer mode. Antigravity and Gemini share one Google slot (`agy` preferred, `gemini` fallback) — they count as one reviewer, not two.

Round 1 is **lens-differentiated**: the dedicated Security reviewer always carries the Security lens; every repo-capable frontier reviewer (Claude, Codex, Google) carries Correctness & concurrency as its core plus one diff-aware specialist overlay (Cross-file/API-contract, Performance & reliability, Design & maintainability, Data-integrity & migration, Config/workflow, or UI-state & accessibility); tool-less Perplexity always carries Dependency/CVE/best-practices. Lens = emphasis, not blinders — every reviewer still flags any critical issue it notices outside its lens. The roster, lens bindings, and run settings are configurable per-repo via `.review-council/config.yml` / `config.local.yml` — see `rules/config.md`.

## Architecture

```
/review-council:run [target]
      |
      v
  Step 0: Detect providers + read config (roster, lenses, settings)
      |
      v
  Step 0.5: Recall learnings (.review-council/learnings.md)
      |
      v
  Step 1-2: Detect target + gather baseline context
      |
      v
  Step 2.5: Static scan (Phase 2, gated on static_analysis.enabled)
      Tier A (verified secrets/CVEs) ----> straight to Judge, pre-[verified]
      Tier B (SAST/lint signals) --------> folded into shared context
      |
      v
  Orchestrator (main Claude thread)
      |
      +---> Step 3: Round 1 (parallel, lens-differentiated) --------+
      |     - Claude (subagent)        [Correctness + overlay]      |
      |     - Security (subagent)      [Security — always on]      |
      |     - Codex (CLI/MCP)          [Correctness + overlay]      |
      |     - Google (agy→gemini)      [Correctness + overlay]      |
      |     - Perplexity (API)         [Dependency/CVE]             |
      |<--------------------------------------------------------------+
      |
      v
  Step 3.5: Well-formed check & recover (structural validation)
      |
      v
  Step 4: Refutation pass (cross-family, budget-bounded)
      UPHELD / REFUTED / INCONCLUSIVE per finding
      |
      v
  Step 5: Judge (fingerprint, dedup, recalibrate, merge Tier A/B, suppress, ledger)
      |
      v
  Step 6: Severity-first report
      badges [verified] > [cross-reviewed] > [1 reviewer · unverified] > [unverified] > [tool-only:<rule>]; dissent; lens map
      |
      v
  Step 7: Capture Gate (record-only, gated on settings.learn)
      Human-confirmed: tackle/skip/skip-all -> distill generalizable skips into
      Suppression (by fingerprint) or Convention -> rc-learn.sh writes learnings.md
      |
      v (feeds Step 0.5 recall on the next run)
```

## File Structure

```
review-council/
  .claude-plugin/     Plugin metadata (plugin.json is the single source of truth for version)
  skills/             Slash commands (run, setup, uninstall)
  agents/             Subagent definitions (Claude reviewer persona, dedicated Security reviewer)
  rules/              Orchestration logic, delegation format, provider registry, config schema (rules/config.md), static-analysis tool registry (rules/static-analysis.md)
  scripts/            Config reader (rc-config.sh), static-analysis runner (rc-static-scan.sh), learnings writer (rc-learn.sh), shared timeout lib (rc-lib-timeout.sh), Codex + Google provider-dispatch state machine (rc-invoke-provider.sh)
  tests/              bats unit tests for the scripts, plus Tier-2 artifact-shape fixtures (local/on-demand, never CI)
```

## Versioning

Bump the `version` field in `.claude-plugin/plugin.json` whenever you ship a bug fix or new feature (semver: patch for fixes, minor for features, major for breaking changes). `marketplace.json` inherits the `version` from `plugin.json` via strict-mode merge — do not duplicate the version there. Pair the bump with a `chore: bump version to X.Y.Z` commit after the change.

## Short Description & Docs

The plugin's one-line **short description** has a single source of truth: the `description` field in `.claude-plugin/plugin.json`. It is stamped into `README.md`, this file, `.claude-plugin/marketplace.json`, and `skills/run/SKILL.md`'s frontmatter by **`scripts/sync-metadata.sh`**. **When you change the description, edit only `plugin.json` and run `scripts/sync-metadata.sh`** to propagate it everywhere — CI's `tests/unit/sync-metadata.bats` (which runs `sync-metadata.sh --check`) fails if any copy drifts.

More broadly, **when you change review-council's functionality or pipeline, review the user-facing docs** (`README.md`, this file, `skills/setup/SKILL.md`) for accuracy — and if the pitch changed, update `plugin.json`'s `description` and re-run the sync. At the close of a major phase, do a thorough user-facing-doc pass and fold the fixes into that phase's last PR.
