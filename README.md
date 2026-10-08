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
  <a href="#build-the-app">Build</a> &middot;
  <a href="docs/README.md">Docs</a> &middot;
  <a href="https://github.com/anguria-studio/Moppo/issues">Issues</a>
</p>

<p align="center">
  <a href="#install-on-a-mac"><img src="https://img.shields.io/badge/status-in%20development-orange?style=flat" alt="In development"></a>
  <a href="#install-on-a-mac"><img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat&amp;logo=apple" alt="macOS 15 and newer"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-8a5fa8?style=flat" alt="MIT License"></a>
</p>

**Moppo is in development.** A packaged release is not available yet.
[Build the app from source](#build-the-app) to try the current version.

## Why Moppo?

Disk usage, cleanup, duplicate review, and application removal in one Mac app.

- **Understand your storage.** See disk usage and compare changes between saved measurements.
- **Review cleanup candidates.** Inspect caches, application leftovers, and developer files before removal.
- **Find duplicate files and photos.** Compare file contents or photo appearance, then review the results.
- **Keep a cleanup record.** Check removal history and restore eligible items with Put Back.

## Features at a glance

### Storage and cleanup

| Feature | What you can do |
| --- | --- |
| Dashboard | See disk capacity, measured categories, unreadable data, and changes since an earlier measurement. |
| Cleanup | Review system caches, package caches, Xcode data, application leftovers, and other files. |
| Storage Explorer | Browse a folder or volume with a table and treemap. Review selected items before removal. |
| Developer folders | Inspect project files and Git worktrees, with badges for local changes and unpushed commits. |
| Local AI models | Review Ollama, Hugging Face, and LM Studio models with shared storage information. |

### Duplicates and applications

| Feature | What you can do |
| --- | --- |
| Duplicate files | Compare files in selected folders by size, hashes, and exact file contents. |
| Duplicate photos | Find identical or similar photos with PhotoKit and Vision. Keep one copy in each group. |
| App Uninstaller | Review an application and its associated files before removal. |
| Finder action | Open an uninstall review with **Services > Review Uninstall with Moppo**. |

### Everyday controls

| Feature | What you can do |
| --- | --- |
| Cleanup history | Review removal results, failures, and saved receipts. |
| Put Back | Restore eligible items that Moppo moved to the Trash. |
| Exclusions | Keep selected paths out of scans and removal plans. |
| Menu bar and schedules | Check free space and run scheduled scans while Moppo is running. |
| Low-space alerts | Get a notification when available space falls below your chosen threshold. |

APFS clones can share storage. Reported cleanup sizes are upper bounds, not promises of recovered space.
Put Back needs a saved receipt and an item still in the Trash.
The [development notes](docs/README.md#deliberate-limitations) explain the current limits.

## Install on a Mac

The app targets **macOS 15 or later**.
Distribution packages, notarization, and updates remain in preparation.
Use the [source build](#build-the-app) until a packaged release is available.

On first launch, follow the welcome guide to review file access.
Choose **Enable** for Full Disk Access, or **Continue with Limited Access** to enter the app.
Limited access can leave protected folders unreadable.
Scheduled scans and automatic storage measurements require Full Disk Access.

Opening **Duplicates > Photos** requests Photos access.
Select **Find Duplicates** to start the photo scan.

<details>
<summary><strong>Photo downloads and removal</strong></summary>

Photo downloads are on by default.
Change this in **Settings > Advanced**.
Scans and the photo grid can download missing previews from iCloud.
Opening a photo preview can download its original.
The setting applies to new requests. Active requests can finish.

With iCloud Photos enabled, deletion affects the linked library and its other devices.
Deleted photos move to Recently Deleted, so storage recovery can take time.
Use Photos to review recovery and permanent deletion.

</details>

## Your data

- **Scans run locally.** Moppo stores scan caches, preferences, and cleanup history on your Mac.
- **Photo downloads use iCloud.** Turn them off in **Settings > Advanced** to use available local previews and originals.
- **Permissions stay under your control.** macOS manages file and photo access. Moppo reports content that it cannot read.
- **Background work needs Moppo.** Schedules and low-space checks also run in menu bar mode.

Read the [permissions notes](docs/README.md#permissions) for local storage and development signing details.

## Build the app

<details>
<summary><strong>Requirements, build commands, and tests</strong></summary>

### Requirements

- Xcode with Swift 6 and Icon Composer support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An Apple Development signing certificate and its team identifier

Current development checks use Xcode 27.
The generated app targets macOS 15 and later.
Vale checks the documentation style.

### Build and test

```sh
git clone https://github.com/anguria-studio/Moppo.git
cd Moppo
```

Set `DEVELOPMENT_TEAM` in `project.yml` to your team identifier.
Keep `CODE_SIGN_IDENTITY` set to `Apple Development`.
Then generate and open the project:

```sh
xcodegen generate
open Moppo.xcodeproj
```

Choose the **Moppo** scheme.
Press **⌘R**.
The app requires code signing because macOS associates privacy access with the signed app identity.
Do not build the app with `CODE_SIGNING_ALLOWED=NO`.

For a command-line build:

```sh
xcodebuild \
  -project Moppo.xcodeproj \
  -scheme Moppo \
  -configuration Debug \
  build
```

Run the core tests and writing checks from the repository root:

```sh
swift test --package-path Core
vale README.md AGENTS.md WRITING_STYLE.md
```

Use the **Moppo Onboarding** scheme to show the welcome guide on every Debug launch.
This scheme keeps saved settings and system permissions.
See the [development notes](docs/README.md) for the command-line scanner, source layout, and measurement rules.

</details>

## Documentation and contributing

| Start here | What you will find |
| --- | --- |
| [Development notes](docs/README.md) | Build setup, source layout, measurement rules, permissions, and current limits |
| [Writing style](WRITING_STYLE.md) | Rules for documentation, interface text, and code comments |
| [Project instructions](AGENTS.md) | Repository guidance and required writing checks |
| [Issues](https://github.com/anguria-studio/Moppo/issues) | Bug reports, feature requests, and release work |
| [Project board](https://github.com/orgs/anguria-studio/projects/1) | Backlog, release phases, and historical work |

Open an issue before a large change.
For a bug report, include the expected behavior and steps to reproduce the problem.
Remove private file paths and personal photos from reports.
Run the relevant tests and writing checks before you submit a pull request.

## Credits

Moppo uses cache-name and container protection lists from
[Purge](https://github.com/jithin-sabu/purge-app), by Jithin Sabu, in `IdentityState.swift`.
Purge also informed the original Ollama manifest reader in `LocalModelStores.swift`.
The current reader uses different shared-model grouping logic.

See [Third-party notices](THIRD_PARTY_NOTICES.md) for the source details and upstream MIT notice.

## License

Moppo uses the [MIT License](LICENSE).
Third-party material retains its notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
