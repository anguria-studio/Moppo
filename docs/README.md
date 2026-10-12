# Moppo development notes

[Back to the project overview](../README.md).

These notes cover build setup, measurement rules, permissions, and current limits.
Run the commands from the repository root unless a command changes the folder.

## Build and run

```sh
xcodegen generate                 # regenerates Moppo.xcodeproj from project.yml
open Moppo.xcodeproj              # ⌘R to run
swift test --package-path Core    # check the engine
swift run --package-path Core moppo-cli scan  # run the scanner
vale README.md AGENTS.md WRITING_STYLE.md  # check project writing
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
The cleanup scan starts when you enter Cleanup, including with limited access.
Scheduled scans and automatic storage measurements wait for Full Disk Access.
macOS can request folder access during a scan. Moppo requests Photos access when you open
Duplicates > Photos. Returning from System Settings refreshes the permission state.
The photo scan starts only when you select Find Duplicates.
Use **Moppo > Show Welcome Guide** to read the guide again.
Photo download controls and guidance are available in **Settings > Advanced**.

## Layout

```
Core/                         Swift package
  Sources/MoppoCore/          Scanning engine and cleanup services
    Measure/                 AllocatedSizeMeasurer, ByteFormatting
    System/                  Disk information, snapshots, process execution
    Scan/                    Category scanners and scan coordination
    Act/                     Cleanup, app uninstall, Trash, history
    Duplicates/              File duplicate detection and removal
    StorageExplorer/         Folder measurement and reviewed removal
  Sources/moppo-cli/         Command-line tools
  Tests/MoppoCoreTests/      Engine tests
App/                          SwiftUI app
  Cleanup/                   Cleanup model, services, and scheduler
  Dashboard/                 Dashboard model and measurement services
  DesignSystem/              Shared controls, colors, and text styles
  Duplicates/                File duplicate model
  MainWindow/                Main views, sidebar, and sheets
  Photos/                    Photo model, PhotoKit access, and thumbnails
  Preferences/               Four panes and the settings store
  Recovery/                  History, Trash, and Put Back model
  StorageExplorer/           Storage Explorer model and services
  Uninstaller/               App Uninstaller model and services
