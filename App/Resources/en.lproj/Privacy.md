# Moppo privacy information

## Files and photos

Moppo scans files on your Mac to find cleanup items and measure storage.
Moppo reads your photo library when you use photo duplicate detection.
Moppo does not upload scanned files, file paths, photos, or photo library contents to Anguria.

## Local records

Moppo stores settings, storage measurements, and removal receipts on your Mac.
Removal receipts can contain original file paths and Trash locations.
Moppo uses these records for History and Put Back.
Tool command results include the command, target path, exit status, and limited error output.
Moppo keeps these local results even when Put Back receipts are off.

## Command line

The CLI saves scan reports locally for seven days.
The report store retains at most ten valid reports after a successful save.
Reports can contain file names, paths, sizes, scan explanations, and file identity checks.
Saved cleanup plans contain identifiers and expire after one day.
Plans can expire earlier with their source report. The plan store retains at most twenty valid plans.
Saved plan outcomes contain identifiers, status codes, and counts without file names or paths.
Outcome records expire after seven days.
The outcome store retains at most 100 records, including separate start and final records.
These stores use private folders under ~/Library/Application Support/Moppo.
Folders use mode 0700, and record files use mode 0600.
Expiry prevents use of records. Files can remain until a later store cleanup.
Invalid files and backups can remain beyond these limits.
Normal command output omits names, paths, and detailed explanations.
The --include-paths option discloses them to the caller.
Plan removal results omit names and paths.
Reduced output still contains categories, sizes, and storage classifications.
The supported CLI does not return file contents.
An AI agent can send command output to its provider.
Moppo does not control that provider or guarantee local model processing.
The provider's settings and policies control its retention and further disclosure.

## Application updates

Moppo checks for updates automatically.
You can turn off automatic checks in Settings > Updates.
When Moppo checks for updates, it contacts the update website over HTTPS.
The website receives your IP address and normal connection information.
Sparkle checks the installed Moppo version against the update feed.
Moppo disables Sparkle system profile reporting.
Moppo asks before it installs an update.

## External services

Photos and iCloud requests use Apple services and your existing Apple account.
Homebrew removal uses your installed Homebrew tools.
Homebrew can contact its package sources under its own settings.
When Homebrew needs your password, Moppo sends it directly to sudo and does not save it.
Worktree merge verification can use your installed GitHub CLI and its existing sign-in.
These requests send repository names and commit identifiers to GitHub.
They do not send local file paths or file contents.
Moppo does not store your GitHub credentials.

## Support

You can send a support request to hello@anguria.studio.
The report includes Moppo and macOS versions.
It does not include file paths, photos, removal logs, or stored measurements.
You can review the report before you send it.
Your email provider and Anguria receive the information that you choose to send.

## Contact

For privacy questions, contact hello@anguria.studio.
