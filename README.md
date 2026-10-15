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

[Website](https://anguria.studio/moppo/) ·
[Privacy](https://anguria.studio/moppo/privacy/) ·
[Changelog](CHANGELOG.md) ·
[Releases](https://github.com/anguria-studio/Moppo/releases)

The Moppo website and privacy page remain in preparation.

## Why Moppo?

Disk usage, cleanup, duplicate review, and application removal in one Mac app.

- **Understand your storage.** See disk usage and compare changes between saved measurements.
- **Review cleanup candidates.** Inspect caches, application leftovers, and developer files before removal.
- **Find duplicate files and photos.** Compare file contents or photo appearance, then review the results.
- **Keep a cleanup record.** Check removal history and restore eligible items with Put Back.

## Features at a glance

<a name="storage-and-cleanup"></a>

### 🧹 Storage and cleanup

| Feature | What you can do |
| --- | --- |
| Dashboard | See disk capacity, measured categories, unreadable data, and changes since an earlier measurement. |
| Cleanup | Review system caches, package caches, Xcode data, application leftovers, and other files. |
| Docker images | Select unused images and remove them through Docker. |
| Storage Explorer | Browse a folder or volume with a table and treemap. Review selected items before removal. |
| Developer folders | Inspect project files and Git worktrees. Review local files, commits, and removal checks. |
| AI Tools | Inspect AI storage. Review Codex sessions, worktrees, and local models. Keep active sessions and VM files protected. |
| Local AI models | Review Ollama, Hugging Face, and LM Studio models with shared storage information. |

<a name="duplicates-and-applications"></a>

### 🗂️ Duplicates and applications

| Feature | What you can do |
| --- | --- |
| Duplicate files | Compare files in selected folders by size, hashes, and exact file contents. |
| Duplicate photos | Find identical or similar photos with PhotoKit and Vision. Keep one copy in each group. |
| App Uninstaller | Review an application and its associated files before removal. |
| Downloaded sounds | Review GarageBand sound libraries under Applications or App Leftovers. Keep content that other installed applications use. |
| Homebrew applications | Review the package, then let Homebrew remove it and update its installation record. |
| Finder action | Open an uninstall review with **Services > Review Uninstall with Moppo**. |

<a name="everyday-controls"></a>

### ⚙️ Everyday controls

Choose **System**, **Light**, or **Dark** in **Settings > General > Appearance**.
Changes apply immediately and remain saved across launches.
**System** follows macOS appearance changes and is the default.
**Reset Settings** restores **System**.

The Dashboard shows an iCloud setup card when storage information is unavailable.
Select **Set Up** to check access and open iCloud settings.
To hide the card, select its **X** button.
This choice remains saved across launches.
To restore it, enable **Settings > General > iCloud > Show on Dashboard**.
The same section contains **Set Up** and the storage plan control.
Moppo requires Full Disk Access for iCloud measurements.
If macOS restarts Moppo during setup, Moppo returns to Dashboard and checks storage.
The setup guide returns only if access or storage information remains unavailable.
The guide shows account settings after a failed measurement.
It does not require a separate Moppo sign-in or report the iCloud Drive switch state.
When a measurement fails, select **Try Again** or check the setup guide.

| Feature | What you can do |
| --- | --- |
| Cleanup history | Review removal results, failures, and saved receipts. |
| Put Back | Restore eligible items that Moppo moved to the Trash. |
| Exclusions | Keep selected paths out of scans and removal plans. |
| Menu bar and schedules | Check free space and run scheduled scans while Moppo is running. |
| Low-space alerts | Get a notification when available space falls below your chosen threshold. |

APFS clones can share storage. Reported cleanup sizes are upper bounds, not promises of recovered space.
Put Back needs a saved receipt and an item still in the Trash.
Put Back cannot restore applications that Homebrew removes.
After Homebrew removes the package, Moppo moves its verified related data to the Trash, including profiles and settings.
Related data moved to the Trash supports Put Back.
If **Confirm before every clean-up** is on, Moppo confirms removals that support recovery.
With this setting off, those removals start without a Moppo confirmation.
Homebrew uninstall always requires review because Put Back cannot restore the package.
Empty Trash always requires confirmation because it permanently erases items.
Moppo does not use `--zap`.
Moppo uses normal file permissions for cleanup, Put Back, and Empty Trash.
When macOS denies access, Moppo leaves those items and provides **Show in Finder**.
Moppo does not delete APFS snapshots.

If Homebrew needs administrator access, Moppo shows a password dialog.
The password helper sends your login password directly to `sudo`.
Moppo does not save the password or run Homebrew as root.
If removal fails, review the application to try again or copy the command to Terminal.
Docker removes selected images permanently, including their listed tags. Put Back cannot restore them.
Images used by containers remain locked. Image sizes include shared layers, so removal can recover less space.
**Confirm before every clean-up** also controls the Docker image review.
The [development notes](docs/README.md#deliberate-limitations) explain the current limits.

## Install on a Mac

The app targets **macOS 15 or later**.
Distribution packages, notarization, and updates remain in preparation.
See [release packages](docs/distribution.md) for the release build and notarization commands.
The planned [direct download](https://github.com/anguria-studio/Moppo/releases/latest/download/Moppo.dmg) becomes available after the first stable release.
Use the [source build](#build-the-app) until a packaged release is available.

On first launch, follow the welcome guide to review file access.
Choose **Enable** for Full Disk Access, or **Continue with Limited Access** to enter the app.
Limited access can leave protected folders unreadable.
Opening **Cleanup** starts its first scan, including with limited access.
macOS can request access to folders during this scan.
Scheduled scans and automatic storage measurements require Full Disk Access.

Open **Duplicates > Photos** to check Photos access.
If access is not set, select **Allow** to show the macOS permission choice.
Select **Find Duplicates** to start the photo scan.
If access is off, select **Open Settings** to change Moppo access.
If Moppo is missing from the Photos list, select **Recover Photos Access** for reset instructions.

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

## Updates and support

Use **Moppo > Check for Updates…** to check for a new version.
Enable automatic checks in **Settings > Updates** if required.
Moppo asks before it installs an update.
Installation waits for active scans, removal, and Put Back.

Use **Help > Privacy Information** to read the included privacy information.
Use **Help > Report a Problem…** to prepare a support report.
Review the email before you send it to `hello@anguria.studio`.
The generated report excludes file paths, photos, and removal logs.

See [update setup](docs/updates.md) for release configuration and pending distribution checks.

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

Run the tests and writing checks from the repository root:

```sh
swift test --package-path Core
xcodegen generate
xcodebuild -project Moppo.xcodeproj -scheme MoppoAppTests -destination 'platform=macOS' test
vale README.md AGENTS.md WRITING_STYLE.md
```

The app state tests use temporary files and a separate test process.
They do not launch Moppo or delete personal photos.

GitHub Actions runs these tests and writing checks for pull requests that target `main`.
Merging a pull request does not start another CI run.
CI uses Xcode 27 and an ad hoc signature for the separate test bundle.
CI runs process timing tests separately to prevent other test fixtures from delaying their timers.
CI does not build or launch the signed Moppo app.
Pull request checks also validate branch names and Conventional Commit titles.

When billing or quota limits prevent Actions jobs from starting, run the checks above locally before merging.
Run the branch and title check with the final pull request title:

```sh
PR_BRANCH="$(git branch --show-current)" \
PR_TITLE='feat: describe the change' \
python3 .github/scripts/check-conventions.py
```

Record the tested commit SHA, commands, results, and blocked jobs in the pull request.
Before merging, confirm that the pull request still points to the tested commit.
If the commit changes, repeat the local checks.
Code, test, build, and writing failures still block merging.
Local checks do not consume GitHub Actions minutes.
When Actions can run again, require its checks to pass.
See the [project instructions](AGENTS.md#local-validation-during-actions-billing-limits) for the complete fallback rules.

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

Moppo uses [Sparkle](https://sparkle-project.org/) for application updates.
See [Third-party notices](THIRD_PARTY_NOTICES.md) for source details and license notices.

## License

Moppo uses the [MIT License](LICENSE).
Third-party material retains its notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
