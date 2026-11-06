# AI storage sources and limits

[Back to the documentation index](README.md).

## Current coverage

AI Tools measures default paths, including command-line data without a desktop application.
It also measures the model store folders that variables set. See [Moved model stores](#moved-model-stores).
Application Leftovers owns verified desktop data when its application is absent.
Settings and history require the existing leftover review before removal.
The scanner does not follow symlinks or parse conversation messages.
Exclusions and protected file patterns take priority over storage rules.
Other categories do not offer paths owned by an enabled AI Tools scan.
If you disable AI Tools, its home data and model stores remain outside generic cleanup scans.
An open model file, a linked model file, or a model file with more than one hard link stays protected.
Each note under the table records the fact that justifies a rule.

<!-- rules:begin ai-tools -->
| Tool | Default paths | Removal rules | Notes |
| --- | --- | --- | --- |
| Codex | `~/.codex`, `~/.cache/codex-runtimes` | Archived and inactive sessions require deletion review. Active sessions and other storage stay protected. Linked Git worktrees retain their review controls. | Moppo deletes a session only through `codex delete --force`, after it repeats its checks. Memories, attachments, and generated images stay out of session deletion. Codex names each database with a schema version, such as `state_5.sqlite`, so the name changes when the schema changes. |
| ChatGPT desktop | `~/Library/Application Support/Codex` | Verified Chromium caches are selectable. Profiles and other files stay protected. |  |
| Claude Code | `~/.claude`, `~/.local/share/claude` | Conversations, memories, attachments, file history, installed versions, and other files stay protected. Linked Git worktrees use the existing review controls. | `claude purge` also deletes memories, so Moppo does not use it. Claude Code owns its retention sweep. |
| Claude desktop | `~/Library/Application Support/Claude` | Verified Chromium caches are selectable. VM disks, runtime downloads, local sessions, and other files stay protected. | VM disks and local task folders can hold task files beside memories and plugins, so all of them stay protected. |
| Cursor | `~/.cursor/projects`, `~/.cursor/chats`, `~/.cursor/worktrees`, `~/.local/share/cursor-agent`, `~/Library/Application Support/Cursor`, `~/.cursor/extensions` | CLI conversations, CLI versions, and workspace state stay protected. Verified Electron caches and linked Git worktrees use the existing review controls. | Cursor advises deleting chats through History, and CLI conversations have no cloud backup, so Moppo never edits `state.vscdb` or removes CLI sessions. |
| Grok Bot | `~/.grokbot`, `~/Library/Application Support/Grok Bot` | Verified Chromium caches and V8 compiled code caches are selectable. Local computer credentials, settings, staged attachments, and session state stay protected. | Grok Bot rebuilds `v8-code-cache` from its bundled JavaScript, so Moppo offers that cache. |
| T3 Code | `~/Library/Application Support/t3code-v2`, `~/.t3` | Application data, scratch projects, downloaded tools, caches, worktrees, desktop data, and unknown files stay protected. |  |
| Ollama | `~/.ollama` | Protected inventory. Moppo cannot verify complete model ownership or active models. | Moppo cannot verify which models Ollama still references, so the rows stay protected inventory. `~/.ollama` whole would offer the user's `id_ed25519` with the models, so no category lists it. |
| Hugging Face | `~/.cache/huggingface` | Model rows retain shared-file grouping. They require review and are not disposable caches. Shared, linked, or open model files stay protected. |  |
| LM Studio | `~/.lmstudio`, `~/.cache/lm-studio` | Model rows retain shared-file grouping. They require review and are not disposable caches. Shared, linked, or open model files stay protected. | LM Studio loads a model by opening its file, and `lms import --symbolic-link` links to Hugging Face files, so an open or linked model stays protected. Installs from before LM Studio moved its models use `~/.cache/lm-studio/models`. |
| PyTorch | `~/.cache/torch/hub` | One row for each weight file in `checkpoints` and each downloaded repository. Other folders in `~/.cache/torch` stay in System Caches & Logs. | Weight files sit in `checkpoints`, and each downloaded repository has its own folder. Other folders in `~/.cache/torch` are compiler caches. |
| Whisper | `~/.cache/whisper` | One row for each `.pt` model file. | Each `.pt` file is one model. |
| Keras | `~/.keras/models`, `~/.keras/datasets` | One row for each model or dataset. Other folders in `~/.keras` stay in Hidden & System Data. Moppo never offers `keras.json`. | `~/.keras` also holds `keras.json` settings, which no rule offers. |
| GPT4All | `~/Library/Application Support/nomic.ai/GPT4All` | One row for each `.gguf` model file. Settings, chats, and LocalDocs databases stay outside removal targets. | Settings, chats, and LocalDocs databases in the same folder stay out. GPT4All can use another download folder, which Moppo does not read. |
| Gemini CLI | `~/.gemini` | Protected inventory. The shared folder counts once. Credentials, settings, history, installed tools, cache folders, and unknown files stay protected. | Gemini CLI and Antigravity share `~/.gemini`. One root counts each byte once. |
| Antigravity | `~/Library/Application Support/Antigravity` | Protected inventory. The desktop support folder stays protected, including its cache folders. |  |
| GitHub Copilot CLI | `~/.copilot` | Protected inventory. Sessions, plugins, logs, settings, and unknown files stay protected. |  |
| OpenCode | `~/.local/share/opencode`, `~/.local/state/opencode`, `~/.config/opencode` | Protected inventory. The session database, snapshots, logs, and settings stay protected. |  |
| Goose | `~/.local/share/goose`, `~/.local/state/goose`, `~/.config/goose` | Protected inventory. Sessions, the model catalog, request logs, sign-in data, and keys stay protected. |  |
| OpenClaw | `~/.openclaw` | Protected inventory. Agent sessions, the workspace, state databases, and settings stay protected. |  |
| Kiro | `~/.kiro`, `~/.kiro-shared` | Protected inventory. Sessions, logs, and shared state stay protected. |  |
| Devin | `~/.codeium`, `~/.devin`, `~/.devin-shared`, `~/.local/share/devin`, `~/.config/devin`, `~/.windsurf/extensions` | Protected inventory. Memories, rules, conversations, CLI sessions, and settings stay protected. | Devin Desktop, Windsurf, and Codeium extensions can share `~/.codeium`. |
| AnythingLLM | `~/Library/Application Support/anythingllm-desktop` | Protected inventory. Documents, vector data, models, engines, keys, and cache folders stay protected. |  |
| Cherry Studio | `~/Library/Application Support/CherryStudio`, `~/.cherrystudio` | Protected inventory. Downloaded tools, the library, toolchains, credentials, and cache folders stay protected. |  |
| Comfy Desktop | `~/ComfyUI-Installs`, `~/ComfyUI-Shared` | Protected inventory. Models, outputs, workflows, custom nodes, and Python environments stay protected. |  |
| Stability Matrix | `~/Library/Application Support/StabilityMatrix`, `/Applications/Data` | Protected inventory. Models, settings, and the database stay protected. | In portable mode, Stability Matrix keeps `Data` next to the application. |
<!-- rules:end ai-tools -->

## Moved model stores

A variable can move some model stores to another folder.
AI Tools then reads the default folder and the folder that the variable sets.
The first variable with a value sets the folder.

| Store | Variables, in the order that the tool reads them |
| --- | --- |
| Ollama models | `OLLAMA_MODELS` |
| Hugging Face hub | `HF_HUB_CACHE`, `HUGGINGFACE_HUB_CACHE`, `HF_HOME` with `hub`, `XDG_CACHE_HOME` with `huggingface/hub` |
| Hugging Face home | `HF_HOME`, `XDG_CACHE_HOME` with `huggingface` |
| PyTorch Hub | `TORCH_HOME` with `hub`, `XDG_CACHE_HOME` with `torch/hub` |
| Whisper | `XDG_CACHE_HOME` with `whisper` |
| Keras | `KERAS_HOME` with `models` and `datasets` |

The `custom` field of each rule in `rules/` holds these variables and the items that identify each store.

- Moppo reads each variable from its own process first, then from `launchctl getenv`.
- An app that starts from the Dock does not get the variables that a shell profile, such as `~/.zshrc`, sets.
- To show a moved store in the app, set the variable with `launchctl setenv`.
- Ollama and Whisper do not expand `~` in a value, so Moppo does not expand it for these tools.
- A row in a moved store shows the variable that set its folder.
- Models in a folder outside the home folder stay protected. Moppo shows them, but does not remove them.
- Other categories do not list a moved store again.
- Moppo does not read the folder settings of LM Studio or GPT4All.

Moppo ignores a value in these conditions:

- The value is not an absolute path.
- The folder is the home folder, a folder above it, or a system folder.
- The folder is, or contains, a folder of many owners, such as `~/Documents`, `~/Library`, or `~/.cache`.
- The folder overlaps the storage of another tool.
- A component of the path is a symbolic link.
- The folder does not contain items from the layout of the tool.

## Bundle identifiers

Headings use these bundle identifiers to show the application icon:

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
<!-- rules:end ai-identifiers -->

If an application is absent, the heading uses the icon that the inventory checks took from its signed application.
GitHub Copilot CLI has no icon, so its heading shows a neutral symbol.
