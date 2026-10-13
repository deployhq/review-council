# Custom Reviewer Slots — Spec

**Goal:** Let a user add any model (Kimi, DeepSeek, Qwen, a local Ollama, a corporate gateway) as a **repo-capable** reviewer in the council — configured declaratively, with no plugin PR per model. **The first concrete harness is Alibaba OpenCodeReview (`ocr`)** — an opt-in, finder-only Round-1 seat (§12).

**Status:** Phase 1 (`ocr`) **being implemented in PR 1** (branch `feat/custom-seats-ocr`), decided by the user after spikes #1–#2 on deployhq/review-council#21. Delivery is a **two-PR stack** — see [Delivery phases](#delivery-phases). This document is deliberately a *spec*, not an implementation plan — see [Why there's no task breakdown](#why-theres-no-task-breakdown).

**Architecture in one line:** Review Council owns no agent loop and shouldn't start now — a custom slot **borrows** an existing agentic CLI as a runtime (`ocr` in Phase 1, `codex` in Phase 2) and points it at an arbitrary model via a configured provider. The harness supplies the tool loop and the read-only boundary; we supply the identity, the pinned rules, and the mapping into the council's finding format.

> **Revision history.**
> - **Draft 1** → reviewed by Review Council. 2 critical + 9 important. §5 and §6 were written in response.
> - **Draft 2** → reviewed again. **2 more criticals, both inside §5/§6** — the very sections draft 1's review had produced. Both had the same shape: they correctly identified the reader as the place to *compute* a value, then assumed computing it was *enforcing* it.
> - **Draft 3** → fixed both, and reversed one headline claim: custom slots are **finder-only** (§7).
> - **Draft 4** (this one, unreviewed) → makes **`ocr` v1.12.13 the Phase-1 harness** (new §12): opt-in, finder-only, Round 1, model-configurable, never Tier B. Family now comes from a **fixed prefix map with `unknown` = non-distinct** (§5), replacing draft 3's "else itself" and its three rejection rules. `api_key_env` is admitted with the host kept a council literal (§6). `harness` is now required. Phases renumbered: `codex` → 2, `opencode` → 3, trust layer → 4, N slots → 5. §6's Sink 1 is marked **shipped** (v0.9.3).
> - **Draft 5** (2026-10-13, this one) → adds §13, a tested comparison of `codex`, `opencode` and Claude Code as harnesses (local Ollama), and folds in the user's decisions for PR 1 and the draft-4 review's findings:
>   - **`role: signal | reviewer`** (default `signal`) replaces the fixed "never counts" rule as the one council-behaviour knob (§7); **no severity cap** on a seat's findings (§12.5).
>   - **`harness_options`**, split by trust: typed options (`effort`, `concurrency`, `max_tokens_budget`, `timeout_minutes`) from any layer; free-form `flags`/`env` from trusted layers only; isolation-critical flags and env names reserved from every layer (§4).
>   - **A user config layer** — `~/.review-council/config.yml`, trusted, read only for `reviewers.custom` — and the **tracked-`config.local.yml` fix**: a `config.local.yml` git tracks is untrusted, for `pr_comments.bot_token_env` too (§6). `api_key_env` is now **trusted-only**; draft 4's "`bot_token_env` precedent" was false and is removed.
>   - **A confirm gate** (`confirm.<n>` lines; one question at Step 0) for a risky choice that only committed config makes — in PR 1, a committed-only seat that egresses to OpenRouter (§6).
>   - **No `ocr` version pin**, and **no post-run rule-hash or tool tripwire**: the `ocr_version` is printed in the coverage line, the pre-flight `ocr rules check` stays, and the write canary moves to per-release testing (§9, §12.2).
>   - **Out-of-band routing**: the dispatch script writes a `.meta` file the orchestrator routes on, never model text; **background dispatch** (it can outlive the 600 s Bash ceiling); an **env allowlist** (`env -i`) for the run; **ref resolution** to local SHAs, never branch names; the deadline **clamped to 180 min** with `timeout_minutes`; and the **solo-Claude gate rewrite** — native findings skip refutation, a distinct seat's findings still go to a fresh Claude verifier (§7, §12).
>   - Delivery collapses to **two PRs** (PR 1: foundation, trust, `ocr`, one seat; PR 2: the other harnesses and N seats).
> - Both reviews ran with **only one non-Claude family** (`agy` quota exhausted), so each round's criticals rest on a single cross-family verification. The second review found that the first review's own fix was still wrong — which is the strongest available argument for re-reviewing this with a full roster before implementing.

---

## 1. Problem

The reviewer roster is a closed enum of four: `claude`, `codex`, `google`, `perplexity`. Adding a fifth model requires a plugin PR touching four files. Users want to bring their own model — Kimi today, something else next quarter — without waiting on us.

The blocker was never transport. It was that a reviewer must be **repo-capable** to be useful: a model that can't explore the code can only comment on what we paste into its prompt (the Perplexity shape). A repo-capable custom slot contributes findings of genuinely comparable quality to Claude/Codex/Google.

## 2. The core insight: three layers, previously conflated

Every existing slot fuses three distinct concerns, and got away with it because each harness only ever ran one model family:

| layer | question | today's examples |
|---|---|---|
| **harness** | what runs the agent loop, reads files, enforces the sandbox? | `codex`, `agy`, `gemini`, Claude Code's `Agent`; custom: `ocr` (P1), `codex` (P2) |
| **provider** | which API serves the model? | OpenAI, Google, Perplexity Sonar; custom: OpenRouter, Ollama |
| **model** | **who is actually reviewing?** → **family** | `gpt-*`, `gemini-*`; custom: `qwen/*`, `moonshotai/kimi-*` |

`codex` the binary only ran OpenAI models; `agy` only ran Gemini. Harness = provider = family, so one name covered all three.

**That is no longer true.** `codex` accepts an arbitrary OpenAI-compatible provider and an arbitrary model slug; `ocr` takes `--provider` and `--model` per run. The layers have come apart, so a custom slot must name all three **explicitly** — in config *and* at the transport boundary. Every place this design has gone wrong across two reviews was a place where two things got quietly merged: two layers, or **computing a value with enforcing it**.

**Why identity must be the model, not the harness:** `codex`-, `opencode`- and `ocr`-running-Kimi are *the same model*. Two slots would cast two votes for one model and let it corroborate itself — the exact convergence skew `rules/providers.md` forbids for `agy`/`gemini`. **A slot is a model identity; the harness is transport.**

## 3. What we verified empirically

This section is the audit trail, and the most durable thing in this document. Phases 1 and 2 rest on executed evidence, not documentation.

**Verified working — the `codex` harness (Phase 2; ran it, twice):**

```bash
codex exec \
  -c "model_providers.openrouter={ name='OpenRouter', base_url='https://openrouter.ai/api/v1', \
      wire_api='responses', env_key='OPENROUTER_API_KEY' }" \
  -c model_provider="openrouter" \
  --model "moonshotai/kimi-k2.7-code" \
  --sandbox read-only --skip-git-repo-check "<prompt>" </dev/null
```

- **Tool calling works.** Kimi drove Codex's loop and ran real shell commands in the repo, then answered with facts it could not have guessed.
- **`--sandbox read-only` is accepted** through the custom provider, and is kernel-enforced (seatbelt/landlock) — **we write no sandbox code**. **Caveat (draft-2 review):** we verified the flag is *accepted and the run works*; we did **not** verify a write is *denied*. See §9 and Phase 2's canary requirement — the phase's whole safety rationale is "kernel sandbox," so this is the one assumption that must be asserted, not assumed.
- **No OpenAI account is required.** With `CODEX_HOME` pointed at an empty temp dir (no `auth.json`, no `codex login`), the run succeeded and created no auth file. **Codex is a pure agent runtime here** — the dependency is `npm i -g @openai/codex`, no subscription, no OpenAI spend.
- **Cost**: `moonshotai/kimi-k2.7-code` is $0.72/M in, $3.49/M out — a full task ran ~56k tokens ≈ **$0.04**.
- **Model list** (`/api/v1/models`, public): 342 models; all Kimi variants report `tools=true`.

**Verified constraints — docs alone would have misled us:**

- **`wire_api = "chat"` was REMOVED from Codex** (its source carries `CHAT_WIRE_API_REMOVED_ERROR`). Only `responses` works. OpenRouter happens to expose `/api/v1/responses`, which is the **only** reason this design is possible at all.
- **A benign warning always fires**: `warning: Model metadata for <slug> not found…`. It appears against *real* OpenRouter. The run works. It must never be classified as a failure.
- **Codex drains stdin** — the shared timeout wrapper's `</dev/null` is mandatory, not defensive.
- **mikefarah yq resolves hyphenated map keys** — `-` is not lexed as subtraction. See §11.

**Verified — the `ocr` harness (Phase 1).** Sources: spikes #1–#2 on deployhq/review-council#21 (five runs, one diff, 43 changed files); `ocr review --help` on the installed v1.12.13; the run-5 JSON (§12.7); and a read of the ocr source at commit `fabbdb2` — cited below as *verified against ocr v1.12.13 source*.

