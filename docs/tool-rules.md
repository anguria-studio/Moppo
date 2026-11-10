# Tool rule registry

[Back to the documentation index](README.md).

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
| `note` | Optional. The fact that justifies the rules of the tool, in one sentence. In the AI coverage table it fills the `Notes` cell. In a catalog section the generator writes one short paragraph for each tool under the table, with the tool name first. |
| `comment` | Optional. Detail for agents and reviewers, such as a team identifier or a package name. It goes into the generated Swift only. |
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
The `aiCoverage` format writes one row for each tool: its document name, its rule paths, its removal rules, and its notes.
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
| `note` | Optional. A fact that justifies the rule. It joins the tool's paragraph under the table and the comment in the generated Swift. |
| `comment` | Optional. Detail that goes into the generated Swift only. |

## Rules that the generator enforces

The generator refuses to write when a rule breaks one of these rules:

- Each path has one owner. No two entries name the same path.
- No rule offers a `userData` path.
- An offered path never holds a protected path.
- An offered path needs `identifiedBy` or `check`, and a `verified` record.
- Each `type`, `table`, `owner`, `treatment`, and `coverage` value is a known value.

The `Moppo today` column comes from the rule: `Protected` for `protect`, and `Row` for `offer` and `review`.
A row without a rule shows its `coverage`.

## Tests

`RuleDocumentTests` compares the document tables with the Swift tables in both directions.
`LayoutFixtureTests` reads the registry files and builds each rule's layout in a temporary home.
A rule with `identifiedBy` or `layout` items must recognize the folder with them and refuse the folder without them.
`Core/Tests/MoppoCoreTests/Fixtures/Layouts/<tool>.txt` holds names from the #216 manifests of a rented Mac: folders at two levels and the files that rules name, with no contents.
Where a tool has a fixture, the suite builds it and checks that each rule of the tool recognizes the real layout.
Generated names, such as session identifiers, and the rental user name are not in the fixtures.
A new tool needs one JSON file and, when a manifest exists, one fixture file.

## Audit

```sh
python3 scripts/rules.py audit
python3 scripts/rules.py audit --manifest layout.jsonl --older-than 90
```

The audit reads the installed version of each tool and compares it with the verification records in its file.
A desktop application gives its version through its `bundleIdentifiers` and `Info.plist` in `/Applications` or `~/Applications`.
A command-line tool gives it through its `versionCommand`: an executable name and up to two plain arguments.
The audit runs only that executable from `PATH`, with no shell, and a ten second limit.

The report lists:

- Tools that are newer than their last verification.
- Installed tools whose verification records no version.
- Offered rules without a verification record.
- Tools whose last verification is older than `--older-than` days. The default is 180.
- With `--manifest`, paths that no rule covers.

`scripts/manifest.py` writes a layout manifest of one or more folders: names, types, and sizes, with no contents.
Run it on a test Mac after a tool update, then run the audit with the manifest.
The audit lists each manifest root with no rule.
For a root whose rule has deeper rules, such as parts or caches, it lists each child that no deeper rule names.
Run the audit before each release and after each test rental. Record the result in the release ticket.

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
| `containerCaches` | `SystemCachesScanner.containerCaches` | Verified cache folders inside a named application container. The rule matches only the given path. |

| `localModelStores` | `LocalModelStores` claim sets and store paths | Model folders that the readers claim. A `store` names the constant that its reader uses. |
| `editorExtensionStores` | `EditorExtensionStores.editors` | The `extensions` folder of a VS Code–family editor, with `"check": "editorObsolete"`. |

A curated AI root, with `"curated": true` and a `remainderName`, is also a curation. Its curation caches sit below it.
A model store path claims a whole home dot folder, a whole child of `~/.cache`, or one child of a folder, by its shape.
A model store elsewhere, such as the GPT4All folder, needs `"claimed": false`.
A model store can have `custom`, with the `variables` that move it and the `identifiedBy` items that identify it.
Each variable has a `name` and an optional `append` path. The first variable with a value sets the folder.
Set `expandsHome` when the tool expands `~`. Set `trimsQuotes` when the tool removes spaces and quotes around the value.
The generator also writes `FileEntry.AITool`, `AIStorageSection.Owner`, and `ToolIcons` from the `aiTool` and `owner` fields of the tool files.

A rule in another table can also set `"applicationData": true`.
The generator then adds its path to `ApplicationDataFolders.byBundleIdentifier` under the tool's `bundleIdentifiers`.
`SystemCachesScanner` and `HiddenDataScanner` derive their skip sets from `PackageManagerScanner.roots`, so no other table lists a package cache twice.

A cache in a home folder or location is an `offer` or `review` entry with the same table, below the folder path.
The generator needs exactly one protected folder above such a path.

Issue #352 moves the other tables into the registry.
