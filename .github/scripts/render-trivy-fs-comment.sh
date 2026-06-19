#!/usr/bin/env bash
# Render the Trivy filesystem-scan PR comment body from the scan JSON.
#
# NON-SENSITIVE half of the comment: it only reads the scan JSON and writes a Markdown file.
# It carries NO GitHub token and makes NO API calls — that is why it is safe to run from the
# checked-out (PR-head) script. The token-bearing PATCH/POST stays inline in the workflow
# (base-trusted), so a PR cannot alter how/where the comment is posted.
#
# The fs scan runs `scanners: vuln,secret`, so the JSON carries two finding kinds:
#   - .Vulnerabilities[]  -> dependency CVEs, grouped per source manifest
#   - .Secrets[]          -> leaked secrets, shown as `file:line` + rule ONLY. The matched value
#                            (.Match) is NEVER echoed — that would leak the secret into a public
#                            PR comment. Detail lives in the Code scanning tab instead.
#
# Local run:
#   FINDINGS_JSON=./trivy-fs.json OUT=/tmp/body.md \
#   MARKER='<!-- security-scan:trivy-fs -->' RUN_URL='https://…' SECURITY_URL='https://…' \
#     bash .github/scripts/render-trivy-fs-comment.sh
set -euo pipefail

FINDINGS_JSON="${FINDINGS_JSON:?FINDINGS_JSON (path to trivy fs JSON) is required}"
OUT="${OUT:?OUT (output markdown path) is required}"
MARKER="${MARKER:?MARKER is required}"
RUN_URL="${RUN_URL:?RUN_URL is required}"
SECURITY_URL="${SECURITY_URL:?SECURITY_URL is required}"

# seen distinguishes "scanned, all clean" from "no results file at all" (failed/aborted scan),
# so a missing JSON is never reported as ✅ clean.
seen=0
[ -s "$FINDINGS_JSON" ] && seen=1

vulns='[]'
secrets='[]'
if [ "$seen" -eq 1 ]; then
  # Carry each finding's source Target; dedup vulns (a CVE can repeat across nested manifests).
  vulns=$(jq -c '
    [ .Results[]? | .Target as $t | (.Vulnerabilities[]?)
      | { tgt: $t, pkg: .PkgName, id: .VulnerabilityID, sev: .Severity,
          inst: .InstalledVersion, fix: .FixedVersion, url: .PrimaryURL } ]
    | unique_by([.tgt, .pkg, .id, .inst])' "$FINDINGS_JSON")
  secrets=$(jq -c '
    [ .Results[]? | .Target as $t | (.Secrets[]?)
      | { tgt: $t, rule: .RuleID, title: .Title, sev: .Severity, line: .StartLine } ]' "$FINDINGS_JSON")
fi

vuln_count=$(printf '%s' "$vulns" | jq 'length')
secret_count=$(printf '%s' "$secrets" | jq 'length')

# One collapsible block per source manifest that has vulnerabilities.
vuln_details=""
if [ "$vuln_count" -gt 0 ]; then
  targets=$(printf '%s' "$vulns" | jq -r '[.[].tgt] | unique | .[]')
  while IFS= read -r tgt; do
    [ -n "$tgt" ] || continue
    # sort_by(.sev, .pkg): "CRITICAL" < "HIGH" alphabetically, so criticals lead.
    rows=$(printf '%s' "$vulns" | jq -r --arg t "$tgt" '
      [ .[] | select(.tgt == $t) ] | sort_by(.sev, .pkg)[]
      | "| \(.pkg) | [\(.id)](\(.url // "")) | "
        + (if .sev == "CRITICAL" then "🔴 CRIT" else "🟠 HIGH" end)
        + " | \(.inst) | \(.fix // "—") |"')
    n=$(printf '%s' "$vulns" | jq --arg t "$tgt" '[ .[] | select(.tgt == $t) ] | length')
    vuln_details+=$'\n'"<details open><summary><b>$tgt</b> — $n HIGH/CRITICAL</summary>"$'\n\n'
    vuln_details+="| Package | CVE | Sev | Installed | Fixed |"$'\n'
    vuln_details+="|---|---|---|---|---|"$'\n'
    vuln_details+="$rows"$'\n\n'"</details>"$'\n'
  done <<< "$targets"
fi

# Secrets block — rule + location only, never the matched value.
secret_details=""
if [ "$secret_count" -gt 0 ]; then
  rows=$(printf '%s' "$secrets" | jq -r '
    sort_by(.tgt, .line)[]
    | "| `\(.tgt):\(.line)` | \(.rule) | "
      + (if .sev == "CRITICAL" then "🔴 CRIT" elif .sev == "HIGH" then "🟠 HIGH" else .sev end)
      + " | \(.title) |"')
  secret_details+=$'\n'"<details open><summary><b>🔑 Secrets</b> — $secret_count found</summary>"$'\n\n'
  secret_details+="| Location | Rule | Severity | Title |"$'\n'
  secret_details+="|---|---|---|---|"$'\n'
  secret_details+="$rows"$'\n\n'"</details>"$'\n'
fi

{
  echo "$MARKER"
  echo "## 🛡️ Trivy Filesystem Scan"
  echo ""
  if [ "$seen" -eq 0 ]; then
    echo "⚠️ **No scan results found** — the scan may not have completed. Do not read this as \"no issues\"; check the [workflow run]($RUN_URL)."
  elif [ "$vuln_count" -gt 0 ] || [ "$secret_count" -gt 0 ]; then
    echo "Fixable **HIGH/CRITICAL** dependency vulnerabilities and/or leaked secrets (report-only — not blocking merge):"
    echo ""
    echo "⚠️ $vuln_count vulnerabilities · 🔑 $secret_count secrets"
  else
    echo "✅ No fixable HIGH/CRITICAL vulnerabilities or leaked secrets."
  fi
  echo ""
  [ -n "$vuln_details" ] && printf '%s\n' "$vuln_details"
  [ -n "$secret_details" ] && printf '%s\n' "$secret_details"
  echo "Full inventory (misconfig + lower severities): **[Security → Code scanning]($SECURITY_URL)** · [workflow run]($RUN_URL)"
} > "$OUT"

# Backstop: GitHub rejects comment bodies > 65536 chars (HTTP 422). Native Markdown output is
# compact and should stay well under, but cap so a pathological finding count can never 422.
MAX=60000
if [ "$(wc -c < "$OUT")" -gt "$MAX" ]; then
  head -c "$MAX" "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
  printf '\n> ⚠️ Output truncated — full report in the [workflow run](%s) artifacts and the Code scanning tab.\n' "$RUN_URL" >> "$OUT"
fi
