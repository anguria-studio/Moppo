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
- Keep `BACKLOG.local.md` as a historical record.
- Do not keep a second active ticket list in local files.

Read project items with this command:

```sh
gh project item-list 1 --owner anguria-studio --limit 200 --format json
```

Check `totalCount` against the number of returned items.
If some items are missing, increase the limit or use API pagination.
Read field identifiers with `gh project field-list` before you update a field.

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

Run `vale README.md AGENTS.md WRITING_STYLE.md` after you change tracked
documentation. Review interface text and code comments manually because Vale does
not check Swift string literals.

The file `design/README.md` contains the archived handoff. Do not revise it during
a general writing pass.
