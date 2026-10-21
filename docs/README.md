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

## Scan profiling

Build the release command before you measure scan duration:

```sh
swift build --package-path Core -c release
Core/.build/release/moppo-cli profile-scan cleanup --skip-docker
Core/.build/release/moppo-cli profile-scan dashboard
Core/.build/release/moppo-cli profile-scan concurrent --skip-docker
Core/.build/release/moppo-cli profile-scan cleanup --skip-docker --cancel-after 2
```

Each command compares two runs in the same process.
The first run can use existing macOS file caches.
The report does not claim a cold disk cache.
Use `--skip-docker` when the Docker category is off.
The cancellation report measures the time from the stop request until the operation returns.

The JSON output includes category times, progress gaps, disk capacity, and completed measurement counts.
Each run also reports process CPU time, disk activity, and peak active filesystem workers.
Moppo uses at most four shared filesystem workers across concurrent measurements.
Process CPU time adds user time and system time across all process threads.
These process totals do not identify CPU time for each category or include child processes.
CPU seconds can exceed elapsed seconds when several cores run concurrently.
Do not compare these totals directly with a monitor percentage that uses an unknown definition.
Disk activity reports process read and write bytes from macOS.
Cached filesystem reads can produce no disk activity.
Each run waits two seconds before reporting idle CPU time and remaining filesystem workers.
File visits include repeated walks of the same files.
Subtree totals count each file once per measurement.
Repeated roots and overlapping root pairs show possible repeated work.
They do not measure the exact number of repeated files.
Location times add concurrent measurements and can exceed elapsed time.
Cancelled reports include only completed measurements.
The output excludes account names, file names, and file paths.
The command does not save results or change preferences.

The command enables all categories unless `--skip-docker` is present.
It does not import application exclusions or file access settings.
Terminal access can differ from signed application access.
Record the Mac model, macOS version, access settings, and application build beside the report.
Check progress, navigation, and Stop Scan in the signed application separately.
Keep pending checks in the GitHub ticket.

Dashboard measurements wait for active Cleanup workers.
Cleanup cancels an active Dashboard measurement before it starts category work.
An interrupted removal measurement does not become a cleanup baseline during a later refresh.
The Dashboard keeps the reason for a skipped, failed, or interrupted cleanup measurement across launches.
Stop Scan also prevents waiting Dashboard measurements from starting.
App Uninstaller pauses new application size walks while Cleanup runs.
A size walk already in progress can finish before that pause.

At launch, Dashboard loads cached figures while Cleanup scans.
Its initial storage measurement waits until Cleanup workers finish.
This also applies when you stop the initial Cleanup scan.
During application ownership checks, Cleanup checks cancellation for each filesystem entry.
A cancelled ownership check throws before it can return an incomplete owner set.
Hidden & System Data checks cancellation before and after each archive discovery entry.
A filesystem read already in progress can still delay cancellation.

## Detailed scan test builds

Detailed logs can contain private file paths, project names, command arguments, and error messages.
Review the logs before you share them.

Use `scripts/package-dmg.sh --scan-logging` to enable detailed logging in a private test package.
Normal packages keep this logging off.
The diagnostic package records each Cleanup scan automatically.
Select **Help > Show Scan Logs** to open `~/Library/Logs/Moppo/Scans`.
Share the newest `scan-*.jsonl` file after the scan pauses, completes, or stops.
The file remains readable while the scan runs.
An interrupted application can leave an unfinished log with its last recorded operations.
Diagnostic builds also write `app-*.jsonl` files in the scan log folder.
These files record startup, permission changes, quit decisions, and termination with the process identifier and app path.
They remain available when no scan is running.
After a Codex database query fails, diagnostic builds record access checks for the database, its folder, and SQLite supporting files.
A bounded read-only SQLite probe records error codes and the operating system error without logging database contents.
Unverified Codex conversations remain protected.

Documents & Files shows the current folder, measured file count, and worktree review progress.
Measurement counts update at most twice each second. Phase changes appear immediately.
The percentage advances when categories finish.
Open symbolic links use their own file identities during worktree checks.
A link outside a worktree does not make that worktree's activity check incomplete.

