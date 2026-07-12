#!/usr/bin/env bash
#
# comprehension-digest — turn a repo's recent changes into a "why-focused"
# markdown reading digest. No audio, no TTS. Combats comprehension debt on
# fast-moving repos (idea: @mattpocockuk, reading-only variant).
#
# Key design choice: a `git diff` only shows the WHAT. The WHY lives in commit
# messages, merge commits and PR context. So we bundle log + diff together and
# instruct the model to lead with intent, not line-by-line description.
#
# Usage:
#   ./digest.sh                     # since last digest (or 7 days if none)
#   ./digest.sh --since "3 days ago"
#   ./digest.sh --since main        # a ref/tag/sha also works
#   ./digest.sh --repo /path/to/repo
#   ./digest.sh --dry-run           # build prompt only, don't call the API
#   ./digest.sh --vault             # also write the digest into the Obsidian vault
#   ./digest.sh --vault ~/notes     # ...into a custom vault dir
#   ./digest.sh --provider ollama   # generate locally via Ollama instead of Anthropic
#   ./digest.sh --provider ollama --model qwen2.5-coder
#
# Needs: git + curl + jq.
# Providers:
#   anthropic (default) — needs ANTHROPIC_API_KEY. Default model claude-opus-4-8.
#   ollama              — local OpenAI-compatible endpoint (OLLAMA_HOST, default
#                         http://localhost:11434). No key needed; OLLAMA_API_KEY
#                         only if you fronted it with auth. Default model llama3.1.
# Without a required key (or with --dry-run) it writes the ready-to-paste prompt.
# --vault only applies to a generated digest, not the prompt fallback.

set -euo pipefail

REPO="$(pwd)"
SINCE=""
DRY_RUN=0
OUT_DIR=""
VAULT=0
VAULT_DIR="${DIGEST_VAULT_DIR:-$HOME/Obsidian/vault-michel/06-GENERATED/digests}"
PROVIDER="${DIGEST_PROVIDER:-anthropic}"
MODEL="${DIGEST_MODEL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)    SINCE="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --out)      OUT_DIR="$2"; shift 2 ;;
    --vault)   VAULT=1
               # optional dir arg: consume it only if it's not another flag
               if [[ -n "${2:-}" && "$2" != --* ]]; then VAULT_DIR="$2"; shift; fi
               shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Provider config. anthropic = hosted API (needs key). ollama = local
# OpenAI-compatible endpoint (key optional; usually none for localhost).
case "$PROVIDER" in
  anthropic)
    : "${MODEL:=claude-opus-4-8}"
    API_KEY="${ANTHROPIC_API_KEY:-}"
    KEY_REQUIRED=1 ;;
  ollama)
    : "${MODEL:=llama3.1}"
    OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
    API_KEY="${OLLAMA_API_KEY:-}"   # optional; only if you fronted Ollama with auth
    KEY_REQUIRED=0 ;;
  *)
    echo "error: unknown provider '$PROVIDER' (use: anthropic | ollama)" >&2; exit 2 ;;
esac

cd "$REPO"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: $REPO is not a git repo" >&2; exit 1; }

REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"
STATE_DIR="${OUT_DIR:-$(git rev-parse --show-toplevel)/.digests}"
mkdir -p "$STATE_DIR"
STAMP_FILE="$STATE_DIR/.last"

# Resolve the range start.
if [[ -z "$SINCE" ]]; then
  if [[ -f "$STAMP_FILE" ]]; then
    SINCE="$(cat "$STAMP_FILE")"
  else
    SINCE="7 days ago"
  fi
fi

# A ref/sha uses A..B range; a date uses --since.
if git rev-parse --verify --quiet "$SINCE^{commit}" >/dev/null 2>&1; then
  RANGE_ARGS=("$SINCE..HEAD")
  RANGE_DESC="$SINCE..HEAD"
else
  RANGE_ARGS=(--since="$SINCE")
  RANGE_DESC="since \"$SINCE\""
fi

echo ">> repo: $REPO_NAME   range: $RANGE_DESC" >&2

LOG="$(git log "${RANGE_ARGS[@]}" --no-merges --pretty=format:'--- %h %an, %ar%n%s%n%b' 2>/dev/null || true)"
STAT="$(git log "${RANGE_ARGS[@]}" --pretty=format: --stat 2>/dev/null | grep -v '^$' || true)"
DIFF="$(git log "${RANGE_ARGS[@]}" -p --no-merges 2>/dev/null || true)"

if [[ -z "$LOG" && -z "$DIFF" ]]; then
  echo ">> no changes in range. nothing to digest." >&2
  exit 0
fi

# Cap the diff so a huge range doesn't blow the context / cost. Log is kept
# whole because commit messages are the highest-signal part (the WHY).
MAX_DIFF_LINES="${DIGEST_MAX_DIFF_LINES:-4000}"
DIFF_TRUNC=""
DIFF_LINES=$(printf '%s\n' "$DIFF" | wc -l | tr -d ' ')
if (( DIFF_LINES > MAX_DIFF_LINES )); then
  # sed (not head) so the writer isn't hit with SIGPIPE under `set -o pipefail`.
  DIFF="$(printf '%s\n' "$DIFF" | sed -n "1,${MAX_DIFF_LINES}p")"
  DIFF_TRUNC=$'\n\n[diff truncated at '"$MAX_DIFF_LINES"' lines — commit log above is complete]'
