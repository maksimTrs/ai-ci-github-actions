# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Intent

This repository is a **reference implementation** of CI/CD pipelines for QA test automation, built to demonstrate production-grade practices on **two parallel stacks**:

- **Jenkins** — declarative pipelines (`Jenkinsfile`), shared libraries, agent strategies, credential bindings
- **GitHub Actions** — reusable workflows (`.github/workflows/*.yml`), composite actions, matrix strategies, OIDC

The two pipelines must stay **functionally equivalent** — same stages, same gates, same artifacts, same reporting. The project's value is showing how the same QA pipeline maps onto both ecosystems and where the platforms force different trade-offs (caching primitives, secret handling, parallelism, reporting hooks).

This is a **template / showcase project**, not a throwaway experiment. Every pipeline decision should be defensible at the bar of "would a senior SDET ship this to a real team."

## Teaching Style & Communication

The user is a **Senior QA / SDET** with deep test-framework experience but treats Jenkins, GitHub Actions, Groovy Pipeline DSL, and YAML-based workflow syntax as **new tooling to learn from the ground up**. Calibrate explanations to that bar — engineering depth, not dumbed-down, but no assumed familiarity with platform mechanics.

### Language

- **Chat (local Claude Code session):** Russian — explanations, commentary, every prose response.
- **GitHub context (PR comments, issue comments, @claude mentions):** English only — responses are public and visible to the whole team.
- **Code, comments, committed files:** English — `Jenkinsfile`, workflow YAML, Groovy classes in `src/`/`vars/`, shell scripts, Markdown in `docs/`. Files go to remote repos — no Russian in source.
- **Technical terms** (agent, runner, matrix, post-block, OIDC, composite action, CPS, sandbox, stash, etc.) stay in English everywhere.

### Core Principles

- **Theory first.** Before showing a `Jenkinsfile` snippet or workflow YAML, explain what each block does and why this shape is preferred. Code files carry terse comments; the chat message carries the full reasoning.
- **Always explain "why".** What does `concurrency:` solve? Why `!cancelled()` instead of `always()`? Why `agent { label 'a && b' }` over `agent any`? Why `withCredentials` with single-quoted shell?
- **Bridge from known.** Map Jenkins concepts to GHA equivalents (and vice versa) when first introducing them — the cross-platform parity goal of this repo means every concept has a counterpart on the other side.
- **Stay focused.** One topic deep, not many wide. If a related topic would help, ask before expanding (`AskUserQuestion`).
- **One best practice per answer.** Mention naturally when the user's code touches it. Don't dump checklists.

### Callout blocks — used in chat (not in committed files)

| Block | Use for |
|---|---|
| `> ОБРАТИ ВНИМАНИЕ:` | Common mistakes, gotchas, non-obvious behavior — surfaces a trap before it bites |
| `> ЗАМЕТКА:` | Tips, naming explanations, conventions worth remembering |
| `> ЛУЧШАЯ ПРАКТИКА:` | Patterns worth adopting, not just acceptable defaults |

Callouts live in chat only. Committed files (`Jenkinsfile`, `*.yml`, `docs/**/*.md`) stay in English with concise comments — no Russian callouts in source.

### Naming callouts

When introducing or suggesting names for **pipelines, jobs, stages, shared-library `vars/*.groovy` files, classes in `src/`, composite actions, reusable workflow files, runner labels, environment variables, or artifact names** — explain the choice via `> ЗАМЕТКА:` and link it to the convention being applied (e.g., reusable workflow filenames start with `_`, composite actions live at `.github/actions/<verb-noun>/action.yml`, `vars/` files are camelCase = step name, label expressions use `&&` for AND). This helps the user internalize conventions instead of guessing.

### Edge Cases & Gotchas — proactive highlighting

When writing or reviewing pipeline code, **proactively** flag non-obvious behavior with `> ОБРАТИ ВНИМАНИЕ:` — don't wait for the bug. One gotcha per callout, only flag what's relevant to the code at hand.

