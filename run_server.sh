#!/usr/bin/env bash
# Starts the RBBScan server in the foreground; Ctrl-C stops it.
#   RBB_HOST      bind address (default: this Mac's Tailscale IPv4 address)
#   RBB_PORT      port (default 8787)
#   RBB_DATA_DIR  database + images directory (default ./data)
#   RBB_AI_READER codex: AI check through the Codex CLI on your ChatGPT plan
#                 (otherwise it uses OPENAI_API_KEY when that is set)
set -euo pipefail
cd "$(dirname "$0")"

host="${RBB_HOST:-}"
if [[ -z "$host" ]]; then
  host="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$host" ]]; then
  echo "Could not determine the Tailscale IP. Is Tailscale running? Set RBB_HOST to override." >&2
  exit 1
fi
port="${RBB_PORT:-8787}"
export RBB_DATA_DIR="${RBB_DATA_DIR:-$PWD/data}"

echo "Review page:     http://$host:$port/"
echo "Live dashboard:  http://$host:$port/live"
echo "Data directory:  $RBB_DATA_DIR"
cd server
exec uv run --frozen uvicorn rbbscan.app:create_default_app --factory --host "$host" --port "$port" --timeout-graceful-shutdown 2
