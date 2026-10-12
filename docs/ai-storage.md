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
| Claude Code | `~/.claude` | Conversations, memories, attachments, file history, and other files stay protected. Linked Git worktrees use the existing review controls. |
| Claude desktop | `~/Library/Application Support/Claude` | Verified Chromium caches are selectable. VM disks, runtime downloads, local sessions, and other files stay protected. |
| Cursor | `~/.cursor/projects`, `~/.cursor/chats`, `~/.cursor/worktrees`, `~/Library/Application Support/Cursor` | CLI conversations and workspace state stay protected. Verified Electron caches and linked Git worktrees use the existing review controls. |
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
Use the amber parent lock to review and unlock inactive conversations together.
Unlocking leaves the parent and child checkboxes unchecked.
Use a child checkbox to select an individual conversation.
Use the parent checkbox to select all unlocked conversations.
Deselecting a conversation keeps it unlocked.
Active sessions and unknown files stay locked.
The parent folder never enters the removal selection.
The parent conversation history badge identifies messages, tool results, and embedded images.
Child conversations do not repeat this badge.
The badge does not identify stored login credentials.
If the usage date is unavailable, the row shows Unknown in neutral text.
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
Deletion removes messages, tool results, and images embedded in the selected history files.
Moppo does not select separate `attachments`, `generated_images`, or `memories` folders for session deletion.
Deleting a transcript does not prove that all copies of its content are gone.

