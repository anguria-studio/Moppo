# Moppo development notes

[Back to the project overview](../README.md).

These notes cover build setup, measurement rules, permissions, and current limits.
Run the commands from the repository root unless a command changes the folder.

Use the [user guide](user-guide.md) for app controls, permissions, and removal instructions.
Use the [build and test guide](building.md) for development requirements and complete validation commands.

## Build and run

```sh
xcodegen generate                 # regenerates Moppo.xcodeproj from project.yml
open Moppo.xcodeproj              # ⌘R to run
swift test --package-path Core    # check the engine
swift run --package-path Core moppo-cli scan  # run the scanner
vale README.md AGENTS.md WRITING_STYLE.md CHANGELOG.md SECURITY.md docs  # check project writing
```

`project.yml` generates `Moppo.xcodeproj`, and Git ignores the generated
project. Change targets or build settings only in `project.yml`. XcodeGen includes
new source files from `App/` automatically.

Moppo imports preferences from the previous app identity once. Existing Moppo
preferences take priority. When a Moppo data folder does not exist, Moppo moves
the previous folder to the new name. This preserves caches, measurement history,
and cleanup records for Put Back. If both folders exist, Moppo keeps them and uses
the Moppo folder. macOS can request permissions again because the app identifier
has changed.

`App/Resources/AppIcon.icon` contains the Icon Composer source. It includes light
and dark appearances with neutral background gradients. The menu bar uses a
vector template image that follows the system appearance.

Select the `Moppo Onboarding` scheme to show the welcome guide on every Debug run.
This scheme passes `--show-onboarding`. It keeps saved settings and system permissions.
The `Moppo` scheme shows the guide until you complete it.
If access is missing on a later launch, Moppo shows the access step again.
Select **Enable** to open System Settings, or select **Continue with Limited Access** to enter the app.
At the end of the welcome guide, **Get Started** opens Cleanup, also without Full Disk Access.
The cleanup scan starts when you enter Cleanup, including with limited access.
With limited access, Cleanup scans only the folders that Moppo can read.
Scheduled scans and automatic storage measurements wait for Full Disk Access.
macOS can request folder access during a scan. Moppo requests Photos access when you open
Duplicates > Photos. Returning from System Settings refreshes the permission state.
The photo scan starts only when you select Find Duplicates.
Use **Moppo > Show Welcome Guide** to read the guide again.
Photo download controls and guidance are available in **Settings > Advanced**.
## Scan profiling and diagnostics

```sh
swift build --package-path Core -c release
Core/.build/release/moppo-cli profile-scan cleanup --skip-docker
Core/.build/release/moppo-cli profile-scan dashboard
Core/.build/release/moppo-cli profile-scan cleanup --skip-docker --log-directory /tmp/moppo-scan-logs
```

`profile-scan` compares two runs in one process and prints category times, process CPU time, disk activity, and worker counts.
The first run can use existing macOS file caches, so the report does not claim a cold disk cache.
The output excludes account names, file names, and file paths. The command saves nothing and changes no preference.
Record the Mac model, the macOS version, the access settings, and the build beside a report.

`scripts/package-dmg.sh --scan-logging` builds a private test package that writes detailed logs to `~/Library/Logs/Moppo/Scans`.
Select **Help > Show Scan Logs** to open the folder. Normal packages keep this logging off.
Detailed logs can contain private file paths, project names, command arguments, and error messages. Review a log before you share it.
Logs exclude file contents, conversation messages, passwords, tokens, and environment values.
The research record describes each log record and each profiling figure.

The [CLI guide](cli.md) describes the supported command interface.
The [agent workflow](agent-workflow.md) covers skill installation, confirmation, disclosure, and client validation.
The app and the CLI share exclusion decoding and the macOS scan context. With `settings.showsSmallItems` on, the scan hides only empty rows.

## Layout

