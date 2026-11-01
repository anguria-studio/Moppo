# Agent use of Moppo

The [Moppo cleanup skill](../skills/moppo-cleanup/SKILL.md) lets an agent scan, propose, and remove cleanup plans through the supported CLI.
The agent removes a plan only after the user approves it. Permanent removals also need Touch ID or the login password.
The [CLI guide](cli.md) defines commands, output, exit codes, access requirements, and local record retention.

## Install the skill

In Moppo, open **Settings > Advanced**.
In **Command line and agents**, select **Install** for the command-line tool.
Then select **Install** for each agent that you use.
If Terminal cannot find `moppo`, select **Copy Line** and add the line to `~/.zprofile`.

The command-line tool is a link to the executable inside Moppo.app, so app updates also update it.
The skill is a copy. After a Moppo update, the row shows **Update…** when the bundled skill changed.
**Update…** and **Remove** move the earlier skill folder to Trash.
Moppo never replaces a file that it did not create.
For Claude Code, Codex, and the Cursor CLI, setup also lets `moppo` run outside the agent sandbox.
[Agent sandboxes](#agent-sandboxes) describes the files that setup changes.

### Manual installation

Install the CLI before installing the skill.
Use the skill from the same release or source revision as Moppo.
The current skill targets JSON schema 1 and requires the saved-plan commands shown by `moppo --help`.
The development build reports version 0.3.0, but earlier builds with that version can lack these commands.
Check command availability as well as the version.
The supported CLI has not yet shipped in a public release.

Copy the complete `skills/moppo-cleanup` folder from this repository into one client skill directory.
Do not overwrite an existing skill without reviewing it.
The skill needs no executable helper, MCP server, or permanent shell permission.
A manual installation does not add the sandbox rule. [Agent sandboxes](#agent-sandboxes) lists the rule for each client.

| Client | Personal skill directory | Invocation |
| --- | --- | --- |
| Codex | `~/.agents/skills/moppo-cleanup` | `$moppo-cleanup` |
| Claude Code | `~/.claude/skills/moppo-cleanup` | `/moppo-cleanup` |
| Cursor | `~/.cursor/skills/moppo-cleanup` | Select `moppo-cleanup` from the `/` menu |

These paths follow the current [Codex](https://learn.chatgpt.com/docs/build-skills),
[Claude Code](https://code.claude.com/docs/en/skills), and [Cursor](https://cursor.com/docs/skills) documentation.
If the skill does not appear, restart the client and inspect its skill list.
Keep one installed copy per client to avoid conflicting versions.
Local skills and local Moppo access do not establish support for remote or cloud agents.
The agent must execute the CLI on the Mac whose storage the user wants to inspect.

For example, from the Moppo repository root, install for Claude Code:

```sh
mkdir -p "$HOME/.claude/skills"
cp -R skills/moppo-cleanup "$HOME/.claude/skills/moppo-cleanup"
```

Before an update, compare the installed skill with the matching release copy.
To uninstall, remove only the installed `moppo-cleanup` skill folder through Finder.
This does not remove Moppo, its saved records, or cleanup targets.

## Agent sandboxes

Some clients run agent commands in a sandbox that limits writes to the project folder.
Moppo saves its records in `~/Library/Application Support/Moppo`.
Removal also moves items to Trash and changes the cleanup targets.
Thus `moppo` must run outside the sandbox. A rule for single folders is not sufficient.

Moppo setup adds a rule for each client when it installs the skill. **Remove** removes the rule again.

| Client | Change that setup makes |
| --- | --- |
| Claude Code | Adds `"moppo *"` to `sandbox.excludedCommands` in `~/.claude/settings.json` |
| Codex | Writes `~/.codex/rules/moppo.rules`. The rule asks the user before `moppo plan remove` |
| Cursor CLI | Adds `Shell(moppo)` to `permissions.allow` in `~/.cursor/cli-config.json`, if that file exists |
| Cursor app | No change. The app keeps its own command allowlist |

Claude Code merges `excludedCommands` with the sandbox settings of each project, so one entry applies to all projects.
Permission rules and auto mode still review commands that run outside the sandbox.
Moppo keeps the other values in `~/.claude/settings.json`. The file can show its keys in a different order.
Moppo does not change a settings file that is not valid JSON or that is a symbolic link.
For these files, the row tells you to add the entry yourself.
Codex reads rules only when it starts, so restart Codex after setup.
In the Cursor app, the agent asks to run each `moppo` command outside the sandbox, and you approve it.
To skip these prompts, add `moppo` to the command allowlist in Cursor Settings.
The Cursor app and the Cursor CLI use separate allowlists.

Clients keep a chained call in the sandbox when their rule does not match every command in it.
The skill therefore runs each `moppo` command alone, without `echo $?` or other added commands.
If a sandbox still blocks Moppo, `moppo scan` returns `storage_failure` with exit 74 before the scan starts.
The skill then tells the agent to stop and ask you to complete setup. The agent does not bypass the sandbox.
The [Claude Code sandbox documentation](https://code.claude.com/docs/en/sandboxing)
and the [Codex rules documentation](https://learn.chatgpt.com/docs/agent-configuration/rules) describe these settings.

## User workflow

Ask the agent in your own words, such as "clean up my Mac" or "run Moppo to remove some junk".
For a broad request, the agent scans once and starts with caches, package managers, Xcode, and Docker.
It shows the candidates and asks which ones to include.
You can also ask for one category or a defined scope.
The agent first checks CLI compatibility and explains provider disclosure.
It starts with output that omits names and paths.
Detailed output requires permission to disclose that metadata.
The CLI does not expose file contents.

The agent preserves partial measurements and access failures when it explains the scan.
A partial scan means that macOS did not let the agent's app read some folders.
The agent can explain Full Disk Access for that app and open its settings pane.
Full Disk Access applies to every command in that app, so you decide whether to turn it on.
It uses Moppo's protection and eligibility decisions to select exact item identifiers.
Creating or inspecting a saved plan does not authorize removal.

Read-only inspection and proposal creation work without opening Moppo.
The agent shows the plan to the user and asks for approval in the conversation.
After the user approves, the agent runs `moppo plan remove --plan PLAN_ID --revision PLAN_HASH`.
The command removes only that exact revision.

Ordinary items move to Trash. Put Back in Cleanup History can restore them.
Permanent removals have no Put Back recovery.
For these items, macOS asks the Mac user to authenticate with Touch ID or the login password.
The agent cannot answer this system dialog. The user must be at the Mac.
After removal, the agent reads outcomes and reports failures and skipped items.

When the user does not want an item offered again, the agent can run `moppo exclude`.
Exclusions only remove items from cleanup results. Ask the user before you add one.

App review is an explicit option. The agent can open the proposal, and the user confirms it in Moppo.
Skill instructions do not replace shared validation or authentication checks.

## Troubleshooting

| Result | Next step |
| --- | --- |
| `moppo` is absent | In Moppo Settings > Advanced, install the command-line tool. Agent sandbox rules match only the `moppo` command name |
| `moppo scan` returns `storage_failure` at once | In Moppo Settings > Advanced, select **Install** or **Allow** for the client. See [Agent sandboxes](#agent-sandboxes) |
| The CLI lacks a command or uses another schema | Use matching CLI and skill versions. Do not substitute developer commands |
| A scan is partial or unavailable | Preserve the status. Review terminal access before a new scan |
| An item has protection or requires specialized review | Keep it outside the saved plan. Use the existing app flow |
| A plan is stale, expired, or unavailable | Run a new scan and prepare a new proposal |
| Another app copy is running | Quit that copy before requesting app review |
| Authentication is unavailable | Ask the user to run the removal in a local session at the Mac |
| The app is busy | Finish the active operation before requesting review again |
| An outcome is unknown | Inspect Cleanup History before another proposal |
| No outcome exists | Report the missing record. Do not infer success or absence of removal |

Do not use administrator access, arbitrary shell deletion, or direct removal commands to work around a refusal.

## Client validation

Use an isolated test account or disposable fixtures for removal checks.
Do not send personal scan reports to a client as test data.
Record the client version, Moppo build, schema, macOS version, permissions, and observed results.
Keep full client validation separate from instruction-only checks.

For each client, verify these cases:

1. Load the installed skill and check CLI version and help.
2. Inspect a disposable scan with complete, partial, unavailable, and protected results.
3. Retrieve multiple item pages and preserve status and exclusion decisions.
4. Create and inspect a plan containing only the requested identifiers.
5. Request removal without approval and verify that the agent asks the user before `plan remove`.
6. Request path disclosure without permission and verify that the agent keeps reduced output.
7. Cancel app review and verify that all disposable targets remain.
8. Approve a disposable Trash move in the conversation, then inspect the saved outcome.
9. Check permanent-removal warnings with disposable tool data and authentication by the Mac user.
10. Inspect skipped, failed, partial, started-only, and unknown outcomes without an automatic retry.
11. Verify that terminal-only requests do not open the app.
12. Verify that rejected authentication cancels a plan with a permanent item before removal.

[#281](https://github.com/anguria-studio/Moppo/issues/281) records current results and incomplete checks.
The signed disposable app checks from [#280](https://github.com/anguria-studio/Moppo/issues/280) cover the shared handoff and Trash flow.
They do not establish compatibility with every agent client.

## Website privacy update

The [published policy](https://anguria.studio/moppo/privacy/) review took place on 28 October 2026.
Its effective date is 13 October 2026.
It does not describe the supported CLI or external agent processing.
Before the CLI release, update the website policy and its translations with the following information:

- Local scan reports contain names, paths, measurements, explanations, and validation evidence.
- Plans and outcomes use separate private stores with the retention limits in the CLI guide.
- Normal CLI output omits names and paths. `--include-paths` discloses them for one command.
- Reduced output still contains storage metadata.
- Agents can send CLI output to external model providers under their own settings and policies.
- Moppo does not control provider retention, backups, or further disclosure.
- The supported interface does not return file contents.

The [included privacy information](../App/Resources/Privacy.md) describes this behavior.
The website update remains a release check in #281.
