#!/usr/bin/env bash
# Assemble the GitHub Pages site from the downloaded test-report artifacts.
#
# This is pure, NON-SENSITIVE assembly: it copies report folders into a site/ tree, aliases a
# default document for the two single-file reports, and renders the landing page from a template.
# It carries NO GitHub token and makes NO API calls. Unlike the Trivy render scripts there is no
# PR-head trust concern either — the publish-pages job runs ONLY on push to main (see its
# `if:` guard), so HEAD always equals the trusted base. Extracting it here (vs. inline `run:`)
# buys shellcheck coverage + local reproducibility.
#
# Local run:
#   COMMIT_SHA=abc1234 RUN_NUMBER=42 \
#     bash .github/scripts/compose-pages-site.sh
set -euo pipefail

# Inputs from the workflow (github context). Dir/template are overridable for local runs.
COMMIT_SHA="${COMMIT_SHA:?COMMIT_SHA (github.sha) is required}"
RUN_NUMBER="${RUN_NUMBER:?RUN_NUMBER (github.run_number) is required}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
SITE_DIR="${SITE_DIR:-site}"
TEMPLATE="${TEMPLATE:-.github/pages/index.template.html}"

mkdir -p "$SITE_DIR"/backend "$SITE_DIR"/frontend "$SITE_DIR"/api "$SITE_DIR"/e2e "$SITE_DIR"/perf

cp -r "$ARTIFACTS_DIR"/backend-test-report/.  "$SITE_DIR"/backend/
cp -r "$ARTIFACTS_DIR"/frontend-test-report/. "$SITE_DIR"/frontend/
cp -r "$ARTIFACTS_DIR"/api-test-report/.      "$SITE_DIR"/api/
cp -r "$ARTIFACTS_DIR"/e2e-test-report/.      "$SITE_DIR"/e2e/
cp -r "$ARTIFACTS_DIR"/perf-test-report/.     "$SITE_DIR"/perf/

# Backend (single coverage.html) and perf (single perf-results.html) have no index.html —
# alias so /backend/ and /perf/ resolve to a default document.
if [ -f "$SITE_DIR/backend/coverage.html" ]; then
  cp "$SITE_DIR/backend/coverage.html" "$SITE_DIR/backend/index.html"
fi
if [ -f "$SITE_DIR/perf/perf-results.html" ]; then
  cp "$SITE_DIR/perf/perf-results.html" "$SITE_DIR/perf/index.html"
fi

# Render the landing page from the template. The positional arg restricts envsubst to these
# three vars so no other env (e.g., GITHUB_TOKEN) can leak into the generated HTML.
export SHORT_SHA="${COMMIT_SHA:0:7}"
export TIMESTAMP
TIMESTAMP="$(date -u +'%Y-%m-%d %H:%M UTC')"
envsubst '$SHORT_SHA $TIMESTAMP $RUN_NUMBER' < "$TEMPLATE" > "$SITE_DIR/index.html"
