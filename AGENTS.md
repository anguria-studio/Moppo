# Project instructions

## Tickets

GitHub is the main ticket record.
The repository is `anguria-studio/Moppo`.
The [Moppo project](https://github.com/orgs/anguria-studio/projects/1) holds status and release fields.

- Use GitHub CLI (`gh`) to read issues and project fields.
- Read the current issue, comments, and linked pull requests before work starts.
- Select `Next` tickets by phase, then source order, unless the user specifies another order.
- Set the project status to `Doing` when work starts.
- Link the pull request to its issue.
- Set `Done` after the required checks and merge.
- Keep incomplete checks visible in the pull request and final report.
- If manual checks remain incomplete when you close a ticket, add them to an open ticket.
- Keep `BACKLOG.local.md` as a historical record.
- Do not keep a second active ticket list in local files.

Read project items with this command:

```sh
gh project item-list 1 --owner anguria-studio --limit 200 --format json
```

Check `totalCount` against the number of returned items.
If some items are missing, increase the limit or use API pagination.
Read field identifiers with `gh project field-list` before you update a field.

## Code and tests

- Before you add a helper, search the code and tests for an equivalent helper.
- Put helpers that more than one test file uses in `AppTests/TestSupport.swift`.
- Remove properties, methods, and stored tasks that no code reads.
- Give the same name to the same event or state in each feature model.
- Use test arguments only when each argument can change the result.
- Before you add a test, make sure that no other test covers the same behavior.
- When you move or add a feature folder, update the layout in `docs/README.md`.
- After a multi-part refactor, review the complete change for repeated code and repeated tests.

## Branches and pull requests

- Commit changes only after an explicit instruction from the user.
- Push changes only after an explicit instruction from the user.
- Create branches with `<type>/<short-description>`, such as `fix/scan-removal-flows`.
- Use lowercase words and hyphens in the description.
- Do not use the `codex/` prefix.
- Use Conventional Commits for commit messages and pull request titles.
- Use `<type>[optional scope][!]: <description>`, such as `fix: clear outdated scan results`.
- Use one of these types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, or `revert`.
- Open a pull request for each change to `main`.
- Do not push directly to `main`.
- Start GitHub Actions checks for pull requests that target `main`.
- Also start those checks after a push to `main`.
- Do not start those checks after a push to another branch.
- Require all CI checks to pass before a merge, except for the billing fallback below.
- Use a squash merge with the pull request title as the commit title.
- Merge only after an explicit instruction from the user.

## Local validation during Actions billing limits

When billing or quota limits prevent GitHub Actions jobs from starting, equivalent local checks can replace those blocked jobs.

- Confirm that the failed jobs did not start because of billing or quota limits.
- Run the core tests, app state tests, writing checks, and branch and title checks locally.
- Use the commands in `README.md` and the tools required by the current workflows.
- Record the tested commit SHA, commands, results, and blocked jobs in the pull request.
- Before merging, confirm that the pull request still points to the tested commit.
- If the commit changes, repeat the local checks.
- Keep code, test, build, and writing failures as merge blockers.
- Report local results separately from GitHub Actions results.
- Do not mark a blocked Actions job as successful.
- When Actions can run again, require its checks to pass.

This fallback does not authorize payments or changes to repository access.
Commit, push, and merge still require the user instructions specified above.

## Writing

Use ADS-STE100 Simplified Technical English for all new writing.

- Use the same term for the same item or action.
- Use approved, common words when possible.
- Use the active voice.
- Give one instruction in each sentence.
- Keep instructions to 20 words or fewer.
- Keep descriptive sentences to 25 words or fewer.
- Do not use contractions or Latin abbreviations.
- Put conditions before the action when the sequence is important.
- Write warnings before the action that can cause harm.
- Do not change technical names, API names, file paths, or quoted interface text.

Apply these rules to documentation, interface text, code comments, release notes,
and messages for users.

Run `vale README.md AGENTS.md WRITING_STYLE.md CHANGELOG.md SECURITY.md docs` after you change
tracked documentation. Review interface text and code comments manually because
Vale does not check Swift string literals.

The file `design/README.md` contains the archived handoff. Do not revise it during
a general writing pass.
