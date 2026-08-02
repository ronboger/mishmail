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
  ./scripts/mcp-summarize.py --mailbox inbox --limit 200   # backfill inbox
  ./scripts/mcp-summarize.py --backend openai --api-base https://api.x.ai/v1 \
      --model luna-5.6-low --limit 500
"""

import argparse
import json
import os
import sys

from mcp_common import MCP, post_json

PROMPT = (
    "Summarize this email thread in 1-2 crisp sentences for an inbox "
    "overview. Lead with what matters or what action is needed. No preamble, "
    "no markdown, just the sentences.\n\nTHREAD:\n{thread}"
)


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
    ap.add_argument("--mailbox", default="inbox",
                    choices=["inbox", "starred", "sent", "drafts", "all"])
    ap.add_argument("--limit", type=int, default=25,
                    help="max threads to examine (newest first)")
    ap.add_argument("--redo", action="store_true",
                    help="re-summarize threads that already have a summary")
    ap.add_argument("--max-chars", type=int, default=6000,
                    help="truncate thread text to its last N chars")
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
    threads = json.loads(mcp.call("list_threads", {
        "mailbox": args.mailbox, "limit": min(args.limit, 100)}))

    todo = [t for t in threads if args.redo or not t.get("summary")]
    print(f"{len(threads)} threads listed, {len(todo)} to summarize "
          f"(backend={args.backend}, model={stored_model})")

    done = failed = 0
    for t in todo:
        try:
            text = mcp.call("get_thread", {"thread_id": t["id"]})
            summary = summarize(text[-args.max_chars:])
            # Guard against runaway model output.
            summary = " ".join(summary.split())[:600]
            if not summary:
                raise RuntimeError("empty summary")
            if args.dry_run:
                print(f"[dry] {t['subject'][:50]!r}: {summary[:100]}")
            else:
                mcp.call("set_thread_summary", {
                    "thread_id": t["id"], "summary": summary,
                    "model": stored_model})
                print(f"[ok]  {t['subject'][:50]!r}: {summary[:100]}")
            done += 1
        except Exception as e:  # keep going; report at the end
            failed += 1
            print(f"[err] {t['subject'][:50]!r}: {e}", file=sys.stderr)

    print(f"done: {done} summarized, {failed} failed, "
          f"{len(threads) - len(todo)} already had summaries")


if __name__ == "__main__":
    main()
