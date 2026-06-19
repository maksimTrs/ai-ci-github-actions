#!/usr/bin/env bash
# Render the Trivy image-scan PR comment body from per-image findings JSON.
#
# This is the NON-SENSITIVE half of the image-scan comment. It only reads the downloaded
# findings JSON and writes a Markdown file: it carries NO GitHub token and makes NO API calls.
# That is why it is safe to run from the checked-out (PR-head) script file — the credential
# never enters this step. The token-bearing PATCH/POST stays inline in the workflow (base-trusted).
#
# Extracting it here (vs. inline `run:`) buys shellcheck + local reproducibility:
#   FINDINGS_DIR=./findings OUT=/tmp/body.md \
#   MARKER='<!-- security-scan:trivy-image -->' RUN_URL='https://…' SECURITY_URL='https://…' \
#     bash .github/scripts/render-trivy-image-comment.sh
set -euo pipefail
shopt -s nullglob   # empty glob expands to nothing, not the literal pattern

FINDINGS_DIR="${FINDINGS_DIR:-findings}"
OUT="${OUT:?OUT (output markdown path) is required}"
MARKER="${MARKER:?MARKER is required}"
RUN_URL="${RUN_URL:?RUN_URL is required}"
SECURITY_URL="${SECURITY_URL:?SECURITY_URL is required}"

# Build a headline ("backend ✅ 0 · frontend ⚠️ 11 · …") plus one collapsible Markdown table
# per image. Extracting only .Vulnerabilities[] drops Trivy's full target inventory — the comment
# carries findings, not the hundreds of clean targets the table format lists. `seen` distinguishes
# "scanned, all clean" from "no results at all" so a failed upstream scan is never reported as ✅.
headline=""
details=""
seen=0
for f in "$FINDINGS_DIR"/trivy-image-*.json; do
  [ -s "$f" ] || continue
  seen=1
  name=$(basename "$f" .json); name=${name#trivy-image-}

  # Flatten + dedup vulnerabilities across all targets in this image. A package/CVE can repeat
  # across nested node_modules copies; unique_by collapses those to one row.
  vulns=$(jq -c '
    [ .Results[]?.Vulnerabilities[]?
      | { pkg: .PkgName, id: .VulnerabilityID, sev: .Severity,
          inst: .InstalledVersion, fix: .FixedVersion, url: .PrimaryURL } ]
    | unique_by([.pkg, .id, .inst])' "$f")
  count=$(printf '%s' "$vulns" | jq 'length')

  if [ "$count" -gt 0 ]; then
    headline="${headline:+$headline · }$name ⚠️ $count"
    # sort_by(.sev, .pkg): "CRITICAL" < "HIGH" alphabetically, so criticals lead.
    rows=$(printf '%s' "$vulns" | jq -r '
      sort_by(.sev, .pkg)[]
      | "| \(.pkg) | [\(.id)](\(.url // "")) | "
        + (if .sev == "CRITICAL" then "🔴 CRIT" else "🟠 HIGH" end)
        + " | \(.inst) | \(.fix // "—") |"')
    details+=$'\n'"<details open><summary><b>$name</b> — $count HIGH/CRITICAL</summary>"$'\n\n'
    details+="| Package | CVE | Sev | Installed | Fixed |"$'\n'
    details+="|---|---|---|---|---|"$'\n'
    details+="$rows"$'\n\n'"</details>"$'\n'
  else
    headline="${headline:+$headline · }$name ✅ 0"
  fi
done

{
  echo "$MARKER"
  echo "## 🛡️ Trivy Image Scan"
  echo ""
  if [ "$seen" -eq 0 ]; then
    echo "⚠️ **No image-scan results found** — the scan may not have completed. Do not read this as \"no issues\"; check the [workflow run]($RUN_URL)."
  elif [ -n "$details" ]; then
    echo "Fixable **HIGH/CRITICAL** CVEs in built image layers (report-only — not blocking merge):"
  else
    echo "✅ No fixable HIGH/CRITICAL CVEs in built image layers."
  fi
  echo ""
  [ -n "$headline" ] && { echo "$headline"; echo ""; }
  [ -n "$details" ] && printf '%s\n' "$details"
  echo "Full inventory (all severities + misconfig): **[Security → Code scanning]($SECURITY_URL)** · [workflow run]($RUN_URL)"
} > "$OUT"

# Backstop: GitHub rejects comment bodies > 65536 chars (HTTP 422). Option-A output is compact and
# should stay well under, but cap so a pathological finding count can never 422 the POST.
MAX=60000
if [ "$(wc -c < "$OUT")" -gt "$MAX" ]; then
  head -c "$MAX" "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
  printf '\n> ⚠️ Output truncated — full tables in the [workflow run](%s) artifacts and the Code scanning tab.\n' "$RUN_URL" >> "$OUT"
fi
