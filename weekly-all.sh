#!/usr/bin/env bash
#
# weekly-all.sh — run comprehension-digest across every git repo under the
# given roots, using local Ollama (no API key). Meant for a weekly cron.
#
# Each repo is digested incrementally (watermark since last run) and a copy is
# dropped into the Obsidian vault. Repos with no changes are skipped by digest.sh.
#
# Usage:
#   ./weekly-all.sh                 # roots: ~/Dev and ~/Dev/projetos
#   ./weekly-all.sh ~/code ~/work   # custom roots
#
# Env: DIGEST_MODEL (default gemma4:e2b-mlx), DIGEST_MAX_DIFF_LINES (default 800).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIGEST="$HERE/digest.sh"

ROOTS=("$@")
[[ ${#ROOTS[@]} -eq 0 ]] && ROOTS=("$HOME/Dev" "$HOME/Dev/projetos")

export DIGEST_PROVIDER=ollama
export DIGEST_MODEL="${DIGEST_MODEL:-gemma4:e2b-mlx}"
export DIGEST_MAX_DIFF_LINES="${DIGEST_MAX_DIFF_LINES:-800}"

LOG_TS="$(date '+%Y-%m-%d %H:%M')"
echo "=== weekly-all $LOG_TS · provider=ollama model=$DIGEST_MODEL ==="

# Bail early if Ollama isn't reachable — no point looping.
if ! curl -sS --max-time 5 "${OLLAMA_HOST:-http://localhost:11434}/api/tags" >/dev/null 2>&1; then
  echo "!! Ollama not reachable — aborting" >&2
  exit 1
fi

# Find git repos one level deep under each root (repos live at ROOT/<name>).
for ROOT in "${ROOTS[@]}"; do
  [[ -d "$ROOT" ]] || continue
  for DIR in "$ROOT"/*/; do
    [[ -d "$DIR/.git" ]] || continue
    NAME="$(basename "$DIR")"
    echo "--- $NAME"
    "$DIGEST" --repo "$DIR" --vault 2>&1 | sed 's/^/    /' || \
      echo "    !! failed: $NAME (continuing)"
  done
done

echo "=== done ==="
