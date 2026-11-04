#!/usr/bin/env python3
"""Generate the Swift rule tables and the document tables from rules/*.json.

Usage:
  rules.py generate   Write the generated Swift file and the document tables.
  rules.py check      Fail when a generated file differs from the registry.

See docs/tool-rules.md for the file format.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RULES_DIRECTORY = ROOT / "rules"
GENERATED_SWIFT = Path("Core/Sources/MoppoCore/Generated/ToolRules.swift")

TYPES = {
    "cache": "Cache",
    "download": "Download",
    "build": "Build",
    "installed": "Installed",
    "logs": "Logs",
    "userData": "User data",
}
OWNERS = {
    "aiTools", "packageManagers", "hiddenSystemData", "systemCaches",
    "applications", "applicationLeftovers", "documentsAndFiles",
}
TREATMENTS = {"offer", "review", "protect"}
TABLES = {"databaseStorage", "toolHomeFolders", "toolHomeLocations", "packageManagerCaches", "applicationDataFolders"}
CHECKS = {"goModuleCache": "packageManagerCaches"}
HOME_TABLES = {"toolHomeFolders", "toolHomeLocations"}
COVERAGE = {
    "row": "Row",
    "protected": "Protected",
    "caches": "Caches",
    "hidden": "Hidden",
    "size": "Size",
    "no": "No",
}
PATH_PREFIXES = ("~/", "/opt/homebrew/", "/usr/local/", "/Users/Shared/", "/Applications/", "<project>/")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TICKET = re.compile(r"^#\d+$")
TABLE_HEADER = (
    "| Path | Type | Recognition | Removal | Restore | Moppo today | Status |\n"
    "| --- | --- | --- | --- | --- | --- | --- |"
)
BEGIN = "<!-- rules:begin {} -->"
END = "<!-- rules:end {} -->"


class RuleError(Exception):
    """A registry file breaks a rule. The message names the file and the path."""


# MARK: - Loading and validation


def load(rules_directory=RULES_DIRECTORY):
    """Read sections.json and each tool file. Raise RuleError for the first problem."""
    sections = json.loads((rules_directory / "sections.json").read_text())
    tools = {}
    for path in sorted(rules_directory.glob("*.json")):
        if path.name == "sections.json":
            continue
        tool = json.loads(path.read_text())
        if tool.get("id") != path.stem:
            raise RuleError(f"{path.name}: id must be {path.stem!r}")
        tools[tool["id"]] = tool
    validate(sections, tools)
    return sections, tools


def validate(sections, tools):
    for section_id, section in sections.items():
        for key in ("title", "document", "tools"):
            if key not in section:
                raise RuleError(f"sections.json: section {section_id!r} needs {key!r}")
        for tool_id in section["tools"]:
            if tool_id not in tools:
                raise RuleError(f"sections.json: section {section_id!r} names {tool_id!r}, which has no file")
    listed = {tool_id for section in sections.values() for tool_id in section["tools"]}
    for tool in tools.values():
        validate_tool(tool, sections, listed)
    validate_overlaps([(tool, storage) for tool in tools.values() for storage in tool["storage"]])


def validate_tool(tool, sections, listed):
    name = f"{tool['id']}.json"
    for key in ("name", "section", "storage"):
        if key not in tool:
            raise RuleError(f"{name}: needs {key!r}")
    if tool["section"] not in sections:
        raise RuleError(f"{name}: section {tool['section']!r} is not in sections.json")
    if tool["id"] not in listed:
        raise RuleError(f"{name}: sections.json does not list this tool")
    if not isinstance(tool["storage"], list) or not tool["storage"]:
        raise RuleError(f"{name}: storage must be a list with at least one entry")
    identifiers = tool.get("bundleIdentifiers", [])
    if not isinstance(identifiers, list) or not all(isinstance(value, str) and value for value in identifiers):
        raise RuleError(f"{name}: bundleIdentifiers must be a list of strings")
    for storage in tool["storage"]:
        validate_storage(name, storage)
        if (storage.get("table") == "applicationDataFolders" or storage.get("applicationData")) and not identifiers:
            raise RuleError(f"{name}: an application data folder needs the tool's bundleIdentifiers")


def validate_storage(name, storage):
    paths = storage_paths(storage)
    if not paths:
        raise RuleError(f"{name}: each storage entry needs path or paths")
    where = f"{name}: {paths[0]}"
    for path in paths:
        if not path.startswith(PATH_PREFIXES):
            raise RuleError(f"{where}: a path starts with one of {', '.join(PATH_PREFIXES)}")
    if storage.get("type") not in TYPES:
        raise RuleError(f"{where}: type must be one of {', '.join(sorted(TYPES))}")
    for key in ("recognition", "removal", "restore"):
        if not isinstance(storage.get(key), str) or not storage[key]:
            raise RuleError(f"{where}: needs {key!r}")
    has_rule = "table" in storage
    if has_rule:
        if "coverage" in storage:
            raise RuleError(f"{where}: a rule computes its coverage. Remove coverage.")
        if storage["table"] not in TABLES:
            raise RuleError(f"{where}: table must be one of {', '.join(sorted(TABLES))}")
        if storage.get("owner") not in OWNERS:
            raise RuleError(f"{where}: owner must be one of {', '.join(sorted(OWNERS))}")
        if storage.get("treatment") not in TREATMENTS:
            raise RuleError(f"{where}: treatment must be one of {', '.join(sorted(TREATMENTS))}")
        table, treatment = storage["table"], storage["treatment"]
        is_folder = table in HOME_TABLES and treatment == "protect"
        if not storage.get("name") and (table == "databaseStorage" or table == "toolHomeLocations" and is_folder):
            raise RuleError(f"{where}: a rule needs the row name")
        if is_folder and not storage.get("explanation"):
            raise RuleError(f"{where}: a protected folder needs an explanation")
        if table == "toolHomeLocations" and is_folder and not storage.get("identifiedBy"):
            raise RuleError(f"{where}: a location needs identifiedBy")
        if table in HOME_TABLES and treatment != "protect":
            if len(storage.get("identifiedBy", [])) > 1:
                raise RuleError(f"{where}: a cache has at most one identifiedBy item")
            if treatment == "review" and not storage.get("caveat"):
                raise RuleError(f"{where}: a cache that needs review needs a caveat")
        if table == "applicationDataFolders" and treatment != "protect":
            raise RuleError(f"{where}: an application data folder is protected")
        if table == "packageManagerCaches" and not storage.get("name"):
            raise RuleError(f"{where}: a package cache needs the row name")
        if "check" in storage and CHECKS.get(storage["check"]) != table:
            raise RuleError(f"{where}: check must be one of {', '.join(sorted(CHECKS))}, for its table")
        if storage["type"] == "userData" and treatment != "protect":
            raise RuleError(f"{where}: user data is never offered")
        if treatment != "protect":
            # A package cache is offered by its path. The scanner does not read a marker in it.
            if not storage.get("identifiedBy") and not storage.get("check") \
                    and table not in HOME_TABLES and table != "packageManagerCaches":
                raise RuleError(f"{where}: an offered path needs identifiedBy or check")
            if "verified" not in storage and not str(storage.get("status", "")).startswith("Not verified"):
                raise RuleError(f"{where}: an offered path needs a verified record, or a status that starts with Not verified")
    else:
        coverage = storage.get("coverage")
        if coverage not in COVERAGE and not (isinstance(coverage, str) and TICKET.match(coverage)):
            raise RuleError(f"{where}: coverage must be a ticket number or one of {', '.join(sorted(COVERAGE))}")
        if storage.get("applicationData"):
            raise RuleError(f"{where}: applicationData needs a table. Use the applicationDataFolders table instead.")
    if storage.get("applicationData") and storage.get("treatment") != "protect":
        raise RuleError(f"{where}: an application data folder is protected")
    for key in ("identifiedBy", "layout"):
        if not isinstance(storage.get(key, []), list):
            raise RuleError(f"{where}: {key} must be a list")
    if "verified" in storage:
        verified = storage["verified"]
        if not DATE.match(str(verified.get("date", ""))):
            raise RuleError(f"{where}: verified.date must be YYYY-MM-DD")
        if verified.get("kind", "verified") not in ("verified", "found"):
            raise RuleError(f"{where}: verified.kind is verified or found")
    elif not storage.get("status"):
        raise RuleError(f"{where}: needs verified or status")


def validate_overlaps(entries):
    """One owner for each path. An offered path never holds protected data."""
    seen = {}
    for tool, storage in entries:
        for path in storage_paths(storage):
            if path.startswith("<project>/"):
                continue   # Several tools document the same project folder, such as `vendor`.
            key = tuple(components(path))
            if key in seen:
                raise RuleError(f"{tool['id']}.json: {path} is also in {seen[key]}.json")
            seen[key] = tool["id"]
    rules = [(tool, storage, path) for tool, storage in entries if "table" in storage
             for path in storage_paths(storage)]
    for tool, storage, path in rules:
        if storage["treatment"] == "protect":
            continue
        for other_tool, other, other_path in rules:
            if other["treatment"] == "protect" and covers(path, other_path):
                raise RuleError(
                    f"{tool['id']}.json: {path} is offered, but {other_path} in {other_tool['id']}.json is protected")
        if storage["table"] in HOME_TABLES:
            folder_of(storage, path, rules)


def folder_of(cache, path, rules):
    """The protected folder of the same table that holds a cache. Exactly one must exist."""
    folders = [(folder, folder_path) for _, folder, folder_path in rules
               if folder["table"] == cache["table"] and folder["treatment"] == "protect"
               and covers(folder_path, path) and folder_path != path]
    if len(folders) != 1:
        raise RuleError(f"{path}: a {cache['table']} cache needs one protected folder above it, found {len(folders)}")
    return folders[0]


def storage_paths(storage):
    if "paths" in storage:
        return list(storage["paths"])
    return [storage["path"]] if "path" in storage else []


def components(path):
    """Path components, with `<name>` as `*`, for comparison."""
    return [part for part in re.sub(r"<[^>]+>", "*", path).split("/") if part]


def covers(parent, child):
    """`parent` is `child` or a folder above it. A `*` component matches one component."""
    a, b = components(parent), components(child)
    return len(a) <= len(b) and all(x == y or x == "*" or y == "*" for x, y in zip(a, b))


# MARK: - Rows


def rows(sections, tools):
    """Each storage entry with its tool and its section, in document order."""
    for section_id, section in sections.items():
        for tool_id in section["tools"]:
            tool = tools[tool_id]
            for storage in tool["storage"]:
                yield section_id, tool, storage


def coverage_text(storage):
    if "table" in storage:
        return "Protected" if storage["treatment"] == "protect" else "Row"
    coverage = storage["coverage"]
    return COVERAGE.get(coverage, coverage)


def status_text(storage):
    verified = storage.get("verified")
    if not verified:
        return storage["status"]
    first = f"{verified.get('kind', 'verified').capitalize()} {verified['date']}"
    if verified.get("scope"):
        first += " " + verified["scope"]
    parts = [first]
    if verified.get("tool"):
        parts.append(verified["tool"])
    if verified.get("macos"):
        parts.append(f"macOS {verified['macos']}")
    text = ", ".join(parts)
    if storage.get("status"):
        text += ". " + storage["status"]
    return text


# MARK: - Documents


def render_section(section_id, sections, tools):
    """The table and the notes between the markers of one section."""
    lines = [BEGIN.format(section_id), TABLE_HEADER]
    notes = []
    for tool_id in sections[section_id]["tools"]:
        tool = tools[tool_id]
        notes.extend(storage["note"] for storage in tool["storage"] if storage.get("note"))
        if tool.get("note"):
            notes.append(tool["note"])
    for _, tool, storage in rows({section_id: sections[section_id]}, tools):
        cells = [
            ", ".join(f"`{path}`" for path in storage_paths(storage)),
            TYPES[storage["type"]],
            storage["recognition"],
            storage["removal"],
            storage["restore"],
            coverage_text(storage),
            status_text(storage),
        ]
        lines.append("| " + " | ".join(cells) + " |")
    if notes:
        lines.append("")
        lines.extend(notes)
    lines.append(END.format(section_id))
    return "\n".join(lines)


def apply_section(text, section_id, rendered):
    """Replace the text between the markers of `section_id`. Both markers must exist once."""
    begin, end = BEGIN.format(section_id), END.format(section_id)
    if text.count(begin) != 1 or text.count(end) != 1:
        raise RuleError(f"the document needs one {begin} and one {end}")
    start = text.index(begin)
    stop = text.index(end) + len(end)
    return text[:start] + rendered + text[stop:]


def render_documents(sections, tools, root=ROOT):
    """Each document path with its new text."""
    documents = {}
    for section_id, section in sections.items():
        path = root / section["document"]
        text = documents.get(path, path.read_text())
        documents[path] = apply_section(text, section_id, render_section(section_id, sections, tools))
    return documents


# MARK: - Swift


def swift_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def swift_list(values):
    return "[" + ", ".join(swift_string(value) for value in values) + "]"


def swift_base(path):
    """The base enum case and the path below it."""
    for prefix, base in (("~/", ".home"), ("/opt/homebrew/", ".homebrew"),
                         ("/Users/Shared/", ".sharedFolder"), ("/Applications/", ".applications")):
        if path.startswith(prefix):
            return base, re.sub(r"<[^>]+>", "*", path[len(prefix):])
    raise RuleError(f"{path}: no Swift base for this path")


def render_database_roots(sections, tools):
    lines = []
    for _, tool, storage in rows(sections, tools):
        if storage.get("table") != "databaseStorage":
            continue
        if storage.get("note"):
            lines.append(f"        // {storage['note']}")
        for path in storage_paths(storage):
            base, relative = swift_base(path)
            contents = swift_string(storage["contents"]) if storage.get("contents") else "nil"
            listed = "true" if storage["owner"] == "applications" else "false"
            lines.append(
                f"        Root(path: {swift_string(relative)}, name: {swift_string(storage['name'])}, base: {base}, "
                f"identifiedBy: {swift_list(storage.get('identifiedBy', []))}, tool: {swift_string(tool['name'])}, "
                f"contents: {contents}, listedWithApplication: {listed}),"
            )
    if lines:
        lines[-1] = lines[-1].rstrip(",")
    return "\n".join(lines)


def swift_optional(value):
    return swift_string(value) if value else "nil"


def render_caches(folder_storage, folder_path, table, sections, tools):
    """The `Cache` literals of the offered paths inside one protected folder."""
    caches = []
    for _, _, storage in rows(sections, tools):
        if storage.get("table") != table or storage["treatment"] == "protect":
            continue
        for path in storage_paths(storage):
            if not covers(folder_path, path) or path == folder_path:
                continue
            relative = re.sub(r"<[^>]+>", "*", path[len(folder_path) + 1:])
            marker = (storage.get("identifiedBy") or [None])[0]
            caches.append(
                f"Cache(path: {swift_string(relative)}, marker: {swift_optional(marker)}, "
                f"isRegenerable: {'true' if storage['treatment'] == 'offer' else 'false'}, "
                f"caveat: {swift_optional(storage.get('caveat'))})"
            )
    return "[" + ", ".join(caches) + "]"


def render_tool_home_folders(sections, tools):
    lines = []
    for _, tool, storage in rows(sections, tools):
        if storage.get("table") != "toolHomeFolders" or storage["treatment"] != "protect":
            continue
        for path in storage_paths(storage):
            _, relative = swift_base(path)
            if storage.get("note"):
                lines.append(f"        // {storage['note']}")
            lines.append(
                f"        Folder(name: {swift_string(relative)}, explanation: {swift_string(storage['explanation'])}, "
                f"layout: {swift_list(storage.get('layout', []))}, "
                f"caches: {render_caches(storage, path, 'toolHomeFolders', sections, tools)}),"
            )
    if lines:
        lines[-1] = lines[-1].rstrip(",")
    return "\n".join(lines)


def render_tool_home_locations(sections, tools):
    lines = []
    for _, tool, storage in rows(sections, tools):
        if storage.get("table") != "toolHomeLocations" or storage["treatment"] != "protect":
            continue
        for path in storage_paths(storage):
            base, relative = swift_base(path)
            if storage.get("note"):
                lines.append(f"        // {storage['note']}")
            lines.append(
                f"        Location(path: {swift_string(relative)}, name: {swift_string(storage['name'])}, base: {base}, "
                f"identifiedBy: {swift_list(storage['identifiedBy'])}, explanation: {swift_string(storage['explanation'])}, "
                f"layout: {swift_list(storage.get('layout', []))}, "
                f"caches: {render_caches(storage, path, 'toolHomeLocations', sections, tools)}),"
            )
    if lines:
        lines[-1] = lines[-1].rstrip(",")
    return "\n".join(lines)


def render_package_caches(sections, tools):
    lines = []
    for _, tool, storage in rows(sections, tools):
        if storage.get("table") != "packageManagerCaches" or storage.get("check"):
            continue
        for path in storage_paths(storage):
            _, relative = swift_base(path)
            if storage.get("note"):
                lines.append(f"        // {storage['note']}")
            caveat = f", reviewCaveat: {swift_string(storage['caveat'])}" if storage["treatment"] == "review" else ""
            lines.append(
                f"        CacheRoot(label: {swift_string(storage['name'])}, "
                f"components: {swift_list(relative.split('/'))}{caveat}),"
            )
    if lines:
        lines[-1] = lines[-1].rstrip(",")
    return "\n".join(lines)


def render_go_module_cache(sections, tools):
    """The constant for the rule with `"check": "goModuleCache"`, or nothing when the registry has none."""
    for _, _, storage in rows(sections, tools):
        if storage.get("check") == "goModuleCache":
            path = swift_string(swift_base(storage_paths(storage)[0])[1])
            return ("\n    /// The Go module cache, which `go clean -modcache` removes. "
                    "The rule has `\"check\": \"goModuleCache\"`.\n"
                    f"    static let goModuleCache = {path}\n")
    return ""


def render_application_data_folders(sections, tools):
    lines = []
    seen = set()
    for _, tool, storage in rows(sections, tools):
        if storage.get("table") != "applicationDataFolders" and not storage.get("applicationData"):
            continue
        for identifier in tool["bundleIdentifiers"]:
            if identifier in seen:
                continue
            seen.add(identifier)
            folders = []
            for entry in tool["storage"]:
                if entry.get("table") != "applicationDataFolders" and not entry.get("applicationData"):
                    continue
                for path in storage_paths(entry):
                    _, relative = swift_base(path)
                    identified = entry.get("identifiedBy", []) if entry.get("table") == "applicationDataFolders" else []
                    suffix = f", identifiedBy: {swift_list(identified)}" if identified else ""
                    folders.append(f"Folder(path: {swift_string(relative)}{suffix})")
            if tool.get("note"):
                lines.append(f"        // {tool['note']}")
            lines.append(f"        {swift_string(identifier)}: [{', '.join(folders)}],")
    if lines:
        lines[-1] = lines[-1].rstrip(",")
    return "\n".join(lines)


def render_swift(sections, tools):
    return f"""// Generated by scripts/rules.py from rules/*.json. Do not edit this file.
