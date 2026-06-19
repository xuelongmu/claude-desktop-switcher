#!/usr/bin/env bash
# sync.sh - Claude Desktop session sidebar one-way sync (macOS / Linux)
#
# Claude Desktop scopes its Claude Code chat sidebar per signed-in account:
#   <userData>/claude-code-sessions/<account-uuid>/<org-uuid>/local_*.json
# The underlying chat transcripts (~/.claude/projects) are shared across
# accounts, so making a chat visible to another account only requires copying
# its small sidebar index entry into that account's bucket.
#
# This script reconciles from source to destination: it copies missing entries
# and updates existing entries whose sidebar metadata differs. It never deletes.
#
# Usage:
#   ./sync.sh                  # interactive
#   ./sync.sh --list           # just list accounts
#   ./sync.sh --name-accounts  # save manual labels for unnamed accounts
#   ./sync.sh --dry-run        # preview only
#
# Compatible with bash 3.2 (stock macOS). Uses jq or python3 for chat titles
# and python3 for auto-labels from Claude's local web cache; degrades
# gracefully without them.

set -u

LIST_ONLY=0
NAME_ACCOUNTS=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    --name-accounts) NAME_ACCOUNTS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--list] [--name-accounts] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  *)
    echo "Unsupported OS: $OS (use sync.ps1 on Windows)" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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

is_uuid() {
  printf '%s' "$1" \
    | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# ---------------------------------------------------------------------------
# Locate the app's user-data folder. CLAUDE_USER_DATA overrides everything;
# otherwise check the known install paths (standard plus fixed-shape sandbox /
# flatpak / snap layouts), and only if none holds a real store fall back to a
# bounded recursive search. Among valid stores, use the one with the most local
# chat entries.
# ---------------------------------------------------------------------------
store_stats() { # $1=userData -> "chats buckets last_epoch"
  local store="$1/claude-code-sessions" chats=0 buckets=0 last=0
  local accdir orgdir names count m
  if [ -d "$store" ]; then
    for accdir in "$store"/*/; do
      [ -d "$accdir" ] || continue
      is_uuid "$(basename "$accdir")" || continue
      for orgdir in "$accdir"*/; do
        [ -d "$orgdir" ] || continue
        is_uuid "$(basename "$orgdir")" || continue
        names="$(cd "$orgdir" && ls -t local_*.json 2>/dev/null || true)"
        [ -n "$names" ] || continue
        count="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
        buckets=$((buckets + 1))
        chats=$((chats + count))
        m="$(file_mtime "$orgdir$(printf '%s\n' "$names" | head -1)")"
        [ "$m" -gt "$last" ] && last="$m"
      done
    done
  fi
  echo "$chats $buckets $last"
}

CANDIDATES=()

add_candidate() {
  local p="$1" e
  [ -n "$p" ] || return 0
  for e in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    [ "$e" = "$p" ] && return 0
  done
  CANDIDATES[${#CANDIDATES[@]}]="$p"
  return 0
}

# Add the known fixed-shape locations for this OS (cheap globs, no recursion).
add_known_candidates() {
  local d
  case "$OS" in
    Darwin)
      add_candidate "$HOME/Library/Application Support/Claude"
      for d in "$HOME/Library/Containers"/*/"Data/Library/Application Support/Claude"; do
        [ -d "$d" ] && add_candidate "$d"
      done
      for d in "$HOME/Library/Group Containers"/*/"Library/Application Support/Claude"; do
        [ -d "$d" ] && add_candidate "$d"
      done
      ;;
    Linux)
      add_candidate "$HOME/.config/Claude"
      for d in "$HOME/.var/app"/*/"config/Claude"; do
        [ -d "$d" ] && add_candidate "$d"
      done
      for d in "$HOME/snap"/*/"current/.config/Claude"; do
        [ -d "$d" ] && add_candidate "$d"
      done
      ;;
  esac
}

# Last resort: bounded recursive search under the app-data roots, adding the
# parent of any claude-code-sessions store found. Only used when the known
# locations turn up nothing, because find over these trees can be slow.
scan_for_candidates() {
  local root depth hit
  case "$OS" in
    Darwin) set -- "$HOME/Library/Application Support:4" "$HOME/Library/Containers:6" ;;
    Linux)  set -- "$HOME/.config:4" "$HOME/.var/app:5" "$HOME/snap:6" ;;
    *)      return 0 ;;
  esac
  for spec in "$@"; do
    root="${spec%:*}"; depth="${spec##*:}"
    [ -d "$root" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      add_candidate "$(dirname "$hit")"
    done <<EOF
$(find "$root" -maxdepth "$depth" -type d -name claude-code-sessions 2>/dev/null)
EOF
  done
}