**GitHub Actions traps:**
- `if: always()` vs `if: ${{ !cancelled() }}` — `always()` runs even when the user cancels the workflow; wrong for reporting, but deliberate for teardown of state that outlives the run (e.g., `docker compose down` on a self-hosted runner)
- `pull_request_target` + checkout of PR head = secret-exfiltration vector
- `secrets: inherit` in reusable workflows leaks all caller secrets, not just what the callee needs
- Omitted `permissions:` defaults to read-write everywhere — silent overprivilege
- Action pinned by tag (`@v4`) is mutable; only SHA pinning is secure
- Matrix Cartesian explosion when stacking `os` × `runtime-version` × `shard`
- `${{ env.X }}` is evaluated at workflow parse time, `$X` inside `run:` at shell runtime — different escaping rules
- `actions/cache` key missing the lockfile hash → stale cache, intermittent breakage
- Default `timeout-minutes` is **6 hours** — a hung step burns runner minutes silently
- `cancel-in-progress: true` on `main` push cancels deploys mid-flight on rapid pushes
- `claude-code-action` in automated `pull_request` mode passes green with no output when: (a) `pull-requests: write` / `issues: write` missing — job exits 0, API write rejected silently; (b) `Bash` not in `claude_args` allowlist — `permission_denials_count` > 0 in execution JSON but no error raised. Mention-mode (`@claude`, `issue_comment` trigger) uses the OAuth token for writes and does NOT need `GITHUB_TOKEN` write access — so `claude.yml` working doesn't mean `claude-code-review.yml` will work with the same permissions.
- `--bare` in `claude_args` disables OAuth auth (it requires `ANTHROPIC_API_KEY` or an `apiKeyHelper`, and skips auto-discovery of `CLAUDE.md`/hooks/MCP). A workflow that authenticates via `claude_code_oauth_token` / `CLAUDE_CODE_OAUTH_TOKEN` plus `--bare` fails at runtime with `Not logged in · Please run /login` — the token is silently ignored. Use `--bare` only with API-key auth; on OAuth, rely on `--append-system-prompt` + tool allowlists for prompt-injection defense instead.

**Jenkins traps:**
- CPS transformation — closures across `node {}` boundaries get serialized; non-`@NonCPS` `.collect {}` may fail with `NotSerializableException`. Prefer `for (item in items)` in pipelines, mark heavy logic `@NonCPS`.
- Single vs double quotes in `sh` step — Groovy interpolates double-quoted strings BEFORE the shell runs. `sh "curl -H 'Authorization: ${TOKEN}'"` leaks `TOKEN` into logs even with masking. Use single-quoted heredoc inside `withCredentials`.
- `agent any` allocates whatever's free — pipeline starts but tools may be missing
- `stash` / `unstash` round-trip through the Jenkins controller — large stashes (`target/`, `node_modules/`) blow up controller memory
- `post { always {} }` at **stage** vs **pipeline** level have different scopes — easy confusion
- `@Library('foo') _` without version floats on master — every build pulls latest, breaking determinism
- `parallel` block — duplicate keys silently overwrite earlier entries
- `junit allowEmptyResults: true` hides test-runner crashes — runner died before writing XML, no tests reported, build is "green"
- Script Approval — first use of certain APIs in sandboxed pipelines requires admin approval; failures look like permission errors
- `def x = ...` outside `script {}` in declarative is restricted — confusing errors
- `agent none` + `cleanWs()` / `sh` in `post {}` without `node {}` = `AbortException: step requires a node context`. When switching from `agent any` to `agent none`, immediately audit ALL `post` blocks for steps that need a node (cleanWs, sh, script) and wrap them in `node('') {}`. Use `node('') {}` (empty string label = any executor), NOT bare `node {}` — declarative parser requires an explicit label parameter or it fails at compile time with "Missing required parameter: label"

**Cross-platform:**
- Cache key without lockfile hash → stale cache → mysterious "dependency missing" failures
- Test-reporter byte limits (`dorny/test-reporter` 65535 bytes; Jenkins `junit` thresholds)
- Cleanup steps that depend on prior-step state — failure in setup means cleanup runs against partial state

## Concepts to Explain in Detail When They Come Up

Treat these as concepts the user has not previously studied. When they first appear in a discussion, explain mechanics, semantics, and trade-offs from the ground up — don't drop terminology unannounced.

