#!/usr/bin/env python3
"""Render the PR comment markdown from review JSON data.

Produces: title, optional files-reviewed list, one-line summary,
severity count table, one collapsible <details> block per severity
(critical/high pre-expanded), and the artifact download link.
"""
import argparse
import json
import pathlib

SEVERITIES = ["critical", "high", "medium", "low"]
BADGES = {"critical": "🔴", "high": "🟠", "medium": "🟡", "low": "⚪"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, help="Path to review-data.json")
    parser.add_argument("--title", required=True, help="Report title")
    parser.add_argument("--artifact-url", default="", help="Download URL of the HTML report artifact")
    parser.add_argument("--out", required=True, help="Path to write the markdown comment")
    args = parser.parse_args()

    data = json.loads(pathlib.Path(args.data).read_text(encoding="utf-8"))
    findings = data.get("findings", [])
    counts = {s: sum(1 for f in findings if f.get("severity") == s) for s in SEVERITIES}

    lines = [f"## 🔍 {args.title}", ""]

    reviewed = data.get("files_reviewed", [])
    if reviewed:
        lines += ["**Files reviewed:**", ""]
        lines += [f"- `{path}`" for path in reviewed]
        lines.append("")

    if not findings:
        lines += ["✅ **No issues found** — reviewed files follow best practices.", ""]
    else:
        known_total = sum(counts.values())
        breakdown = ", ".join(f"{counts[s]} {s}" for s in SEVERITIES if counts[s])
        noun = "issue" if known_total == 1 else "issues"
        lines += [f"**{known_total} {noun} found** ({breakdown})", ""]
        lines += [
            "| Critical | High | Medium | Low |",
            "|---:|---:|---:|---:|",
            f"| {counts['critical']} | {counts['high']} | {counts['medium']} | {counts['low']} |",
            "",
        ]
        for sev in SEVERITIES:
            items = [f for f in findings if f.get("severity") == sev]
            if not items:
                continue
            noun = "finding" if len(items) == 1 else "findings"
            opened = " open" if sev in ("critical", "high") else ""
            lines.append(f"<details{opened}>")
            lines.append(f"<summary>{BADGES[sev]} <b>{sev.capitalize()}</b> — {len(items)} {noun}</summary>")
            lines.append("")
            for finding in items:
                where = f" — `{finding['file']}`" if finding.get("file") else ""
                lines.append(f"#### {finding.get('title', 'Untitled')}{where}")
                lines.append("")
                if finding.get("description"):
                    lines += [finding["description"], ""]
                if finding.get("fix"):
                    lines += [f"**Fix:** {finding['fix']}", ""]
            lines += ["</details>", ""]

    if args.artifact_url:
        lines += [
            f"📎 [Download the full HTML report]({args.artifact_url}) "
            "(zip; requires GitHub login; expires with artifact retention)",
            "",
        ]

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
