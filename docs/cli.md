# Moppo command line

[Back to the documentation index](README.md).

`moppo` scans a Mac for cleanup candidates, saves a plan, and removes a plan that the user approved.
It does not open the app. Each command has a `--json` form for scripts and agents.
The [agent workflow](agent-workflow.md) describes the skill that drives it.
The development tool `moppo-cli` is separate and has diagnostic commands.

## Install

In Moppo, open **Settings > Advanced**. In **Command line and agents**, select **Install** for the command-line tool.
This links `~/.local/bin/moppo` to the executable inside the signed app, so app updates also update the command.
The CLI ships with the next Moppo release. Earlier releases do not include it.

To make the link yourself, without opening the app:

```sh
/Applications/Moppo.app/Contents/Helpers/moppo --version   # Check the executable
mkdir -p "$HOME/.local/bin"
ln -s /Applications/Moppo.app/Contents/Helpers/moppo "$HOME/.local/bin/moppo"
export PATH="$HOME/.local/bin:$PATH"                        # In your shell configuration, if needed
```

Inspect an existing `moppo` in that folder before you replace it.
Keep the executable inside the app, where its resources are.

## Commands

```sh
moppo --help
moppo scan --json                                        # Scan, save a report, return scan_ID and its revision
moppo scan --category xcode --json                       # Scan one enabled category
moppo items --scan scan_ID --limit 100 --json            # Page through the saved items
moppo items --scan scan_ID --category xcode --offset 100 --limit 100 --json
moppo explain --scan scan_ID --item item_ID --json       # One item and its reason
moppo plan create --scan scan_ID --revision SCAN_HASH --items item_ID,item_OTHER --json
moppo plan inspect --plan plan_ID --json                 # Check the plan against a fresh scan
moppo plan remove --plan plan_ID --revision PLAN_HASH --json       # Remove that exact revision
moppo plan review --plan plan_ID --app --json            # Open the plan in Moppo instead
moppo plan outcomes --plan plan_ID --json                # Results of each removal attempt
moppo plan invalidate --plan plan_ID --revision PLAN_HASH --json   # Delete the saved proposal
moppo exclude --scan scan_ID --item item_ID --json       # Never offer the item again
```

The identifiers and hashes are placeholders.
Use the `revision` of the scan response to create a plan, and the `revision` of the plan response to remove or invalidate it.

Normal output omits names, paths, and explanations that can contain paths.
Add `--include-paths` to one command to disclose them:

```sh
moppo items --scan scan_ID --json --include-paths
```

An agent can send command output to its provider, and reduced output still contains categories, sizes, and classifications.
The CLI never returns file contents, and it needs no MCP server.

## Scan and inspect

- **Reports.** Each scan saves a report and returns a scan identifier and revision.
- **Identifiers.** Item identifiers stay stable in one scan. A new scan creates new ones.
- **Not permission.** An identifier is not a path, and a saved report does not authorize removal.
- **Pages.** `items` returns 100 entries by default and 500 at most. Filters apply before pagination.
- **Next page.** `next_offset` gives the next offset, or `null` on the last page.
- **Past the end.** An offset beyond the result count returns an empty page.
- **Explain.** `explain` returns one matching item.

## Save a plan

- **Selection.** A plan holds 1 to 500 item identifiers from one scan revision.
- **No paths.** The CLI rejects paths, commands, protection overrides, and unknown options.
- **All or nothing.** One failed item check rejects the complete proposal.
- **Fresh checks.** Creation and inspection scan the selected categories again with the current preferences.
- **Checks.** Identity, protection, eligibility, target membership, protected patterns, and unreadable items. The checks remove nothing.
- **Supported targets.** Ordinary files, file groups, local model groups, and available fixed tool targets.
- **Unsupported.** Application reviews, virtual targets such as Docker images and volumes, and symbolic links return `unsupported_target`.
- **Protected.** Protected rows and children stay out, regardless of earlier app overrides.
- **Groups.** A child of a model group needs its parent. Selecting both fails validation.
- **Response.** `status: review_required` with the plan identifier, plan revision, scan revision, expiry, and items.
- **Sizes.** `scan_allocated_bytes` counts each selected file identity once, plus exclusive model files.
- **Omitted sizes.** Moppo omits the aggregate when directory measurements can overlap or share files. Row sizes stay.
- **Unverified.** `recoverable_space: unverified` is separate from scan sizes. No plan claims verified recoverable space.
- **Changes.** A size change does not reject a plan. A changed file, identity, kind, protection, or removal command does.
- **Expiry.** A plan expires after one day, or with its source scan. The store keeps twenty valid plans.
- **Invalidate.** Invalidation removes only the saved proposal, not cleanup targets or the selection in the app.