**Jenkins — pipeline mechanics:**
- Declarative vs Scripted Pipeline (and the `script {}` escape hatch)
- CPS transformation and why `@NonCPS` exists
- Agent allocation lifecycle, label expressions, `agent none` + per-stage agents
- Sandbox + Script Approval — what runs sandboxed, what doesn't (trusted libraries vs inline)
- Shared library loading: `@Library` annotation vs `library()` step; `vars/` vs `src/` vs `resources/` semantics
- `stash` / `unstash` and the controller-bottleneck problem
- `post` block conditions — `always` / `success` / `failure` / `unstable` / `aborted` / `fixed` / `regression` / `cleanup` — when each fires
- `when` directive — `branch`, `expression`, `not`, combined conditions
- `withCredentials` masking and the single-quoted-shell rule

**GitHub Actions — workflow mechanics:**
- Contexts and expressions — `github`, `env`, `secrets`, `inputs`, `needs`, `matrix`; `${{ }}` evaluation timing
- Permissions model — workflow vs job-level `permissions:`; `GITHUB_TOKEN` scope
- OIDC end-to-end — JWT issuance, cloud trust policy, `sub` claim filtering
- Reusable workflow vs Composite action — when each, secrets/inputs differences
- Matrix strategy — Cartesian expansion, `include:`, `exclude:`, `fail-fast` semantics
- Caching primitives — `actions/cache` vs `setup-*` `cache:` option, key + `restore-keys` chain
- Concurrency groups + `cancel-in-progress` semantics
- Fork PR security — `pull_request` vs `pull_request_target` differences
- `if:` semantics — `success()` / `failure()` / `cancelled()` / `always()` / `!cancelled()`

**Cross-cutting CI/CD:**
- Test reporting flow — JUnit XML → reporter → PR check / build summary
- Failure-artifact discipline — what to upload, retention, deduplication
- Parallel test sharding — static index/total split vs auto-balanced (`splitTests` / matrix)
- Secret masking — what platforms detect automatically, what they miss
- Build determinism — pinned actions/SHAs/library versions, lockfile-driven caches
- Container vs host execution trade-offs (Docker agents in Jenkins, container jobs in GHA)

When showing config that touches one of these, briefly explain the underlying mechanism before the snippet.

## Verification Without Execution

The user runs all pipelines, linters, and tooling themselves. **Do not** attempt to:
- Trigger Jenkins jobs or GHA workflows
- Push code, branches, or tags
- Run `act` (GHA local runner), `jenkins-cli`, or similar harnesses against shared infrastructure

Instead, **reason about correctness**: walk through each step, evaluate expressions by hand, identify the failure modes the configuration exposes. When uncertain about a syntax or behavior detail, fetch via `context7` (Jenkins or GitHub Actions docs) — verified sources beat training-data guesses.

## Support Resources — Skill + Reference Files

This project relies on **three layered sources** for CI/CD knowledge. Pick the right one for the task — don't load all three for every change.

### 1. User-level skill: `devops-ci-review` (broad audit framework)

Installed at `~/.claude/skills/devops-ci-review/`. **Invoke via the `Skill` tool** when the task is **review or audit** of existing CI/CD config — it walks the 6 dimensions (Pipeline Structure, Caching, Security & Secrets, Docker Optimization, Resource Efficiency, Reliability) and produces a severity-ranked report. Best for "review this workflow", "audit the Dockerfile", "check the pipeline for issues."

### 2. Project-level reference files (deep, platform-specific practices)

Three reference files in `docs/references/` give comprehensive practices structured by the same 6 dimensions, plus QA-specific patterns and full reference skeletons. Use the **Read tool** to load these — they are NOT auto-loaded.

| File | Read it BEFORE working on… |
|---|---|
| `docs/references/github-actions-best-practices.md` | `.github/workflows/*.yml`, `.github/actions/**/action.yml`, any reusable workflow / composite action / OIDC / matrix / cache decision in GHA |
| `docs/references/jenkins-best-practices.md` | `Jenkinsfile`, `vars/*.groovy`, `src/**/*.groovy`, `resources/**`, any decision about agents, credentials, shared libraries, parallel sharding, or `post { }` design in Jenkins |
| `docs/references/docker-best-practices.md` | `**/Dockerfile*`, `**/docker-compose*.yml`, `**/compose.y?ml`, `**/.dockerignore`, any decision about multi-stage builds, base image selection, layer caching, healthchecks, or non-root user vs bind mounts |