# Choose the valid store with the most chats (tie-break: more buckets, then more
# recent). Sets USER_DATA; returns 0 if any candidate held a real store.
USER_DATA=""
pick_best_candidate() {
  local c stats s_chats s_buckets s_last
  local best_chats=-1 best_buckets=-1 best_last=-1
  USER_DATA=""
  for c in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    stats="$(store_stats "$c")"
    set -- $stats
    s_chats="$1"; s_buckets="$2"; s_last="$3"
    [ "$s_buckets" -gt 0 ] || continue
    if [ "$s_chats" -gt "$best_chats" ] \
      || { [ "$s_chats" -eq "$best_chats" ] && [ "$s_buckets" -gt "$best_buckets" ]; } \
      || { [ "$s_chats" -eq "$best_chats" ] && [ "$s_buckets" -eq "$best_buckets" ] \
           && [ "$s_last" -gt "$best_last" ]; }; then
      USER_DATA="$c"
      best_chats="$s_chats"; best_buckets="$s_buckets"; best_last="$s_last"
    fi
  done
  [ -n "$USER_DATA" ]
}

if [ -n "${CLAUDE_USER_DATA:-}" ]; then
  add_candidate "$CLAUDE_USER_DATA"
  pick_best_candidate || USER_DATA="$CLAUDE_USER_DATA"
else
  add_known_candidates
  if ! pick_best_candidate; then
    scan_for_candidates
    pick_best_candidate || true
  fi
  [ -n "$USER_DATA" ] || USER_DATA="${CANDIDATES[0]:-}"
fi
[ -n "$USER_DATA" ] || case "$OS" in
  Darwin) USER_DATA="$HOME/Library/Application Support/Claude" ;;
  *)      USER_DATA="$HOME/.config/Claude" ;;
esac

STORE="$USER_DATA/claude-code-sessions"
case "$OS" in
  Darwin)
    LOG_FILE="$HOME/Library/Logs/Claude/main.log"
    [ -f "$LOG_FILE" ] || LOG_FILE="$USER_DATA/logs/main.log"
    ;;
  Linux)
    LOG_FILE="$USER_DATA/logs/main.log"
    ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABELS_FILE="$SCRIPT_DIR/accounts.conf"

if [ ! -d "$STORE" ]; then
  echo "Session store not found: $STORE" >&2
  echo "Checked locations:" >&2
  for c in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    echo "  - $c/claude-code-sessions" >&2
  done
  echo "Is Claude Desktop installed, and has Claude Code been used in it?" >&2
  echo "(If it lives elsewhere, set CLAUDE_USER_DATA to the app's data folder.)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# JSON reader. "command -v" alone isn't enough: e.g. Windows ships a python3
# stub that exists on PATH but can't run.
# ---------------------------------------------------------------------------
PY_OK=0
if python3 -c 'pass' >/dev/null 2>&1; then PY_OK=1; fi

JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL="jq"
elif [ "$PY_OK" -eq 1 ]; then
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

# ---------------------------------------------------------------------------
# Friendly labels (saved per account UUID in accounts.conf)
# ---------------------------------------------------------------------------
conf_get() { # $1=key
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
# Auto-labels: Claude's local web cache (IndexedDB) sometimes still holds
# profile details for accounts that signed in here. Scan it for account
# UUIDs that sit next to an email_address field and label them.
# ---------------------------------------------------------------------------
AUTO_LABELS=""
if [ "$PY_OK" -eq 1 ] && [ -d "$USER_DATA/IndexedDB" ]; then
  AUTO_LABELS="$(python3 - "$USER_DATA/IndexedDB" <<'PYEOF' 2>/dev/null || true
import os, re, sys

root = sys.argv[1]
uuid_re = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
email_re = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')

def quoted_field(text, start_at, field):
    fi = text.find(field, start_at)
    if fi < 0:
        return None
    qi = text.find('"', fi + len(field))
    while 0 <= qi < len(text) - 1:
        vs = qi + 1
        ve = text.find('"', vs)
        if ve < 0:
            return None
        v = text[vs:ve].strip()
        v = re.sub(r'^[^\w@]+', '', v).strip()
        if re.search(r'[A-Za-z0-9]', v):
            return v
        qi = text.find('"', ve + 1)
    return None

labels = {}
for dirpath, _dirs, files in os.walk(root):
    for name in files:
        try:
            with open(os.path.join(dirpath, name), 'rb') as fh:
                text = fh.read().decode('utf-8', 'replace')
        except OSError:
            continue
        for m in uuid_re.finditer(text):
            ws = max(0, m.start() - 500)
            window = text[ws:ws + 1800]
            if 'email_address' not in window:
                continue
            fs = m.start() - ws
            raw = quoted_field(window, fs, 'email_address')
            em = email_re.search(raw) if raw else None
            if not em:
                continue
            email = em.group(0)
            full = quoted_field(window, fs, 'full_name')
            disp = quoted_field(window, fs, 'display_name')
            if full and full != disp:
                label = '%s <%s>' % (full, email)
            elif disp:
                label = '%s <%s>' % (disp, email)
            else:
                label = email
            labels[m.group(0)] = label

for k in sorted(labels):
    sys.stdout.write('%s\t%s\n' % (k, labels[k]))
PYEOF
)"
fi

