# Tool rule registry

[Back to the development notes](README.md#developer-tool-storage).

The registry in `rules/` holds the storage rules for each third-party tool.
`scripts/rules.py` generates the Swift tables and the document tables from it.
The generated files are in Git. A check in CI fails when they are out of date.
Moppo never reads the registry at run time.

## Files

- `rules/sections.json` lists each document section, its document, and its tools in order.
- `rules/<tool>.json` holds one tool: its identity, a note, and one `storage` entry for each path.
- `Core/Sources/MoppoCore/Generated/ToolRules.swift` holds the generated Swift tables. Do not edit it.
- The generator writes each section table between `<!-- rules:begin <section> -->` and `<!-- rules:end <section> -->` in its document.

## Commands

```sh
python3 scripts/rules.py generate
python3 scripts/rules.py check
python3 -m unittest discover -s scripts -p 'test_rules.py'
```

`generate` writes the generated files. `check` fails when a generated file is out of date.
After you change a file in `rules/`, run `generate` and commit the generated files with the rule.

## Tool fields

| Field | Contents |
| --- | --- |
| `id` | The file name without `.json`. |
| `name` | The tool name. The row explanation uses it. |
| `section` | A section from `sections.json`. |
| `note` | Optional. A sentence under the section table. |
| `storage` | One entry for each path. |

## Storage fields

| Field | Contents |
| --- | --- |
| `path` or `paths` | The path, or the paths of one document row. `~` is the home folder. `<name>` matches one path component. |
| `type` | `cache`, `download`, `build`, `installed`, `logs`, or `userData`. |
| `table` | The Swift table that holds the rule. Omit it for a row without a rule. |
| `owner` | With `table`. The category that lists the path: `aiTools`, `packageManagers`, `hiddenSystemData`, `systemCaches`, `applications`, `applicationLeftovers`, or `documentsAndFiles`. |
| `treatment` | With `table`. `offer`, `review`, or `protect`. |
| `name` | With `table`. The row name in Moppo. |
| `coverage` | Without `table`. The `Moppo today` value: `row`, `protected`, `caches`, `hidden`, `size`, `no`, or a ticket number. |
| `identifiedBy` | Paths in the folder that identify the tool. One is sufficient. A glob component matches any child. A final `/` requires a folder. |
| `recognition`, `removal`, `restore` | The text of the document cells. |
| `verified` | `date`, `tool`, and `macos`. Optional `kind`, `verified` or `found`, and `scope`. |
| `status` | The status text when there is no verification, or the text after it. |
| `contents` | Optional, for `databaseStorage`. What the folder holds, for the row explanation. |
| `note` | Optional. A sentence under the section table and a comment in the generated Swift. |

## Rules that the generator enforces

The generator refuses to write when a rule breaks one of these rules:

- Each path has one owner. No two entries name the same path.
- No rule offers a `userData` path.
- An offered path never holds a protected path.
- An offered path needs `identifiedBy` or `check`, and a `verified` record.
- Each `type`, `table`, `owner`, `treatment`, and `coverage` value is a known value.

The `Moppo today` column comes from the rule: `Protected` for `protect`, and `Row` for `offer` and `review`.
A row without a rule shows its `coverage`.

## Tables

| Table | Swift | Contents |
| --- | --- | --- |
| `databaseStorage` | `DatabaseStorage.roots` | Protected database data folders. |

Issue #352 moves the other tables into the registry.