Cloud directories use up to half the shared measurement workers while other Cleanup categories run.
When only Hidden & System Data remains, that scan can use all four workers.
The reservation returns when the scan finishes or stops.
The progress display names the remaining category or its current phase.
Hidden & System Data reports local iCloud measurements, hidden files, and archive discovery separately.
Cloud measurements run alongside Photos cache measurements, hidden folder measurements, and archive discovery.
The archive search skips all cloud roots and other folders that these steps measure.
The scan waits for both paths to finish. A stop request cancels both paths.
Cleanup reads local directory entries and size metadata in iCloud folders. It does not request downloads or read document contents.
Cleanup cloud measurements use direct directory reads and filesystem allocation attributes instead of Foundation property prefetch.
The shared walker retains cancellation checks, hard-link accounting, protected names, and volume boundaries.
An allocation read failure increases the unreadable count. Logical file size does not replace missing allocation data.
Storage Explorer retains Foundation metadata for its cloud residency checks.
The Dashboard iCloud card separately measures account storage.
The log reports active and queued cloud jobs beside the total worker counts.
This limit does not interrupt a blocked filesystem call or set a maximum scan duration.

The log records enabled categories, exclusions, access state, app versions, machine model, processor counts, memory, and disk capacity.
Category and operation records include paths, elapsed time, measurement counts, unreadable counts, and removal protection flags.
Directory records identify the last file that Moppo checked.
Directory records separate listing time, including metadata prefetch, from subsequent metadata reads.
Each directory record names its reader. Direct filesystem records also preserve the original directory path.
For direct filesystem reads, listing time excludes metadata reads.
For metadata reads above 50 milliseconds, the directory record includes the slowest path and duration.
Worktree records identify discovery, Git checks, process checks, and review results.
Final result records list worktree rows and their parent folders after category filters.
Omitted worktree records state the reason.
Category headers show worktree counts. Project badges expand their worktree rows.
Documents & Files shows project worktrees. AI Tools shows worktrees inside each tool's storage.
Small worktrees remain visible even when shared files contribute no additional bytes.

Worktree process checks reuse prefetched volume and inode values during measurement.
Incomplete process records include the process name, identifier, file descriptor, type, path, identity fields, and failure reason.
Each inventory logs up to 32 issue records. Each field contains up to 1024 characters.
The inventory summary counts omitted records and reports incomplete output or invalid text encoding.
Filesystems without these values retain the separate identity lookup. Logs count these fallback lookups.
The measurement loop reuses metadata keys and builds retained paths once per directory.
Command records include arguments, process identifiers, exit status, timeout, cancellation, and up to 4096 bytes of standard error.
Logs exclude file contents, conversation messages, raw standard output, passwords, tokens, and environment values.
Scan commands retain their existing behavior and time limits.

A one-second heartbeat records active operations, progress gaps, worker queues, CPU time, memory, thread count, and thermal state.
Directory detail stops after 128 MiB per scan. The log records this limit.
Heartbeats, commands, measurement summaries, and category results continue.
Logging adds filesystem and CPU work. Compare test runs with the same settings.
Logs remain local. The support report does not attach them automatically.

The command-line profiler can create the same detailed logs:

```sh
Core/.build/release/moppo-cli profile-scan cleanup --skip-docker --log-directory /tmp/moppo-scan-logs
```

## Layout