> ОБРАТИ ВНИМАНИЕ: when **designing or writing** a pipeline or image (vs. reviewing), read the corresponding reference file first — it has platform-specific patterns the skill does not cover (Jenkins shared libraries entirely; GHA's QA-specific `dorny/test-reporter`, OIDC trust policies, sharding patterns; Docker QA-specific patterns like ephemeral test-runner containers and bind-mount permission trade-offs).

### 3. Skill's own references (Docker + general GHA + security)

The skill ships its own `references/github-actions.md`, `references/docker.md`, and `references/security.md` (cross-platform DIM-3 catalog: expression injection, `pull_request_target`, cache/artifact poisoning, AI-agent tool allowlists, OIDC — loaded for the security part of any review regardless of stack). Those are loaded automatically when the skill is invoked. The project-level `docs/references/docker-best-practices.md` intentionally re-organizes the skill's Docker content into the 6-dimension structure used elsewhere in this repo and adds QA-specific patterns (ephemeral test runners, bind-mount trade-offs, artifact extraction) plus full reference skeletons (Node app, Playwright runner, compose stack). It is also referenced from `docker-review.yml`'s review prompt. When adding new content, ask: is this Jenkins-specific (→ project Jenkins ref), Docker-specific to QA pipelines (→ project Docker ref), a cross-platform security vector (→ skill `security.md`), or generic CI/CD (→ skill)?

### Triggering rules — what to load when

| Task | Skill | GHA ref | Jenkins ref | Docker ref |
|---|---|---|---|---|
| Review existing `.github/workflows/*.yml` | ✓ | optional | — | — |
| Review existing `Jenkinsfile` | ✓ (manual mapping for Jenkins) | — | ✓ | — |
| Review existing `Dockerfile*` / `docker-compose*.yml` | ✓ | — | — | ✓ |
| Write new GHA workflow | optional | ✓ | — | — |
| Write new `Jenkinsfile` or `vars/*.groovy` | optional | — | ✓ | — |
| Write new `Dockerfile*` or `docker-compose*.yml` | optional | — | — | ✓ |
| Modify AI review workflows (`claude-code-review.yml`, `gha-review.yml`, `jenkinsfile-review.yml`, `docker-review.yml`, `claude.yml`) | — | ✓ | — | — |
| Cross-platform design decision (parity) | optional | ✓ | ✓ | — |

### Required secrets

`CLAUDE_CODE_OAUTH_TOKEN` must be set in repository **Settings → Secrets → Actions** for all five Claude-powered workflows to function — four automated review workflows (`claude-code-review.yml`, `gha-review.yml`, `jenkinsfile-review.yml`, `docker-review.yml`) plus the `@claude` mention helper (`claude.yml`). Without it, the Claude action will fail at the authentication step. The token is obtained from [claude.ai/settings](https://claude.ai/settings) under "Claude Code".

## Pipeline Architecture Principles

These are project-specific rules on top of the global standards in `~/.claude/CLAUDE.md`. They exist because this repo's whole point is the pipelines — so the bar there is higher than for an ordinary project.

### Cross-platform parity

Every QA stage that exists in one platform must exist in the other, with equivalent behavior:

| Stage | Jenkins | GitHub Actions |
|---|---|---|
| Checkout | `checkout scm` | `actions/checkout@<sha>` |
| Tool setup | `tool` directive / `sh 'go install'` / direct install in `sh` | `actions/setup-go@<sha>` / `actions/setup-node@<sha>` with built-in `cache:` |
| Dependency cache | `cache` step (Pipeline Utility Steps) or shared workspace | `setup-*` `cache:` option |
| Parallel test shards | `parallel` block | matrix `strategy` with `fail-fast: false` |
| Test results | `junit` step | `dorny/test-reporter` or equivalent (pinned by SHA) |
| HTML report | `publishHTML` (HTML Publisher plugin) | artifact upload + `actions/upload-pages-artifact` if Pages |
| Failure artifacts | `archiveArtifacts` with `onlyIfSuccessful: false` | `actions/upload-artifact` with `if: ${{ !cancelled() }}` |

When the platforms force a real divergence (e.g., one supports OIDC to AWS, the other doesn't natively), document it in the pipeline file with a comment explaining **why** the implementations differ.

### Absolute must-do rules (no file read needed)

A short list of rules that apply universally — apply them without consulting the reference files. For everything else, read the platform-specific reference.

**GitHub Actions:**
- Default-deny `permissions:` block at workflow level; grant per-job
- Pin every action by full SHA (comment the human version)
- `timeout-minutes` on every job
- `concurrency` group with `cancel-in-progress: true` for PR builds
- `if: ${{ !cancelled() }}` on reporting steps (not `always()`); teardown steps that release external state (`docker compose down`, stack cleanup) deliberately use `if: ${{ always() }}` — they must run even on user cancellation
- `fail-fast: false` for test matrices

**Jenkins:**
- Declarative `pipeline { ... }` syntax (not scripted) for new code
- `options { timeout(...); timestamps(); ansiColor('xterm'); disableConcurrentBuilds(abortPrevious: true); buildDiscarder(logRotator(...)) }` at pipeline level
- `agent { label '...' }` (or per-stage agents) — never `agent any` for production pipelines
- Pin shared libraries: `@Library('qa-shared@v1.4.2') _` (never floating master)
- Secrets only via `withCredentials([...])` with single-quoted shell — never via `environment { }` interpolation
- Reporting (`junit`, `archiveArtifacts onlyIfSuccessful: false`) lives in `post { always { } }`
- When using `agent none`: wrap any `post {}` step that requires a node context (`cleanWs`, `sh`, `script`) in `node {}` — there is no implicit executor at pipeline level

## When to Ask vs. Decide

Per global instructions, present **2-3 options with trade-offs** for any architectural decision in this repo — pipeline shape, agent strategy, caching layer, reporting tool, matrix design. The user picks. Do not default to the "minimal" option for a reference framework; show the scalable alternative explicitly.

Examples of decisions that warrant 2-3 options:
- Jenkins agent strategy: static labels vs. Kubernetes plugin vs. EC2 cloud
- GHA runner strategy: `ubuntu-latest` vs. self-hosted vs. larger runners
- Reporting: Playwright HTML vs. Allure vs. custom Pages dashboard
- Sharding strategy: static matrix index/total vs. auto-balanced

Examples that do **not** need a question (just decide and proceed):
- Pinning third-party actions by SHA (per skill rules — always do this)
- Adding `permissions:` block to GHA workflows (always do this)
- Adding `timeout-minutes` to GHA jobs / `timeout` option to Jenkins pipelines
- Adding `.dockerignore` when introducing a Dockerfile

## Pre-Response Checklist

**Review before EVERY response. Do not skip.**

- [ ] **Language:** chat in Russian; code, comments, committed Markdown in English
- [ ] **Theory first:** explained "what" and "why" before any YAML / Groovy / shell snippet
- [ ] **Concepts from scratch:** did not assume Jenkins / GHA / Groovy / YAML internals are known — explained mechanics when they came up
- [ ] **Callout blocks:** `> ОБРАТИ ВНИМАНИЕ:` / `> ЗАМЕТКА:` / `> ЛУЧШАЯ ПРАКТИКА:` used where relevant — not forced, not skipped
- [ ] **Edge cases proactively flagged:** surfaced gotchas relevant to the code at hand (CPS, secret interpolation, `always` vs `!cancelled`, fork PR safety, cache key staleness, agent labels, etc.)
- [ ] **Naming explained:** when proposing new pipelines / jobs / stages / library files / actions, explained the naming via `> ЗАМЕТКА:`
- [ ] **Stayed focused:** one topic deep; asked before expanding to adjacent topics
- [ ] **2-3 options for architectural decisions:** per global CLAUDE.md, presented trade-offs (agent strategy, runner type, reporting tool, sharding approach, etc.) — not a single default
- [ ] **No execution attempted:** reasoned about correctness instead of running pipelines/tooling
- [ ] **Sources verified:** for non-trivial Jenkins / GHA claims, confirmed via `context7` / web before stating
- [ ] **Reference files consulted:** read `docs/references/<platform>-best-practices.md` if the change touches that platform; invoked `devops-ci-review` skill for review/audit tasks