```
Core/                         Swift package
  Sources/MoppoCore/          Scanning engine and cleanup services
    Measure/                 AllocatedSizeMeasurer, MeasurementReader, BulkMeasurementReader, ByteFormatting
    System/                  Disk information, snapshots, process execution, scan and Dashboard diagnostics
    Scan/                    Category scanners, Codex session review, and scan coordination
    Act/                     Cleanup, Docker images and volumes, app uninstall, sound libraries, Trash, history
    Resources/               Homebrew formula version adapter
    Generated/               Rule tables that scripts/rules.py writes from rules/
    Duplicates/              File duplicate detection and removal
    StorageExplorer/         Folder measurement and reviewed removal
  Sources/MoppoScan/         Shared macOS scan context and application ownership
  Sources/MoppoPlans/        Private scan reports, saved plans, validation, and removal outcomes
  Sources/MoppoCLI/          Supported command interface
  Sources/moppo/             Supported command executable
  Sources/moppo-cli/         Developer diagnostics
  Tests/MoppoPlansTests/     Proposal validation, file identity, and retention tests
  Tests/MoppoCLITests/       CLI contract, settings, cancellation, and storage tests
  Tests/MoppoCoreTests/      Engine tests
App/                          SwiftUI app
  Cleanup/                   Cleanup model, services, and scheduler
  Dashboard/                 Dashboard model and measurement services
  DesignSystem/              Shared controls, colors, text styles, and application icons
    Mascot/                  Moppo motion, beams, and acts
      Beams/                 Scan beams, deletion rays, and floor light
      Acts/                  One file for each act, and the act protocol
  Duplicates/                File duplicate model
  MainWindow/                Main views, sidebar, sheets, and external requests
  SavedPlans/                Saved plan review, mandatory confirmation, and outcomes
  Photos/                    Photo model, PhotoKit access, and thumbnails
  Preferences/               Four panes and the settings store
  Recovery/                  History, Trash, and Put Back model
  StorageExplorer/           Storage Explorer model and services
  Uninstaller/               App Uninstaller model, scan services, and permanent removal
  Updates/                   Sparkle controller, preferences, and installation guard
  Support/                   Privacy information, support reports, and scan log access
Helpers/                      Separate application tools
  AdministratorTrash/        Approved sound library moves and recovery
  HomebrewAskpass/            Homebrew password prompt
skills/moppo-cleanup/          Portable agent instructions for CLI inspection and saved plans
rules/                        Tool rule registry, one JSON file for each tool
scripts/                      Release packaging and the rule generator
design/                       Archived design handoff, kept locally
```

Run `swift test --package-path Core` to check engine behavior before you build the interface.
Regression tests cover each measurement bug below.

## State ownership

`AppModel` creates feature models and owns navigation, onboarding, and shared presentation.
Views receive their feature model directly, and navigation goes through explicit callbacks.

| Component | Responsibility |
| --- | --- |
| `PhotoDuplicatesModel` | Photos access, scans, regrouping, selection, preview state, thumbnail requests, and deletion. |
| `CleanupModel` | Cleanup scans, filters, results, selection, captured removal plans, and operation tasks. |
| `AppUninstallerModel` | Application lists, leftovers, uninstall reviews, selection, and removal tasks. |
| `DashboardModel` | Storage measurements, cached figures, snapshots, iCloud data, and growth comparisons. |
| `RecoveryModel` | History, Trash, recovery selection, Put Back, and empty Trash tasks. |
| `CleanupScheduler` | Periodic volume checks and automatic scan requests. |
| `FileDuplicatesModel` | File scans, size filters, keeper selection, removal, and result invalidation. |
| `StorageExplorerModel` | Folder measurements, navigation history, cached results, selection, and removal tasks. |
| `OperationCoordinator` | Shared operation guards and operation identity for scans, reviews, removal, recovery, and update installation. |
| `UpdateController` | Sparkle checks, update preferences, and deferred installation. |

