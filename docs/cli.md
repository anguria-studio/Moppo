# Moppo command line

[Back to the project overview](../README.md).

The supported CLI uses the name `moppo`.
It scans and inspects cleanup candidates without opening the app.
It can save cleanup proposals for later review.
It can remove a saved plan at one exact revision, from Terminal or through optional app review.
The development tool named `moppo-cli` has separate diagnostic commands.
The [agent workflow](agent-workflow.md) provides skill installation and user confirmation guidance.

## Install

This CLI ships with the next Moppo release.
Earlier releases do not include it.

Copy Moppo.app from the release disk image to Applications.
To add the `moppo` command, open Moppo and go to **Settings > Advanced**.
In **Command line and agents**, select **Install** for the command-line tool.
This creates the link in `~/.local/bin` that the next steps describe.

To install the command manually, the app does not need to run.
Check the included executable:

```sh
/Applications/Moppo.app/Contents/Helpers/moppo --version
```

To add the command to a user-owned command folder:

```sh
mkdir -p "$HOME/.local/bin"
ln -s /Applications/Moppo.app/Contents/Helpers/moppo "$HOME/.local/bin/moppo"
```

If that name already exists, inspect it before replacing it.
Add this line to your shell configuration if the folder is absent from PATH:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

The link uses the executable inside the signed app.
App updates also update that executable.
Keep the executable inside the app so its package resources remain available.
A release needs no Swift installation or source build.

## Scan and inspect

```sh
moppo --help
moppo scan --json
moppo scan --category xcode --json
```

Each scan saves a local report and returns a scan identifier and revision.
Copy that identifier into the following commands.
The identifiers below are placeholders.

```sh
moppo items --scan scan_ID --limit 100 --json
moppo items --scan scan_ID --category xcode --offset 100 --limit 100 --json
moppo explain --scan scan_ID --item item_ID --json
```

Item identifiers remain stable within one saved scan.
A new scan creates new identifiers.
An item identifier is not a path or permission to remove data.
Saved reports cannot serve as removal authorization.

Item pages contain up to 100 entries by default.
The maximum page size is 500.
When more items remain, `next_offset` gives the next page offset.
On the last page, `next_offset` is `null`.
An offset beyond the result count returns an empty page.
Filters apply before pagination.
The `explain` command returns one matching item.

## Save and review a plan

A plan selects existing items from one exact scan revision.
It does not authorize removal or change the app's current selection.
The identifiers and hashes below are placeholders.

```sh
moppo plan create --scan scan_ID --revision SCAN_HASH --items item_ID,item_OTHER --json
moppo plan inspect --plan plan_ID --json
moppo plan invalidate --plan plan_ID --revision PLAN_HASH --json
```

Use the scan response's `revision` value for creation.
Use the plan response's `revision` value for invalidation.
The `--items` list accepts one to 500 distinct item identifiers.
The CLI rejects paths, commands, protection overrides, and unknown options.
A failed item check rejects the complete proposal.

Creation and inspection scan the selected categories again.
They apply current preferences and check file identities, protection, eligibility, and target membership.
They also check selected trees for protected patterns and unreadable items.
The checks do not remove files or run removal commands.

Plans currently support ordinary file targets, file groups, local model groups, and available fixed tool targets.
Application removal reviews, virtual targets such as Docker images, and symbolic link targets return `unsupported_target`.
Protected rows and protected children remain excluded, regardless of earlier app overrides.
Children of a model group require their parent selection.
Selecting both a parent and its child fails validation.

A valid response has `status: review_required`.
It includes the plan identifier, plan revision, source scan revision, expiry, and selected items.
Names and paths still require `--include-paths`.
Plan records contain identifiers and revisions, without removal paths or commands.

The optional `scan_allocated_bytes` value counts each selected file identity once.
It includes exclusive model files from the current inventory.
It excludes shared blobs that the inventory keeps for other models.
Moppo omits this aggregate when multiple targets include directory measurements that can overlap or share files.
Individual row sizes remain available.
The `recoverable_space: unverified` value is separate from scan sizes.
No plan claims verified recoverable space.

Sizes can change between the scan and the plan review.
Directory contents can also change during ordinary cache use.
These changes do not reject a plan. The review shows the sizes from the fresh scan.
A changed regular file, identity, kind, protection, or removal command rejects the plan.

Plans expire after one day or when their source scan expires, whichever occurs first.
The plan store retains at most twenty valid plans.
Scan pruning keeps the source scans of unexpired plans.
Expiry of the source scan prevents plan review.
Invalidation removes only the saved proposal.
Invalidation does not change cleanup targets or the app's selection.

