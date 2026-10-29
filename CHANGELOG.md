# Changelog

Changes that affect Moppo users appear here, with the newest release first.

## [Unreleased]

- Show Gemini CLI and Antigravity storage in AI Tools. Keep all files protected and count the shared `~/.gemini` folder once.

- Offer administrator approval when Cleanup cannot move recognized Apple sound libraries to Trash. Preserve receipts and approved Put Back.

- Add Never Offer This Again to Cleanup row menus, with saved exclusions for files, folders, local models, and Docker images.
- Add `moppo exclude` to save the same exclusions as Never Offer This Again from the CLI.
- Install the `moppo` command and the agent skill for Claude Code, Codex, or Cursor from Settings > Advanced.
- Add plan removal from Terminal at an exact plan revision, with shared operation locking and saved outcomes.
- Require Touch ID or the login password before the CLI removes items permanently.
- Keep plans valid when cache sizes or directory contents change after the scan. Plans show the current sizes.
- Keep the scans that saved plans use when the CLI removes old scans.
- Show validation skips in Cleanup History.

- Add a portable Moppo agent skill and guidance for disclosure, user confirmation, and client validation.
- Add optional app review for saved CLI plans, mandatory confirmation, and saved removal outcomes.
- Add saved CLI cleanup proposals with revision, exclusion, and file identity checks.
- Add a read-only CLI with private scan reports, JSON output, filters, and shared app exclusions.

- Offer obsolete Homebrew formula versions for reviewed permanent removal through Homebrew, with separate sizes and Cleanup History results.
- Add Open and Empty Trash to a native sidebar popover with an arrow that points to Trash.
- Allow Command-Q to quit from the worktree review dialog.
- Allow reviewed deletion of compressed Codex history through Codex, including compressed child sessions.
- Remove the Go module cache through Go after mandatory confirmation, with command results in Cleanup History.
- Avoid Trash names that Git still reserves for missing worktrees.
- Explain denied Trash access during worktree removal and show Full Disk Access guidance.
- Show the draggable Moppo icon when a Full Disk Access action opens System Settings.
- Use white fills for Settings action buttons in Light appearance.
- Reduce the hover color change on Cleanup rows and section headers in both appearances.
- Shorten cleanup measurement guidance in Dashboard.

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

[Unreleased]: https://github.com/anguria-studio/Moppo/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/anguria-studio/Moppo/releases/tag/v0.3.0
[0.2.0]: https://github.com/anguria-studio/Moppo/releases/tag/v0.2.0
