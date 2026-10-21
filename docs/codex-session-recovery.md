# Codex session recovery research

Moppo does not offer recovery for deleted Codex sessions.
Codex session deletion is permanent. The confirmation sheet and receipts tell the user this.
[Issue #200](https://github.com/anguria-studio/Moppo/issues/200) recorded this research and closed without recovery support.

## Decision

A recovery copy uses about the same space as the deleted session.
Moppo removes files to free space, so a retained copy works against that goal.
Moppo shows Codex sessions as user data. They never appear in Safe to Remove.
The user must select each session group and confirm the permanent-deletion warning.
These protections replace a recovery path.

## Findings

A transcript copy alone does not restore a usable conversation.
A complete restoration must also restore these items:

- The thread rows in `state_5.sqlite`, which hold titles and archive state.
- The child edges in `thread_spawn_edges`, including the closed state of each child.
- The entries in `session_index.jsonl` that hold session names.
- The paginated history rows in `thread_history_1.sqlite`, when that file exists.
- The history file of each descendant in the session group.

A transcript-only restoration through native resume lost titles and changed closed child edges to open edges.
Native Codex has no supported import operation for a deleted session.
The local App Server protocol marks resume by path as unstable. It has no method to set the child edge state.

A prototype restored scoped rows and index entries for `codex-cli 0.162.0-alpha.17.2`.
It worked for active and archived groups with legacy and paginated history.
It required pinned executable and database schema hashes, so each Codex update could stop recovery.
It also could not make the final source check and the native deletion command one atomic operation.
The prototype rejected sessions with dynamic tools, attachments, projects, goals, queued messages, or related memories.

## If recovery returns

Start a new ticket with the storage cost and retention period as requirements.
Restore scoped records, not complete databases.
Verify each supported Codex version and schema before you enable it.
Verify the restored sessions in the Codex desktop app, not only through the protocol.