design/                       Archived design handoff, kept locally
```

Run `swift test --package-path Core` to check engine behavior before you build the interface.
Regression tests cover each measurement bug below.

## State ownership

`AppModel` creates feature models and owns navigation, onboarding, and shared presentation.
It connects feature events, access checks, and requests to refresh other features.

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
| `OperationCoordinator` | Shared operation guards and operation identity for scans, reviews, removal, and recovery. |

Photo views receive `PhotoDuplicatesModel` directly.
File duplicate views receive `FileDuplicatesModel` directly.
Uninstaller views receive `AppUninstallerModel` and explicit navigation callbacks.
Cleanup views receive `CleanupModel` and presentation values from the application model.
Dashboard views receive `DashboardModel`, scan values, and explicit navigation callbacks.
History and Trash views receive `RecoveryModel` directly.
Storage Explorer views receive `StorageExplorerModel`, including its operation controls.
The photo model receives services, download preferences, an access condition, and an event handler.
It does not hold `AppModel` or change navigation directly.
`AppModel` handles scan-start, deletion-start, deletion-result, and failure events.

Photo, file, and Cleanup scans continue when the user changes pages.
A stop request cancels the scan task and keeps the shared operation guard until the service returns.
Scan and regroup identifiers reject results from cancelled or replaced tasks.
Only the matching operation can release the shared guard.
All feature scans, removal reviews, removal tasks, and recovery operations use the same coordinator.
Presentation state does not determine whether an operation is active.

The photo model owns access and deletion tasks independently of the requesting view.
Photos can decline deletion through its confirmation request.
A completed deletion removes assets from the retained scan and clears the selection before Moppo reports success.
Regrouping creates a new selection because group keepers can change.
Access revocation clears results, selection, previews, and thumbnail requests.
Preview cancellation and retry remain with `PhotoThumbnailLoader`.

Photos deletion moves assets to Recently Deleted and does not create Trash receipts.
It does not request a disk refresh because Photos does not immediately release storage.

The file model captures exclusions for each scan and receipt preferences for each removal.
It scans all eligible sizes, so filter changes do not require another scan.
Selection actions reject keepers, hidden files, and files outside the current results.
File removal owns its task independently of the requesting view.
Changed groups leave the review, while verified copies with permission failures remain selected.
Completed removals retain their Trash receipts and recovery actions.

`AppModel` handles file events for navigation, removal progress, completion, and failure presentation.
After file removal, the model releases the shared guard and requests a refresh through an explicit callback.
`AppModel` clears Cleanup and Storage Explorer results, refreshes Trash and History, and requests a storage measurement.
This refresh preserves the updated file review and cannot clear a later file operation.
Other disk removals and successful Put Back actions invalidate file results and selection.

The Cleanup model captures enabled categories and exclusions before each scan.
The scan service resolves application owners from one leftover candidate scan.
A new scan clears protected-data authorizations from the previous review.
Safe selection starts once per completed scan and preserves later deselection.

A Cleanup plan captures entries, protected-data authorizations, leftover paths, open applications, and the receipt setting.
Delayed size measurements can update only the same pending plan.
Cancelling confirmation discards that plan.
Cleanup removal and application quit requests own their tasks independently of the requesting view.
The shared guard remains active until each task completes.
A quit refusal stops removal before files change.

`AppModel` handles Cleanup events for navigation, confirmation, progress, completion, and failure presentation.
Explicit callbacks refresh application leftovers and disk results after removal.
Successful removal and Put Back invalidate Cleanup results and selection.
Partial removal keeps completed receipts and reports failed items.

`CleanupScheduler` owns the timer and checks the existing automatic scan policy.
It reads current access, power, idle time, preferences, last scan time, and operation state before requesting a scan.
Automatic scans preserve the current page.
The periodic volume check still supplies low-space notifications.

The uninstaller captures exclusions for each review and the receipt setting for each removal request.
Application lists and leftover lists use separate tasks with request identifiers.
Replaced loads cannot restore old results, measurements, or selection.
Review cancellation retains the shared guard until the planner returns.
Navigation preserves the review and its task.

Individual uninstalls, batch uninstalls, and leftover removal own their tasks independently of the requesting view.
Removal captures the reviewed plans before execution starts.
The application and its helpers receive normal quit requests before removal.
A quit refusal preserves the review and prevents removal.
Homebrew results retain partial failures and completed removal details.
Leftover removal checks current application owners before it calls the removal service.

`AppModel` handles uninstall progress, navigation, and completion events.
After removal, the uninstaller releases the shared guard and requests a disk refresh through an explicit callback.
Cleanup can request a leftover refresh through a separate callback.

The Dashboard model owns launch refreshes and measurements independently of the requesting view.
Concurrent measurement requests share one task.
Removal during measurement requests one additional measurement for the cleanup baseline.
Background measurements remain separate from the shared scan and removal guard.
New volume and iCloud requests reject older results.

Dashboard persistence runs outside the main actor and serializes history writes and clearing.
Clearing measurement history rejects results from earlier reads and measurements.
An older history read cannot replace a newly recorded cleanup baseline.
The selected growth baseline remains stored in preferences.

The recovery model owns separate History and Trash read tasks.
Replaced reads cannot restore old rows or selection.
History links select a Trash item only when its path and file identity match.
Put Back and empty Trash own their tasks independently of the requesting view.
The shared guard stays active until the operation and updated list reads finish.
The model then releases the guard and requests a Dashboard refresh through an explicit callback.
Successful Put Back actions also invalidate Cleanup, file duplicate, and Storage Explorer results.

Storage Explorer captures exclusions before each measurement and removal review.
Removal captures the selected rows, parent folder, and receipt setting before the review starts.
The review checks current file identities and protection rules before removal.
Changed, protected, missing, or unreadable selections stop removal with the existing explanation.
Removal owns its task independently of the requesting view.
Completion invalidates measured rows and selection before releasing the shared guard and requesting refreshes.

An Explorer replacement measurement waits for the cancelled measurement to return before starting.
The model retains the same guard through replacement and cancellation.
Generation checks reject late results and progress callbacks, including callbacks after completion.
Cache invalidation retains an active guard until the measurement returns.
The visible Explorer page refreshes invalidated results when the current operation permits it.
Navigation methods also check the guard, so commands cannot bypass disabled controls.

The scheduler remains separate from feature state and reads current conditions before each automatic scan request.
Stopping the scheduler during a volume refresh prevents that check from starting a scan.
Dashboard background measurements keep their existing independent lifetime and do not acquire the shared scan and removal guard.

## Measurement rules

**Distinguish free and available space.** Moppo reports unused APFS container space as Free.
macOS can include space from removable temporary files in its available capacity estimate.
These figures can differ without a measurement error.

**Explain category scope.** Dashboard categories follow folder locations.
Applications measures `/Applications` and `~/Applications`.
App data and apps in other locations remain in their folder categories.
Documents & Desktop measures only those two home folders.
macOS System includes supporting volumes and readable system files on the Data volume.
System Settings uses different category rules. Its totals are not a reference for each Moppo category.

The following rules address measurement errors from the Electron version.

**Do not use `du`.** It stops at the first unreadable directory. The old code's
`catch` converted this failure to `0`. One unreadable folder then zeroed an entire
category. `AllocatedSizeMeasurer` uses `FileManager.enumerator`. Its error handler
counts each failure and continues the scan.

**Report what you could not read.** Each result contains
`SizeMeasurement.unreadableCount`. The Dashboard puts unreadable data in its
`Unmeasured` segment. Callers must see the gap to trust this segment.

**Keep the name `Unmeasured`.** The predecessor used two incorrect names: "APFS
Snapshots & System Overhead" and "Other User Accounts". Both names presented
guesses as measurements. `Unmeasured` is the honest residual. A test checks this
label.

**Measure the Data volume at its own mount point.** The `/System` path through `/`
refers to the read-only System volume. The Data volume has a different `/System`
tree. This tree contains shared Apple assets, including Apple Intelligence models.

Readable Apple assets remain in macOS System. Unreadable storage remains in Unmeasured.
Moppo does not report a separate Apple Intelligence size.
Older saved measurements merge that category into macOS System when loaded.
New measurements use a different contract version and cannot produce growth comparisons with older measurements.

**Categories must be disjoint.** `DisjointCategoriesTests` asserts that no two
scanners claim the same path. Adding a cache root to one scanner fails the build
until you update the overlapping scanner.

**Reported sizes are an upper bound.** APFS clones share blocks between distinct
files and no per-file API can see it, so removing two clones frees less than their
sum. The measurer counts hard links once. Do not change this estimate into a
promise.

**Compare only measurements that use the same rules.** Moppo stores each
finished measurement together with the rules that produced it. The Dashboard then
subtracts two stored measurements and reports what grew, and where. A change to the
rules makes the two figures different kinds of measurement. The report states "not
comparable" and shows no numbers. Moppo keeps this history in
`~/Library/Application Support/Moppo/storage-history/`. Preferences › Advanced
clears it.

## Scanner rows and Git worktrees

The Scanner groups cleanup items. It does not show a complete folder tree.
Projects can expand to show dependencies and Git worktrees. Applications can
expand to show associated files. Ordinary folders stay as single rows.

Child rows have a 22-point indent. Size and action columns stay aligned.
The Safe to Remove filter can show a child as a separate row without its parent.
These separate rows use the normal alignment.

Documents & Files includes the usual user folders, `~/Developer`, and `~/Projects`.
The Scanner detects linked Git worktrees inside project folders and hidden
folders, including `.codex` and `.claude`. Discovery searches up to eight folder
levels and skips dependency stores and Git metadata. Worktree rows include their
contents once in the parent total.

Worktree badges report the state at scan time:

- **Uncommitted changes:** staged changes, unstaged changes, or untracked files.
- **Unpushed commits:** commits absent from the compared remote-tracking branches.
- **No unpushed commits:** both checks pass. This badge has muted green text and an outline.
- **Status unavailable** or **Push status unknown:** Moppo could not complete the corresponding check.

Branches use their upstream branch for comparison. Detached worktrees use all
local remote-tracking branches. Branches without an upstream have unknown push
status. Incomplete Git history also gives unknown push status.

Checks make no network requests. Local remote data can be out of date.
The uncommitted check excludes ignored files, which can include local settings
or databases. Every worktree stays in Needs Review, including worktrees with
no uncommitted changes or unpushed commits. A green outline does not mean
Safe to Remove.

## The boot snapshot

macOS boots from a sealed, read-only APFS snapshot named `com.apple.os.update-…`,
mounted at `/`. It looks like update leftovers and is not: it is the running
operating system. The predecessor rewrote its volume identifier (`disk3s1s1` →
`disk3s1`) specifically to make it a valid delete target. Only SIP prevented
disaster.

Here, deleting it is **unrepresentable**. `SnapshotService.delete` accepts only a
`DeletableSnapshot`. Its initializer is private to its source file. The code does
not create values for the boot snapshot or the System volume. A runtime check and
seven tests provide more protection.

## Deliberate limitations

**Put Back only restores what Moppo trashed.** macOS exposes no API for the
original location of a trashed item. Finder stores this location privately. Items
from Finder have a disabled button and an explanatory tooltip.

**Cleanup History uses saved removal receipts.** The History view lists successful
removals, permanent removals, and failed attempts. Use the Trash view to put back
items whose saved identity still matches an item in the Trash.

**"Last opened" often means last *modified*.** `kMDItemLastUsedDate` returns null
for almost every item on macOS 26. This includes apps that people use daily. Used
alone, it made every row show "Never opened". The design treats this label as the
strongest safe-to-delete signal. The app now falls back through modification dates.
It uses `nil` only when the date is unknown.

**File duplicate scans use selected folders.** Moppo narrows candidates by size,
sampled SHA-256, and full SHA-256. It then compares the bytes before it reports a
match. The app skips hard links, hidden files, exclusions, and cloud-only files. It
does not compare documents that macOS saves as packages, such as Pages and Keynote
files. Moppo does not select any file automatically. Each set keeps
one copy, and selected copies move to the Trash.

APFS clones can share storage. Therefore, the available space for duplicate files
is an upper bound. The volume free-space value is the final result.

The Photos tab uses PhotoKit metadata and Vision feature prints. It keeps one copy
in each group and requires a review before deletion.

**Storage Explorer measures one folder level at a time.** Each row includes all
allocated bytes below that item. Hard links count once across sibling rows.
Moppo protects system locations, applications, managed media libraries, volumes,
exclusions, cloud-only files, and items with unreadable contents. Alias targets do
not count towards a row. A mounted volume is separate from its parent. Reviewed
unlocked items move to the Trash. Moppo refreshes each selected size and checks
each file identity before it shows the removal confirmation. Use List for exact
rows. Use Map to compare direct-child sizes visually.

**Automatic scanning is process-resident.** Moppo evaluates daily and weekly
schedules while it runs. This includes menu-bar-only login launches. No separate
launch daemon wakes the application after a full quit.

**Low-space notifications are process-resident too.** Moppo checks the live
volume total on launch, after its own storage operations, and every five minutes
while running. It warns on a transition below the threshold in General settings,
persists that state across launches, and limits repeated crossings to one per day.

**Complete uninstall requires an existing application bundle.** App Uninstaller
attributes related files from the selected app's verified identity.

**Finder only starts an uninstall review.** Select one application in Finder. Then
choose Services › Review Uninstall with Moppo. Moppo opens the existing
App Uninstaller review. The Finder action never removes files.

**Application Leftovers uses strict ownership rules.** The Scanner finds exact
bundle-identifier paths and roots from curated app rules. It ignores loose name
matches and shared containers. It keeps exclusions, keychains, ambiguous paths,
and files for installed applications protected. Safe to Remove includes each
verified application group. Moppo checks the owner and the file identity
again before removal.

**The app does not include "Storage Report…".** The design specified only its
label and did not specify its function.

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

## Writing

Use ADS-STE100 Simplified Technical English for documentation, interface text,
code comments, release notes, and support text. See [WRITING_STYLE.md](../WRITING_STYLE.md)
for the project rules and the Vale command.