| Rule | Owner |
| --- | --- |
| Handles scan, deletion, removal, and failure events, and refreshes other features through explicit callbacks. | `AppModel` |
| Guards scans, reviews, removal, recovery, and update installation. Only the matching operation releases the guard. | `OperationCoordinator` |
| Scans and Put Back cannot run together. A blocked action shows a toast that names the active operation. | `OperationCoordinator` |
| Continues a scan when the user changes pages. Stop cancels the task and keeps the guard until the service returns. | Each feature model |
| Cancels Cleanup, duplicate, and Storage Explorer scans before the app quits, then waits for workers and log writes. | `AppModel` |
| Rejects results from cancelled or replaced tasks through scan and request identifiers. | Each feature model |
| Captures exclusions, categories, and the receipt setting before each scan or removal. | Each feature model |
| Owns removal and recovery tasks independently of the requesting view. | Each feature model |
| Invalidates results and selection after a removal or a Put Back. | Each feature model |
| Measures in the background, outside the shared guard. Concurrent requests share one task. | `DashboardModel` |
| Waits for active Cleanup workers before a measurement. Cleanup cancels an active Dashboard measurement first. | `DashboardModel` |
| Keeps the cleanup baseline from the measurement before the newest cleanup. A failed removal creates no baseline. | `DashboardModel` |
| Serializes history writes outside the main actor. An older read cannot replace a new baseline. | `DashboardModel` |
| Reads access, power, idle time, preferences, and the operation state before an automatic scan. | `CleanupScheduler` |
| Pauses new application size walks while Cleanup runs. | `AppUninstallerModel` |
| Checks current owners before leftover removal and sends quit requests before removal. A refusal stops removal. | `AppUninstallerModel` |
| Moves assets to Recently Deleted through Photos, with no Trash receipt and no disk refresh. | `PhotoDuplicatesModel` |
| Keeps the guard through a replacement measurement and rejects late results and progress callbacks. | `StorageExplorerModel` |

**Confirm before every clean-up** controls the Cleanup review.
Docker volume removal, Homebrew batches, Empty Trash, and each tool command always show a review.
Confirmation captures the selection and the preferences before the decision. Cancellation keeps the selection and releases the guard.
A tool command runs fixed arguments after Moppo checks the tool and the item identity again.
Its result enters Cleanup History with the measured size reduction and the verified disk recovery.
The research record holds the simulator runtime, Homebrew version, and Docker command rules.

## Measurement rules

| Rule | Reason |
| --- | --- |
| Report unused APFS container space as Free. | macOS can count removable temporary files as available space. |
| Keep category measurements separate from physical usage. | Files can share storage or change during a scan, so categories can exceed usage. |
| Count protected parents once. | AI Tools subtracts disclosed child sizes from each protected parent remainder. |
| Treat allocated bytes as an upper bound. | APFS clones and hard links share storage that no per-file API shows. |
| Read home metadata in batches with `getattrlistbulk`. | The walker visits the complete tree, counts hard links once, and keeps volume boundaries. |
| Follow folder locations for Dashboard categories. | System Settings uses other rules, so its totals are not a reference. |
| Never use `du`. | It stops at the first unreadable directory, and the old code then reported the category as empty. |
| Report what Moppo could not read. | Each result carries its unreadable count, and Unmeasured holds the residual. |
| Keep the name `Unmeasured`. | The predecessor presented guesses as measurements under other names. |
| Measure the Data volume at its own mount point. | The `/System` path through `/` is the read-only System volume. |
| Keep categories disjoint. | `DisjointCategoriesTests` fails when two scanners claim one path. |
| Compare only measurements that use the same rules. | A rule change makes two figures different kinds of measurement, and the report says not comparable. |

Xcode & iOS Dev also finds verified build caches in the user's temporary folders and project release folders.
Storage history lives in `~/Library/Application Support/Moppo/storage-history/`. Preferences › Advanced clears it.
The research record holds the discovery limits and the Apple Intelligence merge rule.

## AI storage

AI Tools shows the default storage of each AI tool and the local model stores. The [AI storage sources and limits](ai-storage.md) document lists them.
Installed application bundles stay under Applications. AI Tools owns installed desktop support folders, and Application Leftovers owns them when the application is absent.
Codex archived and inactive sessions require a deletion review, also when general confirmation is off. Codex deletes them permanently.
Active writers, changed history, and changed child sessions stop deletion.
Only verified desktop caches and worktrees with complete checks enter Safe to Remove. A running application removes its caches from Safe to Remove.
Claude VM rows separate the system disk, the compressed runtime download, and the session disk. The scanner measures allocated storage and does not mount disks.
Use `swift run --package-path Core moppo-cli ai` to inspect the default storage rows without removal.
Moppo offers no session recovery. The research record explains why.

## Developer tool storage

The [tool rule registry](tool-rules.md) in `rules/` is the source of every tool storage rule.
It generates the Swift tables, the AI tool enums, and the icon identifiers.
It also generates the tables of the [developer tool storage catalog](tool-catalog.md) and the AI storage document.
Change a rule in `rules/<tool>.json`, then run `python3 scripts/rules.py generate`.
Add a removal rule only from a catalog row with a `Verified` status. A folder name alone is not evidence.
Hidden & System Data shows a protected home folder or a tool location with its size.
It offers only the caches that the catalog verified, and only when the tool layout is present.
`RuleDocumentTests` compares the documents with the Swift tables. `LayoutFixtureTests` checks each rule against its layout.
`python3 scripts/rules.py audit` lists tools that are newer than their verification and rules without one. Run it before each release and after each test rental.

