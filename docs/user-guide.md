# Using Moppo

[Back to the project overview](../README.md).

- [File and Photos access](#file-and-photos-access)
- [Cleanup filters and actions](#cleanup-filters-and-actions)
- [Dashboard storage](#dashboard-storage)
- [Appearance and iCloud](#appearance-and-icloud)
- [Removal and Put Back](#removal-and-put-back)
- [Your data](#your-data)
- [Updates and support](#updates-and-support)

## File and Photos access

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

### Photo downloads and removal

Photo downloads are on by default.
Change this in **Settings > Advanced**.
Scans and the photo grid can download missing previews from iCloud.
Opening a photo preview can download its original.
The setting applies to new requests. Active requests can finish.

With iCloud Photos enabled, deletion affects the linked library and its other devices.
Deleted photos move to Recently Deleted, so storage recovery can take time.
Use Photos to review recovery and permanent deletion.

## Cleanup filters and actions

### Filter results

In Cleanup, use **All results** to filter items found by the scan.
Available types include worktrees, Node modules, Python environments, and archives and installers.
The menu shows types found in the current **All** or **Safe to Remove** view.
Choosing a specific type opens matching categories and AI tool groups.
Each type includes its item count and size.
**Select All** selects eligible items in the filtered view.
Changing filters keeps earlier selections. A notice identifies selected items outside the current view.
Removal includes all selected items.

### Worktrees and grouped folders

Detected worktrees appear separately from grouped folders. Moppo counts each byte once.
When a group contains worktrees, its **Other files** row shows the remaining size.
Select the parent folder to review removal of the worktrees and other files together.
Moppo blocks separate removal of the **Other files** row because its folder path also contains the worktrees.
Worktrees inside protected groups keep their protection.
**Safe to remove** means all checks passed during the latest scan or requested check.
The review dialog shows those completed results without starting another check.
Select **Check Again** to update the results.
Moppo checks again before removal because files and running processes can change.
If a check fails, Moppo keeps the worktree on disk.

### Xcode build folders

Temporary and release Xcode build folders show caches, logs, test results, and metadata separately.
**Safe to Remove** selects only verified caches from these folders.
Select recognized logs, test results, and metadata manually.
Select the parent folder to move all its reviewed contents to the Trash.
Moppo checks the whole folder again before removal.
Active, excluded, or unverified contents block whole-folder removal.

### Open items elsewhere

Use a Cleanup row's **More actions** menu to select **Show in Storage Explorer** or **Reveal in Finder**.
Right-click a row to use the same actions.
Application rows show **Reveal in Finder** and, where applicable, **Review Uninstall**.
Storage Explorer opens folder contents or highlights a file in its containing folder. Cleanup keeps its selections.

## Dashboard storage

Dashboard shows physical Used and Free space for the volume.
Category measurements use allocated file sizes and can include shared storage.
Files can also change during a scan.
These measurements can therefore total more than physical used space.
When this occurs, the capacity bar scales the categories to fit the used space.
The category list shows the measured values and states the difference.
Moppo keeps the physical Free value unchanged.
Storage comparisons retain both accounts.

Storage changes compares the latest measurement with an earlier measurement.
Since last cleanup starts at the measurement before the newest cleanup.
The comparison therefore shows what the cleanup removed after one measurement.
Last 7 days shows its real start until seven days of measurements exist.
The comparison menu appears only when its options start at different measurements.
With one option, the card shows its name as text.
Without a comparison, the card shows no option.
After a cleanup, the Cleanup totals keep the items that remain on the disk.
Choose **Continue** to return to these results without a new scan.

## Appearance and iCloud

### Appearance

Choose **System**, **Light**, or **Dark** in **Settings > General > Appearance**.
Changes apply immediately and remain saved across launches.
**System** follows macOS appearance changes and is the default.
**Reset Settings** restores **System**.

### iCloud storage

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

## Removal and Put Back

### Sizes and recovery

APFS clones can share storage. Reported cleanup sizes are upper bounds, not promises of recovered space.
Put Back needs a saved receipt and an item still in the Trash.
Moppo does not delete APFS snapshots.

### Confirmation

| Operation | Confirmation |
| --- | --- |
| Removal that supports recovery | **Confirm before every clean-up** controls the confirmation. |
| Homebrew uninstall | Moppo always requires review because Put Back cannot restore the package. |
| Empty Trash | Moppo always requires confirmation because this operation permanently erases items. |
| Permanent application deletion | Moppo always requires confirmation, including when routine cleanup confirmations are off. |
| Docker image removal | **Confirm before every clean-up** controls the review. |
| Tool command removal | Moppo requires confirmation for each command, including when routine confirmations are off. |

With **Confirm before every clean-up** off, removals that support recovery start without a Moppo confirmation.

### Tool commands

Put Back cannot restore items removed by a tool command.
Cleanup lists the Go module cache at `~/go/pkg/mod` under **Package Manager Caches**.
The row stays locked when Moppo cannot find Go at a supported installation path.
Go installations from Homebrew and the standard Go installer use supported paths.
Custom module cache locations are outside this removal rule.

Before removal, Moppo names the item and explains that Put Back cannot restore it.
Select **Remove** for each command.
After the last confirmation, removal starts for the reviewed selection.
Select **Cancel** to stop the review before removal starts.
During removal, select **Stop** to request cancellation.
The current file operation can finish before the command sequence stops.

Moppo checks the cache and tool identities again before it runs `go clean -modcache`.
The command receives the reviewed cache path through `GOMODCACHE`.
Projects can need another dependency download after removal.
Command results always enter Cleanup History, including when Put Back receipts are off.
The result includes command failures, error output, and measured cache size reduction when available.
Cache size reduction and verified disk space recovery are separate figures.
Failed rows stay visible with their removal reason.

### Simulator runtimes

Put Back cannot restore a deleted simulator runtime.
Cleanup lists each simulator runtime under **Xcode & iOS Dev**.
Each row shows the platform, version, build, and backing image size.
The size excludes mounted contents and shared caches.
Shared backing images enter the total once.

Moppo protects runtimes used by installed Xcode versions and active simulators.
Runtimes with shared images or incomplete checks also stay protected.
If a simulator uses the runtime, shut down the simulator before another scan.

Select each runtime that you want to remove.
Review the item name and permanent removal warning.
Select **Remove** for each runtime.
These confirmations remain required when routine confirmations are off.
Moppo checks the runtime identifier and Xcode use again before removal.
Only `xcrun simctl runtime delete <identifier>` removes the runtime.
Command results enter Cleanup History, including when Put Back receipts are off.
Failures and timeouts keep the row visible with a reason.
Moppo waits for the runtime inventory to update before it reports the result.
If macOS keeps the downloaded image, the result identifies that retained storage.
Cleanup shows **Cleanup incomplete** because the image still occupies disk space.
The image stays visible as **Simulator Runtime Download**, including after another scan.
Moppo keeps this row protected because macOS manages the image.
Older Xcode versions can leave simulator images on disk after removal.
Apple lists a fix in Xcode 27.2.
See the [release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes).
For an older selected Xcode version, the result explains this issue and identifies the version with the fix.
If Moppo cannot read the Xcode version, it shows conditional update guidance.
Xcode Components can download a runtime again when it remains available from Apple.
Moppo does not remove unavailable simulator devices through this command.

### Homebrew applications

Put Back cannot restore applications that Homebrew removes.
After Homebrew removes the package, Moppo moves its verified related data to the Trash, including profiles and settings.
Related data moved to the Trash supports Put Back.
Moppo does not use `--zap`.

If Homebrew needs administrator access, Moppo shows a password dialog.
The password helper sends your login password directly to `sudo`.
Moppo does not save the password or run Homebrew as root.
If removal fails, review the application to try again or copy the command to Terminal.

### File permissions and permanent application deletion

Moppo uses normal file permissions for cleanup, Put Back, and Empty Trash.
When macOS denies access, Moppo leaves those items and provides **Show in Finder**.
If macOS denies an application Trash move, App Uninstaller offers permanent deletion.

Permanent deletion cannot be undone. Put Back cannot restore the application.
The warning always requires confirmation.
Select **Cancel** to keep the application and stop the uninstall.
Select **Delete Permanently** to continue. macOS can request administrator approval.
Related files use the normal Trash operation after application removal succeeds.
If application removal fails, Moppo keeps its related files.

### Docker images

Docker removes selected images permanently, including their listed tags. Put Back cannot restore them.
Images used by containers remain locked. Image sizes include shared layers, so removal can recover less space.
The [development notes](README.md#deliberate-limitations) explain the current limits.

## Your data

- **Scans run locally.** Moppo stores scan caches, preferences, and cleanup history on your Mac.
- **Photo downloads use iCloud.** Turn them off in **Settings > Advanced** to use available local previews and originals.
- **Permissions stay under your control.** macOS manages file and photo access. Moppo reports content that it cannot read.
- **Background work needs Moppo.** Schedules and low-space checks also run in menu bar mode.

Read the [permissions notes](README.md#permissions) for local storage and development signing details.

## Updates and support

Use **Moppo > Check for Updates…** to check for a new version.
Moppo checks for updates automatically.
To stop automatic checks, turn them off in **Settings > Updates**.
Moppo asks before it installs an update.
Installation waits for active scans, removal, and Put Back.

Use **Help > Privacy Information** to read the included privacy information.
Use **Help > Report a Problem…** to prepare a support report.
Review the email before you send it to `hello@anguria.studio`.
The generated report excludes file paths, photos, and removal logs.

See [update setup](updates.md) for release configuration and pending distribution checks.
