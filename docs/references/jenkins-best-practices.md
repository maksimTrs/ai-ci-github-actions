# Jenkins — Best Practices for QA Pipelines

**Read this file when:** creating, modifying, or reviewing `Jenkinsfile`, `vars/*.groovy`, `src/**/*.groovy` (shared library), `resources/**`, or making decisions about agents, credentials, parallel execution, or test reporting in Jenkins.

This file fills a gap left by the user-level skill `devops-ci-review` — that skill covers GitHub Actions and Docker but does **not** cover Jenkins. Use this file as the Jenkins counterpart, organized by the same 6 dimensions for cross-platform consistency.

Sources verified against [jenkins.io documentation](https://www.jenkins.io/doc/book/pipeline/) and current production-pipeline references.

---

## DIM-1 — Pipeline Structure

### Declarative > Scripted

Declarative is the **default** for new pipelines. It gives stage visualization, structured `post` actions, the `options { }` block, and validation. Scripted (`node { ... }`) is an escape hatch for things Declarative can't express — wrap escapes in a `script { ... }` block inside a Declarative stage rather than going fully scripted.

```groovy
// GOOD — declarative
pipeline {
  agent { label 'linux && jdk17' }
  options {
    timeout(time: 30, unit: 'MINUTES')
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds(abortPrevious: true)
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
  }
  stages {
    stage('Build') { steps { sh 'mvn -B -DskipTests verify' } }
  }
  post {
    always { junit '**/target/surefire-reports/*.xml' }
    cleanup { cleanWs() }
  }
}
```

### `options { }` block — non-negotiable for production pipelines

| Option | Why |
|---|---|
| `timeout(time: N, unit: 'MINUTES')` | Default is **unlimited**. A hung pipeline blocks an executor forever. |
| `timestamps()` | Log lines without timestamps are useless when debugging long-running QA jobs. |
| `ansiColor('xterm')` | Test runners emit ANSI color; without this, logs are unreadable. Requires AnsiColor plugin. |
| `disableConcurrentBuilds(abortPrevious: true)` | Mirrors GHA `concurrency.cancel-in-progress` — supersedes obsolete PR builds. |
| `buildDiscarder(logRotator(...))` | Without it, build history grows indefinitely → master disk pressure. |
| `skipDefaultCheckout()` | Use only with explicit `checkout scm` in stages where checkout is needed. |

### `triggers { }` — webhooks vs polling

Production Jenkins is typically driven by SCM webhooks (push events fire the pipeline immediately). When webhooks are not viable — local Jenkins behind NAT, developer-workstation instances, environments where GitHub can't reach the controller — fall back to polling:

```groovy
triggers {
  pollSCM('H/2 * * * *')   // hash-distributed every ~2 minutes
}
```

The `H` prefix distributes the actual poll moment across the period **per job** — without `H`, every job hooked to `0 */2 * * *` polls at exactly the top of the period, hammering the SCM server. `H` is Jenkins-specific cron syntax: it deterministically hashes the job name into a slot within the range, so the same job always polls at the same offset but different jobs spread out.

> ОБРАТИ ВНИМАНИЕ: polling burns SCM-API quota and adds latency (up to one poll interval) before a build starts. Use `pollSCM` only when webhooks are unavailable; webhook-driven builds (`triggers { githubPush() }` or the GitHub Branch Source plugin) are faster and lighter.

### Stage-level timeouts for long stages

Pipeline-level timeout is a hard ceiling. Use stage-level timeouts for finer control on flaky stages.

```groovy
stage('UI Tests') {
  options { timeout(time: 20, unit: 'MINUTES') }
  steps { sh './gradlew uiTest' }
}
```

### `parallel` for independent test stages

```groovy
stage('Tests') {
  parallel {
    stage('Unit')   { steps { sh 'mvn -B test' } }
    stage('API')    { steps { sh 'mvn -B verify -Pintegration-tests' } }
    stage('Static') { steps { sh 'mvn -B spotbugs:check' } }
  }
}
```

For dynamic parallel test sharding, see the **QA-Specific Patterns** section below.

### `when` — conditional stages

```groovy
stage('Deploy') {
  when {
    branch 'main'
    expression { currentBuild.result == null || currentBuild.result == 'SUCCESS' }
  }
  steps { /* ... */ }
}
```

`when { }` is preferred over `if`-blocks inside `script { }` because it's visible to the stage view and skipped stages render correctly.

---

## DIM-2 — Caching Strategy

Jenkins has no built-in dependency cache action — caching is workspace-shaped or external.

### Pattern A — persistent agent workspace (simplest)

If the agent is long-lived (static label or long-running pod), `~/.m2/repository` and `~/.gradle/caches` persist across builds naturally. Just don't run `mvn clean install -U` (that forces a redownload of releases).

### Pattern B — `cache` step from the Job Cacher plugin

The Job Cacher plugin (jenkinsci org) provides a workspace-scoped cache step — the closest Jenkins equivalent to GHA's `actions/cache`. Cache freshness is driven by `cacheValidityDecidingFile` (a lockfile-style glob), playing the role GHA's `hashFiles()` plays in the cache key:

```groovy
stage('Build') {
  steps {
    cache(maxCacheSize: 250, caches: [
      arbitraryFileCache(path: "${env.HOME}/.m2/repository",
                         cacheValidityDecidingFile: '**/pom.xml')
    ]) {
      sh 'mvn -B -DskipTests verify'
    }
  }
}
```

> NOTE: an alternative is the Pipeline Cache plugin (`j3t/jenkins-pipeline-cache-plugin`), which mirrors GHA semantics directly (`key:` / `restoreKeys:` / `hashFiles()`) but requires an S3-compatible storage backend and lives in a personal repo. Job Cacher is the jenkinsci-org option — default to it.

### Pattern C — external cache (S3 / shared volume)

For ephemeral Kubernetes agents, neither A nor B work — agents are destroyed after the build. Cache to S3 via `withAWS` + `s3Upload`/`s3Download`, or mount a shared persistent volume into the agent template:

```groovy
// Kubernetes plugin DSL — pod-level volume, mounted into every container of the pod
podTemplate(volumes: [
  persistentVolumeClaim(claimName: 'maven-cache',
                        mountPath: '/home/jenkins/.m2/repository')
]) {
  // node / container blocks here
}
```

For QA pipelines on Kubernetes, **Pattern C is usually right** — ephemeral agents give isolation, the cache PVC gives speed. Document the choice in `Jenkinsfile`.

### Anti-pattern — `mvn install` in CI

`mvn install` writes to local repo, polluting cache across builds and risking version conflicts. Use `mvn verify` for CI:

```groovy
sh 'mvn -B -ntp verify'   // -ntp = no transfer progress (cleaner logs)
```

---

## DIM-3 — Security & Secrets

### `withCredentials { }` — the only correct way to consume secrets

Never put credentials in `environment { FOO = 'bar' }` or interpolate them into shell strings.

```groovy
// BAD — leaks into build log
environment {
  API_TOKEN = credentials('api-token')
}
steps {
  sh "curl -H 'Authorization: ${API_TOKEN}' ..."
}

// GOOD
steps {
  withCredentials([string(credentialsId: 'api-token', variable: 'API_TOKEN')]) {
    sh '''
      curl -H "Authorization: $API_TOKEN" ...
    '''
  }
}
```

Use **single-quoted** shell strings (`'''…'''`) inside `withCredentials` so Groovy doesn't interpolate the secret into the string before the shell runs. Single-quote keeps `$API_TOKEN` as a literal that the shell expands at runtime, where Jenkins' secret masker can suppress it from logs.

### Credential types — pick the right one

| Type | Use for |
|---|---|
| `string` | Simple tokens (API keys, JWTs) |
| `usernamePassword` | Basic-auth credentials, Docker registry login |
| `sshUserPrivateKey` | Git over SSH, deploy keys |
| `file` | TLS certs, kubeconfig, service account JSON |
| `certificate` | PKCS#12 stores |

### Pin shared library versions

```groovy
// BAD — floats on master, supply-chain risk
@Library('qa-shared') _

// GOOD — pinned to a tag or SHA
@Library('qa-shared@v1.4.2') _
@Library('qa-shared@a1b2c3d4') _
```

Library versions can also be pinned in **Jenkins → Configure System → Global Pipeline Libraries** with **Allow default version to be overridden = false** to prevent runtime override of trusted libraries.

### Script approval and sandbox

Trusted libraries (configured globally) bypass the Groovy sandbox. Untrusted libraries (loaded inline via `library('foo')` from a job) run sandboxed and may trigger script approval requests. **Never** disable the sandbox on shared libraries — anything that needs `@NonCPS` or unsafe APIs should live in a trusted library.

### Job-level credential scoping

Use folder-scoped credentials when a credential should only be visible to specific jobs. Avoid global credentials for production secrets; the blast radius is the entire Jenkins instance.

---

## DIM-4 — Shared Libraries

### Standard structure (verified from jenkins.io docs)

```
(root)
├── src/                       # Groovy classes (full Java-style packages)
│   └── org/qa/
│       ├── ApiClient.groovy
│       └── ReportPublisher.groovy
├── vars/                      # Global pipeline steps (camelCase filename = step name)
│   ├── runQaSuite.groovy      # used as: runQaSuite(...)
│   ├── runQaSuite.txt         # help text shown in Global Variables Reference
│   └── publishAllure.groovy
└── resources/                 # Static files loaded via libraryResource step
    └── org/qa/
        └── default-junit-template.xml
```

- Files in `vars/` define **global steps**. Filename `runQaSuite.groovy` → callable as `runQaSuite(env: 'staging')`.
- Files in `src/` are classes loaded via `import`.
- Files in `resources/` are loaded via `libraryResource('org/qa/default-junit-template.xml')`. Internal libraries don't support this — only external (separate Git repo) libraries do.

### `vars/foo.groovy` skeleton

> ОБРАТИ ВНИМАНИЕ: avoid `(1..n).collectEntries { ... }` / `.each { ... }` inside pipelines — Groovy's CPS transformation may serialize closures across `node {}` boundaries and trigger `NotSerializableException`. Prefer plain `for` loops with a Map accumulator, and capture the loop counter into a local `def` so the closure binds to the captured value, not the mutating loop variable.

```groovy
// vars/runQaSuite.groovy
def call(Map config) {
  def env       = config.env       ?: error('env is required')
  def shards    = config.shards    ?: 4
  def reportTo  = config.reportTo  ?: 'allure'

  stage('Run QA Suite') {
    def stages = [:]
    for (int shard = 1; shard <= shards; shard++) {
      def s = shard  // capture into local — closure must not close over mutating loop var
      stages["shard-${s}"] = {
        node('linux && jdk17') {
          checkout scm
          sh "./gradlew test -Dshard.index=${s} -Dshard.total=${shards} -Penv=${env}"
          stash(name: "junit-${s}", includes: 'build/test-results/**/*.xml')
        }
      }
    }
    parallel stages
  }
}
```

### Test the library — JenkinsPipelineUnit

Don't ship shared library code without tests. [`jenkinsci/JenkinsPipelineUnit`](https://github.com/jenkinsci/JenkinsPipelineUnit) is the standard Groovy DSL test harness — it stubs `sh`, `node`, `stage`, `parallel`, and most Jenkins steps so library code can be exercised without a live Jenkins instance.

```groovy
// src/test/groovy/RunQaSuiteSpec.groovy
class RunQaSuiteSpec extends BasePipelineTest {
  @Test void runs_parallel_shards() {
    def script = loadScript('vars/runQaSuite.groovy')
    script.call(env: 'staging', shards: 2)
    assertJobStatusSuccess()
    // assertions on the recorded call sequence
  }
}
```

CI for the shared library itself should run these unit tests — the QA pipeline depends on the library, so the library needs its own pipeline.

### Library size discipline

> ⚠ Source warning: *"Avoid overusing shared libraries — large shared libraries, especially for concurrent tasks, are a drain on system resources."*

Keep `vars/` files small (one responsibility per file). Move heavy logic to `src/` classes. Don't load the whole library on every job — `@Library('qa-shared@v1.4.2') _` loads everything; consider `library('qa-shared@v1.4.2').foo` for selective imports if cold-start time matters.

---

## DIM-5 — Resource Efficiency

### `agent` strategy — labels, not `agent any`

```groovy
// BAD — runs on whatever's free, including underpowered agents
agent any

// GOOD — pin to a label that matches required tools
agent { label 'linux && jdk17 && docker' }
```

Use compound labels (`a && b`) to match agents with multiple capabilities. For ephemeral container agents on Kubernetes, define pod templates per-job:

```groovy
agent {
  kubernetes {
    yaml '''
      apiVersion: v1
      kind: Pod
      spec:
        containers:
          - name: jdk
            image: eclipse-temurin:17-jdk
            command: ['cat']
            tty: true
            resources:
              requests: { cpu: 500m, memory: 1Gi }
              limits:   { cpu: 2,    memory: 4Gi }
    '''
  }
}
```

### `agent none` at pipeline level for parallel pipelines

When stages need different agents, declare `agent none` at the top and assign per stage:

```groovy
pipeline {
  agent none
  stages {
    stage('Build') {
      agent { label 'jdk17' }
      steps { sh 'mvn -B -DskipTests verify' }
    }
    stage('Test') {
      agent { label 'jdk17 && browsers' }
      steps { sh 'mvn -B test' }
    }
  }
}
```

Don't waste a heavy `browsers` agent for a build stage that doesn't need it.

### Docker agents — DooD pattern for compose-based pipelines

When a stage needs to orchestrate `docker compose` (start an app stack, run tests against it, tear it down), the agent has to control the **host** Docker daemon — not run a daemon inside the build container. The DooD (Docker outside of Docker) pattern mounts the host's Docker socket into the agent:

```groovy
stage('Launch Application') {
  agent {
    docker {
      image 'docker:27.5.1'
      reuseNode true
      args '-v /var/run/docker.sock:/var/run/docker.sock -u 0'
    }
  }
  steps {
    sh 'docker compose up --build --wait --wait-timeout 60'
  }
}
```

Key elements:
- `-v /var/run/docker.sock:/var/run/docker.sock` — DooD mount; the agent's `docker` CLI talks to the host daemon, so compose-built containers are siblings of the agent, not children
- `-u 0` — root inside the agent container is required to access the socket file (owned by `root:docker` on the host; non-root user has no group membership inside an arbitrary base image)
- `reuseNode true` — share workspace with the outer Jenkins node; without it, the Docker agent gets a fresh empty workspace and `checkout scm` would have to run again

> ОБРАТИ ВНИМАНИЕ: DooD gives compose-built containers full access to the host filesystem and to every other container on the host. Treat the workload as if it were running directly on the host — there is no isolation between the agent and host Docker resources. **Never use DooD on shared Jenkins controllers where untrusted PRs run** — a malicious PR can mount `/`, exfiltrate credentials, or destroy other containers.

> ЗАМЕТКА: the alternative is **DinD (Docker in Docker)** — `docker:27-dind` as a sidecar — which gives true isolation but is heavier (separate daemon, no shared image cache with the host, more setup). DooD is the right default for single-tenant CI; DinD for multi-tenant or untrusted code execution.

### Inline `agent { docker { ... } }` per stage

When the pipeline needs different toolchains per stage and Kubernetes is overkill, inline Docker agents are the simplest path — each stage runs in its own pinned image without polluting the host:

```groovy
pipeline {
  agent none
  stages {
    stage('Backend') {
      agent {
        docker {
          image 'snakee/golang-junit:1.21'
          reuseNode true
          args '-u root'
        }
      }
      steps { sh 'go test ./...' }
    }
    stage('Frontend') {
      agent {
        docker {
          image 'node:20-alpine'
          reuseNode true
          args '-v $HOME/.npm:/root/.npm'   // mount host npm cache across builds
        }
      }
      steps { sh 'npm ci && npm test' }
    }
  }
}
```

> ЛУЧШАЯ ПРАКТИКА: `reuseNode true` plus host-volume mounts (`$HOME/.npm`, `$HOME/.gradle/caches`, `$HOME/.m2/repository`) recover what Kubernetes pod templates give for free — dependency-cache persistence across builds without external storage. Always pin the image tag (`node:20-alpine`, not `node:alpine`) for reproducibility — `alpine` and `latest` drift silently.

### Workspace cleanup — `cleanWs()` in `post { cleanup { } }`

```groovy
post {
  cleanup {
    cleanWs(deleteDirs: true,
            patterns: [[pattern: '.gradle', type: 'EXCLUDE']])
  }
}
```

`cleanup` runs after `always`/`success`/`failure` and is the right place for disk hygiene. Without it, agent disks fill up — common cause of mysterious "out of space" failures weeks into a pipeline's life.

### Stash size discipline

`stash`/`unstash` round-trips through the Jenkins controller. **Don't stash `target/` or `node_modules/`.** Use `archiveArtifacts` for results that need to be downloaded; use a shared workspace or external storage (S3) for large intermediate files.

---

## DIM-6 — Reliability

### `post { }` conditions — semantics

```groovy
post {
  always   { /* always — including aborted/cancelled */ }
  success  { /* only if pipeline succeeded */ }
  failure  { /* only on failure */ }
  unstable { /* only on UNSTABLE (e.g., test failures with junit step) */ }
  aborted  { /* user clicked Abort or timeout fired */ }
  fixed    { /* this build success after previous failure */ }
  regression { /* this build failed after previous success */ }
  cleanup  { /* after all of the above — workspace cleanup */ }
}
```

Reporting goes in `always`. Disk cleanup goes in `cleanup`. Notifications go in `success`/`failure`/`fixed`/`regression` for noise reduction.

### `junit` step — `keepProperties: true` and `allowEmptyResults: false`

```groovy
post {
  always {
    junit testResults: '**/target/surefire-reports/*.xml',
          allowEmptyResults: false,    // fail if no test results found
          keepLongStdio: true,
          skipPublishingChecks: false
  }
}
```

`allowEmptyResults: false` catches the silent failure where the test runner crashed before writing XML. Without this flag, a test runner crash looks like "no tests, all green."

### `retry { }` step — only at boundaries

```groovy
stage('Pull image') {
  steps {
    retry(3) {
      sh 'docker pull ghcr.io/org/test-runner:latest'
    }
  }
}
```

Like in GHA — retry network-flaky steps, not flaky tests. Test flakiness retries belong in the test framework.

### `timeout` + `retry` combination

```groovy
retry(3) {
  timeout(time: 1, unit: 'MINUTES') {
    sh 'curl -fsS https://api.example.com/health'
  }
}
```

Time-bound each retry attempt so a hanging dependency doesn't consume the full pipeline timeout.

### `catchError` — fail-soft for non-critical stages

```groovy
stage('Code Quality') {
  steps {
    catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
      sh 'mvn -B spotbugs:check'
    }
  }
}
```

Code-quality findings shouldn't fail the build, but they should mark it UNSTABLE. `catchError` lets you classify the severity.

---

## QA-Specific Patterns

### Test result publishing — `junit` + `publishHTML` + Allure

```groovy
post {
  always {
    junit testResults: '**/build/test-results/**/*.xml',
          allowEmptyResults: false

    publishHTML(target: [
      allowMissing:          false,
      alwaysLinkToLastBuild: true,
      keepAll:               true,
      reportDir:             'build/reports/tests/test',
      reportFiles:           'index.html',
      reportName:            'JUnit HTML Report',
      reportTitles:          ''
    ])

    archiveArtifacts artifacts: 'build/reports/**, build/test-results/**',
                     allowEmptyArchive: true,
                     onlyIfSuccessful: false   // KEY: also keep on failure
  }
}
```

> ⚠ `archiveArtifacts onlyIfSuccessful: false` is critical for QA — failure artifacts (screenshots, traces, logs) are MORE important than success artifacts.

### Allure step

Requires Allure Jenkins Plugin:

```groovy
post {
  always {
    allure([
      includeProperties: false,
      jdk:               '',
      properties:        [],
      reportBuildPolicy: 'ALWAYS',
      results:           [[path: 'build/allure-results']]
    ])
  }
}
```

Allure aggregates trends across builds. Set `keepAll: true` for HTML or use Allure's built-in history.

### Parallel test sharding — two approaches

**Approach A — static manual sharding (simple, predictable)**

```groovy
stage('Tests') {
  steps {
    script {
      def stages = [:]
      for (int shard = 1; shard <= 4; shard++) {
        def s = shard  // capture for closure (CPS-safe)
        stages["shard-${s}"] = {
          node('linux && jdk17') {
            checkout scm
            unstash 'build'
            sh "./gradlew test -Dshard.index=${s} -Dshard.total=4"
            stash(name: "junit-${s}", includes: 'build/test-results/**/*.xml')
          }
        }
      }
      parallel stages
    }
  }
}
```

**Approach B — `splitTests` from Parallel Test Executor plugin (auto-balanced)**

The plugin analyzes test execution time from the last successful build and splits into roughly equal chunks. Better for evolving suites where some tests grow slow:

```groovy
stage('Tests') {
  steps {
    script {
      def splits = splitTests(
        parallelism: count(4),
        generateInclusions: true
      )
      def parallelStages = [:]
      splits.eachWithIndex { split, i ->
        parallelStages["shard-${i + 1}"] = {
          node('linux && jdk17') {
            checkout scm
            writeFile file: "build/parallel/${split.includes ? 'includes' : 'excludes'}.txt",
                      text: split.list.join('\n')
            sh './gradlew test'
          }
        }
      }
      parallel parallelStages
    }
  }
}
```

**Approach A** for first delivery (simple, no plugin dependency). Migrate to **Approach B** when shards become uneven (one shard takes 2× longer than others).

### Aggregating shard results

After parallel sharding, gather all JUnit XML on a single node before publishing:

```groovy
stage('Aggregate') {
  steps {
    script {
      for (int shard = 1; shard <= 4; shard++) {
        unstash "junit-${shard}"
      }
    }
  }
}
```

Then `junit` and `publishHTML` run once over all results.

### Failure artifacts — screenshots, videos, traces

```groovy
post {
  failure {
    archiveArtifacts artifacts: 'build/reports/screenshots/**, build/reports/videos/**, build/playwright-traces/**',
                     allowEmptyArchive: true,
                     fingerprint: false
  }
}
```

For Playwright: `trace: 'retain-on-failure'`. Mirror the GHA artifact pattern for consistency.

---

## Reference `Jenkinsfile` Skeleton

A canonical QA pipeline shape — use as the starting structure when scaffolding a new pipeline. Equivalent to the GHA reference workflow in `github-actions-best-practices.md`.

```groovy
@Library('qa-shared@v1.4.2') _

pipeline {
  agent none

  options {
    timeout(time: 45, unit: 'MINUTES')
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds(abortPrevious: true)
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
  }

  parameters {
    choice(name: 'TEST_ENV', choices: ['staging', 'preprod'], description: 'Target environment')
    string(name: 'SHARDS', defaultValue: '4', description: 'Test shards')
  }

  stages {
    stage('Build') {
      agent { label 'linux && jdk17' }
      steps {
        checkout scm
        sh 'mvn -B -ntp -DskipTests verify'
        stash name: 'build', includes: 'target/**'
      }
    }

    stage('Tests') {
      steps {
        script {
          def shards = params.SHARDS.toInteger()
          def stages = [:]
          for (int shard = 1; shard <= shards; shard++) {
            def s = shard  // capture for closure — required for CPS-safe parallel
            stages["shard-${s}"] = {
              node('linux && jdk17') {
                checkout scm
                unstash 'build'
                withCredentials([string(credentialsId: 'qa-api-token', variable: 'API_TOKEN')]) {
                  sh """
                    mvn -B -ntp test \
                      -Dshard.index=${s} \
                      -Dshard.total=${shards} \
                      -Denv=${params.TEST_ENV}
                  """
                }
                stash(name: "junit-${s}",
                      includes: 'target/surefire-reports/**, target/allure-results/**',
                      allowEmpty: true)
              }
            }
          }
          parallel stages
        }
      }
    }

    stage('Aggregate & Report') {
      agent { label 'linux' }
      steps {
        script {
          def shards = params.SHARDS.toInteger()
          for (int i = 1; i <= shards; i++) {
            unstash "junit-${i}"
          }
        }
      }
      post {
        always {
          junit testResults: 'target/surefire-reports/*.xml',
                allowEmptyResults: false
          allure([
            reportBuildPolicy: 'ALWAYS',
            results:           [[path: 'target/allure-results']]
          ])
          archiveArtifacts artifacts: 'target/reports/**, target/surefire-reports/**',
                           allowEmptyArchive: true,
                           onlyIfSuccessful: false
        }
      }
    }
  }

  post {
    failure {
      echo "Pipeline failed — see HTML report and archived artifacts."
      // notify Slack/email here, scoped to fixed/regression for noise reduction
    }
    cleanup {
      node('linux') { cleanWs(deleteDirs: true) }
    }
  }
}
```

> NOTE: the `cleanup` block needs an explicit `node` because the pipeline runs `agent none` — there's no implicit executor for cleanup unless you allocate one. Steps like `cleanWs`, `sh`, and `script` fail with "Required context class hudson.FilePath is missing" / "step that requires a node context while agent none was specified" without one. The `node` step's label parameter is optional — bare `node {}` (any available executor) and `node('linux') {}` (a specific label) are both valid here. Prefer a label that matches an executor with the tools cleanup needs; use bare `node {}` only when any executor will do. (The "label is required" rule applies to the `agent { node { label '...' } }` *directive*, not to the `node` step used inside `post`/`script`.)