```
Core/                         Swift package
  Sources/MoppoCore/          Scanning engine and cleanup services
    Measure/                 AllocatedSizeMeasurer, MeasurementReader, ByteFormatting
    System/                  Disk information, snapshots, process execution, scan diagnostics
    Scan/                    Category scanners, Codex session review, and scan coordination
    Act/                     Cleanup, Docker images, app uninstall, sound libraries, Trash, history
    Duplicates/              File duplicate detection and removal
    StorageExplorer/         Folder measurement and reviewed removal
  Sources/moppo-cli/         Command-line tools
  Tests/MoppoCoreTests/      Engine tests
App/                          SwiftUI app
  Cleanup/                   Cleanup model, services, and scheduler
  Dashboard/                 Dashboard model and measurement services
  DesignSystem/              Shared controls, colors, text styles, and application icons
    Mascot/                  Moppo motion, beams, and acts
      Beams/                 Scan beams, deletion rays, and floor light
      Acts/                  One file for each act, and the act protocol
  Duplicates/                File duplicate model
  MainWindow/                Main views, sidebar, and sheets
  Photos/                    Photo model, PhotoKit access, and thumbnails
  Preferences/               Four panes and the settings store
  Recovery/                  History, Trash, and Put Back model
  StorageExplorer/           Storage Explorer model and services
  Uninstaller/               App Uninstaller model, scan services, and permanent removal
  Updates/                   Sparkle controller, preferences, and installation guard
  Support/                   Privacy information, support reports, and scan log access
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
| `OperationCoordinator` | Shared operation guards and operation identity for scans, reviews, removal, recovery, and update installation. |
| `UpdateController` | Sparkle checks, update preferences, and deferred installation. |

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
Command-Q cancels Cleanup, duplicate, and Storage Explorer scans before the app quits.
The app waits for scan workers and diagnostic log writes. It blocks new operations while quitting.
Active file changes retain their existing quit guard.
The Quit Apps notice excludes Moppo, including other builds with the same application identifier.
Moppo's active caches retain their in-use status and remain outside Safe to Remove.
Scan and regroup identifiers reject results from cancelled or replaced tasks.
Only the matching operation can release the shared guard.
All feature scans, removal reviews, removal tasks, and recovery operations use the same coordinator.
Presentation state does not determine whether an operation is active.

**Confirm before every clean-up** controls the Cleanup review, including permanent Docker image removal.
This includes Cleanup, application data, sound libraries, Storage Explorer, duplicate files, and duplicate photos.
With the setting off, ordinary batch uninstalls start after planning without a review step.
Homebrew batches always require review because their packages cannot move to the Trash.
Docker images appear once per image identifier, with their tags grouped together.
When this Mac has Docker Desktop but it is unavailable, Cleanup shows its setup card in All results.
When Docker Desktop is absent, Cleanup hides the empty Docker card.
Docker removes selected images in the scanned context without forced removal.
Before removal, Moppo checks the image identifier, tags, and container use again.
After removal, Moppo updates the Docker category.
Docker image removal does not use the Trash or support Put Back.
Image sizes include shared layers, so removal can recover less space.
Container, volume, and build cache cleanup still uses manual commands.
Empty Trash always requires confirmation because it permanently erases items.
Photos can show its own system confirmation after Moppo starts the deletion request.
Confirmation captures the selection and preferences before the user makes a decision.
Cancellation keeps the selection and releases the operation guard without removal.

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
Successful removal requests a measurement immediately after cleanup.
Removal during measurement requests one additional measurement for the cleanup baseline.
Failed removal attempts do not create cleanup baselines.
Automatic cleanup measurements require Full Disk Access.
A later manual refresh updates current storage without creating a cleanup baseline.
The Dashboard explains missing cleanup baselines and shows the date of an earlier available baseline.
The next successful cleanup measurement replaces that baseline.
Moving files to Trash does not necessarily recover disk space.
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

Scans and Put Back cannot run together under the shared operation guard.
Concurrent restoration requires path conflict checks and scan result invalidation rules before this guard can change.
Blocked app selection, duplicate file selection, and Put Back attempts show a toast below the page header.
The toast names the active operation and explains when the action can continue.
Repeated attempts reuse the toast for eight seconds without changing selection or queuing the action.
The toast announces its message for VoiceOver.
Its close button dismisses it with a short fade.
Reduce Motion disables the fade.
Page changes also dismiss the toast.

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

Xcode & iOS Dev also finds verified build caches in the current user's temporary folders and project release folders.
Temporary discovery checks two folder levels, with a limit of 2,048 entries.
Release discovery checks `dist/releases`, `build/releases`, and `releases`, with a limit of 200 folders per location.
Moppo requires Xcode metadata and folders owned by the current user.
Moppo offers only recognized cache folders for removal.
Source checkouts, test reports, archives, and unknown files remain in place.
Open files or incomplete process checks protect the cache.
Removal checks the folder identities, metadata, and open files again.
Documents & Files excludes these cache sizes from project totals.
Other project files, including release archives and disk images, remain in Documents & Files.

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

## AI storage

AI Tools shows default Codex, Claude, Cursor, and Grok Bot data paths.
Tool rows use application icons. Child rows keep their file or folder icons.
Bundled vendor icons identify tools when their desktop applications are absent.
It also includes the existing Ollama, Hugging Face, and LM Studio model rows.
Installed application bundles remain under Applications.
AI Tools owns installed desktop support folders.
If the application is absent, Application Leftovers owns its verified desktop data.
Each folder appears in one category.
App Uninstaller builds its own complete review when you select an application.

Codex archived and inactive sessions require an explicit deletion review.
Codex permanently deletes their history, child sessions, and related session files.
Session deletion requires confirmation even when you disable general cleanup confirmation.
Active writers, changed history, and changed child sessions stop deletion.
Other session history, attachments, memories, settings, unknown caches, and downloaded runtimes remain protected.
Claude Code purge also deletes memories, so Moppo does not use it for session cleanup.
Cursor CLI conversations remain protected because Moppo cannot verify inactive sessions.
Their allocated sizes appear in category totals. These totals do not promise that removal will free all listed space.
Only verified desktop caches and worktrees with complete checks enter Safe to Remove.
A running application removes its caches from Safe to Remove.
Model removal keeps the existing shared-file rules and requires review.

Claude VM rows separate the system disk, compressed runtime download, and session disk.
The scanner measures allocated storage. It does not mount disks or read conversations.
The system disk can contain Linux, installed tools, and task files.
A folder name or file age does not make these files disposable.

Read the [AI storage sources and limits](ai-storage.md) before you add storage rules.
Read the [Codex session recovery research](codex-session-recovery.md) before you add session recovery.

## Scanner rows and Git worktrees

Cleanup has two tabs: All and Safe to Remove.
All shows all scan results, including protected items and items that need review.
The Dashboard All card shows the total scanned size and opens All.
This total includes protected storage and does not represent removable space.
Safe to Remove is the initial tab.

The Scanner groups cleanup items. It does not show a complete folder tree.
When a group contains children that support unlocking, its parent shows a clickable amber lock.
The parent review unlocks eligible children without selecting them.
The parent and child checkboxes remain unchecked after unlocking.
The parent checkbox selects child items. It does not select the parent folder.
Deselecting a child keeps it unlocked.
Parent and child checkboxes use the same regular size.
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

Documents & Files collects project, worktree, and ignored file sizes in one traversal.
Worktree metadata checks run two at a time within each project.
One process inventory supplies file identities for that project scan.
The measurement traversal checks those identities, including hard links and open directories.
Incomplete process information keeps the activity check unknown.
Worktree dialogs and cleanup use fresh checks.

Each worktree has one status pill and an information button in the name column.
The branch icon and branch name identify the worktree.
Select the information button or status pill to open the review dialog.
If the worktree row has focus, press Space or double-click the row to open the dialog.
The dialog separates changed files, local ignored files, unverified files, and regenerable files.
Select **Done**, the close button, or Escape to close the dialog.

The status pill reports one result, in this order:

- **In use:** Git locks or an open process were found.
- **Uncommitted changes:** staged changes, unstaged changes, or untracked files.
- **Unpushed commits:** commits absent from the compared remote-tracking branches.
- **Has local files:** ignored files can contain local settings or user data.
- **`Couldn't verify`:** a check failed or could not finish.
- **Safe to remove:** all checks passed. Ignored files have removal evidence, or Moppo confirmed the worktree merge.

