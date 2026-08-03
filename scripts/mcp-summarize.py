#!/usr/bin/env python3
"""Backfill AI summaries into MishMail via its MCP server.

Reads the discovery file (mcp.json) for port + token, lists threads, skips
ones that already have a summary, fetches each thread as Markdown, asks a
model for a 1-2 sentence summary, and writes it back with set_thread_summary.

Backends:
  --backend ollama   (default) local Ollama, no data leaves the machine
  --backend openai   any OpenAI-compatible chat API: set --api-base,
                     --model, and OPENAI_API_KEY (works for cheap hosted
                     models like Luna/Haiku-class endpoints)

Examples:
  ./scripts/mcp-summarize.py --limit 10                    # llama3.2:3b, newest 10
  ./scripts/mcp-summarize.py --limit 600                   # whole Primary tab
  ./scripts/mcp-summarize.py --mailbox inbox --limit 200   # include bulk mail
  ./scripts/mcp-summarize.py --backend openai --api-base https://api.x.ai/v1 \
      --model luna-5.6-low --limit 500
"""

import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

from mcp_common import MCP, post_json

PROMPT = (
    "Summarize this email thread in 1-2 crisp sentences for an inbox "
    "overview. Lead with what matters or what action is needed. No preamble, "
    "no markdown, just the sentences.\n\nTHREAD:\n{thread}"
)


def strip_quotes(text):
    """Drop quoted reply chains (`>` lines) — in a long thread they repeat
    earlier messages verbatim and crowd out the real content."""
    out, blanks = [], 0
    for line in text.splitlines():
        if line.lstrip().startswith(">"):
            continue
        if not line.strip():
            blanks += 1
            if blanks > 1:
                continue
        else:
            blanks = 0
        out.append(line)
    return "\n".join(out)


def fit(text, max_chars):
    """Keep the head AND tail when a thread is too long. The opening message
    usually carries the ask; the newest ones carry the current state.
    Truncating to the tail alone loses the former."""
    text = strip_quotes(text)
    if len(text) <= max_chars:
        return text
    head = int(max_chars * 0.6)
    tail = max_chars - head
    return text[:head] + "\n\n[...middle of thread omitted...]\n\n" + text[-tail:]


def summarize_ollama(base, model, thread_text):
    r = post_json(f"{base}/api/generate", {
        "model": model,
        "prompt": PROMPT.format(thread=thread_text),
        "stream": False,
        "options": {"temperature": 0.2},
    })
    return r["response"].strip()


