# Prompts for running MishMail summarization from Codex

Two variants. Use (A) for local Codex, which can reach the MCP server
directly. Use (B) for a Codex **Cloud** worker, which cannot reach
127.0.0.1 on your Mac and must go through exported files.

---

## A. Local Codex CLI (has network access to 127.0.0.1)

Paste as the task prompt. Prerequisite: MishMail running, Settings → AI →
MCP enabled.

```
Backfill AI summaries into my MishMail inbox using the repo's helper script.

Context:
- Repo: /Users/ronboger/mishmail
- MishMail exposes an MCP server on 127.0.0.1; the port and bearer token are
  in ~/Library/Containers/dev.ronboger.MishMail/Data/Library/Application Support/MishMail/mcp.json
- scripts/mcp-summarize.py already does the whole loop (list threads → skip
  ones that already have a summary → get_thread → summarize → set_thread_summary).
  Read it before changing anything.

Task:
1. Run: python3 scripts/mcp-summarize.py --mailbox inbox --limit 100 --model qwen3:8b
   (local Ollama; add --redo to overwrite existing summaries)
2. Spot-check 5 results by calling the MCP list_threads tool and reading the
   `summary` / `summaryModel` fields. Report any that are vague, wrong, or
   that only describe the first message of a multi-message thread.
3. If quality is poor, improve the PROMPT constant or the fit()/strip_quotes()
   preprocessing in the script — do NOT edit the Swift app. Re-run on 10
   threads to verify before doing a full pass.

Constraints:
- Read-only against Gmail: only set_thread_summary writes anything, and it
  only touches the local threadSummary table. Never call create_draft.
- Don't commit unless I ask.
```

---

## B. Codex Cloud worker (no route to 127.0.0.1)

A cloud worker runs in OpenAI's sandbox against a GitHub repo, so it can
neither reach the MCP server nor read the mailbox. Bridge with files.

**One-time setup:** create an environment for `ronboger/mishmail` at
chatgpt.com/codex (the CLI can only list environments through its
interactive TUI: run `codex cloud`).

**Step 1 — export locally:**

```bash
cd /Users/ronboger/mishmail
python3 scripts/mcp-export-threads.py --mailbox inbox --limit 100 -o /tmp/threads.jsonl
```

`threads.jsonl` holds full message bodies. Uploading it means the contents
leave your machine — decide that deliberately.

**Step 2 — the cloud task prompt** (`codex cloud exec --env <ENV_ID> "..."`,
with threads.jsonl attached or committed to a scratch branch):

```
Read threads.jsonl from the repo root. Each line is
{"thread_id", "subject", "from", "date", "text"} for one email thread.

For every line, write a 1-2 sentence summary of the thread for an inbox
overview: lead with what matters or what action is needed, no preamble, no
markdown. Cover the whole thread, not just the first message — if the latest
messages change the state (a question answered, a meeting scheduled, a deal
closed), that belongs in the summary.

Emit summaries.jsonl in the repo root, one object per line:
{"thread_id": "<same id, verbatim>", "summary": "<your summary>"}

Rules:
- Exactly one output line per input line, ids copied verbatim.
- No other files changed, no code changes, no commits beyond adding
  summaries.jsonl.
- Never invent facts not present in the thread text.
```

**Step 3 — pull the result and import:**

```bash
codex cloud diff <TASK_ID>          # inspect
codex cloud apply <TASK_ID>         # lands summaries.jsonl locally
python3 scripts/mcp-import-summaries.py summaries.jsonl --model gpt-5.4-codex
```

### Worth knowing before investing in (B)

- Cloud workers run the Codex agent model, not a cheap inference pool —
  there is no "run llama on their servers" mode. If the goal is cheap bulk
  summarization, a local Ollama pass or a direct API call to a cheap hosted
  model (`--backend openai`) is simpler and cheaper.
- The round trip is manual (export → upload → run → apply → import). Worth it
  only for models you can't otherwise reach.
