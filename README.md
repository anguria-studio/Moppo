<p align="center">
  <img src="docs/images/moppo-icon-dark.png" width="160" alt="Moppo app icon">
</p>

<h1 align="center">Moppo</h1>

<p align="center">
  See what uses your disk space. Review what you remove.<br>
  A native macOS app, built with Swift and SwiftUI.
</p>

<p align="center">
  <a href="#install-on-a-mac">Install</a> &middot;
  <a href="#features-at-a-glance">Features</a> &middot;
  <a href="#your-data">Privacy</a> &middot;
  <a href="CHANGELOG.md">Changelog</a> &middot;
  <a href="#build-the-app">Build</a> &middot;
  <a href="docs/README.md">Docs</a> &middot;
  <a href="https://github.com/anguria-studio/Moppo/issues">Issues</a>
</p>

<p align="center">
  <a href="https://github.com/anguria-studio/Moppo/releases/latest"><img src="https://img.shields.io/github/v/release/anguria-studio/Moppo?label=release&amp;color=8a5fa8&amp;style=flat" alt="Latest release"></a>
  <a href="#install-on-a-mac"><img src="https://img.shields.io/badge/Apple-notarized-black?style=flat&amp;logo=apple" alt="Apple notarized"></a>
  <a href="#install-on-a-mac"><img src="https://img.shields.io/badge/macOS-15%2B%20Apple%20silicon%20or%20Intel-black?style=flat" alt="macOS 15 and newer, Apple silicon or Intel"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-8a5fa8?style=flat" alt="MIT License"></a>
</p>

<p align="center">
  <img src="docs/images/moppo-cleanup-dark.jpg" width="860" alt="Moppo Cleanup in dark mode on a Mac desktop, showing items selected for removal">
</p>

**[Download Moppo for macOS](https://github.com/anguria-studio/Moppo/releases/latest/download/Moppo.dmg)**
 · macOS 15+ · Apple silicon and Intel · Signed and notarized

Or install with [Homebrew](https://brew.sh):

```sh
brew install --cask anguria-studio/tap/moppo
```

## Features at a glance

| Feature | What you can do |
| --- | --- |
| Dashboard | See disk usage and compare changes between saved measurements. |
| Cleanup | Review caches, application leftovers, Xcode data, developer folders, and Git worktrees. |
| Storage Explorer | Browse folders with a table and treemap. |
| AI Tools | Review AI tool storage, Codex sessions, worktrees, and local models. |
| Duplicates | Compare file contents or find identical and similar photos. |
| App Uninstaller | Review applications and related files. Remove Homebrew packages through Homebrew. |
| Docker images | Review unused images and remove them through Docker. |
| History and Put Back | Review removal results and restore eligible items from the Trash. |
| Everyday controls | Set exclusions, scan schedules, low-space alerts, and menu bar mode. |

See the [user guide](docs/user-guide.md) for filters, file access, settings, and removal behavior.

## Install on a Mac

1. [Download the disk image](https://github.com/anguria-studio/Moppo/releases/latest/download/Moppo.dmg).
2. Open the disk image.
3. Drag **Moppo** to **Applications**.
4. Open Moppo.
5. Follow the welcome guide to review file access.

The Homebrew command above installs the same signed and notarized disk image.
Use the full cask name as shown.

Use **Moppo > Check for Updates…** to check for a new version.
Moppo checks for updates automatically. You can turn off automatic checks in **Settings > Updates**.

## Removal and recovery

| Before removal | What to know |
| --- | --- |
| Reported sizes | Shared storage can reduce the space that removal recovers. |
| Put Back | Recovery requires a saved receipt and the item still in the Trash. |
| Permanent removal | Put Back cannot restore Homebrew packages, Docker images, or permanently deleted items. |
| Photos | With iCloud Photos enabled, deletion affects the linked library and its other devices. |

Read the [removal and Put Back guide](docs/user-guide.md#removal-and-put-back) for confirmation, permission, and recovery details.

## Your data

Scans run locally. Moppo stores scan caches, preferences, and cleanup history on your Mac.
Photo previews and originals can download from iCloud. Controls are in **Settings > Advanced**.
macOS manages file and Photos access.

Read the [privacy policy](https://anguria.studio/moppo/privacy/) and [terms of use](https://anguria.studio/moppo/terms/).

## Build the app

Moppo uses Swift 6, SwiftUI, and XcodeGen.
See the [build and test guide](docs/building.md) for requirements, signing, commands, and CI checks.

## Documentation and contributing

| Guide | Contents |
| --- | --- |
| [User guide](docs/user-guide.md) | Permissions, Cleanup filters, settings, removal, recovery, and updates |
| [Development notes](docs/README.md) | Source layout, measurement rules, and current limits |
| [Build and test](docs/building.md) | Development setup and required checks |
| [Release packages](docs/distribution.md) | Signing, notarization, and packaging |
| [Writing style](WRITING_STYLE.md) | Rules for documentation, interface text, and code comments |
| [Project instructions](AGENTS.md) | Repository guidance and contribution rules |

Open an [issue](https://github.com/anguria-studio/Moppo/issues) before a large change.
For bug reports, include the expected behavior and steps to reproduce the problem.
Remove private file paths and personal photos from reports.
Run the relevant tests and writing checks before you submit a pull request.

For support, use **Help > Report a Problem…** or email [hello@anguria.studio](mailto:hello@anguria.studio).
Review the generated report before you send it.

## Credits and license

Moppo uses protection lists from [Purge](https://github.com/jithin-sabu/purge-app), by Jithin Sabu.
Purge also informed the original Ollama manifest reader.
[Sparkle](https://sparkle-project.org/) provides application updates.

Moppo uses the [MIT License](LICENSE).
See [Third-party notices](THIRD_PARTY_NOTICES.md) for source details and license notices.
