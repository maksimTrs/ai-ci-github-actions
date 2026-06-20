# GitHub Actions — Best Practices for QA Pipelines

**Read this file when:** creating, modifying, or reviewing `.github/workflows/*.yml`, `.github/actions/**/action.yml`, or making decisions about caching, secrets, runners, matrix design, or test reporting in GitHub Actions.

This file is the project-level companion to the user-level skill `devops-ci-review`. The skill provides the general 6-dimension audit framework; this file specializes the practices for **QA test-automation pipelines** and pins down conventions for this repo.

Sources verified against current GitHub Docs and the GitHub Actions 2026 security roadmap.

---

## DIM-1 — Pipeline Structure

### Triggers must be explicit

`on: push` without filters fires on every branch and every tag — wasteful and noisy.

```yaml
# BAD
on: push

# GOOD
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
    paths-ignore:
      - 'docs/**'
      - '**/*.md'
  workflow_dispatch:
    inputs:
      shard_count:
        description: 'Number of test shards'
        default: '4'
```

### `concurrency` on every workflow that runs on PRs

Default behavior queues every push, including obsolete commits. For QA pipelines this wastes runner minutes and delays feedback.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

`cancel-in-progress: true` only on PR runs — never cancel deploys to `main`.

### `timeout-minutes` on every job

Default is **6 hours**. A hung Selenium grid will burn 6h of runner time. Set realistic per-job ceilings:

```yaml
jobs:
  unit-tests:
    timeout-minutes: 10
  ui-tests:
    timeout-minutes: 30
  smoke:
    timeout-minutes: 5
```

### `needs:` graph — make the DAG explicit

Sequential jobs that don't depend on each other should run in parallel.

```yaml
jobs:
  build:        # produces artifact
  unit-tests:
    needs: build
  api-tests:
    needs: build
  ui-tests:
    needs: build
  publish-report:
    needs: [unit-tests, api-tests, ui-tests]
    if: ${{ !cancelled() }}   # report even on failure
```

### Matrix strategy — sharding for QA

`fail-fast: false` is the **right default for test matrices** — you want all shards to finish so you see the full failure picture, not just the first one.

```yaml
strategy:
  fail-fast: false
  matrix:
    shard: [1, 2, 3, 4]
runs-on: ubuntu-latest
steps:
  - run: ./gradlew test -Dshard.index=${{ matrix.shard }} -Dshard.total=4
```

For cross-browser matrices, also include `os` if the test framework is browser-engine sensitive. Avoid combinatorial explosions — use `include:` to add specific combinations rather than full Cartesian products.

---

## DIM-2 — Caching Strategy

### Prefer `setup-*` actions' built-in `cache:` over `actions/cache`

The `setup-java` / `setup-node` / `setup-python` actions handle cache key computation, restore-keys, and path detection automatically.

```yaml
# GOOD — Maven
- uses: actions/setup-java@v5
  with:
    java-version: '17'
    distribution: 'temurin'
    cache: maven

# GOOD — Gradle
- uses: actions/setup-java@v5
  with:
    java-version: '17'
    distribution: 'temurin'
    cache: gradle

# GOOD — Node
- uses: actions/setup-node@v5
  with:
    node-version: '20'
    cache: 'npm'   # or 'yarn' or 'pnpm'
```

The Maven cache key is derived from `pom.xml` hashes; Gradle from `*.gradle*` and `gradle-wrapper.properties`; npm from `package-lock.json`. Cache is invalidated automatically when those files change.

### When `actions/cache` is justified

Use `actions/cache` directly only when:
- Caching tool installations (browsers, kubectl, terraform binaries)
- Caching computed artifacts (compiled test fixtures, prepared databases)
- Multi-key restore chains for downgraded fallback

```yaml
- uses: actions/cache@v5
  id: cache-playwright
  with:
    path: ~/.cache/ms-playwright
    key: ${{ runner.os }}-playwright-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      ${{ runner.os }}-playwright-
```

### Cache key hygiene