def summarize_openai(base, model, thread_text):
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        sys.exit("OPENAI_API_KEY is required for --backend openai")
    r = post_json(f"{base.rstrip('/')}/chat/completions", {
        "model": model,
        "messages": [{"role": "user",
                      "content": PROMPT.format(thread=thread_text)}],
        "temperature": 0.2,
    }, {"Authorization": f"Bearer {key}"})
    return r["choices"][0]["message"]["content"].strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", choices=["ollama", "openai"], default="ollama")
    ap.add_argument("--model", default=None,
                    help="model name (default: llama3.2:3b for ollama)")
    ap.add_argument("--api-base", default=None,
                    help="ollama: http://127.0.0.1:11434; openai: API base URL")
    ap.add_argument("--mailbox", default="primary,correspondence,starred",
                    help="comma-separated scopes, de-duplicated. Default sweeps "
                         "primary (inbox minus Gmail's four categories), "
                         "correspondence (threads you replied to) and starred, "
                         "so real conversations buried in Updates are covered. "
                         "Others: inbox, sent, drafts, all")
    ap.add_argument("--limit", type=int, default=25,
                    help="max threads to examine, newest first; "
                         "pages past the server's 100-per-call cap")
    ap.add_argument("--redo", action="store_true",
                    help="re-summarize threads that already have a summary")
    ap.add_argument("--no-refresh-stale", action="store_true",
                    help="skip threads whose summary predates new messages "
                         "(by default those are refreshed)")
    ap.add_argument("--max-chars", type=int, default=12000,
                    help="budget for thread text (quotes stripped; head+tail kept)")
    ap.add_argument("--replace-model", default=None, metavar="NAME",
                    help="only threads whose current summary came from NAME "
                         "(use to upgrade an earlier pass to a better model)")
    ap.add_argument("--skip-categories", default="", metavar="A,B",
                    help="skip threads the app classified as these (e.g. "
                         "'Newsletter,Receipt'); needs Auto-sort enabled in "
                         "Settings → AI, unclassified threads are kept")
    ap.add_argument("--jobs", type=int, default=4,
                    help="concurrent summarization requests (default 4)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print summaries without writing them back")
    args = ap.parse_args()

    if args.backend == "ollama":
        model = args.model or "llama3.2:3b"
        base = args.api_base or "http://127.0.0.1:11434"
        summarize = lambda t: summarize_ollama(base, model, t)
        stored_model = model
    else:
        if not args.model or not args.api_base:
            sys.exit("--backend openai requires --model and --api-base")
        model, base = args.model, args.api_base
        summarize = lambda t: summarize_openai(base, model, t)
        stored_model = model

    mcp = MCP()
    # Each scope is paged separately (the server caps a call at 100 rows) and
    # merged by thread id, since scopes overlap heavily.
    threads, seen = [], set()
    for scope in [m.strip() for m in args.mailbox.split(",") if m.strip()]:
        offset = 0
        while len(threads) < args.limit:
            page = json.loads(mcp.call("list_threads", {
                "mailbox": scope, "limit": 100, "offset": offset}))
            if not page:
                break
            offset += len(page)
            for t in page:
                if t["id"] not in seen:
                    seen.add(t["id"])
                    threads.append(t)
    threads = threads[:args.limit]

    skip = {c.strip().lower() for c in args.skip_categories.split(",") if c.strip()}

    def needs_work(t):
        # Unclassified threads have no category and are never skipped — the
        # filter must not silently drop mail just because triage hasn't run.
        if skip and (t.get("category") or "").lower() in skip:
            return False
        if args.redo or not t.get("summary"):
            return True
        # A thread that got new messages after its summary was written is
        # described by a summary that no longer covers it.
        return t.get("summaryStale") and not args.no_refresh_stale

    if args.replace_model:
        todo = [t for t in threads if t.get("summaryModel") == args.replace_model]
    else:
        todo = [t for t in threads if needs_work(t)]
    stale = sum(1 for t in todo if t.get("summary"))
    print(f"{len(threads)} threads listed, {len(todo)} to summarize "
          f"({stale} refreshing a stale summary) "
          f"(backend={args.backend}, model={stored_model})")

    done = failed = 0
    def one(t):
        """Summarize a single thread. Returns a line to print; raises on error."""
        text = mcp.call("get_thread", {"thread_id": t["id"]})
        summary = summarize(fit(text, args.max_chars))
        # Guard against runaway model output.
        summary = " ".join(summary.split())[:600]
        if not summary:
            raise RuntimeError("empty summary")
        if args.dry_run:
            return f"[dry] {t['subject'][:50]!r}: {summary[:100]}"
        mcp.call("set_thread_summary", {
            "thread_id": t["id"], "summary": summary, "model": stored_model})
        return f"[ok]  {t['subject'][:50]!r}: {summary[:100]}"

    # Ollama serves a few requests concurrently (OLLAMA_NUM_PARALLEL); going
    # much past that just queues inside the server with no speedup.
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = {pool.submit(one, t): t for t in todo}
        for fut in as_completed(futures):
            t = futures[fut]
            try:
                print(fut.result(), flush=True)
                done += 1
            except Exception as e:  # keep going; report at the end
                failed += 1
                print(f"[err] {t['subject'][:50]!r}: {e}", file=sys.stderr, flush=True)

    print(f"done: {done} summarized, {failed} failed, "
          f"{len(threads) - len(todo)} already had summaries")


if __name__ == "__main__":
    main()