- [Codex App Server](https://learn.chatgpt.com/docs/app-server) documents permanent deletion and spawned child sessions.
- [Codex session commands](https://github.com/openai/codex/blob/main/codex-rs/tui/src/session_archive_commands.rs) connects the CLI deletion command to `thread/delete`.
- [Codex writer locks](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/writer_lock.rs) defines exclusive ownership for active writers.
- [Codex child relationships](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0021_thread_spawn_edges.sql) defines the stored child relationship table.

This review used the installed `codex-cli 0.162.0-alpha.17.2` protocol and source checks on 12 October 2026.

## Claude retention and deletion

Claude Code keeps transcripts under `~/.claude/projects/<project>/`.
Session folders can contain child transcripts, large tool results, and images returned by tools.
The same project folder contains persistent auto memory under `memory/`.
The separate `~/.claude/agent-memory/` folder holds persistent agent memories.
File history supports checkpoint recovery.
Pasted text, older image caches, and uploaded files can contain session content or the only local copies.
Moppo shows these stores as protected rows. It does not parse messages or decide that an old session is inactive.

Claude Code owns its retention sweep. Moppo does not change the retention settings.
The documented default for `cleanupPeriodDays` is 30 days. Version and settings affect its scope.
Desktop transcripts and auto memory have separate retention rules.
The sweep runs when Claude Code starts. File age does not establish that the sweep ran.
See [Claude Code application data](https://code.claude.com/docs/en/claude-directory#application-data) for the complete rules.

The current `claude purge` command removes project transcripts, auto memory, recovery files, prompt history entries, and project configuration.
Earlier versions call this command `claude project purge`.
The command can leave pasted text, attached images, and other session files elsewhere.
Moppo does not use purge because its scope conflicts with memory preservation.
See [Claude Code local deletion](https://code.claude.com/docs/en/hipaa-setup#delete-session-data-right-away) for the version limits and deletion scope.

Claude desktop local task folders contain transcripts, uploaded files, and outputs.
Their parent folder also holds persistent memory and plugins.
VM disks can contain task files. They remain protected, including after you close or remove Claude.
Documented automatic Cowork task removal depends on the HIPAA configuration and other conditions.
It does not establish a general rule for Moppo to delete old task folders.
See [Claude desktop local storage](https://claude.com/docs/cowork/hipaa-setup#manage-cowork-data-on-each-computer) for the conditions.

Claude can run tasks in the cloud. Local cleanup cannot delete or measure those remote sessions.
See [Claude Cowork execution modes](https://support.claude.com/en/articles/14479288-claude-cowork-architecture-overview) for local and cloud storage.

## Cursor retention and deletion

Cursor desktop stores chat and workspace state in its `User` folder.
Moppo protects the folder, including databases, checkpoints, settings, and unsaved files.
Cursor advises users to delete individual chats through History.
That deletion removes messages, checkpoints, and diffs. Archiving does not perform this deletion.
Cursor also provides commands for old chat deletion and unused blob cleanup.
Moppo does not edit or remove `state.vscdb` because direct removal can break chat history.
These rules come from [Cursor support](https://forum.cursor.com/t/how-to-remove-local-archived-chats/158574/4).
The support reply reported no automatic chat expiration setting on 23 April 2026.
Moppo does not infer an expiration period from that dated reply.

Cursor CLI stores local conversations under `~/.cursor/chats/<workspace-hash>/<chat-uuid>/`.
[Cursor support](https://forum.cursor.com/t/cursor-agent-create-chat-and-how-to-delete-old-chats/156640/7) states that these files have no cloud backup.
Moppo measures this folder as protected storage.
The reviewed sources do not establish a supported deletion API with active session protection.
Moppo therefore refuses CLI session removal, including when Cursor desktop is absent.
Deleting exported project history or worktrees does not delete the desktop chat database.
Worktree removal keeps its separate Git checks.

## Preserved data and other tools

Ordinary AI cleanup cannot unlock protected Claude or Cursor history with a user-data override.
Credentials, settings, memories, and active session state stay outside its removal targets.
This includes Claude Code settings, `.credentials.json`, and the separate `~/.claude.json` configuration file.
[Claude Code configuration](https://code.claude.com/docs/en/settings) describes these files.
[Claude Code memory](https://code.claude.com/docs/en/memory#storage-location) describes shared project memories and custom memory locations.
Custom paths remain outside current default-path coverage.

Codex memories have separate [memory controls](https://learn.chatgpt.com/docs/customization/memories).
Moppo keeps their files protected during session cleanup.

The Ollama, Hugging Face, and LM Studio readers target model files only.
They do not offer session history removal.
Ollama keys, LM Studio settings and conversations, and non-model Hugging Face files stay outside model removal targets.
Model removal does not prove that the tool deleted chat history or its attachments.

App Uninstaller and Application Leftovers provide a separate review for complete application data removal.
That review can include credentials, memories, history, uploaded files, and settings in the selected desktop support folder.
These files require the existing user-data authorization and move to the Trash.
Removing a desktop application does not establish that the tool deleted command-line or cloud sessions.

Further tools in issue #66 have no verified session deletion integration.
Their listed vendor sources support later research, not removal permission.
No retention or inactivity rule carries from one tool to another.

## Test coverage

- [AI scanner fixtures](../Core/Tests/MoppoCoreTests/AIToolsScannerTests.swift) cover credentials, memories, attachments, child transcripts, storage ownership, and totals.
- [Codex session fixtures](../Core/Tests/MoppoCoreTests/CodexSessionsTests.swift) cover child sessions, writer locks, open files, changed reviews, unsupported history, deletion failures, and receipts.
- [Cleanup state tests](../AppTests/CleanupModelTests.swift) cover group unlocking, separate selection, changed reviews, child counts, and required confirmation.

The AI scanner fixtures also cover absent applications, sparse VM files, and running applications.

A local native Codex check used temporary storage. It verified active writer protection, archived session deletion, retained settings, and removed database records.
The user completed the original Codex session checks on 12 October 2026.
A second native fixture preserved credentials, settings, memories, separate attachments, and generated images after archived session deletion.
It also verified active writer protection.
The new row text, group selection, and deletion warnings still need manual review in both appearances at the minimum window size.
The pending checks remain in [issue #11](https://github.com/anguria-studio/Moppo/issues/11).

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
The retention review in [issue #67](https://github.com/anguria-studio/Moppo/issues/67) keeps unverified session deletion locked.