- Always include lockfile hash in the key
- Always include `runner.os` (caches don't cross-OS by default but be explicit)
- Provide `restore-keys:` as a fallback chain so partial cache hits beat zero-cache

### Pre-warm browsers / heavy tools on cache miss only

```yaml
- if: steps.cache-playwright.outputs.cache-hit != 'true'
  run: npx playwright install --with-deps
```

---

## DIM-3 — Security & Secrets

### Default-deny `permissions:` block — workflow level + per-job overrides

GitHub's default is **read-write all permissions** for `GITHUB_TOKEN`. Always restrict at workflow level, then grant additional rights per-job where needed.

```yaml
permissions:
  contents: read       # workflow default — read-only

jobs:
  deploy:
    permissions:
      contents: read
      id-token: write       # for OIDC
      deployments: write    # to create deployments
```

### Pin actions by SHA, not tag

Tags are mutable. A compromised maintainer can re-point `@v4` to a malicious commit. The 2026 GHA security roadmap mandates a workflow-lockfile mechanism for this reason — adopt the practice now.

```yaml
# BAD
- uses: aws-actions/configure-aws-credentials@v4

# GOOD
- uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502   # v4.0.2
```

Pin by SHA. Comment the human-readable version. Use Dependabot's `package-ecosystem: github-actions` to update SHAs safely.

### Keep action majors current — the Node 24 runtime cutover

SHA pinning is not "set and forget". GitHub forces all JavaScript actions onto the **Node.js 24 runtime as of 2 June 2026** — actions still on an older major (Node 20 runtime) emit deprecation warnings and eventually stop running. Pin the SHA of a current major:

| Action | Current major (2026) |
|---|---|
| `actions/checkout` | v5 |
| `actions/setup-node` | v5 |
| `actions/setup-java` | v5 |
| `actions/cache` | v5 |

The examples above use the human-readable major (`@v5`) for readability; in real workflows replace each with the pinned SHA of that major's latest patch and let Dependabot bump it.

### OIDC over long-lived secrets for cloud auth

Long-lived `AWS_ACCESS_KEY_ID` / `GCP_SA_KEY` in repo secrets is a high-blast-radius compromise vector. Use OIDC to exchange GitHub's short-lived token for cloud credentials:

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@<sha>
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-deploy
          aws-region: eu-central-1
      - run: aws s3 cp ./report.html s3://qa-reports/
```

In the cloud provider, restrict the OIDC trust policy by repo + branch + workflow:

```
"token.actions.githubusercontent.com:sub": "repo:org/repo:ref:refs/heads/main"
```

### Secrets and `pull_request_target` — never combine carelessly

`pull_request` from a fork has **no access to secrets** (correct, safe default). Some teams switch to `pull_request_target` to "fix" this — that runs the workflow with secrets in the context of the **target branch**, but checks out the PR head. The result: a PR can read secrets via injected workflow code.

Rule: **never** check out PR head code in `pull_request_target` workflows that access secrets. If you must, use a two-job pattern: trusted job (no PR code) reads secrets and exposes deployment-only outputs to the PR job.

### Reusable workflows — explicit secrets, not inheritance

```yaml
# CALLER
jobs:
  test:
    uses: ./.github/workflows/_test.yml
    secrets:
      GH_PAT: ${{ secrets.GH_PAT }}        # explicit pass
    # NOT: secrets: inherit                 # leaks all caller secrets

# CALLEE (_test.yml)
on:
  workflow_call:
    secrets:
      GH_PAT:
        required: true
```

`secrets: inherit` blurs trust boundaries — the GitHub 2026 roadmap explicitly calls this out. Pass only what's needed.

### Fork PRs — restrict triggers

```yaml
on:
  pull_request_target:
    types: [opened, synchronize, labeled]

jobs:
  test:
    if: contains(github.event.pull_request.labels.*.name, 'safe-to-test')
    runs-on: ubuntu-latest
```

Require a maintainer-applied label before running CI on fork PRs that need secrets.

---

## DIM-4 — Reusable Workflows & Composite Actions

### Reusable workflow vs. composite action — when to use each

| Use reusable workflow when… | Use composite action when… |
|---|---|
| Multiple jobs, multiple runners | Single sequence of steps on one runner |
| Needs its own secrets / permissions | Just packaging shell + actions |
| Called via `uses: ./.github/workflows/x.yml` | Called via `uses: ./.github/actions/x` |
| Per-call billed minutes | Inherits caller's runner |

### Composite action skeleton for QA

```yaml
# .github/actions/run-tests/action.yml
name: Run Tests
description: Run test shard with reporting
inputs:
  shard:
    required: true
  total-shards:
    required: true
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        ./gradlew test \
          -Dshard.index=${{ inputs.shard }} \
          -Dshard.total=${{ inputs.total-shards }}
    - uses: actions/upload-artifact@<sha>
      if: ${{ !cancelled() }}
      with:
        name: test-results-${{ inputs.shard }}
        path: build/test-results/
        retention-days: 14
```

### Reusable workflow skeleton

> NOTE: GHA expressions have only 8 built-in functions (`contains`, `startsWith`, `endsWith`, `format`, `join`, `toJSON`, `fromJSON`, `hashFiles`) plus status checks. There is **no `range()` function** — dynamic matrices must be built in a prior job that emits a JSON array via `outputs:`, then consumed via `fromJSON` in the matrix strategy.

```yaml
# .github/workflows/_qa-suite.yml
name: QA Suite (reusable)
on:
  workflow_call:
    inputs:
      environment:
        type: string
        required: true
      shards:
        type: number
        default: 4
    secrets:
      TEST_API_TOKEN:
        required: true
    outputs:
      report-url:
        value: ${{ jobs.publish.outputs.url }}

jobs:
  # Build the shard list dynamically — GHA has no range() in expressions.
  generate-matrix:
    runs-on: ubuntu-latest
    outputs:
      shards: ${{ steps.gen.outputs.shards }}
    steps:
      - id: gen
        run: |
          shards=$(seq -s, 1 ${{ inputs.shards }} | awk '{print "["$0"]"}')
          echo "shards=$shards" >> "$GITHUB_OUTPUT"

  test:
    needs: generate-matrix
    strategy:
      fail-fast: false
      matrix:
        shard: ${{ fromJSON(needs.generate-matrix.outputs.shards) }}
    # ...
```

For fixed shard counts, prefer a static array — simpler and one fewer job:

```yaml
strategy:
  fail-fast: false
  matrix:
    shard: [1, 2, 3, 4]
```

---

## DIM-5 — Resource Efficiency

### Don't install browsers if you don't run UI tests

```yaml
# In API-only jobs
env:
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD: 1
  PUPPETEER_SKIP_DOWNLOAD: 1
```

### Artifact retention — short by default

```yaml
- uses: actions/upload-artifact@<sha>
  with:
    name: test-report
    path: build/reports/
    retention-days: 14   # not 90 (the default)
    if-no-files-found: warn
```

For PR-scope artifacts, 7-14 days. For release-scope, 30-90 days. **Don't** upload `node_modules`, `target/classes`, or other rebuildable content.

### Conditional steps — guard expensive work

```yaml
- name: Run UI tests
  if: contains(github.event.pull_request.labels.*.name, 'ui') ||
      github.event_name == 'push' ||
      github.event_name == 'schedule'
  run: ./gradlew uiTest
```

### Single checkout per job, share via artifacts

If multiple jobs need the same compiled output, build once and pass via `actions/upload-artifact` → `actions/download-artifact`. Don't re-compile in each job.

---

## DIM-6 — Reliability

### `if: ${{ !cancelled() }}` for reporting steps

`if: always()` runs even when the user cancelled the workflow — usually wrong. Reporting steps should run on success and failure, but **not** when the user explicitly cancelled.

```yaml
- name: Publish JUnit
  if: ${{ !cancelled() }}
  uses: dorny/test-reporter@<sha>
  with:
    name: JUnit
    path: '**/test-results/**/*.xml'
    reporter: java-junit
    fail-on-error: true
```

### Retry strategy for known-flaky steps

Don't retry the whole job — retry the specific step:

```yaml
- name: Pull image
  uses: nick-fields/retry@<sha>
  with:
    timeout_seconds: 60
    max_attempts: 3
    command: docker pull ghcr.io/org/test-runner:latest
```

For test flakiness, retry **at the test framework level** (JUnit `@RetryingTest`, TestNG retry analyzer, Playwright `retries`), not at the workflow level. Workflow-level retry hides which test was flaky.

### Fail-fast in matrix — usually false for tests

```yaml
strategy:
  fail-fast: false   # see all shard failures, not just the first
  matrix:
    shard: [1, 2, 3, 4]
```

The opposite holds for **build** matrices (different OS / JDK combos for a library) — there `fail-fast: true` saves runner time.

---

## QA-Specific Patterns

### Test reporting

The current community standard for JUnit XML rendering as PR check is `dorny/test-reporter` (verified: experimental Java-JUnit support, requires source dir to match package name for code annotations). Maximum report size is 65535 bytes (Markdown).

```yaml
- name: Test Report
  if: ${{ !cancelled() }}
  uses: dorny/test-reporter@<sha>
  with:
    name: Unit Tests
    path: '**/build/test-results/test/*.xml'
    reporter: java-junit
    fail-on-error: true
```

For richer reports (history, trends, attachments), use Allure with `actions/upload-pages-artifact` + `actions/deploy-pages` to publish to GitHub Pages, or upload as a regular artifact.

### Failure artifacts — screenshots, videos, traces

Upload only on failure, scoped per-test:

```yaml
- name: Upload failure artifacts
  if: failure()
  uses: actions/upload-artifact@<sha>
  with:
    name: failure-artifacts-shard-${{ matrix.shard }}
    path: |
      build/reports/
      build/test-results/
      build/playwright-traces/
    retention-days: 14
    if-no-files-found: ignore
```

For Playwright: `trace: 'retain-on-failure'`.

### Allure aggregation across shards

```yaml
publish-allure:
  needs: test
  if: ${{ !cancelled() }}
  runs-on: ubuntu-latest
  steps:
    - uses: actions/download-artifact@<sha>
      with:
        pattern: allure-results-*
        path: allure-results
        merge-multiple: true
    - uses: simple-elf/allure-report-action@<sha>
      with:
        gh_pages: gh-pages
        allure_results: allure-results
        allure_history: allure-history
```

### Browser caching for UI tests

```yaml
- uses: actions/cache@v5
  id: pw-cache
  with:
    path: ~/.cache/ms-playwright
    key: ${{ runner.os }}-pw-${{ hashFiles('**/package-lock.json') }}
- if: steps.pw-cache.outputs.cache-hit != 'true'
  run: npx playwright install --with-deps chromium
- if: steps.pw-cache.outputs.cache-hit == 'true'
  run: npx playwright install-deps   # OS deps still need install
```

---

## AI Review Workflows — `claude-code-action` Configuration

When using `anthropics/claude-code-action` for automated PR review (triggered by `pull_request` event, not `@claude` mention), three settings are required or the job exits 0 silently with no comment posted.

### 1. Write permissions — mandatory for automated mode

The action uses `GITHUB_TOKEN` to post the review comment. With only `read`, the API call is rejected silently:

```yaml
permissions:
  contents: read
  pull-requests: write   # required to post PR comments
  issues: write          # required — PR comments are created via the Issues API endpoint
  id-token: write        # for OAuth token exchange
```

### 2. Tool allowlist via `claude_args`

In CI mode, `Bash` is blocked by default. Claude needs explicit allow rules to read the PR diff and post the review:

```yaml
with:
  claude_args: '--allowedTools "Read,Glob,Grep,Bash(gh pr *)"'
```

`Bash(gh pr *)` covers `gh pr diff`, `gh pr comment`, `gh pr view`. Without an allowlist, Claude attempts the calls, hits permission denials, and exits without posting.

Scope Bash rules to the exact commands the prompt needs — never allow bare `Bash` with a deny-list on top: deny-lists are bypassable (`sh -c "..."`, full binary paths, interpreters like `python3 -c`). Rules match by prefix; both `Bash(gh pr *)` (space form) and `Bash(gh pr:*)` (colon form) work.

Two prompt-side traps when narrowing the allowlist:
- Shell operators split a command into parts that are permission-checked individually — `find ... || true` is denied unless `true` is also allowed; drop the `|| true`.
- A command wrapped in `if ...; then` starts with `if` and no longer matches `Bash(gh pr comment:*)` — move conditional logic into the prompt text ("if the event is not pull_request, skip this step") and keep the command bare.

### 3. Use `prompt`, not `direct_prompt`

The only valid input for instructions is `prompt`. `direct_prompt` does not exist in the action's input schema and produces a validation error:

```yaml
with:
  prompt: |
    Review the changes in this pull request and post a detailed code review comment.
    ...
```

### Silent failure diagnostic

When the job completes in under 60 seconds with no PR comment, inspect the run log for:

```json
"permission_denials_count": 2
```

- `> 0` — Claude ran but hit tool blocks → add `claude_args` allowlist
- `= 0`, no comment — GitHub API rejected the write → check `pull-requests: write`

### Mention mode vs. automated mode — different triggers, different write paths

**Mention mode** workflows (typically triggered by `issue_comment`, `pull_request_review_comment`, `pull_request_review`, `issues`) reply to the existing comment thread using the Claude OAuth token passed as `claude_code_oauth_token:`. The OAuth token carries its own GitHub write capability, so the job runs fine with `pull-requests: read` / `issues: read` — no `GITHUB_TOKEN` write needed.

**Automated review mode** workflows (triggered by `pull_request`) must **create** a new comment on the PR via the `gh` CLI. Comment creation goes through `GITHUB_TOKEN`, which requires `pull-requests: write` AND `issues: write` (PR comments use the Issues API endpoint internally).

If an automated review job exits 0 with no PR comment, check the `permissions:` block first — missing `pull-requests: write` / `issues: write` is the most common cause of silent failure.

---

## Reference Workflow Skeleton

A canonical QA workflow shape — use as the starting structure when scaffolding new pipelines:

```yaml
name: QA — PR
on:
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  checks: write          # for test-reporter
  pull-requests: write   # for PR comment

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-java@<sha>
        with:
          java-version: '17'
          distribution: 'temurin'
          cache: maven
      - run: mvn --batch-mode --no-transfer-progress -DskipTests verify
      - uses: actions/upload-artifact@<sha>
        with:
          name: build-output
          path: target/
          retention-days: 1

  test:
    needs: build
    runs-on: ubuntu-latest
    timeout-minutes: 25
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-java@<sha>
        with:
          java-version: '17'
          distribution: 'temurin'
          cache: maven
      - uses: actions/download-artifact@<sha>
        with:
          name: build-output
          path: target/
      - run: mvn --batch-mode test -Dshard.index=${{ matrix.shard }} -Dshard.total=4
      - uses: actions/upload-artifact@<sha>
        if: ${{ !cancelled() }}
        with:
          name: test-results-${{ matrix.shard }}
          path: target/surefire-reports/
          retention-days: 14

  report:
    needs: test
    if: ${{ !cancelled() }}
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/download-artifact@<sha>
        with:
          pattern: test-results-*
          path: test-results
          merge-multiple: true
      - uses: dorny/test-reporter@<sha>
        with:
          name: JUnit
          path: 'test-results/*.xml'
          reporter: java-junit
          fail-on-error: true
```

> NOTE: every `<sha>` placeholder must be replaced with a real commit SHA before merging. Use Dependabot to keep them updated.
