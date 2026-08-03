#!/usr/bin/env python3
"""Delete summaries on threads the daily pass no longer maintains.

Summaries are only kept current for the `primary` mailbox. Threads outside it
(Gmail's Promotions / Social / Updates / Forums) may still carry summaries from
an earlier, wider pass — those will never refresh, so they age into being wrong.
This clears them.

Dry-run by default; pass --apply to actually delete.

    ./scripts/mcp-clear-bulk-summaries.py            # show what would go
    ./scripts/mcp-clear-bulk-summaries.py --apply
"""

import argparse
import json
import sys

from mcp_common import MCP


def walk(mcp, mailbox):
    """Every thread in a mailbox, paging past the 100-per-call cap."""
    out, offset = [], 0
    while True:
        page = json.loads(mcp.call("list_threads", {
            "mailbox": mailbox, "limit": 100, "offset": offset}))
        if not page:
            return out
        out.extend(page)
        offset += len(page)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true",
                    help="actually delete (default is a dry run)")
    # 'inbox' by default, not 'all': the summary passes only ever ran over the
    # inbox, and scanning the full thread table is orders of magnitude slower.
    ap.add_argument("--mailbox", default="inbox",
                    help="scope to scan for stale summaries (default: inbox)")
    args = ap.parse_args()

    mcp = MCP()
    keep = {t["id"] for t in walk(mcp, "primary")}
    everything = walk(mcp, args.mailbox)
    doomed = [t for t in everything
              if t.get("summary") and t["id"] not in keep]

    print(f"{len(everything)} threads in '{args.mailbox}', "
          f"{len(keep)} kept current by the daily pass, "
          f"{len(doomed)} carrying a summary that will never refresh")
    if not doomed:
        return
    if not args.apply:
        for t in doomed[:10]:
            print(f"  [dry] {t['subject'][:60]}")
        if len(doomed) > 10:
            print(f"  ... and {len(doomed) - 10} more")
        print("\nRe-run with --apply to delete these.")
        return

    cleared = failed = 0
    for t in doomed:
        try:
            mcp.call("clear_thread_summary", {"thread_id": t["id"]})
            cleared += 1
        except Exception as e:
            failed += 1
            print(f"[err] {t['id']}: {e}", file=sys.stderr)
    print(f"cleared {cleared}, failed {failed}")


if __name__ == "__main__":
    main()
