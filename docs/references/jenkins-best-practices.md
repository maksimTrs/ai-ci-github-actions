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

### Pattern B — `cache` step from Pipeline Utility Steps plugin

Pipeline Utility Steps provides a workspace-scoped cache:

```groovy
stage('Build') {
  steps {
    cache(path: "${env.HOME}/.m2/repository",
          key: "${env.JOB_NAME}-m2-${hashFiles('**/pom.xml')}",
          restoreKeys: ["${env.JOB_NAME}-m2-"]) {
      sh 'mvn -B -DskipTests verify'
    }
  }
}
```

> NOTE: Plugin support for `cache` step API surface varies by version. Check `Pipeline Utility Steps` ≥ 2.16 for `restoreKeys` support.

### Pattern C — external cache (S3 / shared volume)

For ephemeral Kubernetes agents, neither A nor B work — agents are destroyed after the build. Cache to S3 via `withAWS` + `s3Upload`/`s3Download`, or mount a shared persistent volume into the agent template:

```yaml
# In pod template
volumes:
  - persistentVolumeClaim:
      claimName: maven-cache
      mountPath: /home/jenkins/.m2/repository
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

```groovy
// vars/runQaSuite.groovy
def call(Map config) {
  def env       = config.env       ?: error('env is required')
  def shards    = config.shards    ?: 4
  def reportTo  = config.reportTo  ?: 'allure'

  stage('Run QA Suite') {
    parallel(
      (1..shards).collectEntries { shard ->
        ["shard-${shard}": {
          node('linux && jdk17') {
            checkout scm
            sh "./gradlew test -Dshard.index=${shard} -Dshard.total=${shards} -Penv=${env}"
            stash(name: "junit-${shard}", includes: 'build/test-results/**/*.xml')
          }
        }]
      }
    )
  }
}
```

### Test the library — JenkinsPipelineUnit

Don't ship shared library code without tests. JenkinsPipelineUnit (`/jenkinsci/jenkinspipelineunit`, benchmark score 91.1) provides Groovy DSL mocking for `sh`, `node`, `stage`, etc.

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
  parallel(
    (1..4).collectEntries { shard ->
      ["shard-${shard}": {
        node('linux && jdk17') {
          checkout scm
          unstash 'build'
          sh "./gradlew test -Dshard.index=${shard} -Dshard.total=4"
          stash(name: "junit-${shard}", includes: 'build/test-results/**/*.xml')
        }
      }]
    }
  )
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
    (1..4).each { shard -> unstash "junit-${shard}" }
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

For Selenide: configure `Configuration.reportsFolder = 'build/reports/screenshots'`. For Playwright: `trace: 'retain-on-failure'`. Mirror the GHA artifact pattern for consistency.

---

## Reference `Jenkinsfile` Skeleton

A canonical QA pipeline shape for this project — use as the starting structure when scaffolding a new pipeline. Equivalent to the GHA reference workflow in `github-actions-best-practices.md`.

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
          parallel(
            (1..shards).collectEntries { shard ->
              ["shard-${shard}": {
                node('linux && jdk17') {
                  checkout scm
                  unstash 'build'
                  withCredentials([string(credentialsId: 'qa-api-token', variable: 'API_TOKEN')]) {
                    sh """
                      mvn -B -ntp test \
                        -Dshard.index=${shard} \
                        -Dshard.total=${shards} \
                        -Denv=${params.TEST_ENV}
                    """
                  }
                  stash(name: "junit-${shard}",
                        includes: 'target/surefire-reports/**, target/allure-results/**',
                        allowEmpty: true)
                }
              }]
            }
          )
        }
      }
    }

    stage('Aggregate & Report') {
      agent { label 'linux' }
      steps {
        script {
          def shards = params.SHARDS.toInteger()
          (1..shards).each { unstash "junit-${it}" }
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

> NOTE: the `cleanup` block needs an explicit `node` because the pipeline runs `agent none` — there's no implicit executor for cleanup unless you allocate one. Use `node('') {}` (empty string = any available executor), NOT bare `node {}` — the declarative parser requires an explicit label parameter and fails at compile time with "Missing required parameter: label" otherwise.
