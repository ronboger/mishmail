#!/usr/bin/env python3
"""Export MishMail threads to JSONL for offline/remote summarization.

Pairs with mcp-import-summaries.py. Use when the summarizer can't reach the
MCP server directly — e.g. a Codex Cloud worker or any sandboxed runner that
has no route to 127.0.0.1 on this Mac:

    ./scripts/mcp-export-threads.py --limit 100 -o threads.jsonl
    # ...hand threads.jsonl to the remote job; it emits summaries.jsonl
    # with {"thread_id": ..., "summary": ...} per line...
    ./scripts/mcp-import-summaries.py summaries.jsonl --model <name>

Each output line: {"thread_id", "subject", "from", "date", "text"}.

PRIVACY: the exported file contains full message bodies. Treat it like the
mailbox itself — anywhere you upload it can read your mail.
"""

import argparse
import json
import sys

from mcp_common import MCP


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", default="threads.jsonl")
    ap.add_argument("--mailbox", default="inbox",
                    choices=["inbox", "starred", "sent", "drafts", "all"])
    ap.add_argument("--limit", type=int, default=100)
    ap.add_argument("--redo", action="store_true",
                    help="include threads that already have a summary")
    ap.add_argument("--max-chars", type=int, default=6000,
                    help="truncate each thread to its last N chars")
    args = ap.parse_args()

    mcp = MCP()
    threads = json.loads(mcp.call("list_threads", {
        "mailbox": args.mailbox, "limit": min(args.limit, 100)}))
    todo = [t for t in threads if args.redo or not t.get("summary")]

    written = 0
    with open(args.out, "w") as f:
        for t in todo:
            try:
                text = mcp.call("get_thread", {"thread_id": t["id"]})
            except Exception as e:
                print(f"[err] {t['id']}: {e}", file=sys.stderr)
                continue
            f.write(json.dumps({
                "thread_id": t["id"],
                "subject": t.get("subject", ""),
                "from": t.get("from", ""),
                "date": t.get("date", ""),
                "text": text[-args.max_chars:],
            }) + "\n")
            written += 1

    print(f"exported {written} threads → {args.out} "
          f"({len(threads) - len(todo)} skipped, already summarized)")


if __name__ == "__main__":
    main()
