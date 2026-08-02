#!/usr/bin/env python3
"""Write summaries produced elsewhere back into MishMail via MCP.

Input is JSONL, one object per line, from a remote/offline summarizer:

    {"thread_id": "you@example.com:t1", "summary": "..."}
    {"thread_id": "...", "summary": "...", "model": "optional-per-row"}

Pairs with mcp-export-threads.py:

    ./scripts/mcp-export-threads.py --limit 100 -o threads.jsonl
    # remote job reads threads.jsonl, writes summaries.jsonl
    ./scripts/mcp-import-summaries.py summaries.jsonl --model gpt-5.4-codex
"""

import argparse
import json
import sys

from mcp_common import MCP


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("infile", help="JSONL with thread_id + summary per line")
    ap.add_argument("--model", default=None,
                    help="model attribution when a row omits it")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    mcp = MCP()
    done = failed = 0
    with open(args.infile) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                tid = row["thread_id"]
                summary = " ".join(str(row["summary"]).split())[:600]
                model = row.get("model") or args.model
                if not summary:
                    raise ValueError("empty summary")
                if not model:
                    raise ValueError("no model attribution (pass --model)")
                if args.dry_run:
                    print(f"[dry] {tid}: {summary[:90]}")
                else:
                    mcp.call("set_thread_summary", {
                        "thread_id": tid, "summary": summary, "model": model})
                    print(f"[ok]  {tid}: {summary[:90]}")
                done += 1
            except Exception as e:
                failed += 1
                print(f"[err] line {lineno}: {e}", file=sys.stderr)

    print(f"done: {done} written, {failed} failed")


if __name__ == "__main__":
    main()
