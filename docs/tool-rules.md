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
| `bundleIdentifiers` | The bundle identifiers of the desktop application. Needed for an application data folder, a curation, and the tool icon. |
| `aiTool` | For an AI tool. The `case` and `rawValue` of `FileEntry.AITool`, and `paddedIcon` when the bundled icon includes the padding of an application icon. Tool files can share one. |
| `owner` | For an AI tool. The `case` and `name` of the heading in Cleanup. |
| `documentName` | Optional. The name in the AI coverage table when it differs from `name`. |
| `removalRules` | For an AI tool. The removal rules cell of the AI coverage table. |
| `verified` | Optional. The observed version of the tool, for the bundle identifier table. |
| `storage` | One entry for each path. |

## Sections

`sections.json` gives each section a `title`, a `document`, an optional `format`, and its `tools` in order.
The `catalog` format, the default, writes the seven-column table of `docs/tool-catalog.md`.
The `aiCoverage` format writes one row for each tool: its document name, its rule paths, and its removal rules.
The `bundleIdentifiers` format writes the observed version of each tool with its first bundle identifier.
A tool in an `aiCoverage` section needs no catalog cells.

## Storage fields

| Field | Contents |
| --- | --- |
| `path` or `paths` | The path, or the paths of one document row. `~` is the home folder. `<name>` matches one path component. |
| `type` | `cache`, `download`, `build`, `installed`, `logs`, or `userData`. |
| `table` | The Swift table that holds the rule. Omit it for a row without a rule. |
| `owner` | With `table`. The category that lists the path: `aiTools`, `packageManagers`, `hiddenSystemData`, `systemCaches`, `applications`, `applicationLeftovers`, or `documentsAndFiles`. |
| `treatment` | With `table`. `offer`, `review`, or `protect`. |
| `name` | With `table`. The row name in Moppo. |
| `check` | A check in Swift code that the rule needs, such as `goModuleCache`. |
| `applicationData` | `true` when the path is also an application data folder of the tool. |
| `section` | For an AI tool root. The `title` and `summary` of its storage section in Cleanup. |
| `curated` | For an AI tool root. `true` when the desktop application curation applies, with its `remainderName`. |
| `electronCaches` | For a curation root. `true` when Moppo also offers the Chromium caches at the top of the folder. |
| `reviewsWorktrees` | For an AI tool root. `false` when Git worktree review does not run inside it. |
| `store` | For a model store. The name of the Swift constant that holds the store paths, such as `whisper`. |
| `claimed` | For a model store. `false` when no category claims the path. |
| `coverage` | Without `table`. The `Moppo today` value: `row`, `protected`, `caches`, `hidden`, `size`, `no`, or a ticket number. |
| `identifiedBy` | Paths in the folder that identify the tool. One is sufficient. A glob component matches any child. A final `/` requires a folder. For a cache in a home folder, the one item that identifies its layout. |
| `layout` | For a protected home folder or location. Items that must all exist before Moppo offers a cache in it. |
| `explanation` | For a protected home folder or location. The row explanation in Moppo. |
| `caveat` | For a cache that needs review. The text that tells what removal costs. |
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
| `toolHomeFolders` | `ToolHomeFolders.all` | Protected home folders. An offered path below a folder is one of its caches. |
| `toolHomeLocations` | `ToolHomeFolders.locations` | Protected tool storage outside the listed folders, with the items that identify it. |
| `packageManagerCaches` | `PackageManagerScanner.roots` | Package caches that Moppo offers by their path. The rule with `"check": "goModuleCache"` is the Go module cache. |
| `applicationDataFolders` | `ApplicationDataFolders.byBundleIdentifier` | Data folders that use another name than their application. The tool needs `bundleIdentifiers`. |
| `aiToolStorage` | `AIToolStorage.roots` | Protected AI tool storage. A rule below a root is one of its parts. The tool needs `owner` and `aiTool`. |
| `curations` | `ApplicationsScanner.curations` | A support folder with caches beside user data. The protected root locks the remainder. An offered path below it is a regenerable cache. |

| `localModelStores` | `LocalModelStores` claim sets and store paths | Model folders that the readers claim. A `store` names the constant that its reader uses. |
| `editorExtensionStores` | `EditorExtensionStores.editors` | The `extensions` folder of a VS Code–family editor, with `"check": "editorObsolete"`. |

A curated AI root, with `"curated": true` and a `remainderName`, is also a curation. Its curation caches sit below it.
A model store path claims a whole home dot folder, a whole child of `~/.cache`, or one child of a folder, by its shape.
A model store elsewhere, such as the GPT4All folder, needs `"claimed": false`.
The generator also writes `FileEntry.AITool`, `AIStorageSection.Owner`, and `ToolIcons` from the `aiTool` and `owner` fields of the tool files.

A rule in another table can also set `"applicationData": true`.
The generator then adds its path to `ApplicationDataFolders.byBundleIdentifier` under the tool's `bundleIdentifiers`.
`SystemCachesScanner` and `HiddenDataScanner` derive their skip sets from `PackageManagerScanner.roots`, so no other table lists a package cache twice.

A cache in a home folder or location is an `offer` or `review` entry with the same table, below the folder path.
The generator needs exactly one protected folder above such a path.

Issue #352 moves the other tables into the registry.
