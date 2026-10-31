# Changelog

Changes that affect Moppo users appear here, with the newest release first.

## [Unreleased]

### Cleanup

- Keep dependency folders of recently changed projects out of **Safe to Remove**.
- Keep dependency folders that Git does not ignore out of **Safe to Remove**.

### Command line and agents

- Let `moppo` run outside the Claude Code and Codex sandboxes when Settings installs the agent skill. **Remove** removes the rule again.
- Show **Allow** in Settings when an installed skill lacks its sandbox rule.
- Stop `moppo scan` before the scan starts when Moppo cannot save its report, and say that an agent sandbox can cause this.
- Show `app_review` for Xcode build caches, Git worktrees, sound libraries, and Codex sessions in CLI results.
- Reject these items when an agent creates a plan, so removal does not fail at the last step.
- Let `moppo` run outside the Cursor CLI sandbox when Settings installs the Cursor skill.
- Name the item that failed plan validation in `moppo plan` errors.
- Tell agents to ask again before each later command that shows names and paths.

## [0.5.0] - 2026-10-30

Build 54.

### Simulator runtimes

- Remove selected simulator runtimes through simctl after mandatory confirmation, with permanent Cleanup History records.
- Protect runtimes that an installed Xcode version or an active simulator uses.
- Support the patchable runtime format that newer Xcode versions download.
- Keep retained simulator downloads visible with their size and protection reason for iOS, tvOS, watchOS, and visionOS.
- Report incomplete cleanup when macOS keeps a simulator image after removal.
- Explain the known Xcode deletion issue when an older Xcode version leaves a simulator image on disk.

### Cleanup

- Add a setting that shows Cleanup items smaller than 1 MB.
- Show old Homebrew formula versions smaller than 1 MB.
- Show successful tool command results in the Cleanup banner instead of an alert.
- Show **Remove** on the Cleanup button when the selection has items that cannot go to the Trash.
- Explain that Homebrew keeps the other installed versions when you remove an old formula version.

### Fixes

- Show **No items removed** in the Cleanup banner when a cleanup removes nothing, and count one failed item correctly.

## [0.4.0] - 2026-10-29

Build 53.

### Command line and agents

- Add the `moppo` command for scans, saved cleanup plans, and removal from Terminal.
- Install `moppo` and the agent skill for Claude Code, Codex, or Cursor from Settings > Advanced.
- Require confirmation and Touch ID or the login password before the CLI removes items permanently.
- Open saved CLI plans for review in Moppo. Show their results and validation skips in Cleanup History.

### Cleanup

- Add Never Offer This Again to row menus. The `moppo exclude` command saves the same rules.
- Remove obsolete Homebrew formula versions through Homebrew after review.
- Remove the Go module cache through Go after mandatory confirmation.
- Allow reviewed deletion of compressed Codex history through Codex.
- Offer administrator approval when Cleanup cannot move an Apple sound library to the Trash.
- Return to the remaining results with Continue after removal, without a new scan.
- Add Open and Empty Trash to the Trash item in the sidebar.

### AI Tools

- Protect Hugging Face and LM Studio models that another application opens, links to, or shares.
- Count hard-linked model files once.
- Keep all Ollama models protected.
- Show protected Gemini CLI and Antigravity storage with their icons. Count the shared `~/.gemini` folder once.
- Show Antigravity desktop data in Application Leftovers after you remove Antigravity.

### Fixes

- Avoid Trash names that Git still reserves for missing worktrees.
- Explain denied Trash access during worktree removal and show Full Disk Access guidance.
- Allow Command-Q to quit from the worktree review dialog.
- Keep text colors correct while you select table rows.
- Keep AI application headers and their icons stable while you press them.
- Remove the comparison footer from Dashboard and shorten its measurement guidance.
- Show the draggable Moppo icon when a Full Disk Access action opens System Settings.
- Use white fills for Settings action buttons and softer hover colors in Light appearance.

## [0.3.0] - 2026-10-27

Build 50.

- Show progress during worktree safety checks before removal.
- Keep completed worktree reviews until another scan or an explicit check.
- Use the same process checks during scans, worktree reviews, and removal.
- Save storage comparisons when category measurements exceed physical usage.
- Keep physical Free space separate from category measurements in Dashboard.
- Show the real comparison start when less than seven days of measurements exist.
- Remove a cleanup failure notice after a manual refresh when no cleanup baseline exists.
- Compare Since last cleanup with the measurement before the cleanup.
- Use the same label for Last 7 days on the button and in the menu.
- Show category colors in the capacity bar when categories exceed used space.
- Keep Cleanup results after removal.
- Show the comparison menu only when its options start at different measurements.
- Explain shared storage on the capacity card when categories exceed used space.
- Automatic update checks are now on by default, with a setting to turn them off.
- Show Moppo animations during onboarding, with static symbols when Reduce Motion is on.
- Open Cleanup after onboarding, including with limited file access.

## [0.2.0] - 2026-10-21

0.2.0 is the first public release.
See what uses your disk space and review what you remove.

- Measure storage and compare saved measurements.
- Review cleanup items before removal.
- Find duplicate files and photos.
- Review applications and remove Homebrew packages through Homebrew.
- Restore eligible items with History and Put Back.
- Check for updates with optional automatic checks.
- Read privacy information and prepare a support report from the Help menu.
- Choose System, Light, or Dark appearance in Settings.
- Review AI storage by application with separate section and worktree controls.
- Read protected folder sizes as total storage, with separate removable selections.
- Request Photos access through the native macOS permission prompt.
- Cancel Cleanup while it waits for applications to quit.
- Set up iCloud storage measurements and control the Dashboard card in Settings.
- Show application names, folder names, file counts, and worktree review progress during Cleanup scans.
- Recognize open symbolic links during worktree activity checks.
- Include ignored local files when saved remote data confirms a worktree merge and all remaining checks pass.
- Verify squash merges through GitHub and show the pull request in the worktree checks.
- Filter Cleanup results by data type in All and Safe to Remove.
- Keep selections across filters and remove only selected items in the current view.
- Hide the running application notice across scans and launches when requested.
- Review Xcode build folders with separate caches, logs, test results, and metadata.
- Review T3 Code storage under AI Tools with all T3 data protected.
- Recognize Codex history paths under private folders.
- Check application access and administrator approval during uninstall.

[Unreleased]: https://github.com/anguria-studio/Moppo/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/anguria-studio/Moppo/releases/tag/v0.5.0
[0.4.0]: https://github.com/anguria-studio/Moppo/releases/tag/v0.4.0
[0.3.0]: https://github.com/anguria-studio/Moppo/releases/tag/v0.3.0
[0.2.0]: https://github.com/anguria-studio/Moppo/releases/tag/v0.2.0