## Scanner rows and Git worktrees

Cleanup has the All and Safe to Remove tabs. The [user guide](user-guide.md) describes the rows, the locks, and the worktree dialog.

| Rule | Detail |
| --- | --- |
| Documents & Files scans the user folders, `~/Developer`, and `~/Projects`. | Worktree discovery searches eight folder levels and skips dependency stores and Git metadata. |
| A worktree row counts its contents once in the parent total. | One traversal collects project, worktree, and ignored file sizes. |
| Worktree checks run two at a time within each project. | One process inventory supplies file identities for the project scan. |
| Cleanup repeats every check before removal. | One process inventory covers all selected worktrees. |
| The status pill reports one result in a fixed order. | In use, uncommitted changes, unpushed commits, has local files, could not verify, safe to remove. |
| A merge check first reads the saved remote default branch. | A confirmed merge includes all readable ignored files in removal. |
| Without saved history, Moppo asks GitHub through the installed GitHub CLI. | The merged pull request must match the exact commit and the current default branch, including squash merges. |
| GitHub requests send repository names and commit identifiers only. | Up to 20 commits for each request, two repositories at once, five seconds for each request, ten seconds for each repository. |
| Successful GitHub results stay in memory until Moppo quits or the cache exceeds 2,048 entries. | Failed results expire after 30 seconds and pause repeated requests for 30 seconds. |
| A branch compares with its upstream, and a detached worktree with all remote-tracking branches. | A branch without an upstream, or incomplete history, has unknown push status. |
| Ignored files stay under review without a confirmed merge. | Verified caches, dependency stores with reinstall evidence, Finder metadata, and Xcode window state count as regenerable. |
| A generated Xcode project needs a tracked specification and an installed XcodeGen. | Moppo generates a comparison project in a private temporary folder, with file, size, and time limits. |
| Generated-file checks use bounded reads. | They never execute project code. |
| The open-file check covers the user's visible processes. | It cannot identify every inactive tool session. Close the owning tool before removal. |
| Only worktrees with complete checks enter Safe to Remove. | **Select anyway** selects a worktree that needs review, and the confirmation reports it. |
| Worktree removal moves the folder to the Trash through Git when Git is available. | Git updates the registration. Put Back restores it and needs a saved receipt. |
| Administrator approval can move recognized Apple sound libraries when permissions block Cleanup. | A separate helper checks the content again after approval. |

The research record holds the full check rules and their limits.

## The boot snapshot

macOS boots from a sealed, read-only APFS snapshot named `com.apple.os.update-…`, mounted at `/`. It is the running operating system, not an update leftover.
`SnapshotService` lists snapshots for the Dashboard and deletes only Time Machine local snapshots, with `tmutil deletelocalsnapshots` and the date in the name.
The user confirms each deletion. Moppo deletes no other snapshot, and the Dashboard does not list the boot snapshot.

## Deliberate limitations

| Limitation | Reason |
| --- | --- |
| File operations use normal permissions. | Moppo requests no administrator access for cleanup, Put Back, or Empty Trash. Denied items get **Show in Finder**. |
| Permanent application deletion needs a failed Trash move and a confirmation. | macOS can ask for administrator approval. Moppo never receives the password, and Put Back cannot restore the application. |
| Homebrew manages package removal. | The signed password helper sends the password to `sudo` only when Homebrew requests it. |
| Put Back restores only what Moppo trashed. | macOS exposes no API for the original location of a Finder item. |
| Cleanup History uses saved removal receipts. | The Trash view puts back items whose saved identity still matches. |
| "Last opened" often means last modified. | `kMDItemLastUsedDate` returns null for almost every item on macOS 26, so Moppo falls back to modification dates. |
| File duplicate scans use selected folders and compare bytes. | Size, sampled SHA-256, and full SHA-256 narrow candidates. Moppo skips packages, hard links, hidden files, and cloud-only files. |
| The free space for duplicates is an upper bound. | APFS clones can share storage. The volume free-space value is the final result. |
| Storage Explorer measures one folder level at a time. | Hard links count once across siblings. System locations, applications, media libraries, and volumes stay protected. |
| Automatic scanning and low-space notifications are process-resident. | No launch daemon wakes the application after a full quit. |
| Complete uninstall requires an existing application bundle. | App Uninstaller attributes related files from the verified identity. Helpers stay with their parent application. |
| Finder only starts an uninstall review. | The Finder service opens the App Uninstaller review and never removes files. |
| Application Leftovers uses strict ownership rules. | Exact bundle identifier paths, curated roots, and the verified data folders with other names. Moppo ignores loose name matches. |
| Downloaded Apple sounds use the application flows. | Removal needs Apple asset package receipts, moves content to the Trash, and keeps folders with unknown files. |
| The app has no "Storage Report…". | The design named the label and no function. |