| Error code | Required action |
| --- | --- |
| `exclusions_changed` | Run a new scan after any exclusion change |
| `category_disabled` | Review category settings before a new scan |
| `protected_item` or `excluded_item` | Keep the protected item outside the proposal |
| `missing_item` | Run a new scan because the current inventory lacks an item |
| `changed_target` | Run a new scan because identity, file metadata, or group membership changed |
| `incomplete_scan` | Resolve access or measurement limits before a new scan |
| `scan_changed` or `plan_changed` | Discard the earlier review and inspect current data |
| `evidence_unavailable` | Run a new scan with this CLI version |
| `expired` or `record_unavailable` | Create a new plan from an available scan |

The revision is a SHA-256 digest of the canonical stored record.
It detects changes but is not a signature, consent token, or security boundary against another process under the same account.
Storage never replaces an existing identifier.
A review holds an immutable proposal and checks its revision again after the fresh scan.
Deletion, expiry, or replacement invalidates that review.
Concurrent clients cannot silently replace its selection through the store API.

The shared `MoppoPlans` module provides `CleanupPlanService` and `PlanReview` for terminal and app clients.
Removal clients must call `revalidate` after confirmation, immediately before removal.
They must use the fresh entries and expected identities from the returned review.
Before each item, they call `recheck` with that review. This check does not scan again.
They must retain the owning service's identity, ownership, eligibility, and shared-storage checks.
They must also retain service checks between targets because files can change after validation.
A directory identity does not establish an immutable snapshot of all descendant contents.
App clients must keep the current selection until the user accepts the proposal.
Terminal and app removal use the same execution lock and saved outcomes.

## Removal

Inspect a saved proposal, then remove that exact revision:

```sh
moppo plan inspect --plan plan_ID --json
moppo plan remove --plan plan_ID --revision PLAN_HASH --json
```

The command does not open Moppo.
It removes only the plan revision that you supply.
A different revision returns `plan_changed` before any check or removal.
Protected items remain excluded. Specialized app targets retain their existing review flows.

Ordinary items move to Trash without a prompt.
Put Back in Cleanup History can restore them while they remain in Trash.
An agent can run this command after the user approves the plan.

Permanent removals have no Put Back recovery.
The plan output lists them in `permanent_items`.
`permanent_commands` gives the tool that removes each permanent item, such as `brew` or `go`.
The complete command contains paths, so it appears only with `--include-paths`.
Removal responses do not include these fields.
If a plan contains a permanent item, macOS asks the Mac user to authenticate with Touch ID, a paired watch, or the login password.
A shell process cannot answer this system dialog.
A cancelled or failed authentication cancels the complete plan before removal and returns exit 130.
Without a local login session, the command returns exit 79 and `authentication_unavailable`.
No `--yes`, force, or other bypass option exists.

Before removal, Moppo checks the complete plan again with a fresh scan.
Before each item, it checks the plan, the settings, and the target identities again.
The shared lock prevents another updated Moppo app or terminal client from changing cleanup targets concurrently.
Regular app cleanup, uninstall, Trash operations, duplicate removal, and Storage Explorer removal use the same lock.
External tools and older Moppo builds do not participate in this lock.
A busy lock returns exit 75 and `execution_busy`.

Before removal starts, an interrupt cancels without changing targets.
During removal, Ctrl-C or SIGTERM lets the current item finish, then cancels the remaining items.
For other commands, a second interrupt stops the command at once. Those commands do not change cleanup targets.
The command waits for that item so it can save receipts and outcomes.
A forced process exit can leave a `started` record with an unknown result.
Do not retry automatically after interruption or an unknown result.

A completed removal returns exit 0.
A final result with skipped, failed, partial, or unknown items returns exit 3.
Cancellation or rejected authentication before any item starts returns exit 130.
Use `plan outcomes` to inspect retained results, including after plan expiry or invalidation.
Cleanup History records attempted removals and validation skips.
Put Back requires a saved receipt and a matching item that remains in Trash.

## Optional app review

```sh
moppo plan review --plan plan_ID --app --json
moppo plan outcomes --plan plan_ID --json
```

The explicit `--app` option opens Moppo with the saved plan identifier and revision.
The URL contains no file paths or commands.
The CLI returns `app_requested` after launch accepts the request.
This status does not indicate consent, successful review, or removal.
If another Moppo copy runs, the CLI returns `app_copy_running`.
Quit that copy before requesting app review again.
The app checks the saved revision and scans current targets before showing them.
If Moppo shows the welcome guide, the request waits until that guide finishes.