// Change a rule in rules/<tool>.json, then run `python3 scripts/rules.py generate`.

extension DatabaseStorage {{
    /// Database data folders. Each root comes from a rule with `"table": "databaseStorage"`.
    static let roots: [Root] = [
{render_database_roots(sections, tools)}
    ]
}}

extension ToolHomeFolders {{
    /// Protected home folders. Each folder comes from a rule with `"table": "toolHomeFolders"`.
    /// The caches in a folder come from the offered rules below its path.
    static let all: [Folder] = [
{render_tool_home_folders(sections, tools)}
    ]

    /// Tool storage outside the listed folders. Each location comes from a rule with `"table": "toolHomeLocations"`.
    static let locations: [Location] = [
{render_tool_home_locations(sections, tools)}
    ]
}}

extension PackageManagerScanner {{
    /// Package caches. Each root comes from a rule with `"table": "packageManagerCaches"`.
    /// The roots are pairwise disjoint. `DisjointCategoriesTests` checks this.
    static let roots: [CacheRoot] = [
{render_package_caches(sections, tools)}
    ]
{render_go_module_cache(sections, tools)}}}

extension ApplicationDataFolders {{
    /// Folders by bundle identifier. Each folder comes from a rule with `"table": "applicationDataFolders"`
    /// or `"applicationData": true`, under the `bundleIdentifiers` of its tool.
    static let byBundleIdentifier: [String: [Folder]] = [
{render_application_data_folders(sections, tools)}
    ]
}}
"""


# MARK: - Commands


def outputs(root=ROOT, rules_directory=None):
    """Each generated file path with its text."""
    sections, tools = load(rules_directory or root / "rules")
    files = {root / GENERATED_SWIFT: render_swift(sections, tools)}
    files.update(render_documents(sections, tools, root))
    return files


def generate(root=ROOT):
    for path, text in outputs(root).items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists() or path.read_text() != text:
            path.write_text(text)
            print(f"wrote {path.relative_to(root)}")


def check(root=ROOT):
    """The generated files that differ from the registry."""
    return [path.relative_to(root) for path, text in outputs(root).items()
            if not path.exists() or path.read_text() != text]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["generate", "check"])
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "generate":
            generate()
        else:
            stale = check()
            for path in stale:
                print(f"{path} is out of date. Run python3 scripts/rules.py generate.")
            return 1 if stale else 0
    except RuleError as error:
        print(f"rules: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
