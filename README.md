# claude-desktop-switcher

Make Claude Code chats from one Claude Desktop account visible in another
account's sidebar, via an interactive one-way sync.

## Why this exists

Claude Desktop stores Claude Code chats in two layers:

1. **Transcripts** (the actual conversations) in `~/.claude/projects/<project>/<session>.jsonl`.
   Shared across all accounts — never touched by account switching, and never
   touched by this tool.
2. **Sidebar index** — one small JSON per chat (title, project, branch, model)
   in a per-account bucket:

   | OS | Location |
   |---|---|
   | Windows | `%APPDATA%\Claude\claude-code-sessions\<account-uuid>\<org-uuid>\` |
   | Windows, packaged app | `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\claude-code-sessions\<account-uuid>\<org-uuid>\` |
   | macOS | `~/Library/Application Support/Claude/claude-code-sessions/<account-uuid>/<org-uuid>/` |
   | Linux | `~/.config/Claude/claude-code-sessions/<account-uuid>/<org-uuid>/` |

When you switch accounts, the app reads a different bucket — chats from the
other account aren't deleted, just not shown. This tool copies the small index
entries from one account's bucket into another's, so they show up there too.
The transcripts underneath are account-agnostic, so the copied chats open and
resume normally.

## Usage

**Windows**

```powershell
powershell -ExecutionPolicy Bypass -File sync.ps1          # interactive sync
powershell -ExecutionPolicy Bypass -File sync.ps1 -List    # just list accounts
powershell -ExecutionPolicy Bypass -File sync.ps1 -NameAccounts  # save manual labels
powershell -ExecutionPolicy Bypass -File sync.ps1 -DryRun  # preview adds/updates
```

**macOS / Linux**

```bash
chmod +x sync.sh           # first time only
./sync.sh                  # interactive sync
./sync.sh --list           # just list accounts
./sync.sh --name-accounts  # save manual labels
./sync.sh --dry-run        # preview adds/updates
```

The script lists every account that has used Claude Code on this machine. When
Claude's local web cache still has profile details for an account, the script
uses that name/email automatically. Otherwise it falls back to a fingerprint:
chat count, last activity, most-used projects, and recent chat titles, plus a
"last signed in" marker. If you run with `-NameAccounts` (`--name-accounts` on
macOS/Linux), you can still give any unidentified account a friendly name;
names are remembered in `accounts.conf` next to the script.

Then pick a source and destination, review the planned adds/updates, confirm,
done. Run it again with the accounts swapped if you want the other account's
sidebar metadata to become the source of truth.

In the interactive prompt, you can enter source and destination together as
`1,2` to copy from account 1 to account 2.

## Sync semantics

- **Source wins for sidebar metadata.** Copies index entries that are missing
  at the destination and updates existing destination entries when the source
  JSON differs. This carries over renames, archive state, grouping metadata,
  and other sidebar fields from the source account.
- **Dry run.** Use `-DryRun` or `--dry-run` to preview which chats would be
  added or updated before changing files.
- **Delete caveat.** If you delete a synced chat in the destination account,
  the next sync re-adds it (the file is "missing" again). Archive instead of
  delete if you want that hidden state to sync as metadata. Destination-only
  files are never deleted.
- **Refresh.** The sidebar re-reads its bucket on account switch or app
  restart, not live — switch away and back to see newly synced chats.
- **MCP approvals.** Each entry records MCP connector approvals from the
  account it was created under. Under the other account those connector IDs
  don't exist; the chat works fine, but tool approvals may be re-prompted.
- **Local chats only.** Cloud/remote sessions are listed server-side per
  account and can't be ported this way.

## Caution

This manipulates Claude Desktop's internal UI metadata, which is unsupported
behavior — a future app version could change the format. The tool updates
destination sidebar JSON files from the selected source, but never deletes
destination-only files. If you want a safety net, copy the
`claude-code-sessions` folder somewhere first.

If your install keeps its data somewhere non-standard, set `CLAUDE_USER_DATA`
to the app's data folder before running.

Both scripts first check the known install locations above (including the
Windows packaged app, the macOS sandboxed container, and Linux flatpak/snap
paths). If none works, they do a bounded search under the relevant app-data
roots for a real `claude-code-sessions` store and use the valid store with
the most local chat entries.
