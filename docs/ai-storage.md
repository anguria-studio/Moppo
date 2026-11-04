# AI storage sources and limits

[Back to the development notes](README.md#ai-storage).

## Current coverage

AI Tools measures default paths, including command-line data without a desktop application.
Application Leftovers owns verified desktop data when its application is absent.
Settings and history require the existing leftover review before removal.
The scanner does not follow symlinks or parse conversation messages.
Codex session review reads stored titles, child relationships, and file metadata.
For plaintext history, it also reads the first session metadata record.
Exclusions and protected file patterns take priority over storage rules.
Other categories do not offer paths owned by an enabled AI Tools scan.
If you disable AI Tools, its home data and model stores remain outside generic cleanup scans.

<!-- rules:begin ai-tools -->
| Tool | Default paths | Removal rules |
| --- | --- | --- |
| Codex | `~/.codex`, `~/.cache/codex-runtimes` | Archived and inactive sessions require deletion review. Active sessions and other storage stay protected. Linked Git worktrees retain their review controls. |
| ChatGPT desktop | `~/Library/Application Support/Codex` | Verified Chromium caches are selectable. Profiles and other files stay protected. |
| Claude Code | `~/.claude`, `~/.local/share/claude` | Conversations, memories, attachments, file history, installed versions, and other files stay protected. Linked Git worktrees use the existing review controls. |
| Claude desktop | `~/Library/Application Support/Claude` | Verified Chromium caches are selectable. VM disks, runtime downloads, local sessions, and other files stay protected. |
| Cursor | `~/.cursor/projects`, `~/.cursor/chats`, `~/.cursor/worktrees`, `~/.local/share/cursor-agent`, `~/Library/Application Support/Cursor`, `~/.cursor/extensions` | CLI conversations, CLI versions, and workspace state stay protected. Verified Electron caches and linked Git worktrees use the existing review controls. |
| Grok Bot | `~/.grokbot`, `~/Library/Application Support/Grok Bot` | Verified Chromium caches and V8 compiled code caches are selectable. Local computer credentials, settings, staged attachments, and session state stay protected. |
| T3 Code | `~/Library/Application Support/t3code-v2`, `~/.t3` | Application data, scratch projects, downloaded tools, caches, worktrees, desktop data, and unknown files stay protected. |
| Ollama | `~/.ollama` | Protected inventory. Moppo cannot verify complete model ownership or active models. |
| Hugging Face | `~/.cache/huggingface` | Model rows retain shared-file grouping. They require review and are not disposable caches. Shared, linked, or open model files stay protected. |
| LM Studio | `~/.lmstudio`, `~/.cache/lm-studio` | Model rows retain shared-file grouping. They require review and are not disposable caches. Shared, linked, or open model files stay protected. |
| PyTorch | `~/.cache/torch/hub` | One row for each weight file in `checkpoints` and each downloaded repository. Other folders in `~/.cache/torch` stay in System Caches & Logs. |
| Whisper | `~/.cache/whisper` | One row for each `.pt` model file. |
| Keras | `~/.keras/models`, `~/.keras/datasets` | One row for each model or dataset. Other folders in `~/.keras` stay in Hidden & System Data. Moppo never offers `keras.json`. |
| GPT4All | `~/Library/Application Support/nomic.ai/GPT4All` | One row for each `.gguf` model file. Settings, chats, and LocalDocs databases stay outside removal targets. |
| Gemini CLI | `~/.gemini` | Protected inventory. The shared folder counts once. Credentials, settings, history, installed tools, cache folders, and unknown files stay protected. |
| Antigravity | `~/Library/Application Support/Antigravity` | Protected inventory. The desktop support folder stays protected, including its cache folders. |
| GitHub Copilot CLI | `~/.copilot` | Protected inventory. Sessions, plugins, logs, settings, and unknown files stay protected. |
| OpenCode | `~/.local/share/opencode`, `~/.local/state/opencode`, `~/.config/opencode` | Protected inventory. The session database, snapshots, logs, and settings stay protected. |
| Goose | `~/.local/share/goose`, `~/.local/state/goose`, `~/.config/goose` | Protected inventory. Sessions, the model catalog, request logs, sign-in data, and keys stay protected. |
| OpenClaw | `~/.openclaw` | Protected inventory. Agent sessions, the workspace, state databases, and settings stay protected. |
| Kiro | `~/.kiro`, `~/.kiro-shared` | Protected inventory. Sessions, logs, and shared state stay protected. |
| Devin | `~/.codeium`, `~/.devin`, `~/.devin-shared`, `~/.local/share/devin`, `~/.config/devin`, `~/.windsurf/extensions` | Protected inventory. Memories, rules, conversations, CLI sessions, and settings stay protected. |
| AnythingLLM | `~/Library/Application Support/anythingllm-desktop` | Protected inventory. Documents, vector data, models, engines, keys, and cache folders stay protected. |
| Cherry Studio | `~/Library/Application Support/CherryStudio`, `~/.cherrystudio` | Protected inventory. Downloaded tools, the library, toolchains, credentials, and cache folders stay protected. |
| Comfy Desktop | `~/ComfyUI-Installs`, `~/ComfyUI-Shared` | Protected inventory. Models, outputs, workflows, custom nodes, and Python environments stay protected. |
| Stability Matrix | `~/Library/Application Support/StabilityMatrix`, `/Applications/Data` | Protected inventory. Models, settings, and the database stay protected. |

The native installers keep each installed version in `versions`. `~/.local/bin` links to the active one.
T3 Code 0.1.6, team ARK85ZXQ4Z. The application sets this folder. Its package name is `t3code`. `~/.t3` is not here: the T3 Code command-line server also uses it.
`~/.ollama` whole would offer the user's `id_ed25519` with the models, so no category lists it.
The hub inside carries `CACHEDIR.TAG`. The reader handles the classic layout and the shared blob layout.
Installs from before LM Studio moved its models use `~/.cache/lm-studio/models`.
`~/.cache/torch/hub` holds weight files in `checkpoints` and one folder for each downloaded repository. Other folders in `~/.cache/torch` are compiler caches.
Each `.pt` file is one model.
`~/.keras` also holds `keras.json` settings, which no rule offers.
Each `.gguf` file is one model. Settings, chats, and LocalDocs databases stay outside removal targets. GPT4All can use another download folder, which Moppo does not read.
Gemini CLI and Antigravity share `~/.gemini`. One root counts each byte once.
Antigravity desktop 2.28.1 uses this identifier and support folder. The evidence does not verify its cache folders, so no path counts as regenerable.
Devin Desktop, Windsurf, and Codeium extensions can share `~/.codeium`.
AnythingLLM 1.19.0, team 35S2NMU3G4. The Electron package name is `anythingllm-desktop`.
Cherry Studio 2.1.10, team 87242QY66T. The Electron package name is `CherryStudio`. `~/.cherrystudio` holds the downloaded tools and the `config` folder of the application.
Comfy Desktop 1.1.8 made these folders. Its launcher folder and ComfyUI identify an installation.
Stability Matrix 2.16.5 in portable mode keeps `Data` next to the application.
<!-- rules:end ai-tools -->

Cleanup groups related storage under application headings.
Codex and ChatGPT have separate headings because their displayed storage has different owners.
Claude Code and Claude also have separate headings.
Each heading shows the storage in its displayed rows. Filters can change this total.
Application headings start collapsed.
Expand a heading to show its storage sections.
Expand a section to show its children when they are available.
Collapsing a heading keeps the selection unchanged.
Range selection includes only visible sections.
A heading has no selection or removal action.
Section descriptions identify task data, downloaded tools, desktop data, and other storage.
Child selection, session deletion, cache protection, and worktree review keep their existing rules.

Protected parent rows with child items do not show a protected badge.
Child rows keep their own protection and review badges.
Moppo blocks removal of the whole folder to keep protected files.
Closing the owning application does not remove this protection.
Child items use separate removal checks. A selectable item can still need review.
Worktrees with local files stay outside automatic Safe to Remove selection.
The parent size shows Total storage. It includes child items and other protected files.
Selected items have a separate total.
Other storage sections have separate totals.

The scanner subtracts disclosed child sizes from each protected parent remainder.
Child rows do not add the same bytes a second time.
Allocated bytes include shared APFS storage. They do not prove how much a removal will free.
Sparse VM files can have a large virtual capacity and a small allocated size.

Use `swift run --package-path Core moppo-cli ai` to inspect the default storage rows without removal.

## T3 Code inventory

Moppo discovers `~/.t3` without an installed T3 Code desktop application.
Two complete diagnostic scans on 21 October 2026 verified this path on one installation.
They measured 9,085,263,872 allocated bytes across 283,506 files, with no unreadable files.
The root measurement took 14.924 and 14.383 seconds.
The logs did not identify the installed T3 Code version.
These results verify storage discovery and measurement. They do not establish safe removal.

| Observed child | Displayed storage | Protection |
| --- | --- | --- |
| `userdata` | Application data | Settings, credentials, attachments, browser files, logs, and unknown state stay protected. |
| `scratch` | Scratch projects | Project files and dependencies, including `node_modules/.pnpm`, stay protected. |
| `tools` | Downloaded tools | Installed tools, including an observed Codex installation, stay protected. |
| `caches` | Caches | Observed children include `codex.json` and `pull-requests`. Names do not establish safe removal. |
| `worktrees` | Worktrees | This folder was empty in the supplied scans. All T3 Code worktrees stay protected. |

Present children with measured data have separate rows and protection explanations.
Unknown files remain in the protected parent remainder.
The root measurement also collects child totals in one traversal.
Generic Git worktree discovery and removal review do not run inside T3 Code storage.
Other AI tools keep their existing worktree rules.
No T3 Code storage contributes to Safe to Remove.
User-data overrides cannot unlock these inventory rows.
Hidden & System Data excludes the root and its archives, including when you disable AI Tools.
Exclusions, protected patterns, unreadable paths, and symlinks retain their existing scan protections.
The scanner reads file metadata. It does not parse T3 conversations, credentials, or databases.

T3 Code can also use shared provider storage outside `~/.t3`.
Shared `~/.claude` storage remains under Claude Code and counts once.
The official [Claude provider guide](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/docs/user/providers-claude.md) describes shared login and configuration.
The [Claude home resolver](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/apps/server/src/provider/Drivers/ClaudeHome.ts) uses `~/.claude` by default.
Configured paths and `CLAUDE_CONFIG_DIR` can change that provider location.
The source review used revision `680152e27b2a961686389ca69a1557cbb2c55f08` on 21 October 2026.
It does not identify the installed T3 Code revision.

The logs reached their directory-detail limit. Their detailed paths do not provide an exhaustive inventory.
Raw logs remain private because they contain work project paths.
Synthetic fixtures verify grouping, accounting, and protection.
A scan on the reported laptop still needs to verify the new presentation, sizes, and timing.
These checks remain in [issue #196](https://github.com/anguria-studio/Moppo/issues/196).
Custom roots and provider discovery remain in [issue #66](https://github.com/anguria-studio/Moppo/issues/66).
Automatic cache cleanup and T3 session deletion require separate evidence.

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

Session sections remain visible when the installed Codex CLI does not support verified deletion.
Moppo lists recognized conversation files even when the expected database schema is unavailable.
These conversations stay locked. Use Codex to manage them.
Available database titles identify conversations. Otherwise, each row shows its session identifier.
For plaintext history, Moppo reads the first metadata record without reading conversation messages.
Compressed history uses the session identifier in its filename and the matching database record.
Codex owns compressed history parsing and deletion. Moppo does not decompress conversation history.

Moppo reads `state_5.sqlite` without writing to it.
The reader checks stored titles, rollout paths, and `thread_spawn_edges`.
It supports plaintext and compressed rollout files in the same deletion review.
For compressed history, the saved path can still name the missing plaintext file at the same location.
Missing records, unknown formats, duplicate history files, symlinks, and exclusions keep affected storage protected.
A held Codex writer lock protects the session and its deletion group.
Open history files also protect sessions from removal, including sessions from older clients.
Before deletion, Moppo checks the child relationships, file identities, modification dates, sizes, and writer locks again.
Moppo also checks open history files again.
Changed checks stop deletion and require another scan.

Moppo calls `codex delete --force <UUID>` with the reviewed `CODEX_HOME`.
Codex removes history files and related records. Moppo does not directly remove session folders or edit Codex databases.
Native deletion errors do not fall back to ordinary file removal.
Receipts record permanent deletions. They cannot restore deleted sessions.
The [Codex session recovery research](codex-session-recovery.md) explains why Moppo does not offer session recovery.
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

## Gemini CLI and Antigravity inventory

Gemini CLI and Antigravity share `~/.gemini`.
Installation does not establish which tool owns each child, so Moppo shows one shared row under Gemini.
Each byte in the folder counts once.

| Observed child | Displayed storage |
| --- | --- |
| `antigravity`, `antigravity-cli`, `antigravity-ide` | Antigravity data, CLI data, and editor data |
| `history` | Shared history |
| `bin` | Shared installed tools |
| `logs` | Shared logs |
| `tmp` | Shared temporary files |

Account files, settings, `config`, and unknown files remain in the protected parent remainder.
The Antigravity desktop application uses bundle identifier `com.google.antigravity`.
Its support folder has a separate protected row under Antigravity.
Moppo does not apply the generic Electron cache rule to this folder. Cache folder names do not establish safe removal.
Applications and Hidden & System Data do not count or offer these paths again.
The bundle identifier links the support folder to its application.
If the application is absent, Application Leftovers owns the support folder and requires the existing user-data review.
The uninstall review also treats the whole folder as user data. No Antigravity cache folder counts as regenerable.
Generic Git worktree discovery and removal review do not run inside this storage.
No Gemini CLI or Antigravity storage contributes to Safe to Remove.
User-data overrides cannot unlock these inventory rows.

A rented Mac test on 29 October 2026 used Antigravity CLI 1.4.10 and Antigravity desktop 2.28.1.
The CLI completed a real coding task. The desktop application passed launch and sign-in only.
Gemini CLI 0.66.0 installed, but Google rejected its sign-in. No Gemini task ran.
A metadata check read file names and types. It did not read file contents or credentials.
These results verify storage discovery and measurement. They do not establish safe session, cache, or uninstall removal.
The [Gemini CLI session management](https://geminicli.com/docs/cli/tutorials/session-management/) and [checkpointing](https://geminicli.com/docs/cli/checkpointing/) guides describe its conversations and checkpoints.
The results and remaining checks are in [issue #216](https://github.com/anguria-studio/Moppo/issues/216).

## Tools from the #216 inventory

The #216 checks on 3 November 2026 found 13 AI tools without AI Tools rules.
AI Tools now shows protected inventory rows for 11 of these tools.
Jan desktop data keeps its existing protection under Applications.
Draw Things models stay in their container. The Draw Things paragraph below gives the reason.

Each row shows its measured storage and counts each byte once.
Child rows show observed folders. Unknown files stay in the protected parent remainder.
Folder names do not establish safe removal. Moppo does not offer logs, caches, or temporary folders from these tools.
Hidden & System Data, System Caches, and Applications do not list these paths again.
Plans for a root or its children fail with `protected_item`.
Generic Git worktree review does not run inside this storage.
No storage from these tools contributes to Safe to Remove.
User-data overrides cannot unlock these inventory rows.

Some folder names are not specific to one tool. For these folders, Moppo also requires files from the observed layout:

| Folder | Required layout |
| --- | --- |
| `~/ComfyUI-Installs` | An installation with `.launcher` and `ComfyUI/main.py` |
| `~/ComfyUI-Shared` | `models/checkpoints`, `models/loras`, and `output` |
| `/Applications/Data` | The Stability Matrix portable marker `.sm-portable` and `StabilityMatrix.db` |

If the layout does not match, AI Tools does not show or claim the folder.
Stability Matrix in portable mode keeps `Data` next to the application.

AI Tools claims `~/.config/opencode`, `~/.config/goose`, and `~/.config/devin`.
Hidden & System Data lists the other folders in `~/.config` as separate rows.
It does not list loose files in `~/.config` because they are settings.
Devin Desktop, Windsurf, and Codeium extensions can share `~/.codeium`, so Moppo shows one shared row under Devin.

T3 Code, AnythingLLM, and Cherry Studio use support folder names that do not match their applications.
`ApplicationDataFolders` connects these folders to the bundle identifiers of their applications.
While the application is in an Applications folder, the AI Tools rows show the folders. The application row does not count them again.
App Uninstaller lists the folders as user data.
If the application is absent, Application Leftovers owns the folders and requires the user-data review.
`~/.t3` stays in AI Tools because the T3 Code command-line server also uses it.
OpenCode, Goose, Kiro, Devin, and Comfy Desktop keep their support folders with their applications.
These folders keep their existing Applications protection.

The rented Mac supplied these bundle identifiers. Headings use them to show the application icon:

<!-- rules:begin ai-identifiers -->
| Tool | Bundle identifier |
| --- | --- |
| T3 Code (Beta) 0.1.6 | `com.t3tools.t3code` |
| OpenCode 2.2.5 | `ai.opencode.desktop` |
| Goose 1.57.0 | `com.electron.goose` |
| Kiro 1.4.86 | `dev.kiro.desktop` |
| Devin 3.11.238 | `com.exafunction.windsurf` |
| AnythingLLM 1.19.0 | `com.anythingllm` |
| Cherry Studio 2.1.10 | `com.kangfenmao.CherryStudio` |
| Comfy Desktop 1.1.8 | `com.todesktop.241012ess7yxs0e` |
| Stability Matrix 2.16.5 | `ai.lykos.stabilitymatrix` |

T3 Code 0.1.6, team ARK85ZXQ4Z. The application sets this folder. Its package name is `t3code`. `~/.t3` is not here: the T3 Code command-line server also uses it.
Devin Desktop, Windsurf, and Codeium extensions can share `~/.codeium`.
AnythingLLM 1.19.0, team 35S2NMU3G4. The Electron package name is `anythingllm-desktop`.
Cherry Studio 2.1.10, team 87242QY66T. The Electron package name is `CherryStudio`. `~/.cherrystudio` holds the downloaded tools and the `config` folder of the application.
Comfy Desktop 1.1.8 made these folders. Its launcher folder and ComfyUI identify an installation.
Stability Matrix 2.16.5 in portable mode keeps `Data` next to the application.
<!-- rules:end ai-identifiers -->

If an application is absent, the heading uses the icon that the #216 checks took from its signed application.
GitHub Copilot CLI and OpenClaw have no desktop application, so their headings use a generic icon.

The native installers of Claude Code and Cursor CLI keep each installed version in a `versions` folder.
AI Tools shows `~/.local/share/claude` and `~/.local/share/cursor-agent` as protected rows only when this folder exists.
App Uninstaller for Cursor does not list `~/.local/share/cursor-agent`, because the Cursor CLI uses it without the application.

Hidden & System Data shows `~/Library/Application Support/multimodal-models` as a protected row.
It contains an ai-coustics audio model. The #216 checks did not identify the application that uses it.

Moppo does not change these cache rows. The layouts do not show user data in them:

- `~/Library/Caches/copilot` holds a downloaded Copilot CLI package, managed settings, and marketplace data.
- `~/.cache/devin` holds downloaded CLI configuration files.
- `~/.cache/lemonade` was empty. No AnythingLLM task ran.

Draw Things keeps its models in `~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models`.
An AI Tools claim on this folder removes the complete container from the Draw Things Applications row.
The models therefore stay protected in the container, and AI Tools does not show them.

The rented Mac used macOS 27.2 on Apple silicon.
The manifests recorded file names, types, sizes, and links. They did not record file contents.
Each tool completed a real task, except AnythingLLM and Cherry Studio.
These results verify discovery and measurement. They do not establish safe session, cache, or uninstall removal.
The [GitHub Copilot CLI configuration directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference) describes `~/.copilot`.
The [Devin Desktop memories guide](https://docs.devin.ai/desktop/cascade/memories) describes `~/.codeium/windsurf/memories`.
The evidence is in [issue #216](https://github.com/anguria-studio/Moppo/issues/216) and [issue #66](https://github.com/anguria-studio/Moppo/issues/66).

## Preserved data and other tools

Grok Bot desktop uses bundle identifier `com.anysphere.sand`.
The installed Grok Bot 0.70.2 profile contains top-level Chromium caches and caches under `Partitions`.
Its bundled startup code loads `v8-code-cache` when available.
If this cache is missing or V8 rejects it, the app compiles its bundled JavaScript and saves a new cache.
Moppo offers these cache paths with the existing running application protection.
Cookies, local storage, session storage, shared dictionaries, service worker data, and other profile files stay protected.
The separate `~/.grokbot` folder holds local computer credentials, settings, and staged attachments.
Moppo keeps the whole folder protected, including when you disable AI Tools.
Grok Bot runs its main computer in the cloud. Local storage cleanup cannot measure or remove that remote computer.
See [Grok Bot computer and apps](https://docs.x.ai/grok-bot/computer-and-apps) for its cloud and local computer limits.

Local file metadata and installed app source confirmed these Grok Bot paths on 13 October 2026.

Ordinary AI cleanup cannot unlock protected Claude or Cursor history with a user-data override.
Credentials, settings, memories, and active session state stay outside its removal targets.
This includes Claude Code settings, `.credentials.json`, and the separate `~/.claude.json` configuration file.
[Claude Code configuration](https://code.claude.com/docs/en/settings) describes these files.
[Claude Code memory](https://code.claude.com/docs/en/memory#storage-location) describes shared project memories and custom memory locations.
Custom paths remain outside current default-path coverage.

Codex memories have separate [memory controls](https://learn.chatgpt.com/docs/customization/memories).
Moppo keeps their files protected during session cleanup.

Ollama models remain protected inventory.
Moppo cannot verify all current Ollama model references or active models.
Use Ollama to manage these files.
The local model readers target model files only.
They do not offer session history removal.
Model rows require review. Cleanup does not select them automatically.

Moppo protects a local model row in these conditions:

- A process has a model file or a link target open. LM Studio loads models in this way.
- A link in the LM Studio folders points to the Hugging Face files. The `lms import --symbolic-link` command makes these links.
- Moppo cannot read all LM Studio folders. A missing LM Studio row does not prove that no link exists.
- Moppo cannot check a link target for open files.
- A model file has more than one hard link. Removal of one link does not free the space.
- Moppo cannot complete the open file check.

Moppo counts a hard-linked model file once across model rows.
Plan creation and plan execution scan again, so these checks apply before removal.
Moppo reads only the default LM Studio, PyTorch Hub, Whisper, Keras, and GPT4All folders.
GPT4All can use another download folder.
Its `modelPath` setting changed its name in GPT4All 2.4.11, so Moppo does not read this setting.
[Issue #66](https://github.com/anguria-studio/Moppo/issues/66) records this gap.
Moppo does not read `TORCH_HOME`, `KERAS_HOME`, or `XDG_CACHE_HOME`. [Issue #44](https://github.com/anguria-studio/Moppo/issues/44) records moved model folders.
Moppo also reads the folders that their directory links point to.
Moppo does not check links from other folders.
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

### Workflow validation

Use a disposable macOS environment for real application checks.
Install each tool from its official source.
Record the tool version, install method, Moppo build, macOS version, and permissions.
Measure storage before first use and after a small task.
Repeat the scan with the desktop application closed and a CLI task still running.
Repeat the scan after all tool processes stop.
Use disposable data for removal and uninstall checks.
Compare the resulting files, protection decisions, allocated bytes, and task behavior.
Keep conversation content and credentials out of published evidence.
Record results and untested cases in [issue #216](https://github.com/anguria-studio/Moppo/issues/216).
Write a layout manifest with `python3 scripts/manifest.py`, and run `python3 scripts/rules.py audit --manifest` with it.
The audit lists each tool that is newer than its verification and each path that no rule covers.
The tables in this document come from `rules/`. See the [tool rule registry](tool-rules.md).

A temporary CLI experiment tested Codex `0.162.0-alpha.17.2` and Claude Code `2.1.283` on 20 October 2026.
It verified Codex executable discovery, active session protection, archived session deletion, Claude Code storage protection, and allocated totals.
The experiment used private profiles and local test responses.
It did not verify desktop workflows, cloud authentication, or Codex CLI `0.160`.
The experimental harness stays outside the maintained regression suite.
The initial findings remain in [issue #199](https://github.com/anguria-studio/Moppo/issues/199).

### Regression fixtures

- [AI scanner fixtures](../Core/Tests/MoppoCoreTests/AIToolsScannerTests.swift) cover credentials, memories, attachments, child transcripts, storage ownership, and totals.
- [Local model fixtures](../Core/Tests/MoppoCoreTests/LocalModelStoresTests.swift) cover shared files, LM Studio links, hard links, and open model files.
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
- [PyTorch Hub](https://pytorch.org/docs/stable/hub.html) describes the `hub` folder, its repository folders, and `checkpoints`.
- [GPT4All settings source](https://github.com/nomic-ai/gpt4all/blob/main/gpt4all-chat/src/mysettings.cpp) shows the default model folder and the `modelPath` setting.

## Further tools

Kimi, OpenRouter, Midjourney, and other media tools have no native storage evidence.
Draw Things default desktop paths and cleanup remain unverified.
Custom paths and further tools remain in [issue #66](https://github.com/anguria-studio/Moppo/issues/66).
The retention review in [issue #67](https://github.com/anguria-studio/Moppo/issues/67) keeps unverified session deletion locked.
