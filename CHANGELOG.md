# Changelog

Changes that affect Moppo users appear here, with the newest release first.

## [Unreleased]

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

[Unreleased]: https://github.com/anguria-studio/Moppo/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/anguria-studio/Moppo/releases/tag/v0.2.0