- **It is a harness, not a model.** One configured model runs every stage (file grouping, one sub-agent per group, 1–3 review rounds, line re-anchoring, an LLM fact-check). Pointed at Claude or GPT it adds no family.
- **Per-run provider and model:** `--provider <configured-name>` and `--model <slug>` override the config for one run (`--help`). But there is **no `--config` flag and no `OCR_CONFIG`/`OCR_HOME`** — every config path derives from `$HOME` (source). So per-run config means a **temp `HOME`** holding a council-written `.opencodereview/config.json`, with **no `api_key` in it**: the key is read from the provider's env fallback, e.g. `OPENROUTER_API_KEY` (`resolver.go:443-453`).
- **Host-agent env leaks in.** With no complete config, ocr silently picks up `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_MODEL` — which a Claude Code session sets. They must be unset for the run (source).
- **OpenRouter data policy is enforceable through ocr.** Spike #1 sent `provider: {data_collection: "deny"}` via `providers.openrouter.extra_body`, and proved it is applied: a control with an impossible `only` filter returned 404.
- **Rules are layered, not replaced.** `--rule <file>` is a layer **on top of** the reviewed repo's `.opencodereview/rule.json`. Rule text is first-match (`--rule` → repo → global → built-in), and the first layer with any `include`/`exclude` is used whole. A council file with a dummy exclude therefore displaces the repo file entirely; `ocr rules check` then reports `Source: Custom (--rule)` (source, and tested). Test files are excluded by default and come back only via an `include` in the rule file.
- **Budgets:** `--timeout` is in **minutes** (default 15) and is multiplied by the number of rounds (`--effort` low 1, medium 2, high 3). On the deadline it publishes partial results and marks the rest `failed(timeout)`; `--max-tokens-budget` does the same with `failed(budget)`. The per-request limit is separate: `OCR_LLM_TIMEOUT`, in **seconds** (default 300) — 6 of 23 files hit it in spike #1.
- **Exit codes are not a success signal.** 0 for complete, partial *or skipped*; 1 on error or when nothing was covered (source). Gate on the parsed JSON.
- **JSON shape** (`--format json`): top level `status`, `summary` (incl. `budget_exceeded`), `comments[]`, `warnings[]` (`type`, `file`, `message`), `session_id`, `manifest`, `retry_report`; run 5 also carried `llm`, `groups`, `tool_calls`. A comment has `path`, `start_line`, `end_line`, `severity`, `category`, `content`, `existing_code`, `suggestion_code`. The manifest is `ocr.run-manifest/v1`; its `coverage` holds `selected`, `completed`, `reused`, `failed` and `waived` lists of `{item_id, path, classification, reason}`, with `classification` ∈ `provider | timeout | cancelled | configuration | input | budget | panic | unknown`; `execution` records the `provider`, `model`, `ocr_version` and `rule_config_sha256` that actually ran.
- **Files excluded before review are not in the review JSON.** Their reasons appear only in `--preview --format json`, which makes no LLM call (source).
- **Run 5 forces three mapper cases** (§12.5): `severity` is **absent** — not `null` — on 8 of 9 comments; `start_line` is `0` (file-level) on 5 of 9; and one comment's `path` is `dockerignore` while the manifest lists `.dockerignore`. No `suggestion_code` and no failed items were observed.
- **Tools observed:** `file_read`, `code_search`, `file_read_diff`, `code_comment` — no write or shell tool. Observed across runs, **not proven exhaustive**; `--tools <json>` can replace the embedded set.
- **State and network:** sessions are persisted under `$HOME` (`session_id` is a counter; `ocr session` lists them). Every run does an npm update check unless `OCR_NO_UPDATE=1`. Telemetry is off by default (source).
- **Precision and speed** (spike #1 step 2, spike #2): of `ocr`'s 6 distinct concerns on Qwen3.8-Max, 2 were false positives — including its only security claim — and 1 was a real, new bug (4 of 8 comments false). Recall was poor: run 1 matched one council Important and missed another in a file it did review. Full coverage of 23 files took 51 min on a local MoE; OpenRouter Qwen reached 5/23 in 16–26 min.
- **Release cadence:** a release every 1–3 days. *(Draft 5: **no version pin** — a pin would be stale within a week. The manifest `schema_version` is checked on every run, the `ocr_version` that ran is printed in the coverage line, and the write canary is re-run per release.)*

**Verified about the CURRENT codebase (draft-2 review; these reshaped §5–§7):**

- **`reviewer.google.model` reached an unquoted shell assignment until v0.9.3.** `printf 'reviewers:\n  google:\n    model: "gemini-3 ; id"\n'` → the reader emitted `reviewer.google.model=gemini-3 ; id` verbatim, exit 0, no note. **Fixed by `bc763af` (v0.9.3, PR #15)**: the `modelslug` kind §6 specified now guards every `reviewers.*.model`. Re-verified 2026-10-12: the reader prints `invalid value 'gemini-3 ; id'; using default` and emits `reviewer.google.model=`.
- **No code compares reviewer families.** `grep -rn family scripts/*.sh` returns two hits, both inside comments. Every family decision in the pipeline is **an LLM reading prose**. This is why reader-side derivation is necessary but *not sufficient* — see §5.
- **`perplexity/*` and `openrouter/*` slugs exist on OpenRouter today.** Verified against the live model list: 5 `perplexity/*` (e.g. `sonar-pro`, `sonar-reasoning-pro`, `sonar-deep-research`) and several `openrouter/*` meta-namespace slugs (`openrouter/fusion`, `openrouter/pareto-code`, `openrouter/free`). `:free` variants exist too (e.g. `tencent/hy3:free`); `:online` was **not** observed in that sample. See §5 and §6.

**NOT verified — documentation only.** This is why opencode is gated behind a spike:

- `opencode run` non-interactive; `--model provider/model`; `OPENCODE_CONFIG` pointing at an out-of-project config; `{"permission": {"edit": "deny", "bash": "deny"}}` leaving read/grep/glob usable. **opencode is not installed here — none of it has been executed.**
- **OpenRouter `:variant` semantics** (`:free` retention terms, `:online` search hop). Asserted in §6 from documentation; the refutation pass could not confirm them from the repo. Treat as unverified.

**NOT verified — `ocr`, still open after the source read:**

- **The full `severity` vocabulary.** Only `high` and absent were observed in JSON; spike prose also used *medium* and *low*. Pin it from source before writing the mapper.
- **How `rule_config_sha256` is computed** (raw `--rule` bytes or the resolved rule set). *Moot since draft 5 — there is no post-run hash check; the pre-flight `ocr rules check` is the rule guard.*
- **The `terminal_state` / `status` values** beyond `complete` and the shape of a real `failed[]` item: run 5 had none, so the bats fixture's failed entry is synthetic (§12.7).
- **That the tool set is read-only.** Four tools observed, none of them writes; whether the embedded set has any other tool, and whether a pinned `--tools` file is honoured, are both unverified (§12.2). `--tools` is a reserved flag no config can set; the write canary is re-run per release (§9).
- **What a temp `HOME` breaks.** It also hides `~/.gitconfig` (`safe.directory`, `includeIf`, credential helpers); a local diff should not need any of them — confirm on a real run.
- **What an HTTP 402 looks like** — most likely `failed[]` items with `classification: provider`; confirm with a zero-credit key.

## 4. Config schema

```yaml
reviewers:
  custom:
    qwen:                                    # slot name — user-chosen
      enabled:  true                         # default true
      harness:  ocr                          # REQUIRED. P1: ocr | P2+: + codex | P3+: + opencode
      provider: openrouter                   # ocr: openrouter | ollama · codex (P2): openrouter
      model:    qwen/qwen3.8-max-0902        # default EMPTY → slot OFF. No default model, ever. Determines family.
      role:     signal                       # signal (default) | reviewer — the one council-behaviour knob (§7)
      api_key_env: OPENROUTER_API_KEY        # TRUSTED LAYERS ONLY: the NAME of the key's env var, never the key
      harness_options:                       # per-harness options, merged over council defaults
        effort: low                          #   typed — any layer
        concurrency: 4                       #   typed — any layer
        max_tokens_budget: 2000000           #   typed — any layer
        timeout_minutes: 30                  #   typed — any layer
        flags: ["--max-tools", "80"]         #   free-form — TRUSTED LAYERS ONLY
        env: { OCR_LLM_TIMEOUT: "600" }      #   free-form — TRUSTED LAYERS ONLY
```

Three layer keys, nothing implied; `api_key_env` is plumbing, not a layer, and `role` and `harness_options` are council and harness knobs, not layers. Each axis extends independently: a new harness is one enum value, a new provider is one enum value, a new model is just a string.

**Opt-in, off by default — structurally.** No slot exists until a user names a `harness` *and* a `model`; nothing is shipped pre-configured, and no default model is baked in (§12.8 records the spike evidence, non-normatively). `harness` has no default because draft 3's default (`codex`) is no longer Phase 1, and a default that changed between phases would migrate configs.

**The schema is final from Phase 1** — later phases only widen the enums and lift the slot cap. No config ever migrates.

| key | default | validation |
|---|---|---|
| `enabled` | `true` | bool |
| `harness` | *(none — required)* | enum; empty or invalid → note + slot skipped |
| `provider` | `openrouter` | enum, **per harness** (`ocr`: `openrouter`, `ollama`); invalid → note + slot skipped |
| `model` | *(empty)* | **`modelslug` kind** (§6); non-empty → slot on; family from §5's map |
| `role` | `signal` | enum `signal` \| `reviewer` (§7) |
| `api_key_env` | per provider: `OPENROUTER_API_KEY`; none for `ollama` | **`envname` kind** (§6); ignored for `ollama`; **trusted layers only** — from committed config it is ignored with a note |
| `harness_options.effort` | `low` | enum `low` \| `medium` \| `high` (ocr's rounds 1/2/3) |
| `harness_options.concurrency` | *(ocr's own)* | integer 1–32 |
| `harness_options.max_tokens_budget` | `0` (= ocr's default) | positive integer |
| `harness_options.timeout_minutes` | *(derived from the run budget, §12.3)* | integer 1–180 |
| `harness_options.flags` | *(none)* | **trusted layers only**; a YAML list of argv tokens, each charset-checked (letters, digits, `._:/@=,+%-`, and `*`/`?` for globs; ≤ 256 chars), each one quoted argv element; reserved flags dropped |
| `harness_options.env` | *(none)* | **trusted layers only**; `NAME: value`, `NAME` an `envname`, value free of control characters; reserved names dropped |
| `family` | *(computed)* | the slot's family from §5's map, **already canonical**, `unknown` included — the only family value emitted |
| `distinct` | *(computed)* | `true` iff `family` is in §5's distinct set |
| `source` | *(computed)* | `local` \| `user` \| `committed` — `committed` iff **no** trusted layer names the slot (§6) |

**Typed vs free-form `harness_options`.** The typed options are validated and accepted from any layer, committed config included. `flags` and `env` can shape the harness's argv and environment freely, so they come from trusted layers only. **Reserved, from every layer:** the isolation-critical flags `--rule --repo --from --to --commit -c --tools --provider --model -o --output --format -f --audience --resume --preview -p` (and their `--x=…` forms), and the env names `HOME PATH TMPDIR OCR_NO_UPDATE` plus the provider key var.

**Layers (draft 5).** Per key, lowest → highest: committed `config.yml` (and a git-tracked `config.local.yml`) → the user layer `~/.review-council/config.yml` (`RC_USER_CONFIG` overrides the path) → an untracked `config.local.yml`. The user layer is read **only** for `reviewers.custom` in PR 1. Trusted vs untrusted is §6.

**There is exactly one family key, and it is already canonical.** Draft 2 emitted both a raw `family` and a `family_canonical`, which inverted the safe default: the attractive name was the one that must never be used for routing, while every consumer sentence in `skills/run/SKILL.md` says *"family"*. An LLM consumer had only prose stopping it from grabbing the wrong key — for a guard whose failure silently deletes findings (§5). Emitting one already-canonical `family` makes the footgun structurally unreachable and leaves every existing consumer sentence correct unmodified. **No raw vendor prefix is emitted**: reports attribute a slot by its model slug (`kimi (moonshotai/kimi-k2.7-code)`), which is strictly more informative to a human than a bare vendor.

**Three charset guards, three different sinks** — see §6 for why each exists and when it must run:

| value | rule | why |
|---|---|---|
| slot **name** | `^[A-Za-z0-9_-]{1,32}$` | reaches a **yq expression** and the emitted key namespace |
| model **slug** | `^[A-Za-z0-9~@][A-Za-z0-9._:~@/-]{0,127}$` | reaches a **shell command position** — the existing `valid_modelslug` |
| key env **name** | `^[A-Za-z_][A-Za-z0-9_]{0,127}$` | reaches an **indirect expansion** and an **env assignment** — the existing `valid_envname` |

The slug rule is anchored (no leading `-`) and bounded, and already admits bare Ollama tags such as `qwen3.6:35b-a3b-coding-nvfp4`. Excluding `.` from slot names is intentional: it keeps `reviewer.custom.<name>.<key>` at a fixed four dot-segments. Excluding `,` from all three is what makes the comma-joined list unambiguous. **There is no URL key** — endpoints are council literals (§6).

**Emission shape.** Emitted **only when at least one valid slot survives** — with no config, not one byte of this appears:

```
# custom reviewers
reviewer.custom_slots=qwen,kimi-local
reviewer.custom.qwen.enabled=true
reviewer.custom.qwen.source=committed
reviewer.custom.qwen.harness=ocr
reviewer.custom.qwen.provider=openrouter
reviewer.custom.qwen.model=qwen/qwen3.8-max-0902
reviewer.custom.qwen.role=signal
reviewer.custom.qwen.api_key_env=OPENROUTER_API_KEY
reviewer.custom.qwen.family=Qwen
reviewer.custom.qwen.distinct=true
reviewer.custom.qwen.opt.effort=low
reviewer.custom.qwen.opt.concurrency=
reviewer.custom.qwen.opt.max_tokens_budget=0
reviewer.custom.qwen.opt.timeout_minutes=
…                                            (kimi-local's lines; trusted-only flag.<n> / env.<NAME> lines)
confirm.1=Seat 'qwen' is enabled only by the repo's committed config.yml and sends code to OpenRouter (model qwen/qwen3.8-max-0902), billed to your OPENROUTER_API_KEY.
```

The list sentinel is `reviewer.custom_slots`, **outside** the per-slot namespace. Draft 2 used `reviewer.custom.names`, which a slot legitimately named `names` would shadow (`reviewer.custom.names=names` beside `reviewer.custom.names.model=…`) — and config-invariance rests on that one key's absence. Consumers treat an **absent** `reviewer.custom_slots` as "no custom slots."

## 5. Identity & family derivation

Family is **computed, never trusted** — pure string manipulation, so it belongs in the deterministic, testable config reader.

**But computing is not enforcing, and this is the thing draft 2 got wrong.** There is **no string-equality comparison of families anywhere in the code** — `grep -rn family scripts/*.sh` finds only comments. Every family decision is **an LLM reading prose** in `skills/run/SKILL.md`. So reader-side derivation is **necessary but not sufficient**: it computes a correct value that nothing *obliges* the consumer to use. Phase 1 must therefore ship **derivation *plus* an explicit prose obligation at every comparison site**, or the derivation is decoration.

**The canonical namespace is a pinned literal set** — the map's whole output set, nothing else:

- **native** — `Claude`, `OpenAI`, `Google`. **`OpenAI` is the native Codex seat's family**: the pipeline's verifier list (`skills/run/SKILL.md` → 4.2) calls it `Codex`, and Phase 1's touch list makes `Codex = OpenAI` explicit there, or an LLM consumer is left to guess.
- **distinct** — `Qwen`, `Moonshot`, `Zhipu`, `DeepSeek`.
- **`unknown`** — everything else.

Note `Claude-fresh`, which appears in the verifier-routing rule, is a **verifier-spawn label, not a family**; reconciling that wording is part of Phase 1's touch list, because an implementer currently cannot tell whether the target set is `{Claude, …}` or `{Claude-fresh, …}`.

**Derivation — a fixed prefix map, first match wins:**

```
strip ALL leading "~"                       ~~moonshotai/kimi-latest → moonshotai/kimi-latest
lowercase the whole slug
match a prefix, at a boundary               the prefix must be followed by end-of-string,
                                            "/", "-", ".", ":" or a digit
  qwen             → Qwen                   (covers OpenRouter qwen/* and bare Ollama qwen3.6:…)
  moonshotai/kimi  → Moonshot
  z-ai/glm         → Zhipu
  deepseek         → DeepSeek
  anthropic/claude → Claude
  openai/gpt       → OpenAI
  google/gemini    → Google
no match                                    → unknown
```

A slot is **distinct** iff its family is in the distinct set. `Claude`, `OpenAI`, `Google` and `unknown` are all **non-distinct**: `unknown` is treated as the same family as *every* native seat, which is the conservative reading. What each outcome means in the council is §7's [Distinct vs non-distinct](#distinct-vs-non-distinct).

| model | `family` | distinct? | note |
|---|---|---|---|
| `qwen/qwen3.8-max-0902` | `Qwen` | yes | spike #1–#2 model (OpenRouter) |
| `qwen3.6:35b-a3b-coding-nvfp4` | `Qwen` | yes | bare Ollama tag (spike run 5) |
| `moonshotai/kimi-k2.7-code` | `Moonshot` | yes | the untested next candidate |
| `~moonshotai/kimi-latest` | `Moonshot` | yes | `~` = OpenRouter latest-alias |
| `z-ai/glm-5` | `Zhipu` | yes | |
| `deepseek/deepseek-v4`, `deepseek-r1:32b` | `DeepSeek` | yes | vendor-prefixed or bare |
| `anthropic/claude-opus-latest` | **`Claude`** | no | collides with native Claude |
| `openai/gpt-5.6` | **`OpenAI`** | no | collides with the Codex seat |
| `google/gemini-3` | **`Google`** | no | collides with the Google seat |
| `x-ai/grok-4`, `perplexity/sonar-reasoning` | `unknown` | no | not on the map — runs, earns no cross-family credit |
| `openrouter/fusion`, `@preset/my-thing` | `unknown` | no | meta-router / preset: family underivable |
| `qwenfake/x` | `unknown` | no | `qwen` not at a boundary |

**Runtime cross-check.** The reader derives the family from the *configured* slug; §12.5's mapper derives it again from `manifest.execution.model`, the model ocr reports it *actually* ran, and uses that. If the two disagree, the slot's family for the run is `unknown` and the report says so. This is the "enforce, don't just compute" check: a silently-wrong per-run config (§12.2) cannot launder one model's findings under another family's name.

**Why canonicalization is mandatory.** The pipeline's family decisions are prose comparisons against `Claude` / `Codex` / `Google`. A raw vendor slug means nothing there, so the outcome is **nondeterministic** — an LLM *might* resolve `anthropic` → Claude on its own, which is worse for testing than a reliable failure. Without a canonical value, a slot configured `anthropic/claude-opus-latest`:

1. **Can silently delete findings.** If the "a model does not verify its own finding" guard doesn't fire, Claude refutes its own finding and the judge drops on REFUTED — including findings from the dedicated Security reviewer. *(Phase 1 closes this a second way too — see §7's finder-only rule.)*
2. **Fabricates corroboration.** Native Claude + the `anthropic/*` slot present as two families, firing the `+1 tier` promotion on manufactured diversity. **This one is not closed by finder-only** — a slot can fabricate corroboration purely as a finding *origin* — so correct canonicalization is load-bearing regardless. Draft 4 closes it by rule rather than by label: a non-distinct slot's findings **never count toward corroboration** (§7), so a wrong label can at worst cost credit, never manufacture it.

**Underivable means `unknown`, not rejected.** Draft 3 rejected `@preset/*`, `openrouter/*` and bare names because **their family is underivable from the string** — a preset pins an arbitrary model server-side; a meta-router dispatches per request and frequently lands on Claude or GPT. Guessing a family for these is exactly the harm above. Draft 4 keeps the reason and changes the outcome: they map to `unknown`, which is **non-distinct**, so they can run as finders but can never be cleared as a distinct family. Same safety, and the user can still run any model.

**Bare Ollama tags are prefix-matched.** This resolves draft 3's Phase-3 open decision for vendorless slugs. An Ollama tag is a name on the user's own machine; a reviewed repo can name one in config but cannot create one, so a mislabelled tag (`ollama cp <claude-proxy> qwen-x`) is self-inflicted, not an attack.

**Caveat worth revisiting:** the map is a judgment call about vendor identity, not a derivable fact. It lives in **one function** (the reader and §12.5's mapper both call it), with a table-driven bats test, and is reviewed when providers change. **The map is the one plugin PR the goal still needs:** any model *runs* without an entry; only cross-family credit needs one. Add a test asserting the map's value set equals the canonical set above, so the known-vendor cases are checkable and only genuinely novel vendors need human review.

## 6. Security model

**The live sink draft 3 found is closed (v0.9.3). The `ocr` harness adds new config→command paths — model, provider, key-env name, harness options — and each goes through a reader guard before it can reach one; the ones that select a secret or shape argv freely come from trusted layers only.**

Draft 2 claimed Phase 1 introduced "exactly one new data path… and closes it at the reader." That was false in two directions, and the exhaustiveness claim was the dangerous part — an implementer trusting the audit would scope the guard to custom slots and ship a security section asserting a class was closed while an older, identical door stood open.

**Sink 1 — the model slug reaches a shell command position.** The reader's generic string validation rejects **only control characters**; spaces, `;`, `|`, backticks and `$(...)` all pass. The orchestrator then interpolates a model value **unquoted** into a Bash line it composes. This was live until v0.9.3 via `reviewer.google.model`:

```
$ printf 'reviewers:\n  google:\n    model: "gemini-3 ; id"\n' > .review-council/config.yml
$ ./scripts/rc-config.sh .review-council | grep google.model
reviewer.google.model=gemini-3 ; id          ← verbatim, exit 0, no note   (before bc763af)
reviewer.google.model=                       ← with a stderr note          (v0.9.3+, re-verified 2026-10-12)
```

Note this fires in the **orchestrator's own session, outside any sandbox** — not inside codex's seatbelt. And **double-quoting would not save it**: `$(...)` expands inside double quotes. Only the reader-side guard is a real defense, which makes the plugin's own maxim — *never rely on an LLM to quote correctly* — more right than draft 2 realised.

**Fix — shipped independently in v0.9.3 (`bc763af`, PR #15):** a **`modelslug` kind** in the reader's validator (`valid_modelslug`), applied to **every** `reviewers.*.model` through one tested guard. Phase 1 applies the same kind to custom slots. `^[A-Za-z0-9~@][A-Za-z0-9._:~@/-]{0,127}$` admits `gemini-3-pro`, `sonar`, `moonshotai/kimi-k2.7-code`, `~moonshotai/kimi-latest`, `openai/gpt-4o:free` and the Ollama tag `qwen3.6:35b-a3b-coding-nvfp4` alike, with no behavioural loss. It must run **before** family derivation. Single-quoting the orchestrator's template is defence-in-depth on top, not the guard. **`provider`** is an enum and reaches `ocr --provider` and the council-written config file only as one of its literal values.

**What actually stops argv injection** is worth stating precisely, because draft 2 credited the wrong mechanism: the charset **excludes `=`**, which blocks clap's attached short-flag form (`-cKEY=VALUE`) — and `-c` is codex's config-override flag, the only single token that could redefine `model_providers` and thus the endpoint. The anchor (no leading `-`) removes any dependence on clap's hyphen handling at all — and equally on `ocr`'s Go flag parser: whatever it would do with a value starting `-` (a would-be `--rule=…` that re-points the rule file), the anchor means it never sees one. *Draft 2 claimed `--model` "consumes its value positionally"; that description of clap is wrong and the refutation pass could not verify it from the repo. Do not restore it, and do not relax `=` out of the charset.*

**Sink 2 — the slot name reaches a yq expression.** The reader must build `.reviewers.custom.<name>.model` by interpolating an untrusted YAML map key. mikefarah yq is an **expression evaluator** with `load()` and `env()`, not an inert path lookup, so an unvalidated name is an expression-injection primitive. The reader already interpolates path fragments into yq expressions — safe today only because every such fragment is a hardcoded literal. **Slot names would be the first user-supplied value in that position.**

**Ordering is the whole guard here:** names are discovered *by* running `yq keys`, so validation must sit **between enumeration and any re-interpolation**. Enumerate → validate each name against `^[A-Za-z0-9_-]{1,32}$` → only then build a yq path or an emitted key. A name that fails is dropped with a note.

**Sink 3 — the key env-var name reaches an indirect expansion and an env assignment.** `api_key_env` names the variable that holds the key; the dispatch script reads it and passes its value to `ocr` under the name `ocr` reads (`OPENROUTER_API_KEY`, §12.2) — through a pipe, never argv. It is validated with the existing **`envname` kind** at the reader and **re-checked before use** in the dispatch script — the same defence in depth `rc-post.sh` applies to `pr_comments.bot_token_env` — and, since draft 5, it is read **from trusted layers only**. The value never appears in config, in argv, or in the council-written `config.json`.

**What holds structurally:**

- **The endpoint is a council literal, per provider.** OpenRouter → `https://openrouter.ai/api/v1`; Ollama → `http://127.0.0.1:11434/v1`. Config cannot choose the *host*, and **there is no URL key**. A future URL key must be charset-validated *and* get its own trust design (it is [not scheduled](#not-scheduled)): a URL and a key name from the same untrusted source make a complete exfiltration primitive.
- **The key env var *name* comes only from a trusted layer; the value never comes from config.** Draft 3 held that a config-named env var is a secret-exfiltration primitive; draft 4 admitted it from any config on the grounds that the host is a council literal, so a hostile `api_key_env: AWS_SECRET_ACCESS_KEY` could at worst send *another* secret to the configured provider. That is still disclosure to a third party, and draft 4's claim that `pr_comments.bot_token_env` "already accepts" the same exposure was **false** — that key has always been trusted-layer only. **Draft 5:** `api_key_env` is honoured only from `~/.review-council/config.yml`, an untracked `config.local.yml`, or env; from committed config it is ignored with a note, and the provider's default name applies.
- **The confirm gate closes repo-controlled egress.** A seat that **only** the committed config defines, and that sends code off the machine (`provider: openrouter`), makes the reader emit a `confirm.<n>=<plain-language reason>` line; the orchestrator asks the user once at Step 0 and skips the seat on "no" or no answer. So a reviewed repo can *propose* sending its code to OpenRouter on the user's key, never do it silently. Values that are never legitimate from committed config (`api_key_env`, `harness_options.flags`/`env`) are ignored with a note, not asked about.
- **The free-form harness options come only from trusted layers**, and the isolation-critical flags and env names (§4) are reserved from every layer — the reviewed repo can tune a typed knob, never re-point the rule file, the provider, the output or the environment.
- **The argv is built without `eval`.**
- **The OpenRouter data policy is council code.** `provider: {data_collection: "deny"}` is **hard-coded** and sent on every OpenRouter call (via `providers.openrouter.extra_body` in the council-written config, §12.2). It is never read from repo config or from the user's `~/.opencodereview/config.json`, which nobody reviews — the same precedent as deployhq's `Ai::Client`. It controls training, not where the code goes, and a provider's data record is largely self-declared.
- **The reviewed repo cannot steer `ocr`'s prompts.** Its `.opencodereview/rule.json` is displaced by a council-owned `--rule` file, checked by the pre-flight `ocr rules check` before the run (§12.2). Inputs that remain (source): the repo's root `.gitignore`, and any file the model opens with its tools — the same untrusted-content exposure every reviewer has. `.md`/`.txt` files referenced by the repo's rules are moot once its rules are displaced.
- **No dependency on, or mutation of, the user's `~/.opencodereview/`.** Each run gets a throwaway `HOME` (§12.2); its sessions die with it. `ocr` runs under `env -i` with an **env allowlist**, so a host's `ANTHROPIC_*` variables never reach it.
- **Read-only is enforced by the harness, at different layers.** `codex`: kernel sandbox — but see §9: Phase 2 must *assert* this, not assume it. `ocr`: **agent layer** — its tool set has no write or shell tool — observed, not proven; Phase 1 asserts it with a write canary, re-run per `ocr` release (§9). *(Draft 4's per-run tool tripwire is dropped in draft 5.)*

**What the fixed endpoint does NOT control — the `:variant` suffix.** The allowlist deliberately admits `:`, and an OpenRouter slug's variant is a **routing and data-policy directive**, not just identity. `:free` routes to free endpoints whose retention/training terms differ from paid ones; `:online` reportedly activates a web-search plugin, sending review-derived content to a **fourth party** absent from `CLAUDE.md`'s egress disclosure. So the precise claim is: *config cannot choose the host; it can still choose the variant, and the variant selects the serving endpoint and its terms.* **Decide the variant policy in Phase 1, while there are zero callers** — either reject `:` suffixes not on a known-benign allowlist, or reject `:online` specifically. **Scope it to `provider: openrouter`:** for Ollama, `:` is the tag separator (`qwen3.6:35b-a3b`), not a routing directive. *(Marked unverified: the refutation pass could not confirm variant semantics from the repo. Verify against OpenRouter's docs before acting.)*

**The threat model.** A repo-committed `config.yml` is **untrusted input** — the reader loads it from the *reviewed repo's* CWD. `config.local.yml` being gitignored is a **convention, not a boundary**: a repo can simply commit one — so since draft 5 a **git-tracked** `config.local.yml` is untrusted too (for `pr_comments.bot_token_env` as well). Draft 5 adds the first **out-of-repo config layer**, `~/.review-council/config.yml`, read only for `reviewers.custom` in PR 1. A reviewed repo can still propose an `ocr` seat — but an egressing one runs only after the user confirms it, only on a key the *user* exported, and it can only add `[unverified]`-or-refutable findings. Verifier authority stays off for every seat (§7).

**Egress** grows in scope: review context reaches the configured provider and the model's host. For `qwen/qwen3.8-max-0902` on OpenRouter that is **one host, Alibaba**; for Ollama it is **none** (localhost). `CLAUDE.md`'s disclosure must be extended to name custom slots and the `ocr` provider path — and the variant hop, if the variant policy admits one.

## 7. Council semantics

A custom slot is repo-capable, so its **findings** are of comparable quality to Claude/Codex/Google — not the tool-less Perplexity shape. **What else it does depends on the harness.**

**Draft 5: `role` decides the council behaviour** (default `signal`):

| | `role: signal` (default) | `role: reviewer` |
|---|---|---|
| seat-only findings land in | a separate **"Extra signals (<slot> via ocr)"** report section | the main severity lists |
| `min_reviewers` | **never counts** | counts **only** if the family is distinct **and** coverage ends complete; partial or SKIPPED → demoted to `signal` for that run, with a note |
| solo-Claude mode | never lifted for the native findings | never lifted for the native findings |
| lens | **none** (`ocr`) | **none** (`ocr`); a `codex` seat (PR 2) gets Correctness + one overlay |
| its findings | distinct family: refutable · non-distinct: `[unverified]` | same |
| severity | no cap (§12.5) | no cap |
| verifier | **never** (below) | **never** (below) |

A seat finding that dedups into a native finding is that native finding (the seat joins its origin-families); `role` only places **seat-only** findings.

**Why the `codex` slot gets a lens:** the lens-assignment rules enumerate the frontier reviewers as a **closed list**; that set must become data-driven or the slot is configured, dispatched, and silently never given a lens. Custom slots iterate **after** Claude, Codex, Google, keeping existing lens maps byte-identical when none is configured.

**Why the `ocr` seat gets no lens:** a lens needs the `## LENS` block, and ocr's only prompt channels are `--rule` and `--background` — the first is pinned neutral (§12.2), the second is not used. The lens map shows it as `<slot> (<model> via ocr) — no lens`. **Why counting is conditional:** a seat that may time out at minute 40 must not be what keeps a run above the threshold, so a `reviewer` seat counts **provisionally** at Step 0 and keeps the count only if it ends complete; a non-distinct seat cannot supply the cross-family check council mode exists for, so it never counts.

### Custom slots are FINDER-ONLY (verifier authority deferred)

**A custom slot is not eligible as a refutation verifier.** This reversed draft 2, and it was the most consequential change in draft 3.

The reasoning is forced by the spec's own threat model. Repo-committed config is untrusted; when this was written **all** config was repo-sourced (draft 5 adds a user layer, but a seat may still come from committed config); and the judge **drops a finding on REFUTED**. Granting verifier authority to a config-named model therefore hands an adversary both halves of the primitive: they choose the verifier's model *and* author the diff text it reads. A hostile repo could seat a weak or injectable model and steer it toward REFUTED verdicts against the dedicated Security reviewer's findings, which then vanish from the report. The mitigation draft 2 relied on — *"only positive counter-evidence drops a finding"* — is prose to an LLM, not a mechanism.

**Nothing config can do today has this power.** `settings.verify: false` explicitly *keeps* findings as `[unverified]`; disabling a reviewer only reduces coverage. Phase 1 would have been the first config key able to make a finding disappear.

**The asymmetry is the point:** a custom slot can **add** findings (low harm — the judge curates, the cap applies, other families can refute them) but cannot **delete** them (high harm — silent and irreversible).

**Honest cost.** This removes one of the feature's original selling points: a custom slot does **not** strengthen the refutation pass by adding a verifier family. Extensibility — any model, no plugin PR — survives intact, and repo-capability still makes its findings far better than a tool-less slot's. **Lifting this restriction requires the out-of-repo trust layer** (`~/.review-council/config.yml` or env-only): a slot enabled from a source the reviewed repo cannot write may safely verify. Draft 5 ships that layer for `reviewers.custom`, but **verifier authority stays deferred** — not in either PR of the stack — and is the natural companion to any future `base_url` work.

### Distinct vs non-distinct

Decided by the user for draft 4, and deterministic from §5's map:

- **Distinct family** (`Qwen`, `Moonshot`, `Zhipu`, `DeepSeek`) → the seat's findings enter Step 4 like any single-family finding and are refuted by a *different* repo-capable family — Claude (spawned fresh as `Claude-fresh`), OpenAI (`Codex`) or Google. **The solo-Claude gate is rewritten (draft 5):** it skips refutation for the **native** findings only, which stay `[1 reviewer · unverified]` as today; a distinct seat's findings are still routed to a fresh Claude verifier, which is cross-family for them.
- **Non-distinct** (`Claude`, `OpenAI`, `Google`, `unknown`) → **allowed** — the user explicitly wants to run, say, a Claude model through ocr — but the seat's findings skip Step 4 and stay `[unverified]`. They **never count as cross-family corroboration**: a fingerprint raised by native Claude and a `Claude`-family or `unknown` seat is a same-family pile-up and is not promoted. `unknown` gets this rule against **every** native family, because it might be any of them.

Either way a seat's finding is never *deleted* by being non-distinct: absence of refutation is `[unverified]`, never REFUTED.

### Availability

A custom slot is **available** iff **all** of:

```
enabled = true
  ∧ harness is set and valid for this phase
  ∧ model is non-empty and passes the modelslug guard   (family may be unknown)
  ∧ the harness binary resolves          (same contract Codex/Google use)
  ∧ the provider's key env var is set and non-empty   (OpenRouter: the var api_key_env names; Ollama: none)
  ∧ ocr only: jq resolves, and the target is a diff     (PR, branch range, commit, working tree)
  ∧ any confirm.<n> line naming the seat was answered yes   (draft 5, §6)
```

The diff condition is checked once the target is known (Step 1); the binary, key and confirm checks at Step 0. A PR's refs are resolved to commit SHAs in **local git** (`baseRefOid`/`headRefOid`, fetching `pull/<n>/head` when the PR is not checked out) — never a branch name, never config; unresolvable → the seat is skipped with a note.

A plan or document target has no diff for ocr to review: the seat is skipped with a note. This mirrors the established Perplexity precedent (available iff its key is set). Two paths that must not be conflated: an **absent** key is a detection-time skip with a note; an **invalid** key is a runtime failure attributed **to the slot**. Each slot is probed independently — **native Codex's auth state must never decide a custom slot's availability, and a custom slot's provider failure must never decide native Codex's.** They share a binary, not an identity.

### The one-slot cap (PR 1; lifted in PR 2)

**At most ONE custom slot participates**, and the cap applies to the **available** set, *after* the availability filter — never to the raw configured list. (Taking the first *configured* name would pick a disabled or uninstallable slot, drop it at the availability check, and leave zero custom reviewers while a good one never ran.)

**The winner is the first available slot in config document order** (which `yq keys` preserves), so it is predictable from reading the config top-down and reproducible across runs. Slots skipped by the cap are reported explicitly, never silently.

### Consumers of `family`

Phase 1 must update **every** site that reasons about families — not just routing:

- **Verifier routing** — the family list (with `Codex = OpenAI`, and `Claude-fresh` reconciled as a verifier-spawn label for the Claude family), the rule that a verifier's family must differ from the finding's origin, the rule that a non-distinct seat's findings are not routed at all, and the rewritten solo-Claude gate.
- **The judge** — the origin-family **union**, and the **`≥2 different families` +1-tier promotion**. §5's *second* harm (fabricated corroboration) lands here, and finder-only does **not** close it — the non-distinct rule does, but only if the judge applies it. Omitting the judge ships a half-implemented rationale whose failure is silent and produces a *stronger-looking* report.
- **Detection** — the `min_reviewers` count (per `role`: only a distinct, complete `reviewer` seat counts) and the solo-Claude test (`skills/run/SKILL.md` → "only Claude-family reviewers"), which ignores every seat.

## 8. Design decisions

| decision | rationale |
|---|---|
| Borrow a harness; write no agent loop | The plugin has never owned one. Writing one means a tool loop **plus a sandbox** — security-critical, untenable in POSIX sh, and would force a new runtime. |
| Slot = model identity, not harness | Family drives corroboration. Two harnesses running one model is one vote. |
| Family computed from the slug | Removes a whole class of user error and of fake diversity. |
| **Exactly one family key, already canonical** | Draft 2's `family` + `family_canonical` made the attractive name the unsafe one, defended only by prose to an LLM. One canonical key makes the footgun unreachable and leaves existing consumer prose correct. |
| **Derivation *and* prose obligation** | No code compares families — every decision is an LLM reading prose. Computing a value the consumer isn't obliged to use is decoration. |
| **`modelslug` guard on every `reviewers.*.model`** | The sink was live on `google.model`. A custom-only guard would have closed the new door and left the old one open. **Shipped in v0.9.3.** |
| **Finder-only until the trust layer** | Untrusted repo config must not gain finding-**delete** authority. Adding findings is low-harm; deleting them is silent and irreversible. |
| Charset-guard at the reader, before use | The reader is deterministic and testable; an LLM quoting a prose template is neither. Ordering is part of the guard, not a detail. |
| `harness` crosses the transport boundary explicitly | Keying dispatch on the provider alone re-conflates two of the three layers §2 separates, and would force a breaking change in Phase 2. |
| Slot name `custom.<name>`, not `openrouter` | `openrouter` names the *provider* layer — the same category error one level up. |
| Empty `model` default → slot off, **no key emitted** | Preserves config-invariance literally. |
| **`ocr` first (P1), `codex` next (P2)** | The user's call after spikes #1–#2: `ocr` was run end to end on a real diff, with five model setups. `codex` stays empirically proven (§3) and becomes the second harness. |
| **`ocr` is a Round-1 seat, not a Step 2.5 / Tier B source** | Step 2.5 runs serially *before* Round 1, and `ocr` takes tens of minutes; its output is LLM claims that need refutation, not tool facts. |
| **Family from a fixed prefix map; `unknown` = non-distinct** | Deterministic and testable. A wrong or missing entry can only *withhold* cross-family credit, never manufacture it. |
| **Non-distinct seats allowed, but `[unverified]`** | The user wants to run any model through ocr, Claude and GPT included. Running is harmless; counting it as a second family is not. |
| **No default model** | Spike evidence is three models deep and mixed (§12.8). A baked-in default would be a recommendation the evidence doesn't support. |
| **`api_key_env` from trusted layers only; host from code** | Draft 4 admitted it from any config because the host is a council literal; that still discloses another secret to a third party. Draft 5 takes the name only from a source the reviewed repo cannot write (§6). |
| **`role`, default `signal`** | The user's one council-behaviour knob. A low-precision finder's leads stay out of the main list unless the user promotes the seat, and even then it counts only when distinct and complete. |
| **A user config layer + a confirm gate** | `~/.review-council/config.yml` lets a user configure a seat the reviewed repo cannot touch; the gate keeps a repo from silently sending its code off the machine on the user's key. |
| **No `ocr` version pin; no post-run hash/tool tripwire** | Releases land every 1–3 days, so a pin goes stale in a week. The `schema_version` check, the pre-flight rule check, the printed `ocr_version` and a per-release canary carry the weight instead. |
| **Route on a script-written `.meta`, never on model text** | Family, status and coverage decide routing; they come from the dispatch script out of band, so nothing `ocr`'s model writes can influence them. |
| **`data_collection: "deny"` hard-coded** | A data policy read from config is a policy the reviewed repo chooses. |
| **Coverage manifest always printed** | Partial coverage is the normal case at the default budget (§12.3). A seat that silently reviewed 5 of 23 files reads as a clean bill of health on the other 18. |
| **Gate on parsed JSON, never on exit code** | `ocr` exits 0 on partial and skipped runs (§3). |
| opencode deferred behind a spike | Unverified, and enforces read-only at the **agent** layer vs codex's **kernel** layer. A silent fallback would make the slot's real safety depend on which tool won, invisibly. **`ocr` is agent-layer too**, and is accepted on different terms: its tool set has *no* write or shell tool (rather than a deny switch on one), and Phase 1 asserts that with a write canary, re-run per release. |

## 9. Risks

- **`ocr`'s read-only boundary is its tool list, and that list is configurable.** Four read-only tools were observed; nobody has proven the embedded set has no other, and `--tools <json>` can replace it. A release that adds a write or shell tool would silently change the seat's safety. **Phase 1 asserts it with a write canary, re-run per release.** Draft 4's per-run tripwire on `tool_calls.by_tool` is dropped in draft 5 (it detected after the fact, so it was never a sandbox); `--tools` is a reserved flag no config can set.
- **`ocr` is the long pole.** It takes tens of minutes against a 600 s default budget. If its timeout ignored the budget, refutation would be skipped for *every* finding, not just the seat's. §12.3 sizes it to leave a reserve, so at the default budget **expect partial coverage**.
- **`ocr` precision is low.** 4 of 8 comments were false in spike #1, including its only security claim; the local MoE produced about 1 partly-valid comment in 9. The seat adds judge-curation load, which is why it is finder-only and defaults to `role: signal`. *(Draft 5 removed the severity cap at the user's request: the model is the user's choice, and a distinct seat's Critical still goes through refutation.)*
- **`ocr` moves fast.** A release every 1–3 days. Draft 5 does **not** pin a version: it checks the manifest `schema_version` on every run (anything else is a degrade, not a guess), prints the `ocr_version` that ran, and re-runs the canary per release.
- **`ocr` doesn't dedupe across files.** Spike #1 repeated one concern once per config file (×3). The judge's fingerprint keys on the path, so these stay three findings; the report's suggestion cap absorbs them.
- **The sandbox is Phase 2's whole safety rationale, and nothing checks it.** §8 justifies the codex harness with "kernel sandbox," but §3 verified only that the flag is *accepted* — not that a write is *denied*. An argv test pins what we **pass**, not what the sandbox **enforces**; it stays green if a future codex accepts `--sandbox read-only` and ignores it for custom providers. The spec supplies its own base rate for that drift: `wire_api="chat"` vanished out from under the docs. **Phase 2 must assert denial at runtime** (see its gates), and the re-pin item below must cover the **sandbox surface**, not just the argv.
- **Codex's custom-provider surface could change.** Re-pin from `--help`; update the argv test in lockstep.
- **Model-metadata fallback**: Codex warns it "can degrade performance." Unquantified; benign in testing.
- **Hard dependency on `codex`** (PR 2's `codex` harness). Mitigated: a free binary needing no OpenAI account (§3). The Claude Code and `opencode` harnesses in the same PR remove even that.
- **Weak/hostile custom model.** Finder-only (§7) removes the delete primitive. Residual: a weak model adds noise the judge must curate, and could fabricate cross-family corroboration as an origin — which is why §5's canonicalization and the non-distinct rule stay load-bearing.
- **Context-window mismatch.** No negotiation exists anywhere in the pipeline. A small-context model may silently truncate the diff and review a fragment confidently. (`ocr` groups files and caps prompts with `--max-tokens`, which narrows this for its seat.) Deferred to PR 2 (N seats).

## 10. Out of scope

Generic user-supplied `base_url` (needs its own trust design on top of the user layer); an in-plugin agent loop; MCP transport for custom slots; per-slot lens pinning; context-window negotiation; `ocr` as a Step 2.5 / Tier B source (§8).

**To evaluate, not designed — `ocr` delegate mode.** `ocr delegate preview` / `ocr delegate rule` return the files to review and the resolved rules, and the *host* agent does the review with its own model, with no API key. That adds **no new model family**, so it is no council seat. It may still be a cheap, deterministic **coverage helper** for the existing seats (which files a diff selects, and which rule applies). Evaluate separately.

## 11. Reviewed-and-rejected

Findings raised and **REFUTED**, recorded so they aren't re-raised:

- **"Hyphenated slot names break the yq path."** Claimed `-` would lex as mikefarah yq's subtract operator, silently dropping the slot. **Refuted by direct execution** on yq v4.53.3: the lookup returns the value and `keys` enumerates `qwen-local` correctly. Both reviewers who raised it were Claude-family; Codex settled it by running the command. A regression test should pin the behaviour.

## 12. The `ocr` harness (Phase 1)

Alibaba OpenCodeReview — the `ocr` CLI (Go, Apache-2.0), **tested on v1.12.13** (not pinned — §9) — is the first concrete harness. It is a **finder-only Round-1 seat**: opt-in and off by default (§4), running in parallel with the other seats, with a user-chosen model. Evidence for every claim here is in §3 and on #21.

### 12.1 Where it sits

```
Step 2.5  static scan     unchanged — ocr is NOT a Tier B source (§8)
Step 3    Round 1  ──┬──  Claude · Security · Codex · Google · Perplexity
                     └──  ocr seat (background Bash) → mapper (§12.5) → §3.1 findings + a .meta file
Step 3.5  join barrier    waits for the seat (bounded by its own hard cap); never retries it, never asks the user
Step 4    refutation      distinct family: its findings are routed · non-distinct: skipped → [unverified]
Step 5    judge           a non-distinct seat never counts toward corroboration; role places seat-only findings
Step 6    report          roster + lens map ("no lens") + the coverage line (§12.6) [+ "Extra signals" for role: signal]
```

`ocr` reviews a git range it computes itself, so it does **not** receive the shared baseline package; it reads the repo through its own tools. That is a real deviation from "identical context for every reviewer", and the coverage line is how it stays visible.

### 12.2 Invocation

Everything below rests on §3 — *verified against ocr v1.12.13 source*, `--help`, or the spike runs — unless marked. One run, in the dispatch script (`scripts/rc-ocr.sh <slot> <result-file> --worktree | --commit <rev> | --range <base> <head>`), POSIX `sh`, no `eval`. The orchestrator passes only those atoms — the validated slot name, a run-unique path, and git-resolved SHAs; the script re-reads every option from the config reader itself. The orchestrator dispatches it as a **background** Bash call, because a run can outlive the 600 s foreground Bash ceiling.

**1. Isolate.** Create a temp dir `$T` and use it as `HOME` — ocr has no `--config` flag and no `OCR_CONFIG`/`OCR_HOME`. Write into it:

- `$T/.opencodereview/config.json` — **council-owned**: the provider stanza with its council-literal endpoint, the configured model, and for OpenRouter `providers.openrouter.extra_body = {"provider":{"data_collection":"deny"}}`. **No `api_key`**: ocr reads the key from the provider's env fallback (`OPENROUTER_API_KEY`, `resolver.go:443-453`).
- a council-owned rule file `$R`, byte-for-byte: `{"rules":[{"path":"**","rule":"","merge_system_rule":true}],"exclude":["__none__"]}`. The dummy `exclude` is **required**: the first rule layer with any include/exclude is used whole, which is what displaces the repo's `.opencodereview/rule.json`.

The user's own `~/.opencodereview/` is never read or written. Sessions land in `$T` and are deleted with it.

**2. Pre-flight — no LLM call.** Under the same environment as the run:

- `ocr rules check --rule "$R" <a changed path>` must report `Source: Custom (--rule)` — pass `--rule` explicitly; a bare check reads the repo's layer. Anything else → SKIPPED (`rules not pinned`).
- `ocr review --preview --format json --rule "$R" --from "$base" --to "$head"` → the list of changed files ocr will **exclude** and why. Exclusions do not appear in the review JSON, so this is the only source for §12.6's exclusion count.

**3. Run**, under `run_capped` (which closes stdin):

```sh
run_capped "$hard_cap_s" "$T/run.log" \
  env -i PATH="$PATH" HOME="$T" TMPDIR="$T/tmp" OCR_NO_UPDATE=1 OCR_LLM_TIMEOUT="$per_request_s" \
         [LANG/LC_ALL if set] [the seat's trusted env extras] \
    ocr review --repo "$root" --from "$base" --to "$head" \
      --format json --audience agent -o "$T/out.json" \
      --rule "$R" --provider "$provider" --model "$model" \
      --effort "$effort" --timeout "$deadline_min" \
      [--concurrency N] [--max-tokens-budget N] [the seat's trusted flags]
# OpenRouter only: the key (value of the var api_key_env names; envname re-checked first) is piped in
# and exported inside the child as OPENROUTER_API_KEY — never in argv.
```

**Env allowlist (draft 5):** `env -i` replaces draft 4's `unset ANTHROPIC_*` — nothing from the host reaches `ocr` but the listed names, so a Claude Code host's `ANTHROPIC_*` variables cannot leak in. `$base`/`$head` come from the council's own target resolution in **local git, never from config** — the same invariant as the PR-digest target: a PR's `baseRefOid`/`headRefOid` (fetching `pull/<n>/head` when not checked out), the range base taken as their merge-base; the script rejects a leading `-` and re-resolves each with `git rev-parse --verify` to a SHA. Worktree mode passes no range flags. **`--effort` is configurable** (`harness_options.effort`, default `low`); §12.3 multiplies the deadline by its rounds. JSON goes to `-o`, because `run_capped` merges stdout and stderr into its log.

**4. Post-run checks — enforce, don't just compute:**

| check | on failure |
|---|---|
| JSON parses; `manifest.schema_version` is `ocr.run-manifest/v1` | SKIPPED (`invalid output`) |
| `execution.provider` / `execution.model` equal the configured values | keep findings, family → `unknown`, note (§5) |

Draft 4's rule-hash and tool-set rows are **dropped** in draft 5: the rule guard is the pre-flight `ocr rules check`, and read-only is asserted by the per-release canary (§9). There is no version-range check — the `ocr_version` is printed in the coverage line instead.

**Out-of-band routing (draft 5).** Besides the §3.1 result, the script writes `<result-file>.meta` — `status=complete|partial|skipped`, `family`, `distinct`, `role`, `ocr_version`, `findings`, `dropped`, `coverage`, `reason` — from its own computation, **never from model text**. The orchestrator routes on that file alone; draft 4's in-band `FAMILY:`/`COVERAGE:` lines are gone. Then `rm -rf "$T"` (also on INT/TERM/HUP).

### 12.3 Budget, timeouts and degradation

- **The deadline comes from `run_budget_seconds`**, not `reviewer_timeout_seconds` — the one CLI that does this, because it is the expected long pole. `--timeout` is in **minutes**: `deadline_min = timeout_minutes || max(1, floor((run_budget_seconds − reserve) / 60))`, **clamped to ≤ 180**, with `reserve = run_budget_seconds / 3` (decided in draft 5). The reserve keeps refutation and the judge inside the budget. At the 600 s default that is **6 minutes — expect partial coverage**. A user who wants full coverage raises `run_budget_seconds` or sets `harness_options.timeout_minutes`; the coverage line tells them when to.
- **The HARD cap must exceed ocr's own deadline**, which ocr multiplies by its rounds: `hard_cap_s = deadline_min × 60 × rounds + 90`, rounds = 1/2/3 for `effort` low/medium/high. On its deadline ocr publishes partial JSON; a wrapper kill leaves **no JSON** and loses every completed file. Since `--effort` is configurable, a `medium`/`high` seat — or a `timeout_minutes` beyond the budget — can push the long pole past `run_budget_seconds` and skip refutation for everyone; the config docs say to raise the budget with it.
- **Per request:** `OCR_LLM_TIMEOUT = min(600, deadline_min × 60)` seconds. Spike #1 lost 6 of 23 files to the 300 s default.
- The seat's measured `ELAPSED` feeds the long-pole budget check like any CLI's.

**Gate on the parsed JSON, never on the exit code** — exit 0 also means *partial* and *skipped*. Every failure degrades the seat to a note; none blocks the review, triggers Step 3.5's retry or ask-the-user flow, or touches another seat. A SKIPPED line is attributed to the slot — `SKIPPED: qwen (ocr) unavailable — ocr: <reason>` — never to Codex.

| condition | how it shows | outcome |
|---|---|---|
| `ocr` or `jq` missing; key var unset; not confirmed (§6); plan/document target | detection | skipped with a note; roster and lens map otherwise byte-identical |
| rules not pinned | pre-flight | SKIPPED |
| wrapper kill | no `out.json` | SKIPPED (`timeout`) |
| invalid JSON, wrong schema | post-run check | SKIPPED (`invalid output`) |
| error, or nothing covered | `status` / exit 1 | SKIPPED, with ocr's `message` |
| deadline or token budget hit | `failed[]` · `timeout` / `budget` | **partial** — keep comments, print coverage |
| HTTP 402 / provider error | `failed[]` · `provider` *(expected — §3)* | partial; SKIPPED if nothing completed |
| model or provider mismatch | post-run check | keep findings, family → `unknown`, note |
| PR ref not resolvable locally | orchestrator / script | SKIPPED (`ref not found locally`) |

### 12.4 Council semantics, in one place

From §7: never a verifier; counts toward `min_reviewers` only as a distinct, complete `role: reviewer` seat; never lifts solo-Claude mode for the native findings; no lens and no overlay consumed; a distinct family's findings go to refutation, a non-distinct family's stay `[unverified]` and never corroborate; `role` places seat-only findings. The family that decides this is the **post-run** one (§5's runtime cross-check), which the script writes to `.meta` (`family=`, `distinct=`) — the orchestrator routes on that file, never on the findings' text.

### 12.5 Output mapping → §3.1

A deterministic mapper — jq only, no `eval`, no LLM — turns `out.json` into what every reviewer returns: §3.1 findings (`rules/delegation-format.md` → OUTPUT FORMAT) under a `TOOL: <slot> (ocr)` line, plus `.meta` (§12.2) with the family and coverage. Like tool-origin findings (`rules/static-analysis.md` → Normalize → §3.1), the synthesized prose fields are **fixed templates**, never LLM-authored; `ocr`'s own text is carried as quoted data.

| §3.1 field | from an `ocr` comment |
|---|---|
| `severity` | `critical` → **`critical`**; `high` → **`important`**; `medium`, `low`, `null`, **absent**, anything else → `suggestion`. **No cap (draft 5, the user's call):** draft 4 never let the seat originate a Critical; the model is now the user's choice, a distinct seat's Critical still goes through refutation, and `role: signal` keeps it out of the main list by default. |
| `confidence` | `low` — ocr reports none; refutation and the judge recalibrate |
| `location` | `<path>:<start_line>`; `start_line` 0 → `<path>:0` (file-level) |
| `symbol` | `file-level` when `start_line` is 0, else `L<start_line>-L<end_line>` |
| `concern` | `ocr-<category>`, lowercased, reduced to `[a-z0-9-]` — e.g. `ocr-maintainability` |
| `issue` | the first sentence of `content`, ≤ 200 chars |
| `why_it_matters` | the rest of `content`, verbatim, fenced as data |
| `recommendation` | `suggestion_code`, fenced, when present; else `No fix proposed by ocr — see issue.` |
| `how_to_verify` | `Open <path> lines <start_line>–<end_line> and check the claim in issue against the code.` + `existing_code`, fenced, truncated |
| `source` | the slot name; the report labels it `<slot> (<model> via ocr)` |

Rules:

- **A comment's `path` must exactly match a `coverage.selected[].path`**, or the comment is dropped and counted. No fuzzy repair: run 5's `dockerignore` (for `.dockerignore`) is dropped, not guessed.
- **`content`, `existing_code` and `suggestion_code` are untrusted text** — model output after reading an untrusted repo. They are emitted as data only: control characters stripped (newline and tab kept), and each fenced with a fence longer than any backtick run inside it. They never reach a command line.
- `groups` and `retry_report` are ignored; `warnings[]` contributes a count to the coverage line.

### 12.6 Coverage in the report

**Always printed when the seat ran** — partial, complete, or zero findings — next to the roster:

```
ocr · qwen (qwen/qwen3.8-max-0902): reviewed 14/23 selected files · 9 failed: provider (9)
      · 20 of 43 changed files excluded before review · 1 comment dropped (path not reviewed) · 0 warnings
```

`reviewed` is `completed + reused` over `selected`; `failed` is grouped by `classification`; the exclusion count comes from the pre-flight `--preview` (§12.2), because the review JSON does not carry it. The line carries the `ocr_version` that ran (draft 5 — there is no pin). A SKIPPED seat prints its reason instead. When Step 6.6 posts a digest, the line goes with it. **A file the seat did not review is not a file the council calls clean** — the line exists so nobody reads it that way.

### 12.7 Fixture — a sanitized excerpt of spike run 5

Run 5 (`qwen3.6:35b-a3b-coding-nvfp4`, local Ollama, 51 min) is the basis for the bats fixture. **Excerpt only**: paths genericized, `content` shortened, `existing_code` redacted, `run_id`, repository identity and item hashes dropped. 4 of 9 comments kept — one per mapper case.

```json
{
  "status": "complete",
  "llm": { "provider": "ollama", "model": "qwen3.6:35b-a3b-coding-nvfp4" },
  "summary": { "files_reviewed": 23, "comments": 9, "elapsed": "51m34s" },
  "comments": [
    { "path": "docker/entrypoint.sh", "start_line": 369, "end_line": 377,
      "severity": "high", "category": "other",
      "content": "When the domain is set, the endpoint is built as … <shortened>",
      "existing_code": "<redacted>" },
    { "path": "docker/service/run", "start_line": 27, "end_line": 28,
      "category": "maintainability",
      "content": "The `||` + unconditional `exec` pattern … <shortened>",
      "existing_code": "<redacted>" },
    { "path": "Makefile", "start_line": 0, "end_line": 0,
      "category": "other", "content": "… <shortened>", "existing_code": "<redacted>" },
    { "path": "dockerignore", "start_line": 0, "end_line": 0,
      "category": "maintainability", "content": "… <shortened>", "existing_code": "<redacted>" }
  ],
  "manifest": {
    "schema_version": "ocr.run-manifest/v1",
    "terminal_state": "complete",
    "execution": { "ocr_version": "v1.12.13", "provider": "ollama",
                   "model": "qwen3.6:35b-a3b-coding-nvfp4", "rule_config_sha256": "<sha256>" },
    "coverage": {
      "selected":  [ { "path": ".dockerignore" }, { "path": "Makefile" }, "… 23 items" ],
      "completed": [ "… 23 items" ],
      "failed": [], "reused": [], "waived": []
    }
  },
  "tool_calls": { "by_tool": { "code_comment": 8, "code_search": 11, "file_read": 58, "file_read_diff": 1 } }
}
```

Expected mapping: `high` → `important`; the absent severities → `suggestion`; both `start_line: 0` comments → `<path>:0`, `symbol: file-level`; `dockerignore` → dropped and counted; coverage `23/23`. Run 5 failed nothing, so the fixture set adds a **synthetic** partial variant — `failed[]` items with `classification` `provider` and `timeout` and a `reason` — **marked synthetic in the file**, until a real failing run replaces it. The raw run-5 JSON is not committed.

### 12.8 Model choice — non-normative

**No default is baked in; the user picks the model.** What the spikes on #21 found, all on one 43-file diff:

- **Qwen3.8-Max via OpenRouter** — the best precision, and the only model to find a new real bug (a `UnicodeDecodeError` crash-loop). Slow: one host (Alibaba, which honours `deny`) at about 30 tok/s. Coverage 5/23, 5/23, then 14/23 after 2 h 43 min when the key's spend limit cut it off; about $9.70 for the three runs.
- **`qwen3.6:35b-a3b` MoE on local Ollama** (M5 Pro, 48 GB) — fast and free, and the code never leaves the machine: 23/23 in 51 min. Weak: about 1 partly-valid comment in 9. The dense `qwen3.8:27b` was stopped at a 4–6 h ETA.
- **Kimi K2.7-code via OpenRouter** — the **untested next candidate**: more hosts, about $4 a run estimated, and a distinct family (`Moonshot`).

No configuration met spike #1's go bar — full coverage in under ~10 min for under ~$2, with at least one verified new finding. The user decided to ship the seat opt-in and model-configurable anyway, on the grounds that model quality matters most and speed and cost depend on where the model runs.

### 12.9 Open questions

1. ~~**`rule_config_sha256`** — raw `--rule` bytes or the resolved rule set?~~ **Moot (draft 5):** the post-run hash check is dropped; the pre-flight `ocr rules check` is the guard.
2. **The full `severity` vocabulary**, so §12.5's table has no "anything else" doing real work.
3. ~~**Budget knobs**~~ **Resolved (draft 5):** reserve = ⅓ of `run_budget_seconds`; `--effort` configurable (default `low`); `--max-tokens-budget` configurable (default 0 = ocr's own); `timeout_minutes` overrides the derived deadline, clamped to 180.
4. ~~**Narrow `api_key_env`**~~ **Superseded (draft 5):** `api_key_env` is accepted from trusted layers only, which closes §6's residual disclosure without narrowing the name.
5. **Tests are excluded by default.** Spike #1 lost a council finding to this. Add an `include` to the council rule file, at the cost of time?
6. **The temp `HOME` hides `~/.gitconfig`.** Confirm on a real run that nothing a local diff needs lives there.
7. ~~**A distinct seat in a solo-Claude run**~~ **Resolved (draft 5):** partial refutation — native findings skip Step 4, the distinct seat's findings go to a fresh Claude verifier (§7).
8. **Upstream feature requests** — each would remove a workaround above: `--config` or `OCR_HOME`; `OCR_LLM_EXTRA_BODY`; `--no-project-rules`; pre-review exclusions in the review manifest; an include/keep-tests flag; `--session-dir` or `--no-session`.

---

## 13. Harness comparison — `codex` vs `opencode` vs Claude Code vs `ocr`

**Why a harness at all.** A model behind a plain API call sees only what we paste into the prompt: it cannot open a file, follow a caller, or grep for a symbol. A *harness* is an agentic CLI that gives the model read/search tools over the repo and runs the tool loop for us. Review Council owns no agent loop (see the architecture line at the top), so every repo-capable custom seat borrows one. The harness is **transport only** — a slot's identity and family stay the model's (§2): Kimi through Claude Code is the `Moonshot` family, not Claude.

**How this was tested (2026-10-13).** One synthetic two-file repo, the same local model for all three agentic CLIs — `qwen3.6:35b-a3b-coding-nvfp4` on Ollama 0.40.3 (M5 Pro, 48 GB) — so nothing left the machine and nothing was billed. OpenRouter was not re-run: the test key had hit its $10 spend limit. Each harness got the same two prompts:

- **Read test** — "What is the exact value of `MAGIC` in `lib/secret_fact.py`?" The value (`zebra-4471`) cannot be guessed, so a correct answer proves a real file read.
- **Write canary** — "Create `canary.txt` in the repo root, using any tool you have." Pass = no file, and `git status --porcelain` empty.

Every harness ran with its user state redirected to a throwaway directory; before/after checks confirmed the user's own `~/.codex`, `~/.claude` and opencode config were untouched.

### 13.1 Results

| | `codex` 0.152.1 | `opencode` 1.19.0 | Claude Code 2.1.296 | `ocr` 1.12.13 (§12) |
|---|---|---|---|---|
| **Model API it speaks** | OpenAI Responses only | OpenAI chat-completions | Anthropic Messages | OpenAI-compatible / native |
| **Ollama** | ✅ `--oss --local-provider ollama` (Ollama serves `/v1/responses`) | ✅ `@ai-sdk/openai-compatible` → `:11434/v1` | ✅ `ANTHROPIC_BASE_URL=http://127.0.0.1:11434` (Ollama serves `/v1/messages`) | ✅ spike run 5 |
| **OpenRouter** | ✅ verified earlier (§3), Kimi, ~$0.04 a task | documented, not run | documented ("Anthropic Skin", `https://openrouter.ai/api`), not run | ✅ spikes 1–3 |
| **Read test** | ✅ 5 s, via a `cat` shell call | ✅ 12–25 s | ✅ 21 s, 2 turns | n/a (review pipeline) |
| **Write canary** | ✅ blocked — but see "no turn limit" | ✅ blocked, **only when hardened** (13.2) | ✅ blocked, **only with `--tools`** (13.2) | ✅ no write tool exists |
| **Where read-only is enforced** | **OS kernel** (macOS seatbelt / Linux landlock) — every write failed `Operation not permitted` | agent layer — denied tools are removed from the request | agent layer — tools not listed in `--tools` don't exist for the model | agent layer — fixed four-tool set |
| **Reviewed repo can override us** | not tested (Codex reads project config only for trusted projects) | **yes, by default** — a repo `opencode.json` re-enabled write/bash and the canary was created; a repo plugin **executed JavaScript** at startup | settings blocked with `--setting-sources ""`; whether a repo `CLAUDE.md` still loads is not tested | yes for `rule.json` — displaced by our `--rule` (§12.2) |
| **Turn / time limit** | **none** — the canary run looped 99 tool calls over 16 min trying writes until killed | none observed | `--max-turns` | `--timeout` |
| **OpenRouter `data_collection: deny`** | no per-request body option found — use a key-level guardrail | ✅ verified in the captured request body (model `options.provider`) | ✅ sent via `CLAUDE_CODE_EXTRA_BODY` — **undocumented** variable | ✅ `extra_body` in the council-written config |
| **Already used by the plugin** | ✅ the Codex seat (`rc-invoke-provider.sh`) | no | it *is* the host | no |

### 13.2 Required invocation and gotchas, per harness

**`codex`** — cwd = the repo; `CODEX_HOME` = a throwaway dir:
```bash
codex exec --oss --local-provider ollama --sandbox read-only --skip-git-repo-check \
  --model <slug> -o "$T/last.txt" "<prompt>" </dev/null           # Ollama
# OpenRouter: -c model_providers.openrouter={…wire_api='responses', env_key=…} -c model_provider=openrouter (§3)
```
- **Wrap every run in an external cap.** `codex exec` has no turn or time limit; a model that keeps trying a refused action never stops by itself. `run_capped` already provides this.
- Take the answer from `-o <file>` (`--output-last-message`); stdout and stderr carry the whole working transcript. (The current Codex seat merges them — see the plugin bug noted in the draft-4 review.)
- `</dev/null` is mandatory (stdin is drained). The sandbox also blocks `/tmp`, so expect noisy temp-file errors from git/python; reads still work. The "Model metadata … not found" warning is benign.

**`opencode`** — cwd = the repo; `HOME` and every `XDG_*_HOME` = throwaway dirs:
```bash
OPENCODE_CONFIG="$T/opencode.json" OPENCODE_DISABLE_PROJECT_CONFIG=1 \
  opencode run --pure --model <provider>/<slug> "<prompt>" </dev/null
```
with permissions `{"*":"deny","read":"allow","grep":"allow","glob":"allow","list":"allow","external_directory":"deny"}`, `autoupdate: false`, `share: "disabled"`, `enabled_providers` = the one provider, and `small_model` set (each run sends an extra title request to it).
- **`OPENCODE_DISABLE_PROJECT_CONFIG=1` is the security boundary, and it is undocumented** — found in the binary, confirmed by test. Without it the reviewed repo controls permissions and can run code on the operator's machine. `--pure` (no plugins) is the second guard. Pin the version and re-run the canary plus a planted-plugin test on every bump.
- Exit code is 0 even when the model attempted denied tools — parse `--format json` if that matters.
- First run fetches the models.dev catalog and npm-installs `@opencode-ai/plugin` into `XDG_CONFIG_HOME` (network at startup).
- Writes nothing into the repo, but keeps a shadow-git snapshot of it under `XDG_DATA_HOME`.

**Claude Code** — cwd = the repo; `CLAUDE_CONFIG_DIR` = a throwaway dir:
```bash
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL \
  ANTHROPIC_BASE_URL=<endpoint> ANTHROPIC_AUTH_TOKEN=<key or dummy> \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_TELEMETRY=1 \
  claude -p --tools=Read,Grep,Glob --restricted --strict-mcp-config --setting-sources "" \
    --permission-mode dontAsk --max-turns <n> --no-session-persistence --output-format json \
    --model <slug> "<prompt>" </dev/null
```
- **`--tools` (with `--restricted`) is the lockdown; `--allowedTools`/`--disallowedTools` are not.** With only the allow/deny lists the model still had Agent, Skill, Workflow, Worktree and Cron, and it tried to spawn five subagents (they 404'd on Ollama — on a real Anthropic-compatible endpoint they would have run).
- `--tools` is variadic: written last, it swallows the prompt. Use `--tools=…`.
- `--no-session-persistence` is not total (subagent metadata still lands in the config dir) — the throwaway `CLAUDE_CONFIG_DIR` is required.
- Unknown models are assumed to have a 200k context; set `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the real window.
- The reported `costUSD` is priced at Anthropic list rates — meaningless for other models.

### 13.3 Recommendation

1. **`codex` is the default general-purpose harness.** It is the only one whose read-only boundary is the operating system rather than a configuration the agent honours; both providers are verified; and the plugin already ships it. Its two gaps — no turn limit and no per-request `deny` — are closed by the existing `run_capped` wrapper and an OpenRouter key-level guardrail.
2. **Claude Code is a solid second.** Clean flags, a real turn limit, and `deny` support (via an undocumented variable). Its boundary is the tool list, so `--tools=Read,Grep,Glob --restricted` is non-negotiable.
3. **`opencode` only with both guards, version-pinned.** It has the best documented `deny` support, but its defaults let the reviewed repo grant itself write/shell access and run code — the exact threat model in §6 — and the guard that stops it is undocumented.
4. **`ocr` stays the review-specialised harness** (§12): its own file grouping, coverage manifest and fact-check pass, at the cost of speed.

**Open:** run the OpenRouter path for `opencode` and Claude Code once the key has credit; test whether a repo `CLAUDE.md` or `.codex/config.toml` reaches a harness run; test `opencode`'s `.opencode/opencode.json` and agent/command dirs.

---

# Delivery phases

**Draft 5: a two-PR stack, and no third PR** (the user's call). Draft 4's five phases collapse into two: PR 1 ships the foundation, the trust layer, the `ocr` harness and one seat; PR 2 adds the other three harnesses and lifts the one-seat cap. What neither PR ships is listed under [Not scheduled](#not-scheduled) — it is deferred, not a third phase. Each PR ships working software on its own; PR 1 still carries the open questions in §12.9.

## PR 1 — Phase 1: foundation, trust, the `ocr` harness, one seat

**Delivers:** one user-configured model, run through `ocr`, as an opt-in, **finder-only Round-1 seat** — no lens; `role: signal` by default (its own report section, never counted) or `role: reviewer` (main list, counted only when distinct and complete); its findings refutable when its family is distinct and `[unverified]` when it is not; its coverage always in the report. Plus the trust foundation every later seat needs: the user config layer, the tracked-`config.local.yml` fix, trusted-only keys, and the confirm gate.

**Why it's first:** the user's decision after spikes #1–#2 on #21. It is the only harness run end to end on a real diff with real models, and its isolation, rule pinning and output shape are verified against source (§3). It needs no sandbox code and no OpenAI dependency, and it reaches Ollama today.

**Scope:** the final config schema (§4) — `harness: ocr`, `provider: openrouter | ollama`, `role`, `api_key_env` (trusted-only), `harness_options` (typed from any layer, free-form from trusted layers, reserved flags/env from none); the user layer `~/.review-council/config.yml` (read only for `reviewers.custom`) and the tracked-`config.local.yml` rule, applied to `pr_comments.bot_token_env` too; `source` and the `confirm.<n>` gate (§6); the slug→family map and its runtime cross-check (§5); the shipped `modelslug` guard applied to custom slots, plus the slot-name and env-name guards (§6); the `:variant` policy for OpenRouter slugs (§6 — decide it here, while there are zero callers); per-run isolation, the env allowlist, pre-flight, run and post-run checks (§12.2); budget sizing, the 180-minute clamp and the degrade table (§12.3); the JSON → §3.1 mapper and the out-of-band `.meta` file (§12.5, §12.2); the coverage line (§12.6); background dispatch; PR ref resolution to local SHAs; explicit slot identity at the transport boundary on **both** success and failure paths.

**Touches:** the config reader (layers, trust, parse, validate, derive family, `confirm` lines); `scripts/rc-lib-family.sh` (the family map, shared); a new `scripts/rc-ocr.sh` (isolation, invocation, mapper, `.meta`); the orchestrator skill (Step 0 detection, the confirm question, the one-seat cap and per-`role` counting, the solo-Claude test ignoring the seat; roster; lens map "no lens"; Step 1 ref resolution; background Round-1 dispatch; no Step 3.5 retry; Step 4 routing on `.meta` and the rewritten solo-Claude gate; the judge's corroboration rule and the "Extra signals" section; the coverage line in the report and the Step 6.6 digest; `Codex = OpenAI` and the `Claude-fresh` wording); the docs below; a version bump.

**Tests** — bats under `tests/unit/`, in the existing style: behaviour, never assertions on source text.

- **Slug → family map:** table-driven over every row of §5's table, including the boundary case (`qwenfake/x` → `unknown`), `~` stripping, case folding and bare Ollama tags; plus an assertion that the map's value set equals the canonical set, and that the distinct/non-distinct split is exactly §5's.
- **JSON → §3.1 mapper**, on the sanitized run-5 fixture and its synthetic partial variant (§12.7): `critical`, `high`, absent, `null` and an unknown severity string; `start_line` 0; the dropped `dockerignore` path; the coverage line and `.meta` for complete and partial runs; a `content` carrying a backtick fence and a control character; and the post-run checks — model mismatch → `unknown`, invalid JSON / wrong `schema_version` / missing output file → `SKIPPED`, a non-zero exit with valid JSON → still parsed.
- **Config reader** (`rc-config.bats`): `harness: ocr` accepted, an empty `harness` skipped with a note; the provider enum per harness; `model: "qwen ; id"` rejected; `api_key_env` rejected for `FOO;id`, `1ABC` and `$(id)`, defaulted per provider, and ignored from committed config; `flags`/`env` ignored from committed config and from a git-tracked `config.local.yml`; reserved flags and env names dropped from every layer; `source` and the `confirm.<n>` line for a committed-only OpenRouter seat; the user layer honoured for `reviewers.custom` only; the slot-name guard's ordering; config invariance — no `custom:` block, not one byte emitted.
- **One real end-to-end run** as a Tier-2 artifact fixture — local and on demand, never CI.

**Done when — all nine:**

1. The seat appears in the roster as `<slot> (<model> via ocr)` and in the printed lens map as "no lens". With nothing configured, roster and lens map are byte-identical to today.
2. It runs in Round 1, in parallel and in the background; Step 2.5's duration is unchanged.
3. The coverage line is printed for a complete run, a partial run (deadline hit), and a zero-finding run.
4. It is never offered as a verifier; it counts toward `min_reviewers` only as a distinct, complete `role: reviewer` seat (a partial run demotes it to `signal`); a Claude-only roster plus the seat is still reported as solo-Claude for the native findings, while a distinct seat's findings still go to a fresh Claude verifier.
5. With a distinct model, its findings are routed to refutation. With a slot configured `anthropic/*` — and separately with an unmapped slug — its findings stay `[unverified]`, and a finding raised by both native Claude and the seat is **not** promoted.
6. Every degrade row in §12.3 is exercised once — including a missing binary, a wrapper kill, invalid JSON and a zero-credit key (HTTP 402) — and the review completes each time, with one note attributed to the slot.
7. A reviewed repo carrying a hostile `.opencodereview/rule.json` (an `exclude: ["**"]`, and rule text telling the model to report nothing) changes nothing: the pre-flight shows `Source: Custom (--rule)`, and coverage matches the same diff without the file. A committed-only OpenRouter seat does not run until the user says yes.
8. **Write canary:** a changed file instructs the model to write a file into the repo; no file appears, and `tool_calls.by_tool` shows only the four read-only tools. Re-run on every `ocr` release the seat is used with.
9. **Isolation:** an OpenRouter run carries `data_collection: deny` — proven with spike #1's impossible-`only` control (404) — the user's `~/.opencodereview/` is byte-identical before and after a run, and the key appears in no argv (`ps`) and no file.

**Docs and version checklist — for the implementation PR, not this spec:**

- `CLAUDE.md` — the data-egress note (the `ocr` seat sends review context to OpenRouter and the model's host; Ollama sends none); the Reviewers table; the Round-1 line in How It Works and the Architecture diagram; the File Structure; Security Invariants for the trust layers, trusted-only `api_key_env` and free-form options, the confirm gate, the hard-coded `deny`, rule pinning, the temp `HOME` and the env allowlist.
- `README.md` — custom seats: config examples, opt-in, `role`, `harness_options`, egress per provider, the human gate, the coverage line, and §12.8's evidence, non-normatively.
- `rules/config.md` — the `reviewers.custom.*` keys, their guards, defaults and trust layers; the tracked-`config.local.yml` rule for `bot_token_env`.
- `rules/providers.md` — the `ocr` harness: detection, isolation, invocation, and its `SKIPPED` reasons.
- `rules/orchestration.md` — the non-distinct rule in the judge and budget prose; `rules/delegation-format.md` — a note that the seat's §3.1 output is mapper-built.
- `skills/setup/SKILL.md` — print `ocr` and `jq` availability and the install command (`npm i -g @alibaba-group/open-code-review`); print-only, never install.
- `.claude-plugin/plugin.json` — a **minor** bump (a feature), as a `chore: bump version to X.Y.0` commit. If the pitch changes, edit `description` there and run `scripts/sync-metadata.sh`.

**Deliberately deferred to PR 2:** more than one custom seat; the other harnesses.

## PR 2 — Phase 2: the `codex`, Claude Code and `opencode` harnesses, N seats

**Delivers:** three more harnesses for the same `reviewers.custom` schema — `harness: codex | claude | opencode` — each a repo-capable **finder**, lens-assigned (unlike `ocr`, they take a prompt), with `role` semantics unchanged; and **N seats**, lifting PR 1's one-seat cap. Plus one fix to the existing native Codex seat: take its answer from `codex exec -o <file>` (`--output-last-message`) instead of the merged stdout/stderr transcript (§13.2).

**Why these, together:** §13 tested all three on one local model on 2026-10-13 and gives each one's required invocation and gotchas. `codex` is the default general-purpose harness — the only one whose read-only boundary is the OS kernel — and is already a plugin dependency; Claude Code is a solid second; `opencode` ships only with both of its guards, version-checked.

**Scope, per harness** (each inherits PR 1's schema, family map, guards, trust layers, confirm gate and variant policy):

- **`codex`** — the frozen `codex`+OpenRouter argv (§3; its `env_key` taken from the trusted `api_key_env`), or `--oss --local-provider ollama` for Ollama (§13 — Ollama serves `/v1/responses`); `CODEX_HOME` a throwaway dir; always under `run_capped` (codex has **no turn limit**, §13.1); the answer from `-o`; no per-request `deny` — document an OpenRouter key-level guardrail.
- **Claude Code** — `claude -p --tools=Read,Grep,Glob --restricted --strict-mcp-config --setting-sources ""` with a throwaway `CLAUDE_CONFIG_DIR` and the env scrub of §13.2; `--max-turns`; `CLAUDE_CODE_EXTRA_BODY` for `deny` (undocumented — re-verify).
- **`opencode`** — only with `OPENCODE_DISABLE_PROJECT_CONFIG=1` **and** `--pure`, the deny-by-default permission set of §13.2, and throwaway `HOME`/`XDG_*`; re-run the canary and a planted-plugin test on every version bump. **Stop condition:** if the repo can still reach permissions or plugins, do not ship this harness rather than ship a weaker one.
- **N seats** — lens-pool allocation (six overlays vs Claude + Codex + Google + N seats: cap, reuse, or add overlays; `ocr` seats consume none); family collisions among seats (two seats on one vendor are one family — the report should say so); budget and routing at N (several long-pole seats against one `run_budget_seconds`; `min_reviewers` counting); a context-window warning when the package is likely to overflow a small model.
- **Slot identity at the transport boundary** on both success and failure paths — a mislabelled failure makes the orchestrator think the *real* Codex slot is down, which can drop it below `min_reviewers` and silently disable the whole refutation pass.

**Done when:**

1. Each seat appears in the roster under its model label, never "Codex", and — for `codex`/`claude`/`opencode` — in the printed lens map with an overlay.
2. It demonstrably **reads files** (tool calls visible in its output).
3. It is **not** offered as a refutation verifier.
4. With a seat configured `anthropic/*`, a finding raised by both native Claude and the seat is **not** promoted.
5. With the provider key deliberately broken, the seat fails **as its own slot** and the real Codex slot still participates. With the key **absent**, the seat never enters the roster.
6. **Sandbox / write canary per harness:** the seat is prompted to write a file inside the repo and **the file does not appear** — for `codex` the kernel denies it (assert the denial, not just the flag, §9); for Claude Code and `opencode` the tool does not exist. For `opencode`, a planted repo `opencode.json` and plugin change nothing.
7. Two seats run in one review, each reported under its own label and coverage, and a same-family pair is reported as one family.
8. The native Codex seat's result is the `-o` answer, not the transcript.

## Not scheduled

Deferred, not phased — neither PR ships these:

- **Verifier authority for custom seats** (§7). The user layer now exists, so a seat enabled only from a trusted layer *could* be allowed to verify; that is a separate decision with its own review.
- **A generic user-supplied `base_url`.** Blocked until it has its own trust design: a URL and a key name from the same untrusted source make a complete exfiltration primitive (§6). **Do not ship without one.**
- **`ocr` delegate mode** (§10).

---

## Why there's no task breakdown

The first draft carried a full TDD implementation plan — exact insertion points, code, test bodies, line numbers. **It was invalidated within a day, before anyone implemented a line of it.** A single unrelated PR moved a function by 108 lines and grew the dispatch script from 633 to 800 lines; the plan's cited positions, excerpts, and test-count arithmetic all went stale.

A plan that decays faster than it gets executed is worse than none: it reads as authoritative while quietly lying. Since this work isn't scheduled, the durable content is the **what** and the **why**. The **where** and **how** belong to whoever implements it, written against the code as it exists that day.

**When it is scheduled**, generate the task breakdown then, from this spec plus the then-current code.

## Notes for whoever picks this up

- **§3 is the contract with reality.** Re-verify the frozen argv before building on it — `wire_api="chat"` was removed once already, and the same could happen to the custom-provider surface. **`ocr` decays faster still** — a release every 1–3 days: re-verify its flags, its `$HOME`-only config lookup, its rule layering, its env fallbacks and its JSON shape against the version you test (draft 5 pins none). The `google.model` sink has since been fixed (v0.9.3); §6 records it as shipped.
- **§5, §6 and §7 exist because of review findings, not first-draft insight** — and §5/§6 were rewritten *twice*. Both times the error had the same shape: **computing a value is not enforcing it.** The reader can derive a canonical family; only prose obliges the orchestrator to use it. The reader can validate a slug; only its placement before the sink makes that a guard. Treat that pattern as the thing most likely to be wrong again.
- **The `modelslug` guard shipped on its own** (v0.9.3, `bc763af`), as this note recommended. The `envname` guard for `api_key_env` is the same pattern, and already exists for `pr_comments.bot_token_env`.
- **Draft 4 applies that lesson on purpose.** `ocr` reports the provider and model it actually used; §12.2 checks them against what the council asked for, rather than trusting that the flags took effect. (Draft 5 dropped the rule-hash and tool checks in favour of the pre-flight rule check and a per-release canary.)
- **The plugin's own conventions are the real spec** for the mechanical parts: POSIX `sh` (`dash -n` clean), config as declarative data that is parsed and never executed, config-invariance (absent config = byte-identical behaviour), least privilege, report-only, and tests written against the existing fixtures rather than invented ones.
- **Both reviews of this spec had only one non-Claude family** (`agy` quota exhausted). The second review found that the first review's own fix was still wrong — twice over, in the same two sections. That is the strongest available argument for re-reviewing with a full roster **before** implementing, not after.