The proposal shows names, paths, sizes, reasons, and recovery limits.
Existing Cleanup selection remains separate.
Select **Review Removal…** to accept the proposal for confirmation.
Confirm the listed items before removal starts.
The app requires confirmation even when settings disable normal cleanup confirmation.
Each permanent tool removal requires an additional warning with the exact command.
Protected targets remain excluded.

Another request cannot replace an open review.
Active app operations block a new review.
After the operation finishes, request the review again.
Git worktrees, Codex history, sound libraries, and Xcode build cache reviews require their existing specialized app controls.
Application and virtual targets retain the limits listed above.

The shared executor checks the plan again after confirmation and before each item.
It uses the existing removal service, file identities, tool checks, and Cleanup History receipts.
Ordinary targets move to the Trash when supported.
The executor never falls back to permanent deletion for an ordinary target.
Concurrent saved-plan execution fails with `execution_busy`.
A retained execution record prevents another attempt with the same plan revision.

Cancel before confirmation to keep all targets unchanged.
During removal, **Stop After Current Item** lets the current item finish before stopping remaining items.
Cancellation does not restore completed removals.
Use available Put Back actions in Cleanup History for recovery.

Use `plan outcomes` after app review to retrieve saved results.
The command works after plan invalidation or expiry.
Each attempt has a `run_id`, status, and item outcomes.
Item results include `trashed`, `deleted`, `partial`, `failed`, `skipped`, `cancelled`, or `unknown`.
Counts distinguish Trash moves from permanent removals.
`private_bytes` records measured private allocation. It does not promise free space after a Trash move.

A `started` record without a final record means the outcome is unknown.
An `unknown` item can have file changes that Moppo could not report.
Check Cleanup History and the affected files before another attempt.
`no_outcome` means no retained record exists. It does not prove that no removal occurred.
Records can expire or leave the retention limit.

## Exclude an item

Stop Moppo from offering an item again:

```sh
moppo exclude --scan scan_ID --item item_ID --json
```

This command saves the same rules as **Never Offer This Again** in the app.
It scans the item's category again to find the current identities.
Local model rules identify manifests or repository folders, so shared blobs stay protected.
Docker rules include the image context.

| Status | Meaning |
| --- | --- |
| `excluded` | Moppo saved one or more rules. `added_rules` gives the number |
| `already_excluded` | Saved rules already cover the item |

Protected items return `exclusion_unsupported` because cleanup already skips them.
Later scans skip the item. A running Moppo app reloads the rules.
The current app results keep the row until the next scan.
Plans saved before the change fail with `exclusions_changed`.
To remove a rule, open Moppo and go to **Settings > Exclusions**. Removal takes effect after another scan.

## Settings and access

The CLI reads enabled categories and exclusions from the Moppo preferences domain.
Exclusions can identify folders, files, tool items such as Docker images, and filename patterns.
Only `moppo exclude` changes these settings. It adds exclusions and never removes them.
Without saved settings, the CLI enables all categories and applies built-in exclusions.
The `--category` option restricts a scan to an enabled category.
It cannot enable a disabled category.
Invalid settings stop the CLI scan.

Category identifiers are:

```text
documentsAndFiles
applications
applicationLeftovers
aiTools
hiddenSystemData
systemCaches
packageManagers
xcode
docker
```

Terminal access can differ from the signed app's access.
The CLI cannot inherit the app's Full Disk Access grant.
If macOS denies access, review the terminal's permissions in System Settings.
Then run a new scan.
Do not run the CLI with sudo.
The CLI cannot use administrator access to bypass macOS privacy controls.

## Output contract

JSON output uses `schema_version: 1` and snake_case field names.
Dates use UTC ISO 8601 strings.
Progress goes to standard error.
Standard output contains one JSON document when `--json` is present.
JSON errors include an error code and a message.
Text errors go to standard error.

A scan response contains category totals and an item count.
It does not include an unbounded item list.
Use `items` to retrieve entries.
Responses include the scan identifier, revision, timestamps, expiry, and scan status.