The research record holds the details of each limitation.

## Permissions

The app measures `~/Documents`, `~/Desktop` and `~/Downloads`, all TCC-gated. The
Debug target uses the stable Apple Development identity configured in `project.yml`,
so TCC grants survive rebuilds. Do not validate the app with
`CODE_SIGNING_ALLOWED=NO`: that replaces the Debug product with an ad-hoc identity
and macOS correctly asks for access again. The app target rejects unsigned builds.

Moppo stores the last breakdown at
`~/Library/Application Support/Moppo/breakdown-cache.json`. This data seeds the
initial layout. The Dashboard refreshes it at launch. A scan also refreshes it with
the category results.

## Design

`design/README.md` contains the archived design handoff. It stays outside the repository.
Its pixel values describe the appearance of standard native controls. The app uses these stock controls. The
platform supplies all three glass tiers. They use `.listStyle(.sidebar)`, the
unified toolbar, and `.bar` in a `safeAreaInset`. The app does not draw gradients.

Colours resolve to `NSColor` semantics so the app follows the user's accent choice
and Increase Contrast. Three literals survive, for shades AppKit has no name for.

## Moppo acts

Moppo can play a short act during some scans.
Most scans show one act.
`MascotActScheduler` applies these rules:

- An act never starts in the first 5 seconds of an operation.
- Each operation has a 3 in 4 chance to get an act.
- Each operation gets one act at most.
- An act starts only after the beams have been off for a pause.
- After an act ends, no other act starts in the app for 30 seconds.
- After an act, the beams wait for a full rest before they fire again.
- With Reduce Motion on, Moppo does not move, and no act plays.

Each scan has its own set of acts:

| Screen | Acts |
| --- | --- |
| Cleanup scan | Magnifying lens, radar ping, peek, barcode, binoculars, and a rare Sauron eye |
| Photo duplicate scan | Duplicates split, yawn after 60 seconds, binoculars, magnifying lens, and peek |
| File duplicate scan | Duplicates split and peek |
| Large deletion | None |

The beams are not acts. They fire on their normal schedule.
Short operations show the hourglass mode.
In this mode, Moppo turns into an hourglass until the operation ends.
With Reduce Motion on, these operations show the static hourglass symbol.

Onboarding shows Moppo above the content of each step.
On Welcome, Moppo looks around.
On Preferences, Moppo turns into the settings icon, and its knobs slide.
Moppo stays in place between the steps, and only the content below it changes.
With Reduce Motion on, onboarding shows the app icon and the slider symbol.

## Writing

Use ADS-STE100 Simplified Technical English for documentation, interface text,
code comments, release notes, and support text. See [WRITING_STYLE.md](../WRITING_STYLE.md)
for the project rules and the Vale command.

## Updates and support

[Update setup](updates.md) covers the update feed, signing key, and publishing commands.
[Release packages](distribution.md) covers Developer ID signing, notarization, and DMG preparation.
[Changelog](../CHANGELOG.md) records changes for each public release.
Sparkle 2.10.0 provides the standard update interface.
Moppo checks for updates automatically by default. Users can turn off automatic checks in Settings.
Installation requires approval.
The installation guard waits for the active operation and then prevents new disk work.
App termination waits for disk work, including when an approved update is waiting.
An unconfigured Debug build makes no update requests.
Release builds require a valid HTTPS feed and Ed25519 public key.

The Help menu provides Privacy Information and Report a Problem.
The app includes [privacy information](../App/Resources/Privacy.md).
Support reports include application and macOS versions.
They exclude file paths, photos, removal logs, and stored measurements.
Email Support opens a draft to `hello@anguria.studio` for user review.
