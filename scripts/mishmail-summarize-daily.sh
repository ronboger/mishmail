#!/bin/sh
# Daily incremental summary pass, run by the launchd agent.
#
# This is the ONE file to edit when changing how summaries get made — the
# launchd plist just runs this script, so switching models or moving to a
# cloud backend never means touching launchd again.
#
# Local (default): Ollama on this machine, nothing leaves the Mac.
# Cloud: comment out the local block, uncomment the cloud one, and put the
#        key in the environment (launchd agents do not read your shell rc,
#        so set it here or via `launchctl setenv`).

cd "$(dirname "$0")/.." || exit 1

# launchd agents cannot read MishMail's sandbox container, so take the token
# from a file outside it. The port is fixed in Settings → AI → MCP.
TOKEN_FILE="$HOME/.config/mishmail/mcp-token"
[ -r "$TOKEN_FILE" ] || { echo "no token at $TOKEN_FILE"; exit 1; }
MISHMAIL_MCP_TOKEN=$(cat "$TOKEN_FILE"); export MISHMAIL_MCP_TOKEN
MISHMAIL_MCP_PORT=41888; export MISHMAIL_MCP_PORT

# Nothing to do if the app isn't running (the server lives inside it).
/usr/bin/pgrep -x MishMail >/dev/null || { echo "MishMail not running; skipping"; exit 0; }

# --- local model -----------------------------------------------------------
exec /usr/bin/python3 scripts/mcp-summarize.py \
    --mailbox primary --limit 200 \
    --model qwen3:8b --jobs 4 \
    --skip-categories "Newsletter,Receipt"

# --- cloud model (uncomment to switch, and comment out the block above) -----
# export OPENAI_API_KEY="..."
# exec /usr/bin/python3 scripts/mcp-summarize.py \
#     --mailbox primary --limit 200 \
#     --backend openai --api-base https://api.openai.com/v1 --model <cheap-model> \
#     --jobs 8 --skip-categories "Newsletter,Receipt"