The dialog verdict uses the same title and color as the row.
The sentence reports every known problem.
Checks show merges, local changes, unpushed commits, ignored files, Git locks, and process use.
Unpushed commits includes the last fetch date. There is no separate push comparison row.
The date gives context. Its age does not change the status.
An incomplete check shows **`Couldn't check`**. Its question mark icon shows the reason in a tooltip.

Moppo first checks whether a saved remote default branch contains the worktree commits.
The remote HEAD reference identifies the default branch.
The upstream selects the remote. Without an upstream, one default branch must be available.
Confirmed merges include all readable ignored files in removal, including `.env` and temporary files.
The Merge check shows the target branch and available pull request number.
When Moppo cannot confirm a merge, the check shows **Not confirmed**.
The question mark tooltip gives the reason.
The dialog marks included local ignored files as **Included**.
Protected files, incomplete checks, uncommitted changes, open processes, and Git locks still prevent Safe to Remove.
Merge checks require complete Git history.
When saved history cannot confirm a merge, Moppo checks GitHub through the installed GitHub CLI and its existing sign-in.
This check supports `github.com` repositories with a saved remote default branch.
The merged pull request must match the exact worktree commit and the current GitHub default branch.
The merge commit must exist in saved default-branch history.
Moppo checks local file status, the worktree commit, the remote URL, and the default branch again before it accepts the result.
This also supports squash merges, whose original commit identities differ.
Missing access, incomplete responses, and failed requests leave the merge unverified.
If GitHub cannot find the exact commit, the tooltip explains that the commit may exist only on this Mac.