auto_label_for() { # $1=account-uuid
  [ -n "$AUTO_LABELS" ] || return 0
  printf '%s\n' "$AUTO_LABELS" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'
}

# ---------------------------------------------------------------------------
# Which account signed in most recently? (useful when profile identity is not
# cached locally for older accounts)
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
      tcount=0
      for n in $names; do
        [ "$tcount" -ge 3 ] && break
        t="$(json_get title "$orgdir$n")"
        if [ -n "$t" ]; then
          titles="$titles$t\n"
          tcount=$((tcount + 1))
        fi
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

bucket_label() { # $1=index -> label or empty (manual by uuid, manual by key, auto)
  local l
  l="$(conf_get "${B_ACC[$1]}")"
  [ -n "$l" ] || l="$(conf_get "${B_KEY[$1]}")"
  [ -n "$l" ] || l="$(auto_label_for "${B_ACC[$1]}")"
  printf '%s' "$l"
}

display_name() { # $1=index(0-based)
  local l
  l="$(bucket_label "$1")"
  if [ -n "$l" ]; then
    printf '%s' "$l"
  else
    printf 'account %s...' "$(printf '%s' "${B_ACC[$1]}" | cut -c1-8)"
  fi
}

print_bucket_list() {
  local i n label header
  echo ""
  echo "Claude Desktop accounts on this machine"
  echo "(cached profiles are named automatically; otherwise accounts are identified by their chats)"

  i=0
  while [ "$i" -lt "$NBUCKETS" ]; do
    n=$((i + 1))
    label="$(bucket_label "$i")"
    if [ -n "$label" ]; then
      header="[$n] $label ($(printf '%s' "${B_ACC[$i]}" | cut -c1-8)...)"
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
}

# ---------------------------------------------------------------------------
# Show the accounts and optionally save manual labels
# ---------------------------------------------------------------------------
print_bucket_list

if [ "$LIST_ONLY" -eq 1 ]; then exit 0; fi

if [ "$NAME_ACCOUNTS" -eq 1 ]; then
  labels_changed=0
  i=0
  while [ "$i" -lt "$NBUCKETS" ]; do
    n=$((i + 1))
    if [ -z "$(bucket_label "$i")" ]; then
      printf "Name for account [%s] (e.g. 'work', Enter to skip): " "$n"
      read -r name || exit 1
      if [ -n "$name" ]; then
        set_label "${B_ACC[$i]}" "$name"
        labels_changed=1
      fi
    fi
    i=$((i + 1))
  done

  if [ "$labels_changed" -eq 1 ]; then
    print_bucket_list
  fi
fi