A plan never changes the selection in the app, and it does not authorize removal.
The revision is a SHA-256 digest of the stored record.
It detects changes, but it is not a signature, a consent token, or a security boundary against another process under the same account.
The [architecture notes](architecture.md#saved-plan-execution) describe the module that terminal and app clients share.

| Error code | Required action |
| --- | --- |
| `exclusions_changed` | Run a new scan after any exclusion change |
| `category_disabled` | Review category settings before a new scan |
| `protected_item` or `excluded_item` | Keep the protected item outside the proposal |
| `missing_item` | Run a new scan because the current inventory lacks an item |
| `changed_target` | Run a new scan because identity, file metadata, or group membership changed |
| `unsupported_target` | Keep the item outside the proposal. Remove it in the Moppo app |
| `incomplete_scan` | Resolve access or measurement limits before a new scan |
| `scan_changed` or `plan_changed` | Discard the earlier review and inspect current data |
| `evidence_unavailable` | Run a new scan with this CLI version |
| `expired` or `record_unavailable` | Create a new plan from an available scan |

## Remove a plan

`plan remove` does not open Moppo. An agent runs it only after the user approves the plan.

- **One revision.** The command removes only the revision you pass. Another revision returns `plan_changed` before any check.
- **Trash first.** Ordinary items move to Trash without a prompt. Put Back in Cleanup History restores them.
- **Protected items** stay out, and specialized app targets keep their own review flows.
- **Permanent items.** No Put Back. `permanent_items` lists them, and `permanent_commands` names the tool, such as `brew`.
- **Paths.** The complete command contains paths, so it appears only with `--include-paths`.
- **Authentication.** For a permanent item, macOS asks the Mac user for Touch ID, a paired watch, or the login password.
- **No bypass.** A shell cannot answer that dialog. No `--yes`, force, or bypass option exists.
- **Cancelled authentication.** A cancelled or failed authentication cancels the complete plan before removal.
- **Fresh checks.** Moppo scans again before removal, and checks the plan, settings, and identities before each item.
- **One lock.** Terminal removal, app review, app cleanup, uninstall, Trash, duplicates, and Storage Explorer share one lock.
- **Busy.** A busy lock returns exit 75 and `execution_busy`. Older builds and external tools do not take part.
- **Interrupts.** Before removal, Ctrl-C cancels without changes. During removal, the current item finishes, then Moppo cancels the rest.
- **Unknown results.** A forced exit can leave a `started` record with an unknown result. Do not retry automatically.
- **After removal.** `plan outcomes` keeps the results after expiry or invalidation. Cleanup History records attempts and skips.

For other commands, a second interrupt stops the command at once. Those commands do not change cleanup targets.

## Review in the app

- **Open.** `--app` opens Moppo with the plan identifier and revision. The URL holds no paths or commands.
- **Status.** `app_requested` means that Moppo accepted the request, not consent, review, or removal.
- **Busy app.** `app_copy_running` means that another Moppo copy runs. Quit it, then request the review again.
- **Welcome guide.** The request waits until the welcome guide finishes.
- **Proposal.** Moppo checks the revision, scans the targets, and shows names, paths, sizes, reasons, and recovery limits.
- **Confirmation.** Select **Review Removal…**, then confirm the items. Settings cannot disable this confirmation.
- **Permanent tools.** Each permanent tool removal shows an extra warning with the exact command.
- **One review.** Another request cannot replace an open review, and an active app operation blocks a new one.
- **Specialized reviews.** Git worktrees, Codex history, sound libraries, and Xcode build caches keep their own app controls.
- **Stop.** Cancel before confirmation to keep every target. **Stop After Current Item** finishes the current item first.
- **Recovery.** Cancellation does not restore completed removals. Use Put Back in Cleanup History.

App review removes items with the same checks, lock, and receipts as the terminal command.
The existing Cleanup selection stays separate, and a retained execution record prevents another attempt with the same plan revision.

## Outcomes

`plan outcomes` returns each attempt with its `run_id`, status, counts, and item results.
It works after plan invalidation or expiry.

| Value | Meaning |
| --- | --- |
| `trashed`, `deleted`, `partial`, `failed`, `skipped`, `cancelled`, `unknown` | Item results. Counts separate Trash moves from permanent removals |
| `private_bytes` | Measured private allocation. It does not promise free space after a Trash move |
| `started` without a final record | The outcome is unknown. Check Cleanup History and the files before another attempt |
| `unknown` | The item can have changes that Moppo could not report |
| `no_outcome` | No retained record exists. It does not prove that no removal occurred. Records expire |

## Exclude an item

`moppo exclude` saves the same rules as **Never Offer This Again** in the app.
It scans the category again to find the current identities.

| Status | Meaning |
| --- | --- |
| `excluded` | Moppo saved one or more rules. `added_rules` gives the number |
| `already_excluded` | Saved rules already cover the item |
| `exclusion_unsupported` | Cleanup already skips the protected item |

- **Model rules** identify manifests or repository folders, so shared blobs stay protected.
- **Docker rules** include the image or volume context.
- **Effect.** Later scans skip the item. A running app reloads the rules but keeps the row until the next scan.
- **Plans** saved before the change fail with `exclusions_changed`.
- **Undo.** Open **Settings > Exclusions** in Moppo. The change applies after another scan.

## Settings and access

- **Preferences.** The CLI reads enabled categories and exclusions from the Moppo preferences domain.
- **Defaults.** Without saved settings, it enables every category and applies the built-in exclusions.
- **Exclusions.** Rules can name folders, files, tool items such as Docker images, and filename patterns.
- **Only `moppo exclude`** changes these settings. It adds exclusions and never removes them.
- **Categories.** `--category` restricts a scan to an enabled category. It cannot enable a disabled one.
- **Invalid settings** stop the scan.
- **Access.** The CLI cannot inherit the Full Disk Access of the app. Grant the terminal access, then scan again.
- **No sudo.** Administrator access cannot bypass macOS privacy controls.

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

## Output contract

- **JSON.** `schema_version: 1`, snake_case names, UTC ISO 8601 dates, and one document on standard output.
- **Progress and text errors** go to standard error.
- **Errors.** A JSON error has a code and a message, plus `item_id` when one selected item caused it.
- **Scan response.** Category totals, an item count, the identifier, revision, timestamps, expiry, and status.
- **Items.** The scan response has no item list. Use `items` to retrieve entries.

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
| `regeneration` | `regenerable` or `not_regenerable`, when the engine classified the item |
| `regeneration_reason` | Why a `not_regenerable` item does not come back, when the engine knows |

| Field | Values |
| --- | --- |
| `eligibility` | `protected`, `parent_review`, `app_review`, or `review_required`. None authorizes removal |
| `app_review` | Needs a review screen in Moppo: applications, Docker images and volumes, Xcode build caches, Git worktrees, sound libraries, and Codex sessions. A plan returns `unsupported_target` |
| `recovery` | `trash_if_supported`, `permanent`, or `external_tool`. Check Trash availability before a removal command |
| `project_activity` | `last_activity_at`, `git_ignore`, and `hold`. An item with a `hold` value is not safe to remove |
| `git_ignore` | `ignored`, `not_ignored`, `unknown`, or `outside_repository` |
| `hold` | `recent_activity`, `not_ignored_by_git`, or `unknown` |
| `regeneration` | Absent when the engine did not classify the item. Do not treat absence as `regenerable` |
| Scan status | `complete`, `partial`, `unavailable`, or `notInstalled`. Complete means no unreadable items in the enabled categories, not every file on the Mac |

- **Sizes overlap.** Parent and child sizes can overlap. Do not add item sizes for a total.
- **Not recoverable space.** Allocated and displayed sizes do not establish recoverable space.
- **Partial** sizes can understate usage, and `unavailable` zero values do not mean empty storage.

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

- **Exit codes 2 and 77** still return a saved scan identifier.
- **Inspection** returns 0 when retrieval succeeds, even for a partial scan. Check the status first.
- **Cancellation** before report storage saves nothing. Cancelled scans and inspections change no targets.
- **Storage.** A scan checks that it can save its report first. A blocked folder returns exit 74 and `storage_failure`.

Agent sandboxes often block that folder. The [agent guide](agent-workflow.md#agent-sandboxes) explains the client setting.

## Privacy and retention

| Store | Location under `~/Library/Application Support/Moppo` | Contents | Limits and retention |
| --- | --- | --- | --- |
| Scan reports | `cli-scans` | Names, paths, explanations, and private identity and policy evidence for plan validation | 64 MiB each. Seven days. The ten newest valid reports and the reports of unexpired plans stay |
| Plans | `cleanup-plans` | Identifiers and revisions, without paths or commands | 64 KiB each. One day, or the life of the source scan. Twenty valid plans |
| Outcomes | `plan-outcomes` | Identifiers, status codes, and counts, without names or paths | 512 KiB each. Seven days. 100 records, start and final records counted separately |
| Execution lock | `plan-execution` | The lock that terminal and app removal share | None |

Each folder uses mode 0700 and each file mode 0600.
The store rejects symbolic links, shared file links, and unexpected permissions, and it preserves invalid and unknown files.
Command output never includes the stored evidence.
The CLI refuses expired reports, and an unsupported schema requires a new scan.