| Field | Meaning |
| --- | --- |
| `allocated_bytes` | Bytes reported by the scan engine |
| `display_bytes` | Bytes shown for this row, using the app's accounting |
| `parent_id` | Parent row, when present |
| `measurement_status` | Category measurement status applied conservatively to its items |
| `eligibility` | Required review or protection at scan time |
| `safe_to_remove` | The engine's safe classification, subject to locks and parent review |
| `reason` | General explanation that omits file names and paths |
| `protection` | Engine protection code, when present |
| `recovery` | Trash, permanent removal, or an external tool |
| `project_activity` | Project state for a dependency folder, when present |

Eligibility values are `protected`, `parent_review`, `app_review`, and `review_required`.
None authorizes removal.
`app_review` items need a review screen in Moppo. Examples are applications, Xcode build caches, Git worktrees, sound libraries, and Codex sessions.
A saved plan cannot include these items, and plan creation returns `unsupported_target`.
Recovery values are `trash_if_supported`, `permanent`, and `external_tool`.

`project_activity` contains `last_activity_at`, `git_ignore`, and `hold`.
`git_ignore` values are `ignored`, `not_ignored`, `unknown`, and `outside_repository`.
`hold` values are `recent_activity`, `not_ignored_by_git`, and `unknown`.
An item with a `hold` value is not safe to remove.
Removal commands must check Trash availability.

Parent and child sizes can overlap.
Do not add item sizes to calculate total storage.
Allocated and displayed sizes do not establish recoverable space.

Status values are `complete`, `partial`, `unavailable`, and `notInstalled`.
Complete means that the engine reported no unreadable items within the enabled categories and current scan rules.
It does not mean that Moppo scanned every file on the Mac.
Partial sizes contain measured bytes and can understate usage.
Unavailable zero values do not mean empty storage.
Missing applications receive `notInstalled` status.

| Exit code | Result |
| --- | --- |
| 0 | Command completed |
| 2 | Scan completed with partial or unavailable categories |
| 3 | Removal finished with incomplete item results |
| 64 | Invalid command or arguments |
| 65 | Invalid record, unsupported schema, or plan validation failure |
| 66 | Missing, expired, inaccessible, or unmatched record or item |
| 69 | App unavailable or launch failed |
| 70 | Scan or removal operation failed |
| 74 | Record storage or output failed |
| 75 | Another client holds the removal lock |
| 77 | Every scanned category is unavailable |
| 78 | Invalid scan settings |
| 79 | Permanent removal requires authentication by the Mac user, and authentication is unavailable |
| 130 | Operation cancelled |

Exit codes 2 and 77 still return a saved scan identifier.
Inspection commands return 0 when retrieval succeeds, even when the saved scan is partial.
Check the response status before using its measurements.
Cancellation of scans or plan inspection does not remove cleanup targets.
Cancellation before report storage does not save a partial report.

A scan checks that it can save its report before it starts.
If the report folder blocks writes, the scan returns exit 74 and `storage_failure` at once.
Agent sandboxes often cause this. The [agent guide](agent-workflow.md#agent-sandboxes) explains the client setting.

## Privacy and retention

Reports contain file names, paths, and scan explanations.
They remain under `~/Library/Application Support/Moppo/cli-scans`.
The report folder uses mode 0700.
Report files use mode 0600.
The store rejects symbolic links at report files and the report folder.
It also rejects shared file links and unexpected permissions.
Each report can contain at most 64 MiB.
Reports also store private file identity and policy evidence for plan validation.
Command output never includes that evidence.
Plans remain under `~/Library/Application Support/Moppo/cleanup-plans`.
The same directory and file access rules apply to plans.
Each plan can contain at most 64 KiB.
Outcome records remain under `~/Library/Application Support/Moppo/plan-outcomes`.
They contain identifiers, status codes, and counts without names or paths.
The same directory and file access rules apply.
Each record can contain at most 512 KiB.
Records expire after seven days. The store retains at most 100 records.
Start records and final records count separately toward this limit.
The execution lock uses `~/Library/Application Support/Moppo/plan-execution`.

Reports expire after seven days.
A successful save removes expired reports.
It retains the ten newest valid reports and the reports that unexpired plans use.
The CLI refuses expired reports even before the next save.
The store preserves invalid and unknown files.
Unsupported schemas require a new scan.

Normal output omits names, paths, and detailed explanations that can contain paths.
Use `--include-paths` only when you want to disclose that information:

```sh
moppo items --scan scan_ID --json --include-paths
```

The option applies to the current command only.
An agent can send command output to an external provider.
Even reduced output contains categories, sizes, and storage classifications.
Local execution does not guarantee local model processing.
The CLI does not return file contents.
The CLI needs no MCP server.
