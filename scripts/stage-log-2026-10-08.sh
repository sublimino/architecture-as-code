#!/usr/bin/env bash
# ── Staged Obsidian Daily Task Insert ──────────────────────────────────────────
# Generated during Antigravity CLI session 8a7265d4-1f97-4fb1-8b94-473291575db6.
# Bridge status was degraded (Obsidian renderer was disposed / window backgrounded).
# Run this script once Obsidian is focused or re-opened to log the session task.
# ───────────────────────────────────────────────────────────────────────────────

set -uo pipefail

DAILY_NOTE="${HOME}/Documents/Obsidian/v1/4. Archive/daily/2026-10-08.md"
TASK_NEEDLE="8a7265d4-1f97-4fb1-8b94-473291575db6"

echo "Checking Obsidian bridge health..."
if ! obsidian-bridge-health --quiet; then
  echo "Obsidian bridge is still degraded (socket responsive but renderer has not answered)." >&2
  echo "Please bring the Obsidian window to the foreground / refocus it, then run this script again." >&2
  exit 3
fi

if [ -f "$DAILY_NOTE" ] && rg -qF "$TASK_NEEDLE" "$DAILY_NOTE"; then
  echo "Task already present in $DAILY_NOTE. Nothing to do."
  exit 0
fi

echo "Adding session task to $DAILY_NOTE..."
obsidian-daily-task-add \
  --date 2026-10-08 \
  --started 21:00 \
  --completed \
  --subsection "Technical & AI Systems" \
  "🪐 PAI session: Signal Loom UI enhancements — Feeds super-table, historical ingestion density, wrapped raw observations, and risk agent click-throughs <span id=\"agy://open?id=8a7265d4-1f97-4fb1-8b94-473291575db6&dir=/home/andy/src/cp/osramp-demo&host=fortuna\" />"

# Verify write landed
if rg -qF "$TASK_NEEDLE" "$DAILY_NOTE"; then
  echo "Verified: session task successfully inserted into daily note."
else
  echo "Warning: insert command completed but needle was not found on disk." >&2
  exit 1
fi