# ---------------------------------------------------------------------------
# Pick source and destination
# ---------------------------------------------------------------------------
select_bucket() { # $1=prompt $2=excluded-number(0 for none) -> sets SELECTED
  local raw
  while :; do
    printf '%s' "$1"
    read -r raw || exit 1
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

select_pair() { # sets SRC_N and DST_N
  local raw nums count a b
  while :; do
    printf 'Copy chats FROM,TO account numbers (e.g. 1,2; Enter for separate prompts): '
    read -r raw || exit 1
    if [ -z "$raw" ]; then
      select_bucket "Copy chats FROM account #: " 0
      SRC_N="$SELECTED"
      select_bucket "Copy chats TO account #: " "$SRC_N"
      DST_N="$SELECTED"
      return 0
    fi

    nums="$(printf '%s\n' "$raw" | grep -oE '[0-9]+' || true)"
    count=0
    [ -n "$nums" ] && count="$(printf '%s\n' "$nums" | wc -l | tr -d ' ')"
    if [ "$count" -ne 2 ]; then
      echo "Enter exactly two account numbers, like 1,2."
      continue
    fi

    a="$(printf '%s\n' "$nums" | head -1)"
    b="$(printf '%s\n' "$nums" | tail -1)"
    if [ "$a" -lt 1 ] || [ "$a" -gt "$NBUCKETS" ] || [ "$b" -lt 1 ] || [ "$b" -gt "$NBUCKETS" ]; then
      echo "Enter numbers from 1 to $NBUCKETS."
      continue
    fi
    if [ "$a" -eq "$b" ]; then
      echo "Source and destination must be different accounts."
      continue
    fi

    SRC_N="$a"
    DST_N="$b"
    return 0
  done
}

select_pair

src_i=$((SRC_N - 1)); dst_i=$((DST_N - 1))
SRC_PATH="${B_PATH[$src_i]}"
DST_PATH="${B_PATH[$dst_i]}"

# ---------------------------------------------------------------------------
# Plan and confirm
# ---------------------------------------------------------------------------
src_total=0; to_add=0; to_update=0; ADD_LIST=""; UPDATE_LIST=""
for f in "$SRC_PATH"local_*.json; do
  [ -e "$f" ] || continue
  src_total=$((src_total + 1))
  base="$(basename "$f")"
  if [ ! -e "$DST_PATH$base" ]; then
    to_add=$((to_add + 1))
    ADD_LIST="$ADD_LIST$base\n"
  elif ! cmp -s "$f" "$DST_PATH$base"; then
    to_update=$((to_update + 1))
    UPDATE_LIST="$UPDATE_LIST$base\n"
  fi
done
unchanged=$((src_total - to_add - to_update))

echo ""
echo "$src_total chats at source; $unchanged unchanged at destination; $to_add to add; $to_update to update."

if [ "$to_add" -eq 0 ] && [ "$to_update" -eq 0 ]; then
  echo "Nothing to do - '$(display_name "$dst_i")' is already up to date."
  exit 0
fi

printf '%b' "$ADD_LIST" | while read -r base; do
  [ -n "$base" ] || continue
  title="$(json_get title "$SRC_PATH$base")"
  echo "  + ${title:-${base%.json}}"
done
printf '%b' "$UPDATE_LIST" | while read -r base; do
  [ -n "$base" ] || continue
  title="$(json_get title "$SRC_PATH$base")"
  echo "  ~ ${title:-${base%.json}}"
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "Dry run only - no files were changed."
  exit 0
fi

if pgrep -x "Claude" >/dev/null 2>&1 || pgrep -x "claude-desktop" >/dev/null 2>&1 || pgrep -x "claude" >/dev/null 2>&1; then
  echo "Note: Claude Desktop is running. Copying is safe, but the sidebar only"
  echo "re-reads this folder on account switch or app restart."
fi

printf "Apply %s add(s) and %s update(s) from '%s' to '%s'? [y/N] " "$to_add" "$to_update" "$(display_name "$src_i")" "$(display_name "$dst_i")"
read -r confirm || exit 1
case "$confirm" in
  y*|Y*) ;;
  *) echo "Aborted - nothing was changed."; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Copy/update from source to destination. Destination-only files are left alone.
# ---------------------------------------------------------------------------
printf '%b' "$ADD_LIST" | while read -r base; do
  [ -n "$base" ] || continue
  title="$(json_get title "$SRC_PATH$base")"
  cp "$SRC_PATH$base" "$DST_PATH$base"
  echo "  + ${title:-${base%.json}}"
done
printf '%b' "$UPDATE_LIST" | while read -r base; do
  [ -n "$base" ] || continue
  title="$(json_get title "$SRC_PATH$base")"
  cp "$SRC_PATH$base" "$DST_PATH$base"
  echo "  ~ ${title:-${base%.json}}"
done

echo ""
echo "Applied $to_add add(s) and $to_update update(s). Switch to that account (or restart Claude Desktop) to see them."
echo "Tip: destination-only chats are left alone. Archive state and renames follow"
echo "the source account when its sidebar JSON is updated."
