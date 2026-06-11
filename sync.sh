#!/usr/bin/env bash
# sync.sh - Claude Desktop session sidebar one-way sync (macOS / Linux)
#
# Claude Desktop scopes its Claude Code chat sidebar per signed-in account:
#   <userData>/claude-code-sessions/<account-uuid>/<org-uuid>/local_*.json
# The underlying chat transcripts (~/.claude/projects) are shared across
# accounts, so making a chat visible to another account only requires copying
# its small sidebar index entry into that account's bucket.
#
# This script is ADDITIVE ONLY: it copies entries that are missing at the
# destination and never overwrites or deletes anything.
#
# Usage:
#   ./sync.sh           # interactive
#   ./sync.sh --list    # just list accounts
#
# Compatible with bash 3.2 (stock macOS). Uses jq or python3 for chat titles
# if available; degrades gracefully without them.

set -u

LIST_ONLY=0
if [ "${1:-}" = "--list" ]; then LIST_ONLY=1; fi

# ---------------------------------------------------------------------------
# Platform paths (override with CLAUDE_USER_DATA if your install differs)
# ---------------------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Darwin)
    USER_DATA="${CLAUDE_USER_DATA:-$HOME/Library/Application Support/Claude}"
    LOG_FILE="$HOME/Library/Logs/Claude/main.log"
    ;;
  Linux)
    USER_DATA="${CLAUDE_USER_DATA:-$HOME/.config/Claude}"
    LOG_FILE="$USER_DATA/logs/main.log"
    ;;
  *)
    echo "Unsupported OS: $OS (use sync.ps1 on Windows)" >&2
    exit 1
    ;;
esac

STORE="$USER_DATA/claude-code-sessions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABELS_FILE="$SCRIPT_DIR/accounts.conf"

if [ ! -d "$STORE" ]; then
  echo "Session store not found: $STORE" >&2
  echo "Is Claude Desktop installed, and has Claude Code been used in it?" >&2
  echo "(If it lives elsewhere, set CLAUDE_USER_DATA to the app's data folder.)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Pick a JSON reader once at startup. "command -v" alone isn't enough:
# e.g. Windows ships a python3 stub that exists on PATH but can't run.
JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL="jq"
elif python3 -c 'pass' >/dev/null 2>&1; then
  JSON_TOOL="python3"
fi

json_get() { # $1=field $2=file -> value or empty
  case "$JSON_TOOL" in
    jq)
      jq -r --arg k "$1" '.[$k] // empty' "$2" 2>/dev/null || true
      ;;
    python3)
      python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[2])).get(sys.argv[1], "")
    print(v if v is not None else "")
except Exception:
    pass' "$1" "$2" 2>/dev/null || true
      ;;
  esac
}

file_mtime() {
  case "$OS" in
    Darwin) stat -f %m "$1" 2>/dev/null || echo 0 ;;
    *)      stat -c %Y "$1" 2>/dev/null || echo 0 ;;
  esac
}

fmt_epoch() {
  case "$OS" in
    Darwin) date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?' ;;
    *)      date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?' ;;
  esac
}

get_label() { # $1=key
  if [ -f "$LABELS_FILE" ]; then
    grep -m1 "^$1=" "$LABELS_FILE" 2>/dev/null | cut -d= -f2- || true
  fi
}

set_label() { # $1=key $2=label
  touch "$LABELS_FILE"
  grep -v "^$1=" "$LABELS_FILE" > "$LABELS_FILE.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >> "$LABELS_FILE.tmp"
  mv "$LABELS_FILE.tmp" "$LABELS_FILE"
}

# ---------------------------------------------------------------------------
# Which account signed in most recently? (best identity signal on disk -
# the app does not store account emails in plaintext anywhere)
# ---------------------------------------------------------------------------
LAST_SIGNED_IN=""
if [ -f "$LOG_FILE" ]; then
  idline="$(grep -F '[account] Identity changed' "$LOG_FILE" 2>/dev/null | tail -1 || true)"
  if [ -n "$idline" ]; then
    LAST_SIGNED_IN="$(printf '%s\n' "$idline" \
      | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
      | tail -1 || true)"
  fi
