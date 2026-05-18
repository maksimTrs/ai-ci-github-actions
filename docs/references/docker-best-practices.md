# Docker & Compose — Best Practices for QA Pipelines

**Read this file when:** creating, modifying, or reviewing `Dockerfile*`, `docker-compose*.yml`, `compose.y?ml`, or `.dockerignore` — for application images, test runner images, or CI service stacks.

This file is the Docker counterpart to `github-actions-best-practices.md` and `jenkins-best-practices.md`, organized by the same 6 dimensions (DIM-1..6) for cross-platform consistency. It is sourced from the user-level skill `devops-ci-review` (`references/docker.md`) and adapted with QA-specific patterns relevant to this repo — multi-service compose stacks, ephemeral test-runner containers, and bind-mounted artifact extraction.

Sources verified against [docs.docker.com](https://docs.docker.com/build/building/best-practices/) and current production-image references.

---

## DIM-1 — Build Structure

### Multi-stage builds — separate build-time and runtime

The final image should contain only what's needed to run the application. Move compilers, dev dependencies, and build tools to a discarded build stage:

```dockerfile
# Stage 1 — build
FROM node:20-slim AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2 — production
FROM node:20-slim AS production
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev
COPY --from=builder /app/dist ./dist
USER node
EXPOSE 3000
CMD ["node", "dist/index.js"]
```

**Key principles:**
- Build stage can be fat (compilers, dev deps, build tools) — it's discarded
- Production stage should be minimal — only runtime deps and built artifacts
- Use named stages (`AS builder`) for clarity and selective builds (`docker build --target builder`)
- Prefer `npm ci --omit=dev` in the production stage over `COPY --from=builder /app/node_modules` — gives a clean dependency tree without dev deps

### When single-stage is fine

Multi-stage is the default, but it's not always the right tool:

- Simple scripts or CLI tools with no build step
- Development containers (compose dev environment)
- Test runner images that need the full toolchain at runtime (e.g., Playwright with browsers)
- Images that need compilers or system tools to be present (e.g., native module rebuilds)

Single-stage with `USER node` for production services, and root-user single-stage for ephemeral test runners — both acceptable. See QA-Specific Patterns below.

### COPY order — predictable cache behavior

Order instructions from least-frequently-changed to most-frequently-changed:

```dockerfile
FROM node:20-slim
WORKDIR /app

# 1. System deps (rare changes) — chain install + cleanup in one RUN
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# 2. App dependencies (changes when lockfile changes)
COPY package*.json ./
RUN npm ci --omit=dev

# 3. Source code (changes on every commit)
COPY . .

# 4. Build step
RUN npm run build
```

**The critical pattern:** copy `package*.json` first, run `npm ci`, then copy source. This way the `npm ci` layer is cached unless dependencies actually change — even when source code changes on every commit.

---

## DIM-2 — Caching Strategy

### Local Docker layer cache

Docker caches each instruction's output. When an instruction's input changes, it and all subsequent layers are rebuilt. The COPY order pattern above is the primary lever — get it right and most builds hit cache on everything except the final source-copy layer.

**Cache busters to watch for:**

- `COPY . .` before `npm ci` — busts cache on every code change
- `ARG` or `ENV` before `RUN` — any value change invalidates all layers below
- Timestamp-based operations (`RUN date > /build-time`) — always busts cache
- `ADD` with remote URLs — re-fetches every build (use `RUN curl` instead)

### CI-side layer caching (GitHub Actions)

Docker layer cache does not persist between CI runs by default. Two production-grade options:

**Option 1 — GitHub Actions cache backend (simplest):**

```yaml
- uses: docker/build-push-action@<sha>  # v5
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

GHA cache has a 10GB per-repo limit and 7-day eviction on inactivity — fine for most pipelines.

**Option 2 — Registry-based caching (shared across repos / faster on warm runs):**

```yaml
- uses: docker/build-push-action@<sha>  # v5
  with:
    cache-from: type=registry,ref=ghcr.io/org/app:cache
    cache-to: type=registry,ref=ghcr.io/org/app:cache,mode=max
```

Pushes cache as a separate registry tag — works across forks, branches, and repos but requires registry write access.

> NOTE: `mode=max` exports cache for ALL stages (including discarded build stage). Without it, only the final stage is cached — defeats the multi-stage caching point.

### BuildKit cache mounts — for package manager caches inside RUN

```dockerfile
# syntax=docker/dockerfile:1.6
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev
```

`--mount=type=cache` is BuildKit-only and not persisted in the image layer — perfect for npm/pip/apt caches that you want to reuse across builds without bloating the image.

> NOTE: Cache mounts require the BuildKit-compatible `# syntax=docker/dockerfile:1.6` header (or newer). Without it, the parser may not recognize `--mount`.

---

## DIM-3 — Security & Secrets

### Pin base images — at least to minor version

```dockerfile
# Bad — unpredictable, breaks reproducibility
FROM node:latest
FROM node:20

# Good — predictable
FROM node:20.11-slim
FROM node:20-slim@sha256:abc123...   # most reproducible
```

Pin at least to minor version (`20.11`). SHA pinning is most reproducible but adds maintenance overhead — minor version pinning is the practical default for CI images, SHA pinning is preferred for production runtime images.

### `.dockerignore` — non-negotiable

Every Dockerfile needs a `.dockerignore`. Missing it is a security issue (secrets in build context) AND a performance issue (huge context sent to daemon every build):

```dockerignore
# Version control — can be hundreds of MB, leaks commit history
.git
.gitignore

# Dependencies — reinstalled in container, may be platform-incompatible
node_modules

# Build outputs — rebuilt in container
dist
build

# Test artifacts — no reason in production image
test-results
playwright-report
coverage

# IDE and OS files
.vscode
.idea
*.swp
.DS_Store

# CI/CD files — not needed inside the image
.github
.gitlab-ci.yml
Jenkinsfile

# Environment files — secrets leak into build context
.env
.env.*
!.env.example

# Documentation
*.md
LICENSE
```

**Impact of missing `.dockerignore`:** every `COPY . .` sends the entire build context to the Docker daemon. A 500MB `node_modules` + 200MB `.git` turns a 5-second build into a 30-second build even when nothing changed. Worse, `.env` files get included in the context and may end up in layers.

### Build args vs build secrets

```dockerfile
# Build args — visible in `docker history`, OK for non-sensitive config
ARG NODE_ENV=production
ENV NODE_ENV=$NODE_ENV
RUN npm ci --omit=dev
```

```dockerfile
# Build secrets — NOT in any layer, NOT in `docker history`
# syntax=docker/dockerfile:1.6
RUN --mount=type=secret,id=npm_token \
    NPM_TOKEN=$(cat /run/secrets/npm_token) npm ci
```

```bash
# Build command — pass the secret at build time
docker build --secret id=npm_token,src=$HOME/.npmrc .
```

> ⚠ Anti-pattern: `ARG NPM_TOKEN` + `RUN echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > .npmrc` — the token is baked into the layer history even if you delete `.npmrc` afterward. Layers are immutable.

### Secrets in Compose — `env_file`, never inline

```yaml
services:
  app:
    environment:
      - NODE_ENV=production           # OK — non-sensitive
    env_file:
      - .env                          # OK — file is gitignored
    # NEVER:
    # environment:
    #   - API_TOKEN=ghp_xxxxxxxxxxxx   # secrets committed to git
```

For production deployments, use Docker secrets (`secrets:` block in Compose v3.1+) or an external secret manager. `env_file` is for dev and CI service stacks; never put real production credentials in `.env`.

### `USER` directive — defense in depth

Long-running services should not run as root:

```dockerfile
FROM node:20-slim
WORKDIR /app
COPY --chown=node:node . .
USER node                 # drop privileges before CMD
CMD ["node", "server.js"]
```

`node:20-slim` ships with a pre-created `node` user (UID 1000). For other base images, create the user explicitly:

```dockerfile
RUN groupadd -r app && useradd -r -g app -u 1000 app
USER app
```

For when `USER` causes more problems than it solves (bind mounts, test runners), see the Non-Root User and Bind Mounts section under QA-Specific Patterns.

---

## DIM-4 — Image Optimization

### Base image variants — pick by use case

| Variant | Size | Use case | Trade-off |
|---------|------|----------|-----------|
| `node:20` (full/bookworm) | ~350MB | Dev containers, when you need system tools | Large, slow pulls |
| `node:20-slim` | ~80MB | Production apps, test runners, CI | Good balance of size, compatibility, debuggability |
| `node:20-alpine` | ~50MB | Minimal containers, simple apps | musl libc — some native modules break |
| `gcr.io/distroless/nodejs20` | ~40MB | Production microservices with max security | No shell, no package manager, no debugging tools |

**Choosing by use case:**

| Use case | Recommended | Why |
|----------|-------------|-----|
| Production web server / API | `slim` or `distroless` | slim for debuggable prod, distroless for max security |
| Test runner / CI executor | `slim` (not distroless, not alpine) | Needs npm/npx, shell for debugging, full glibc for Playwright/native deps |
| CLI tool / batch job | `slim` or `alpine` | slim if native deps, alpine if pure JS |
| Dev container | `full` (bookworm) | Needs compilers, git, debugging tools |
| Single-binary Go/Rust app | `distroless` or `scratch` | No runtime deps, smallest possible image |

### Distroless — when it fits and when it doesn't

Distroless images (`gcr.io/distroless/*`) contain only the runtime — no shell, no package manager, no coreutils. This minimizes attack surface but severely limits operability.

**Distroless is a good fit when:**
- The app is a single binary or a self-contained Node.js bundle
- You never need to `docker exec` into the container for debugging
- The image runs in orchestrated environments with external monitoring
- Security compliance requires minimal attack surface (no shell = no shell exploits)

**Distroless is NOT a good fit when:**
- The container needs `npm`, `npx`, or `node_modules/.bin/*` scripts at runtime
- You need shell access for debugging (`docker exec -it ... /bin/sh` is impossible)
- The app has postinstall scripts or native deps that need system tools
- Test runners, CI executors, dev containers — all need shell and package manager

The size difference vs slim is ~40MB; rarely worth losing debuggability. **For test runners specifically, distroless is a strong no.**

### Chain RUN commands — fewer layers, real cleanup

Each `RUN` creates a layer. Cleanup in the same `RUN` actually reduces size; cleanup in a later `RUN` doesn't (the files still exist in the previous layer):

```dockerfile
# Bad — 3 layers, apt cache persists in layer 1
RUN apt-get update
RUN apt-get install -y curl
RUN rm -rf /var/lib/apt/lists/*

# Good — 1 layer, apt cache cleaned in same layer
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
```

**Reduce what gets installed:**
- `--no-install-recommends` for apt — skip suggested packages
- `npm ci --omit=dev` for Node — skip devDependencies
- `pip install --no-cache-dir` for Python — skip pip's download cache

### `COPY --link` for faster rebuilds (BuildKit)

```dockerfile
# syntax=docker/dockerfile:1.6
COPY --link package*.json ./
COPY --link src ./src
```

`--link` decouples the layer from the previous one — if an earlier layer changes, this layer is NOT rebuilt. Faster rebuilds, especially for COPY-heavy multi-stage images. Available since BuildKit 1.4.

### Size audit — local tools

```bash
docker images myapp                   # check total image size
docker history --no-trunc myapp       # see per-layer size and instruction
dive myapp                            # interactive layer explorer (third-party)
docker scout cves myapp               # CVE scan (Docker Desktop)
docker run --rm -i hadolint/hadolint < Dockerfile   # Dockerfile linter
```

---

## DIM-5 — Resource Efficiency

### Don't install what you don't need

In a production image:
- No dev dependencies (`npm ci --omit=dev`)
- No test fixtures or test data
- No build toolchains (compilers, headers) — that's what the build stage is for
- No documentation (`*.md`, LICENSE) — exclude via `.dockerignore`

In a test runner image:
- No production-only code paths if they bloat the image with extra deps
- No Playwright browsers if only API tests run (`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`)
- No `node_modules` from the host (always reinstall inside the container — host modules may be platform-incompatible)

### Disable lifecycle scripts that have no purpose in containers

Tools like husky, lefthook, and lint-staged install git hooks. They run on `npm install` / `npm ci` but have nothing to hook into inside a container (no `.git`):

```dockerfile
ENV HUSKY=0
RUN npm ci --omit=dev
```

Or use `--ignore-scripts` if no postinstall is needed:

```dockerfile
RUN npm ci --omit=dev --ignore-scripts
```

> NOTE: `--ignore-scripts` is aggressive — some packages need postinstall to compile native code (e.g., `better-sqlite3`, `bcrypt`). Use `HUSKY=0` (or the equivalent flag) when only git-hook tools need to be silenced.

### Image size budget

Track image size in CI as a regression signal. A 50MB jump means somebody added a dep or forgot `--no-install-recommends`. Tools:

- `docker images <name>` in a CI step → fail if size > N MB
- `dive --ci <image>` → fail on wasted-bytes thresholds (efficiency, highest user wasted bytes)

---

## DIM-6 — Reliability

### `HEALTHCHECK` — Dockerfile-level

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD curl -fsS http://localhost:3000/health || exit 1
```

| Parameter | Purpose | Typical value |
|-----------|---------|---------------|
| `--interval` | Time between checks | 15-30s |
| `--timeout` | Max time for a single check | 3-5s |
| `--start-period` | Grace period after start (failures don't count) | 10-30s |
| `--retries` | Consecutive failures before "unhealthy" | 3-5 |

**Check type by service:**

| Type | When to use | Example |
|------|------------|---------|
| HTTP | Web servers, APIs | `curl -fsS http://localhost:3000/health` |
| TCP | Databases, queues | `pg_isready`, `redis-cli ping` |
| CMD | Custom logic | Script that checks multiple conditions |

> NOTE: `wget` may not be installed in slim images — `curl` is more common. For minimal images, consider using the app's own health endpoint via a built-in binary.

### `depends_on` with `condition: service_healthy`

`depends_on` controls startup ORDER, not readiness. A DB container can be "started" before it's accepting connections. Combine with the dependency's `healthcheck:`:

```yaml
services:
  app:
    depends_on:
      db:
        condition: service_healthy    # wait for healthcheck, not just "started"
    environment:
      DATABASE_URL: postgres://user:pass@db:5432/mydb

  db:
    image: postgres:16-alpine
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U user -d mydb"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
```

Without `condition: service_healthy`, the app starts before the DB accepts connections and crashes with a connection-refused error. Common cause of flaky CI test stacks.

### `init: true` — proper signal handling

By default the container's CMD runs as PID 1. In Linux, PID 1 doesn't receive default signal handling — `SIGTERM` from `Ctrl+C` or `docker stop` may be ignored. The container hangs for 10 seconds until Docker sends `SIGKILL`.

```yaml
services:
  app:
    init: true    # adds tini as PID 1 — proper signal forwarding
```

`init: true` adds a lightweight init process (tini) that forwards signals to child processes. Especially important for `npx`, `npm run`, and other wrappers that spawn child processes — without init, the child never receives the signal and stays running.

### Restart policies

```yaml
services:
  app:
    restart: unless-stopped     # restart on crash, but not on `docker compose down`
  one-shot-task:
    restart: "no"               # don't restart batch jobs
```

| Policy | When to use |
|---|---|
| `no` (default) | One-shot tasks, test runners, ephemeral containers |
| `on-failure` | Long-running services where a graceful exit means "done" |
| `unless-stopped` | Production services (recommended default for daemons) |
| `always` | Always-on services where you want restart even after manual stop (rare) |

### Resource limits — prevent runaway containers

```yaml
services:
  app:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 256M
```

In Compose v2+, `deploy.resources` works in non-swarm mode (older docs say it's swarm-only — that's outdated). Without limits, a memory leak in one service can OOM the whole host.

---

## QA-Specific Patterns

### Test runner containers — single-stage, ephemeral, root-OK

Test runners (e.g., Playwright, Cypress, integration test images) have different trade-offs from production app images. They are:

- **Ephemeral** — destroyed after the test run, no persistent attack surface
- **Bind-mount-friendly** — host directories mount in for output extraction (reports, traces, screenshots)
- **Tooling-heavy** — need npm, npx, shell access, full glibc for browser dependencies

```dockerfile
FROM mcr.microsoft.com/playwright:v1.45.0-noble
WORKDIR /tests
COPY package*.json ./
RUN npm ci
COPY . .
CMD ["npx", "playwright", "test"]
```

**Why no `USER` directive here:** bind mounts overlay the container filesystem with host-owned directories. The non-root user inside the container cannot write to root-owned host directories — `EPERM` errors when Playwright tries to write traces or reports. See Non-Root User and Bind Mounts below.

**Why single-stage:** the test runner needs the same toolchain at runtime as at build time. Multi-stage adds complexity without size benefit.

**What still applies:**
- Pin the base image (`v1.45.0-noble`, not `latest`)
- `.dockerignore` is still required (don't ship the host's `node_modules` into the build context)
- Lifecycle scripts off (`ENV HUSKY=0`)
- Disable browser auto-download if using a base image that already has them (`ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`)

### Non-Root User and Bind Mounts — the trade-off

`USER node` (or any non-root user) is a security best practice for long-running services. With bind mounts, it causes `EPERM` errors:

1. Docker creates bind-mounted host directories with root ownership
2. The non-root user inside the container cannot write to root-owned directories
3. `COPY --chown` and `RUN chown` in Dockerfile have no effect — bind mounts overlay the container filesystem

**When `USER node` is appropriate:**
- Long-running services (web servers, APIs, workers) that expose ports or handle user input
- Images pushed to registries and run by others — non-root is defense-in-depth
- Containers using NAMED volumes (Docker sets correct permissions automatically)

**When `USER node` causes more problems than it solves:**
- Ephemeral containers (test runners, CI jobs, CLI tools) — destroyed after execution
- Containers with BIND mounts for output extraction (reports, logs, artifacts)
- Development containers where debugging access is needed

**If non-root is required with bind mounts**, workarounds:
- Pre-create host directories with correct permissions before running
- Use an entrypoint that starts as root, fixes permissions, drops to non-root via `gosu`/`su-exec`
- Use named volumes instead of bind mounts (requires `docker cp` to extract files)

For ephemeral test runners with no exposed ports and no persistent state, running as root is an acceptable trade-off. Security is better addressed by `.dockerignore` (no secrets in image) and `env_file` (runtime injection).

### Volumes — named vs anonymous vs bind

```yaml
volumes:
  db-data:                              # named volume — persists across restarts

services:
  db:
    volumes:
      - db-data:/var/lib/postgresql/data    # named volume for persistence
  app:
    volumes:
      - ./src:/app/src                       # bind mount for dev hot-reload
      - /app/node_modules                    # anonymous volume — prevents host overwrite
```

**Anonymous volume pattern** (`/app/node_modules`): when bind-mounting source code for hot-reload, the host's `node_modules` would overwrite the container's. An anonymous volume for `node_modules` keeps the container's installed deps separate. Common in dev compose stacks.

### Networks — isolate services explicitly when it matters

```yaml
networks:
  frontend:
  backend:

services:
  app:
    networks: [frontend, backend]     # app talks to both
  db:
    networks: [backend]                # db is only on backend
  nginx:
    networks: [frontend]               # nginx only talks to app
```

Default network is fine for most cases. Use explicit networks when you want to prevent a service from being reachable from another — e.g., DB should not be reachable from nginx.

### Failure-artifact extraction from test containers

Test runners need to surface artifacts (screenshots, traces, JUnit XML, HTML reports) to the host or CI. Two patterns:

**Pattern A — bind-mount output directory** (simpler, root-user containers):

```yaml
services:
  e2e:
    image: tests-e2e:local
    volumes:
      - ./test-results:/tests/test-results
      - ./playwright-report:/tests/playwright-report
```

**Pattern B — `docker cp` after exit** (when using named volumes or non-root):

```bash
docker compose up --abort-on-container-exit e2e
docker cp $(docker compose ps -q e2e):/tests/test-results ./test-results
```

Pattern A is the common choice for CI — simpler, lets the CI runner upload artifacts directly. Pattern B is needed when bind mounts cause permission issues.

---

## Common Anti-Patterns Quick Reference

| Anti-pattern | Dimension | Severity | Fix |
|---|---|---|---|
| `FROM node:latest` | DIM-3 | High | Pin to specific minor version: `node:20.11-slim` |
| `COPY . .` before `npm ci` | DIM-2 | High | Copy lockfile first, install, then copy source |
| `ARG` for secrets | DIM-3 | Critical | Use `--mount=type=secret` |
| Separate `RUN` for install + cleanup | DIM-4 | Medium | Chain in single `RUN` with `&&` |
| No `.dockerignore` | DIM-3 / DIM-5 | High | Create with node_modules, .git, .env, test-results |
| `depends_on` without healthcheck | DIM-6 | High | Add `condition: service_healthy` + healthcheck |
| `ADD` for local files | DIM-1 | Medium | Use `COPY` for local files, `RUN curl` for URLs |
| Running as root in long-lived services | DIM-3 | High | Add `USER node` for production services. Root is acceptable for ephemeral containers (test runners) with bind mounts |
| Dev deps in production image | DIM-5 | High | Multi-stage build or `npm ci --omit=dev` |
| Secrets in `docker-compose.yml` | DIM-3 | Critical | Use `env_file` with gitignored `.env`, or Docker secrets |
| `USER node` with bind mounts | DIM-4 | High | Non-root + bind mounts = EPERM. For ephemeral containers, root is acceptable |
| No `init: true` in Compose | DIM-6 | Medium | Add `init: true` for proper signal handling (Ctrl+C graceful stop) |
| Distroless for test runners | DIM-4 | Medium | Distroless has no shell/npm — use `slim` for test runners and CI |
| Lifecycle scripts running in container | DIM-5 | Medium | Tools like husky have no purpose in Docker (no `.git`). Disable via `ENV HUSKY=0` |
| `latest` tag in compose `image:` | DIM-3 | High | Pin to a specific tag or digest |
| No resource limits on long-running services | DIM-6 | Medium | Set `deploy.resources.limits.memory` to prevent OOM cascades |

---

## Reference Skeletons

Canonical Dockerfile and compose shapes — use as the starting structure when scaffolding new images. Mirrors the GHA workflow and Jenkinsfile reference skeletons in `github-actions-best-practices.md` and `jenkins-best-practices.md`.

### Node.js production app — multi-stage, non-root, healthcheck

```dockerfile
# syntax=docker/dockerfile:1.6

# Stage 1 — build
FROM node:20.11-slim AS builder
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci
COPY . .
RUN npm run build

# Stage 2 — production
FROM node:20.11-slim AS production
ENV NODE_ENV=production \
    HUSKY=0
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev
COPY --from=builder --chown=node:node /app/dist ./dist
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD curl -fsS http://localhost:3000/health || exit 1
CMD ["node", "dist/index.js"]
```

### Playwright test runner — single-stage, root-OK, bind-mount-friendly

```dockerfile
FROM mcr.microsoft.com/playwright:v1.45.0-noble
ENV HUSKY=0 \
    CI=true
WORKDIR /tests
COPY package*.json ./
RUN npm ci
COPY . .
# No USER — bind mounts need root for write access
# No HEALTHCHECK — ephemeral, no exposed ports
CMD ["npx", "playwright", "test"]
```

### Compose stack — healthchecks, init, env_file, networks

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    image: bug-tracker-app:local
    init: true
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      db:
        condition: service_healthy
    networks: [frontend, backend]
    ports:
      - "3000:3000"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:3000/health"]
      interval: 30s
      timeout: 3s
      start_period: 10s
      retries: 3
    deploy:
      resources:
        limits:
          memory: 512M

  db:
    image: postgres:16.2-alpine
    init: true
    restart: unless-stopped
    environment:
      POSTGRES_USER: app
      POSTGRES_DB: bugtracker
    env_file:
      - .env.db
    volumes:
      - db-data:/var/lib/postgresql/data
    networks: [backend]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d bugtracker"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    deploy:
      resources:
        limits:
          memory: 256M

  e2e:
    profiles: [test]
    build:
      context: ./tests-e2e
      dockerfile: Dockerfile
    image: bug-tracker-e2e:local
    depends_on:
      app:
        condition: service_healthy
    environment:
      BASE_URL: http://app:3000
    volumes:
      - ./test-results:/tests/test-results
      - ./playwright-report:/tests/playwright-report
    networks: [frontend]
    restart: "no"

volumes:
  db-data:

networks:
  frontend:
  backend:
```

> NOTE: `profiles: [test]` keeps the e2e container out of the default `docker compose up` lifecycle — run it explicitly with `docker compose --profile test up --abort-on-container-exit e2e`. Mirrors the GHA pattern where test jobs run on `pull_request`, not on every push.
