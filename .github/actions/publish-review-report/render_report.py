#!/usr/bin/env python3
"""Merge review JSON data into the HTML report template.

The template contains a literal REVIEW_DATA_PLACEHOLDER token that is
replaced with the JSON object. The report title is injected here, not
produced by the AI agent, so it stays deterministic. Every "<" in the payload is
escaped to "\\u003c" so agent-produced text can never terminate the
<script> block ("</script>") or open an escaped state ("<!--").
"""
import argparse
import json
import pathlib

PLACEHOLDER = "REVIEW_DATA_PLACEHOLDER"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, help="Path to review-data.json")
    parser.add_argument("--template", required=True, help="Path to the HTML template")
    parser.add_argument("--title", required=True, help="Report title shown in the page header")
    parser.add_argument("--out", required=True, help="Path to write the rendered HTML")
    args = parser.parse_args()

    data = json.loads(pathlib.Path(args.data).read_text(encoding="utf-8"))
    # Title always comes from the CLI; any agent-supplied "title" key is discarded.
    data["title"] = args.title

    template = pathlib.Path(args.template).read_text(encoding="utf-8")
    if PLACEHOLDER not in template:
        raise SystemExit(f"template {args.template} has no {PLACEHOLDER} token")

    # "<" never occurs in JSON structure itself, only inside string values.
    payload = json.dumps(data, indent=2).replace("<", "\\u003c")
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(template.replace(PLACEHOLDER, payload), encoding="utf-8")


if __name__ == "__main__":
    main()