fi

# ---------------------------------------------------------------------------
# Enumerate account buckets and fingerprint each one
# (parallel indexed arrays for bash 3.2 compatibility)
# ---------------------------------------------------------------------------
B_KEY=(); B_PATH=(); B_ACC=(); B_COUNT=(); B_LAST=(); B_TITLES=(); B_PROJECTS=()

for accdir in "$STORE"/*/; do
  [ -d "$accdir" ] || continue
  acc="$(basename "$accdir")"
  for orgdir in "$accdir"*/; do
    [ -d "$orgdir" ] || continue
    org="$(basename "$orgdir")"

    # session files, newest first (filenames are uuid-based: no spaces)
    names="$(cd "$orgdir" && ls -t local_*.json 2>/dev/null || true)"
    count=0
    if [ -n "$names" ]; then count="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"; fi

    last_epoch=0
    titles=""
    projects=""
    if [ "$count" -gt 0 ]; then
      newest="$(printf '%s\n' "$names" | head -1)"
      last_epoch="$(file_mtime "$orgdir$newest")"

      # three most recent chat titles
      for n in $(printf '%s\n' "$names" | head -3); do
        t="$(json_get title "$orgdir$n")"
        [ -n "$t" ] && titles="$titles$t\n"
      done

      # top 3 project folders by chat count
      projects="$(for n in $names; do
          p="$(json_get originCwd "$orgdir$n")"
          [ -z "$p" ] && p="$(json_get cwd "$orgdir$n")"
          [ -n "$p" ] && basename "$p"
        done | sort | uniq -c | sort -rn | head -3 | sed 's/^ *[0-9]* //' \
          | tr '\n' ',' | sed 's/,$//;s/,/, /g')"
    fi

    B_KEY[${#B_KEY[@]}]="$acc/$org"
    B_PATH[${#B_PATH[@]}]="$orgdir"
    B_ACC[${#B_ACC[@]}]="$acc"
    B_COUNT[${#B_COUNT[@]}]="$count"
    B_LAST[${#B_LAST[@]}]="$last_epoch"
    B_TITLES[${#B_TITLES[@]}]="$titles"
    B_PROJECTS[${#B_PROJECTS[@]}]="$projects"
  done
done

NBUCKETS=${#B_KEY[@]}
if [ "$NBUCKETS" -lt 2 ]; then
  echo "Found $NBUCKETS account bucket(s) in $STORE." >&2
  echo "Syncing needs at least two accounts that have used Claude Code in the desktop app." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Show the accounts
# ---------------------------------------------------------------------------
echo ""
echo "Claude Desktop accounts on this machine"
echo "(the app doesn't store emails on disk, so accounts are identified by their chats)"

i=0
while [ "$i" -lt "$NBUCKETS" ]; do
  n=$((i + 1))
  label="$(get_label "${B_KEY[$i]}")"
  if [ -n "$label" ]; then
    header="[$n] $label"
  else
    header="[$n] unnamed account ($(printf '%s' "${B_ACC[$i]}" | cut -c1-8)...)"
  fi
  if [ -n "$LAST_SIGNED_IN" ] && [ "${B_ACC[$i]}" = "$LAST_SIGNED_IN" ]; then
    header="$header   <- last signed in"
  fi
  echo ""
  echo "$header"
  if [ "${B_LAST[$i]}" -gt 0 ]; then
    echo "    ${B_COUNT[$i]} chats | last active $(fmt_epoch "${B_LAST[$i]}")"
  else
    echo "    ${B_COUNT[$i]} chats"
  fi
  [ -n "${B_PROJECTS[$i]}" ] && echo "    projects: ${B_PROJECTS[$i]}"
  if [ -n "${B_TITLES[$i]}" ]; then
    printf '%b' "${B_TITLES[$i]}" | sed 's/^/      - /'
  fi
  i=$((i + 1))
done
echo ""

if [ "$LIST_ONLY" -eq 1 ]; then exit 0; fi

# ---------------------------------------------------------------------------
# Offer to name unnamed accounts (saved to accounts.conf for next time)
# ---------------------------------------------------------------------------
i=0
while [ "$i" -lt "$NBUCKETS" ]; do
  n=$((i + 1))
  if [ -z "$(get_label "${B_KEY[$i]}")" ]; then
    printf "Name for account [%s] (e.g. 'zerospace dev', Enter to skip): " "$n"
    read -r name
    [ -n "$name" ] && set_label "${B_KEY[$i]}" "$name"
  fi
  i=$((i + 1))
done

display_name() { # $1=index(0-based)
  local l
  l="$(get_label "${B_KEY[$1]}")"
  if [ -n "$l" ]; then printf '%s' "$l"; else printf 'account %s...' "$(printf '%s' "${B_ACC[$1]}" | cut -c1-8)"; fi
}

# ---------------------------------------------------------------------------
# Pick source and destination
# ---------------------------------------------------------------------------
select_bucket() { # $1=prompt $2=excluded-number(0 for none) -> sets SELECTED
  while :; do
    printf '%s' "$1"
    read -r raw
    case "$raw" in
      *[!0-9]*|'') ;;
      *)
        if [ "$raw" -ge 1 ] && [ "$raw" -le "$NBUCKETS" ] && [ "$raw" -ne "$2" ]; then
          SELECTED="$raw"
          return 0
        fi
        ;;
    esac
    if [ "$2" -gt 0 ]; then
      echo "Enter a number from 1 to $NBUCKETS (other than $2)."
    else
      echo "Enter a number from 1 to $NBUCKETS."
    fi
  done
}

select_bucket "Copy chats FROM account #: " 0
SRC_N="$SELECTED"
select_bucket "Copy chats TO account #: " "$SRC_N"
DST_N="$SELECTED"

src_i=$((SRC_N - 1)); dst_i=$((DST_N - 1))
SRC_PATH="${B_PATH[$src_i]}"
DST_PATH="${B_PATH[$dst_i]}"

# ---------------------------------------------------------------------------
# Plan and confirm
# ---------------------------------------------------------------------------
src_total=0; to_copy=0; COPY_LIST=""
for f in "$SRC_PATH"local_*.json; do
  [ -e "$f" ] || continue
  src_total=$((src_total + 1))
  base="$(basename "$f")"
  if [ ! -e "$DST_PATH$base" ]; then
    to_copy=$((to_copy + 1))
    COPY_LIST="$COPY_LIST$base\n"
  fi
done

echo ""
echo "$src_total chats at source; $((src_total - to_copy)) already present at destination; $to_copy to copy."

if [ "$to_copy" -eq 0 ]; then
  echo "Nothing to do - '$(display_name "$dst_i")' is already up to date."
  exit 0
fi

if pgrep -x "Claude" >/dev/null 2>&1 || pgrep -x "claude-desktop" >/dev/null 2>&1 || pgrep -x "claude" >/dev/null 2>&1; then
  echo "Note: Claude Desktop is running. Copying is safe, but the sidebar only"
  echo "re-reads this folder on account switch or app restart."
fi

printf "Copy %s chat(s) from '%s' to '%s'? [y/N] " "$to_copy" "$(display_name "$src_i")" "$(display_name "$dst_i")"
read -r confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "Aborted - nothing was copied."; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Copy (additive: only files missing at the destination)
# ---------------------------------------------------------------------------
copied=0
printf '%b' "$COPY_LIST" | while read -r base; do
  [ -n "$base" ] || continue
  title="$(json_get title "$SRC_PATH$base")"
  cp "$SRC_PATH$base" "$DST_PATH$base"
  echo "  + ${title:-$base}"
done
# (the while runs in a subshell; recount for the summary)
copied="$to_copy"

echo ""
echo "Copied $copied chat(s). Switch to that account (or restart Claude Desktop) to see them."
echo "Tip: archive synced chats you don't want instead of deleting them -"
echo "deleted ones reappear on the next sync, archived ones stay hidden."