fi

read -r -d '' PROMPT <<EOF || true
You are writing a "comprehension digest" for a developer who has been away from
the repo "$REPO_NAME" and needs to catch up on what changed and WHY.

Rules:
- Lead with the WHY (intent, motivation, trade-offs), not a line-by-line recap
  of the diff. The reader can read the diff themselves; they cannot read minds.
- Infer intent from commit messages and merge/PR context. The diff shows WHAT
  changed; the log tells you WHY. When the why is unclear, say so explicitly
  rather than inventing a plausible motivation.
- Group related commits into themes, not one blob per commit.
- Call out anything that changes behavior, public API, config, or that a
  teammate would trip over. Flag risky or surprising changes.
- Markdown. Structure: a 3-5 bullet TL;DR, then "## Themes" with a short
  narrative per theme, then "## Watch out" for gotchas. Be concise. No fluff.

=== COMMIT LOG ($RANGE_DESC) ===
$LOG

=== FILES CHANGED (stat) ===
$STAT

=== DIFF ===
$DIFF$DIFF_TRUNC
EOF

TS="$(date +%Y-%m-%d_%H%M)"
OUT_FILE="$STATE_DIR/digest_${TS}.md"

# Prompt-only fallback: dry-run, or a hosted provider with no key.
MISSING_KEY=0
[[ $KEY_REQUIRED -eq 1 && -z "$API_KEY" ]] && MISSING_KEY=1
if [[ $DRY_RUN -eq 1 || $MISSING_KEY -eq 1 ]]; then
  PROMPT_FILE="$STATE_DIR/prompt_${TS}.md"
  printf '%s\n' "$PROMPT" > "$PROMPT_FILE"
  [[ $MISSING_KEY -eq 1 && $DRY_RUN -eq 0 ]] && \
    echo ">> ANTHROPIC_API_KEY not set — wrote prompt instead of calling API." >&2
  echo ">> prompt: $PROMPT_FILE" >&2
  echo ">> paste it into an LLM, or set a key / use --provider ollama to auto-generate." >&2
  [[ $VAULT -eq 1 ]] && \
    echo ">> --vault ignored: no digest generated (prompt-only mode)." >&2
  exit 0
fi

command -v jq >/dev/null || { echo "error: jq required for API mode" >&2; exit 1; }

echo ">> calling $PROVIDER / $MODEL ..." >&2
case "$PROVIDER" in
  anthropic)
    BODY="$(jq -n --arg m "$MODEL" --arg p "$PROMPT" '{
      model: $m, max_tokens: 4000,
      messages: [ { role: "user", content: $p } ]
    }')"
    RESP="$(curl -sS https://api.anthropic.com/v1/messages \
      -H "x-api-key: $API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d "$BODY")"
    TEXT="$(printf '%s' "$RESP" | jq -r '.content[0].text // empty')"
    ;;
  ollama)
    # OpenAI-compatible chat endpoint. Auth header only if a key was provided.
    BODY="$(jq -n --arg m "$MODEL" --arg p "$PROMPT" '{
      model: $m, stream: false,
      messages: [ { role: "user", content: $p } ]
    }')"
    AUTH=(); [[ -n "$API_KEY" ]] && AUTH=(-H "Authorization: Bearer $API_KEY")
    # ${AUTH[@]+..} guards against "unbound variable" on empty array (bash 3.2).
    RESP="$(curl -sS "$OLLAMA_HOST/v1/chat/completions" \
      ${AUTH[@]+"${AUTH[@]}"} \
      -H "content-type: application/json" \
      -d "$BODY")"
    TEXT="$(printf '%s' "$RESP" | jq -r '.choices[0].message.content // empty')"
    ;;
esac

if [[ -z "$TEXT" ]]; then
  echo "error: $PROVIDER returned no text:" >&2
  printf '%s\n' "$RESP" | jq -r '.error.message // .error // .' >&2
  exit 1
fi

{
  echo "# Digest — $REPO_NAME"
  echo "_${RANGE_DESC} · ${PROVIDER}/${MODEL} · generated ${TS}_"
  echo
  printf '%s\n' "$TEXT"
} > "$OUT_FILE"

# Advance the watermark to current HEAD so the next run starts here.
git rev-parse HEAD > "$STAMP_FILE"

echo ">> wrote $OUT_FILE" >&2

# Optionally drop a copy into the Obsidian vault, with frontmatter so it's a
# first-class note (tags/dataview) instead of a loose file.
if [[ $VAULT -eq 1 ]]; then
  mkdir -p "$VAULT_DIR"
  VAULT_FILE="$VAULT_DIR/${REPO_NAME}_${TS}.md"
  # strip embedded double-quotes so the YAML value stays valid
  RANGE_YAML="${RANGE_DESC//\"/}"
  {
    echo "---"
    echo "title: Digest — $REPO_NAME"
    echo "type: digest"
    echo "repo: $REPO_NAME"
    echo "range: \"$RANGE_YAML\""
    echo "generated: $(date +%Y-%m-%d)"
    echo "tags: [digest, comprehension-debt]"
    echo "---"
    echo
    printf '%s\n' "$TEXT"
  } > "$VAULT_FILE"
  echo ">> vault: $VAULT_FILE" >&2
fi