GitHub requests group up to 20 commits from one repository.
At most two repositories use the network at once.
Each request has a five-second timeout.
Each repository lookup has a ten-second budget, including its queue wait.
Process shutdown can add a short delay.
Successful results stay in memory until Moppo quits or the cache exceeds 2,048 entries.
Each cache entry identifies the repository and exact commit.
Failed results expire after 30 seconds. Connection and access failures also pause repeated requests for 30 seconds.
Cached results still require the local Git checks.
Cleanup repeats these checks before removal.

Otherwise, branches use their upstream branch for comparison. Detached worktrees use all
local remote-tracking branches. Branches without an upstream have unknown push
status. Incomplete Git history also gives unknown push status.

GitHub verification sends repository names and commit identifiers to GitHub.
It does not send local file paths or file contents.
Moppo does not fetch remote Git data. Saved remote data can be out of date.
Moppo checks installed Git before use. It does not start a Git installation.
The review measures ignored files separately. Without a confirmed merge, unknown ignored content remains under review.
Ignored files inside verified caches inherit the cache classification.
The same rule applies to dependency stores with reinstall evidence.
Moppo uses the existing cache tags, source checks, and lockfile rules.
Additional checks recognize empty ignored folders, Finder metadata, and Xcode scheme ordering and window state.
Xcode user folders remain under review if they contain custom schemes, breakpoints, or unknown files.
Generated Xcode projects require a matching tracked specification and an installed XcodeGen executable.
Moppo copies tracked files into a private temporary folder and generates a comparison project there.
The original project files must match the generated files exactly.
Empty folders, recognized Xcode window state, and scheme ordering can appear as additional content.
Generation commands, external paths, included specifications, and symbolic links prevent verification.
The check accepts one root specification: `project.yml`, `project.yaml`, or `project.json`.
It limits the copy to 2,048 files and 32 MB, with a 4 MB limit for each file.
Each tool command and the copy loop have a two-second limit.
Missing tools, changed files, unsupported specifications, and exceeded limits keep the project under review.
Next.js output needs a Next.js dependency, generated manifests, and server output.
Generated Next.js type declarations must contain only recognized generated lines.
TypeScript build information needs a nearby configuration file and a recognized data structure.
Generated-file checks use bounded reads. They do not execute project code.
Without a confirmed merge, environment files and generated project bundles with dependency lock files remain under review.
Classification stops at the worktree root and does not cross symbolic links.
Parent classifications remain cached only during that review.
Protected, unreadable, and cloud-only content cannot receive a regenerable classification.
The scan log records each ignored file classification and the final group counts.
The open-file check covers the current user's visible processes. It cannot identify every inactive tool session.
Documents and AI Tools share process information across each worktree group.
They measure each containing folder once and reuse its worktree and ignored-file totals.
Revoked handles without file identities do not make the process inventory incomplete.
Missing identities for regular files and directories still prevent a safe verdict.
Close the owning tool session before removal.

Only worktrees with complete checks can enter Safe to Remove or the initial selection.
Other worktrees remain selectable. **Select anyway** selects removal and closes the dialog.
The cleanup confirmation reports selected worktrees that need review, including with confirmation disabled.
All worktree removals move to the Trash.
If Git is available, Git moves the worktree and updates its registration.
Git can refuse locked worktrees or unsupported moves. Moppo does not force these moves.
If Git is unavailable, Moppo uses the normal Trash action.
Put Back restores the worktree and updates Git registration when Git is available.
Put Back requires a saved receipt. Emptying the Trash ends recovery through Moppo.

