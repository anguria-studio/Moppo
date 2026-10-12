# AI storage sources and limits

[Back to the development notes](README.md#ai-storage).

## Current coverage

AI Tools measures default paths, including command-line data without a desktop application.
Application Leftovers owns verified desktop data when its application is absent.
Settings and history require the existing leftover review before removal.
The scanner does not follow symlinks or parse conversation messages.
Codex session review reads stored titles, child relationships, and the first session metadata record.
Exclusions and protected file patterns take priority over storage rules.
Other categories do not offer paths owned by an enabled AI Tools scan.
If you disable AI Tools, its home data and model stores remain outside generic cleanup scans.

| Tool | Default paths | Removal rules |
| --- | --- | --- |
| Codex | `~/.codex`, `~/.cache/codex-runtimes` | Archived and inactive sessions require deletion review. Active sessions and other storage stay protected. Linked Git worktrees retain their review controls. |
| ChatGPT desktop | `~/Library/Application Support/Codex` | Verified Chromium caches are selectable. Profiles and other files stay protected. |
| Claude Code | `~/.claude` | Conversations, file history, and other files stay protected. Linked Git worktrees use the existing review controls. |
| Claude desktop | `~/Library/Application Support/Claude` | Verified Chromium caches are selectable. VM disks, runtime downloads, local sessions, and other files stay protected. |
| Cursor | `~/.cursor/projects`, `~/.cursor/worktrees`, `~/Library/Application Support/Cursor` | Workspace state stays protected. Verified Electron caches and linked Git worktrees use the existing review controls. |
| Ollama, Hugging Face, LM Studio | Existing default model stores | Model rows retain shared-file grouping. They require review and are not disposable caches. |

The scanner subtracts disclosed child sizes from each protected parent remainder.
Child rows do not add the same bytes a second time.
Allocated bytes include shared APFS storage. They do not prove how much a removal will free.
Sparse VM files can have a large virtual capacity and a small allocated size.

Use `swift run --package-path Core moppo-cli ai` to inspect the default storage rows without removal.

## Codex session deletion

Expand Codex sessions or Codex archived sessions to review individual conversations.
Each row includes its spawned child sessions. Their storage appears once in the category total.
Use the session lock to review the deletion warning.
Select Clean Up to confirm permanent deletion.
The warning explains that deleted sessions cannot be put back.
Codex session rows never enter Safe to Remove or automatic selection.

Moppo reads `state_5.sqlite` without writing to it.
The reader checks stored titles, rollout paths, and `thread_spawn_edges`.
It supports plaintext rollout files with a verified first metadata record.
Missing records, unknown formats, symlinks, and exclusions keep affected storage protected.
A held Codex writer lock protects the session and its deletion group.
Open history files also protect sessions from removal, including sessions from older clients.
Before deletion, Moppo checks the child relationships, file identities, modification dates, sizes, and writer locks again.
Moppo also checks open history files again.
Changed checks stop deletion and require another scan.

Moppo calls `codex delete --force <UUID>` with the reviewed `CODEX_HOME`.
Codex removes history files and related records. Moppo does not directly remove session folders or edit Codex databases.
Native deletion errors do not fall back to ordinary file removal.
Receipts record permanent deletions. They cannot restore deleted sessions.
Credentials, settings, and unrelated stored files keep their existing protection.

- [Codex App Server](https://learn.chatgpt.com/docs/app-server) documents permanent deletion and spawned child sessions.
- [Codex session commands](https://github.com/openai/codex/blob/main/codex-rs/tui/src/session_archive_commands.rs) connects the CLI deletion command to `thread/delete`.
- [Codex writer locks](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/writer_lock.rs) defines exclusive ownership for active writers.
- [Codex child relationships](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0021_thread_spawn_edges.sql) defines the stored child relationship table.

This review used the installed `codex-cli 0.162.0-alpha.17.2` protocol and source checks on 12 October 2026.

## Test coverage

- [AI scanner fixtures](../Core/Tests/MoppoCoreTests/AIToolsScannerTests.swift) cover storage ownership, totals, protected paths, absent applications, sparse VM files, and running applications.
- [Codex session fixtures](../Core/Tests/MoppoCoreTests/CodexSessionsTests.swift) cover child sessions, writer locks, open files, changed reviews, unsupported history, deletion failures, and receipts.
- [Cleanup state tests](../AppTests/CleanupModelTests.swift) cover explicit session selection, child counts, and required confirmation when you disable general confirmation.

A local native Codex check used temporary storage. It verified active writer protection, archived session deletion, retained settings, and removed database records.
The user completed manual testing on 12 October 2026.

## Evidence

This review used the rules on 12 October 2026.

Local inspection covered ChatGPT 26.1007.30912, Claude 2.31226.1, and existing Codex, Claude Code, and Cursor folders.
Cursor was absent, but its desktop support folder remained.
The exact Cursor bundle identifier links this folder to the application-leftover review.
The current ChatGPT bundle uses `com.openai.codex` and the `Codex` desktop support folder.
Claude keeps top-level Chromium caches and additional caches under `Partitions`.
Existing application curation supplies the desktop cache paths. The AI scanner does not infer safety from folder names.
`Service Worker`, account databases, and workspace state remain protected.

Read-only inspection of one Claude VM found Linux and installed tools in its system disk.
Its session disk was empty. This observation does not prove that other session disks are empty.
The production scanner reads file metadata. It does not inspect VM filesystems.

- [Claude Cowork architecture](https://support.claude.com/en/articles/14479288-claude-cowork-architecture-overview) describes local task execution in a dedicated virtual machine.
- [Cursor worktrees](https://cursor.com/docs/configuration/worktrees) describes separate Git checkouts for agent work.
- [Cursor retained data](https://forum.cursor.com/t/unable-to-update-cursor-to-latest-version-both-nightly-and-stable/167614/7) identifies desktop storage in a vendor reply.
- [Cursor bundle identifier](https://forum.cursor.com/t/cursor-bundle-identifier/779/9) confirms the stable application identifier in a vendor reply.
- [Ollama FAQ](https://docs.ollama.com/faq) documents `~/.ollama/models` and the `OLLAMA_MODELS` override.
- [Hugging Face cache management](https://huggingface.co/docs/huggingface_hub/guides/manage-cache) describes model cache inspection and managed removal.
- [LM Studio model downloads](https://lmstudio.ai/docs/app/basics/download-model) describes downloaded models and model management.

## Further tools

These sources support further research. They do not establish safe Moppo removal rules.
Documented paths can supply fixtures without application installation.

| Tool | Source | Protected storage to verify |
| --- | --- | --- |
| Gemini CLI | [Session management](https://geminicli.com/docs/cli/tutorials/session-management/) and [checkpointing](https://geminicli.com/docs/cli/checkpointing/) | Conversations, checkpoints, shadow Git history, settings, and authentication files. |
| GitHub Copilot CLI | [Configuration directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference) | `~/.copilot` sessions, plans, checkpoints, plugins, settings, and credentials. |
| Windsurf and Devin Desktop | [Cascade memories](https://docs.devin.ai/desktop/cascade/memories) | Legacy `~/.codeium/windsurf/memories` and workspace rules. Current documentation uses Devin Desktop. |
| Antigravity | Local desktop support folder observed | AI Tools has no separate Antigravity rows. Standard application and Electron cache rules apply. Session and workspace removal rules require verification. |

Custom paths and further tools remain in [issue #66](https://github.com/anguria-studio/Moppo/issues/66).
Session deletion and retention for other tools require separate rules in [issue #67](https://github.com/anguria-studio/Moppo/issues/67).