## The boot snapshot

macOS boots from a sealed, read-only APFS snapshot named `com.apple.os.update-…`,
mounted at `/`. It looks like update leftovers and is not: it is the running
operating system. The predecessor rewrote its volume identifier (`disk3s1s1` →
`disk3s1`) specifically to make it a valid delete target. Only SIP prevented
disaster.

`SnapshotService` lists snapshots as information in the Dashboard.
Moppo does not delete snapshots.
The boot snapshot remains identified as part of macOS.

## Deliberate limitations

**File operations use normal permissions.** Moppo does not request administrator access for cleanup, Put Back, or Empty Trash.
When macOS denies access, Moppo reports the affected items and provides **Show in Finder**.
Other selected items can still complete.
If the application bundle cannot move, Moppo keeps its related data.

**Permanent application deletion requires confirmation.** A direct Trash move must fail with an access error before Moppo offers permanent deletion.
The warning provides **Cancel** and **Delete Permanently**. This confirmation applies when routine cleanup confirmations are off.
After confirmation, macOS can request administrator approval. Moppo does not receive the password.
The command checks the reviewed application identity after administrator approval.
The application path is a command argument. It is never executable shell text.
Moppo records successful permanent removal as deleted. Put Back cannot restore the application.
If you cancel or application removal fails, related files stay in place.
Cancellation also stops the remaining applications in a batch.
Related file removal, cleanup, Homebrew cleanup, Put Back, and Empty Trash use normal file permissions.

**Homebrew manages package removal.** Homebrew applications keep their review and password flow in Moppo.
The signed password helper sends the password directly to `sudo` when Homebrew requests it.
Related file cleanup uses normal permissions after Homebrew removes the package.

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
each file identity before removal or optional confirmation. Use List for exact
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

App Uninstaller and Cleanup find applications in nested folders under `/Applications` and `~/Applications`.
Discovery stops at each application bundle. Embedded helpers stay part of their parent application.
Visible lists skip hidden folders, symbolic links, and excluded paths.
Ownership checks still include excluded applications to protect their related files.
Cancellation stops discovery before the app publishes results.

Application details keep completed results in memory for three minutes, with a limit of 32 applications.
Reopening details checks the application identity and bundle metadata before reusing a result.
Refresh Apps clears these results.
Removal and Put Back also clear them.
Changed exclusions or Full Disk Access require a new calculation.
Each removal still checks the reviewed files before it moves them.

**Finder only starts an uninstall review.** Select one application in Finder. Then
choose Services › Review Uninstall with Moppo. Moppo opens the existing
App Uninstaller review. The Finder action never removes files.

**Application Leftovers uses strict ownership rules.** The Scanner finds exact
bundle-identifier paths and roots from curated app rules. It ignores loose name
matches and shared containers. It keeps exclusions, keychains, ambiguous paths,
and files for installed applications protected. All includes each verified application group.
Moppo checks the owner and the file identity again before removal.

**Downloaded Apple sounds use the existing application flows.** An installed
application has a separate sound removal review. Complete uninstall keeps this
sound content. Without an installed owner, App Leftovers shows a GarageBand group.
Logic Pro and MainStage protect shared content while installed.

Moppo requires Apple asset package receipts for the standard `/Library` locations.
It keeps folders that contain unknown files, symbolic links, or protected content.
Relocated libraries and sound content inside newer application bundles are outside
this separate review. Projects that use removed sounds may need another download.
Sound removal moves content to the Trash.
If **Confirm before every clean-up** is on, Moppo shows a sound removal confirmation.
Put Back requires a saved receipt.

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

## Writing

Use ADS-STE100 Simplified Technical English for documentation, interface text,
code comments, release notes, and support text. See [WRITING_STYLE.md](../WRITING_STYLE.md)
for the project rules and the Vale command.

## Updates and support

[Update setup](updates.md) covers the update feed, signing key, and publishing commands.
[Release packages](distribution.md) covers Developer ID signing, notarization, and DMG preparation.
[Changelog](../CHANGELOG.md) records changes for each public release.
Sparkle 2.10.0 provides the standard update interface.
Automatic checks are optional and initially disabled.
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
