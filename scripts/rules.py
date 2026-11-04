#!/usr/bin/env python3
"""Generate the Swift rule tables and the document tables from rules/*.json.

Usage:
  rules.py generate   Write the generated Swift file and the document tables.
  rules.py check      Fail when a generated file differs from the registry.
  rules.py audit      List tools that are newer than their verification, rules without
                      verification, old verifications, and, with --manifest, paths that
                      no rule covers.

See docs/tool-rules.md for the file format.
"""
import argparse
import datetime
import json
import plistlib
import re
import shutil
import subprocess
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
TABLES = {"databaseStorage", "toolHomeFolders", "toolHomeLocations", "packageManagerCaches", "applicationDataFolders",
          "aiToolStorage", "curations", "localModelStores", "editorExtensionStores"}
FORMATS = {"catalog", "aiCoverage", "bundleIdentifiers"}
AI_COVERAGE_HEADER = "| Tool | Default paths | Removal rules |\n| --- | --- | --- |"
BUNDLE_HEADER = "| Tool | Bundle identifier |\n| --- | --- |"
CHECKS = {"goModuleCache": "packageManagerCaches", "editorObsolete": "editorExtensionStores"}
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
        if section.get("format", "catalog") not in FORMATS:
            raise RuleError(f"sections.json: section {section_id!r} format must be one of {', '.join(sorted(FORMATS))}")
        for tool_id in section["tools"]:
            if tool_id not in tools:
                raise RuleError(f"sections.json: section {section_id!r} names {tool_id!r}, which has no file")
            if section.get("format") == "aiCoverage" and not tools[tool_id].get("removalRules"):
                raise RuleError(f"{tool_id}.json: an AI coverage row needs removalRules")
            if section.get("format") == "bundleIdentifiers":
                if not tools[tool_id].get("bundleIdentifiers") or not tools[tool_id].get("verified", {}).get("tool"):
                    raise RuleError(f"{tool_id}.json: a bundle identifier row needs bundleIdentifiers and verified.tool")
    listed = {tool_id for section in sections.values() for tool_id in section["tools"]}
    placements = {}
    for section_id, section in sections.items():
        for tool_id in section["tools"]:
            key = (tool_id, section.get("format", "catalog"))
            if key in placements:
                raise RuleError(f"sections.json: {tool_id!r} is in {placements[key]!r} and {section_id!r}, which have the same format")
            placements[key] = section_id
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
    command = tool.get("versionCommand")
    if command is not None:
        if not isinstance(command, list) or not 1 <= len(command) <= 3 or not all(isinstance(part, str) for part in command) \
                or not re.match(r"^[a-z][a-z0-9.+-]*$", command[0]) \
                or not all(re.match(r"^(-{1,2}[a-z][a-z-]*|[a-z][a-z.-]*)$", part) for part in command[1:]):
            raise RuleError(f"{name}: versionCommand is an executable name and up to two plain arguments")
    for key in ("aiTool", "owner"):
        if key in tool and not (isinstance(tool[key], dict) and tool[key].get("case") and tool[key].get("rawValue" if key == "aiTool" else "name")):
            raise RuleError(f"{name}: {key} needs case and {'rawValue' if key == 'aiTool' else 'name'}")
    if ("aiTool" in tool) != ("owner" in tool):
        raise RuleError(f"{name}: aiTool and owner come together")
    catalog = sections[tool["section"]].get("format", "catalog") == "catalog"
    for storage in tool["storage"]:
        validate_storage(name, storage, catalog)
        if (storage.get("table") == "applicationDataFolders" or storage.get("applicationData")) and not identifiers:
            raise RuleError(f"{name}: an application data folder needs the tool's bundleIdentifiers")
        if storage.get("table") == "aiToolStorage" and "owner" not in tool:
            raise RuleError(f"{name}: an AI tool root needs the tool's owner and aiTool")
        if storage.get("curated") and not identifiers:
            raise RuleError(f"{name}: a curated root needs the tool's bundleIdentifiers")
        if storage.get("table") == "curations" and storage["treatment"] == "protect" and not identifiers:
            raise RuleError(f"{name}: a curation needs the tool's bundleIdentifiers")


def validate_storage(name, storage, catalog=True):
    """`catalog` is false for a tool in an AI document section, which has no catalog cells."""
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
        if catalog and (not isinstance(storage.get(key), str) or not storage[key]):
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
        if table == "aiToolStorage":
            if treatment != "protect":
                raise RuleError(f"{where}: an AI tool root or part is protected")
            if not storage.get("name"):
                raise RuleError(f"{where}: an AI tool root or part needs the row name")
            section = storage.get("section")
            if section is not None and not (isinstance(section, dict) and section.get("title") and section.get("summary")):
                raise RuleError(f"{where}: section needs title and summary")
            if storage.get("curated") and not storage.get("remainderName"):
                raise RuleError(f"{where}: a curated root needs remainderName")
        if table == "curations":
            if treatment == "protect" and not storage.get("name"):
                raise RuleError(f"{where}: a curation needs the name of its locked remainder")
            if treatment == "review":
                raise RuleError(f"{where}: a curation cache is offered, not reviewed")
        if table == "localModelStores":
            for path in paths:
                if model_claim(path) is None and storage.get("claimed", True):
                    raise RuleError(f"{where}: a model store outside a home dot folder or ~/.cache needs \"claimed\": false")
            if storage.get("store") and not re.match(r"^[a-z][A-Za-z0-9]*$", storage["store"]):
                raise RuleError(f"{where}: store is a Swift constant name")
        if table == "editorExtensionStores":
            if storage.get("check") != "editorObsolete" or treatment != "offer" or not storage.get("name"):
                raise RuleError(f"{where}: an editor store is offered with check editorObsolete and the editor name")
            for path in paths:
                parts = components(path)
                if len(parts) != 3 or parts[2] != "extensions" or not parts[1].startswith("."):
                    raise RuleError(f"{where}: an editor store is ~/.<editor>/extensions")
        if table == "packageManagerCaches" and not storage.get("name"):
            raise RuleError(f"{where}: a package cache needs the row name")
        if "check" in storage and CHECKS.get(storage["check"]) != table:
            raise RuleError(f"{where}: check must be one of {', '.join(sorted(CHECKS))}, for its table")
        if storage["type"] == "userData" and treatment != "protect":
            raise RuleError(f"{where}: user data is never offered")
        if treatment != "protect":
            # A package cache or a curation cache is offered by its path, and a model reader checks its own layout.
            if not storage.get("identifiedBy") and not storage.get("check") \
                    and table not in HOME_TABLES and table not in ("packageManagerCaches", "curations", "localModelStores"):
                raise RuleError(f"{where}: an offered path needs identifiedBy or check")
            if catalog and "verified" not in storage and not str(storage.get("status", "")).startswith("Not verified"):
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
    elif catalog and not storage.get("status"):
        raise RuleError(f"{where}: needs verified or status")


def validate_overlaps(entries):
    """One owner for each path. An offered path never holds protected data."""
    seen = {}
    ai_roots = {(tool["id"], tuple(components(path))) for tool, storage in entries
                if storage.get("table") == "aiToolStorage" for path in storage_paths(storage)}
    for tool, storage in entries:
        for path in storage_paths(storage):
            if path.startswith("<project>/"):
                continue   # Several tools document the same project folder, such as `vendor`.
            key = tuple(components(path))
            if storage.get("table") == "curations" and storage["treatment"] == "protect" and (tool["id"], key) in ai_roots:
                continue   # A curation of a desktop application can share the path of the tool's AI root.
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
        if storage["table"] in HOME_TABLES or storage["table"] == "curations":
            folder_of(storage, path, rules)
    for tool, storage, path in rules:
        if storage["treatment"] == "protect" and storage["table"] == "aiToolStorage" and is_part(storage, path, rules):
            if not storage.get("explanation"):
                raise RuleError(f"{path}: an AI tool part needs an explanation")
            if storage.get("section") or storage.get("curated") or storage.get("identifiedBy"):
                raise RuleError(f"{path}: an AI tool part has no section, curation, or identifiedBy")
        elif storage["treatment"] == "protect" and storage["table"] == "aiToolStorage" and not storage.get("section"):
            raise RuleError(f"{path}: an AI tool root needs a section")


def holds_cache(folder, folder_table, cache_table):
    """A folder of the same table holds a cache. A curated AI root also holds curation caches."""
    if folder_table == cache_table:
        return True
    return cache_table == "curations" and folder_table == "aiToolStorage" and folder.get("curated")


def folder_of(cache, path, rules):
    """The protected folder that holds a cache. Exactly one must exist."""
    folders = [(folder, folder_path) for _, folder, folder_path in rules
               if folder["treatment"] == "protect" and holds_cache(folder, folder["table"], cache["table"])
               and covers(folder_path, path) and folder_path != path]
    if len(folders) != 1:
        raise RuleError(f"{path}: a {cache['table']} cache needs one protected folder above it, found {len(folders)}")
    return folders[0]


def is_part(storage, path, rules):
    """An AI tool entry below another AI tool root is a part of that root."""
    return any(other["table"] == "aiToolStorage" and other_path != path and covers(other_path, path)
               for _, other, other_path in rules if "table" in other)


def ai_root_of(part_path, roots):
    """The nearest AI root above a part path."""
    above = [root_path for root_path in roots if covers(root_path, part_path) and root_path != part_path]
    return max(above, key=lambda root_path: len(components(root_path)))


def model_claim(path):
    """How `LocalModelStores` claims a path: a whole home dot folder, a whole `~/.cache` child, or part of a folder."""
    parts = components(path)[1:]   # Without the `~`.
    if not parts or not parts[0].startswith("."):
        return None
    if len(parts) == 1:
        return ("home", parts[0])
    if len(parts) == 2 and parts[0] == ".cache":
        return ("cache", parts[1])
    return ("part", "/".join(parts[:-1]), parts[-1])


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
    """Each storage entry with its tool and its section, in document order. A tool in two sections comes once."""
    seen = set()
    for section_id, section in sections.items():
        for tool_id in section["tools"]:
            if tool_id in seen:
                continue
            seen.add(tool_id)
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


def rule_paths(tool, sections, tools):
    """The paths of a tool that its document row lists: roots and rows, not parts."""
    all_rules = [(other, storage, path) for _, other, storage in rows(sections, tools) if "table" in storage
                 for path in storage_paths(storage)]
    paths = []
    for storage in tool["storage"]:
        for path in storage_paths(storage):
            if storage.get("table") == "aiToolStorage" and is_part(storage, path, all_rules):
                continue
            if storage.get("table") == "curations" and storage["treatment"] != "protect":
                continue
            if path not in paths:
                paths.append(path)
    return paths


def render_rows(section_id, sections, tools):
    """The header and the rows of one section, in its format."""
    section = sections[section_id]
    fmt = section.get("format", "catalog")
    if fmt == "aiCoverage":
        lines = [AI_COVERAGE_HEADER]
        for tool_id in section["tools"]:
            tool = tools[tool_id]
            paths = ", ".join(f"`{path}`" for path in rule_paths(tool, sections, tools))
            lines.append(f"| {tool.get('documentName', tool['name'])} | {paths} | {tool['removalRules']} |")
        return lines
    if fmt == "bundleIdentifiers":
        lines = [BUNDLE_HEADER]
        for tool_id in section["tools"]:
            tool = tools[tool_id]
            lines.append(f"| {tool['verified']['tool']} | `{tool['bundleIdentifiers'][0]}` |")
        return lines
    lines = [TABLE_HEADER]
    for _, tool, storage in rows({section_id: section}, tools):
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
    return lines


def render_section(section_id, sections, tools):
    """The table and the notes between the markers of one section."""
    lines = [BEGIN.format(section_id)] + render_rows(section_id, sections, tools)
    notes = []
    for tool_id in sections[section_id]["tools"]:
        tool = tools[tool_id]
        notes.extend(storage["note"] for storage in tool["storage"] if storage.get("note"))
        if tool.get("note"):
            notes.append(tool["note"])
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


def swift_bool(value):
    return "true" if value else "false"


def ai_rules(sections, tools):
    return [(tool, storage, path) for _, tool, storage in rows(sections, tools)
            if storage.get("table") == "aiToolStorage" for path in storage_paths(storage)]


def render_ai_roots(sections, tools):
    entries = ai_rules(sections, tools)
    root_paths = [path for _, storage, path in entries if not is_part(storage, path, [(t, s, p) for t, s, p in entries])]
    lines = []
    for tool, storage, path in entries:
        if path not in root_paths:
            continue
        base, relative = swift_base(path)
        parts = []
        for _, part, part_path in entries:
            if part_path in root_paths or ai_root_of(part_path, root_paths) != path:
                continue
            _, part_relative = swift_base(part_path)
            part_relative = part_relative[len(relative) + 1:]
            parts.append(f"Part(path: {swift_string(part_relative)}, name: {swift_string(part['name'])}, "
                         f"explanation: {swift_string(part['explanation'])})")
        if storage.get("note"):
            lines.append(f"        // {storage['note']}")
        arguments = [f"path: {swift_string(relative)}", f"name: {swift_string(storage['name'])}",
                     f"section: .init(owner: .{tool['owner']['case']}, title: {swift_string(storage['section']['title'])}, "
                     f"summary: {swift_string(storage['section']['summary'])})"]
        if base != ".home":
            arguments.append(f"base: {base}")
        if storage.get("explanation"):
            arguments.append(f"explanation: {swift_string(storage['explanation'])}")
        if storage.get("curated"):
            arguments.append(f"curationIdentifier: {swift_string(tool['bundleIdentifiers'][0])}")
        if storage.get("reviewsWorktrees") is False:
            arguments.append("reviewsWorktrees: false")
        if storage.get("identifiedBy"):
            arguments.append(f"identifiedBy: {swift_list(storage['identifiedBy'])}")
        if parts:
            arguments.append("parts: [\n            " + ",\n            ".join(parts) + "\n        ]")
        lines.append("        Root(" + ", ".join(arguments) + "),")
    if lines:
        lines[-1] = lines[-1].rstrip(",")
    return "\n".join(lines)


def render_curations(sections, tools):
    lines = []
    all_rules = [(tool, storage, path) for _, tool, storage in rows(sections, tools) if "table" in storage
                 for path in storage_paths(storage)]
    for tool, storage, path in all_rules:
        is_root = (storage["table"] == "curations" and storage["treatment"] == "protect") \
            or (storage["table"] == "aiToolStorage" and storage.get("curated"))
        if not is_root:
            continue
        _, relative = swift_base(path)
        caches = []
        for _, cache, cache_path in all_rules:
            if cache["table"] == "curations" and cache["treatment"] == "offer" and covers(path, cache_path) and cache_path != path:
                _, cache_relative = swift_base(cache_path)
                caches.append(cache_relative[len(relative) + 1:])
        regenerable = swift_list(caches)
        if storage.get("electronCaches"):
            regenerable = "electronRegenerable + " + regenerable if caches else "electronRegenerable"
        remainder = storage["remainderName"] if storage["table"] == "aiToolStorage" else storage["name"]
        if storage.get("note") and storage["table"] == "curations":
            lines.append(f"        // {storage['note']}")
        lines.append(f"        {swift_string(tool['bundleIdentifiers'][0])}: AppDataCuration(root: {swift_string(relative)}, "
                     f"regenerable: {regenerable}, remainderName: {swift_string(remainder)}),")
    if lines:
        lines[-1] = lines[-1].rstrip(",")
    return "\n".join(lines)


def ai_tools(sections, tools):
    """Each AI tool case once, in section order, with its raw value and icon padding."""
    seen = {}
    for _, tool, _ in rows(sections, tools):
        if "aiTool" in tool:
            case = tool["aiTool"]["case"]
            entry = (tool["aiTool"]["rawValue"], bool(tool["aiTool"].get("paddedIcon")))
            if seen.setdefault(case, entry) != entry:
                raise RuleError(f"{tool['id']}.json: aiTool {case!r} differs from another file")
    return seen


def owners(sections, tools):
    """Each owner once, in section order."""
    seen = {}
    for _, tool, _ in rows(sections, tools):
        if "owner" in tool:
            case = tool["owner"]["case"]
            entry = (tool["owner"]["name"], tool["aiTool"]["case"])
            if seen.setdefault(case, entry) != entry:
                raise RuleError(f"{tool['id']}.json: owner {case!r} differs from another file")
    return seen


def icon_identifiers(sections, tools):
    """The first bundle identifier of each AI tool, from the first tool file that has one."""
    identifiers = {}
    for _, tool, _ in rows(sections, tools):
        if "aiTool" in tool and tool.get("bundleIdentifiers"):
            identifiers.setdefault(tool["aiTool"]["case"], tool["bundleIdentifiers"][0])
    return identifiers


def render_enums(sections, tools):
    cases = ai_tools(sections, tools)
    owner_cases = owners(sections, tools)
    if not cases:
        return ""
    tool_lines = "\n".join(f"        case {case} = {swift_string(raw)}" for case, (raw, _) in cases.items())
    owner_lines = "\n".join(f"        case {case} = {swift_string(name)}" for case, (name, _) in owner_cases.items())
    switch_lines = "\n".join(f"            case .{case}: .{tool}" for case, (_, tool) in owner_cases.items())
    identifiers = icon_identifiers(sections, tools)
    identifier_lines = "\n".join(f"        .{case}: {swift_string(identifier)}," for case, identifier in identifiers.items()).rstrip(",")
    padded = ", ".join(f".{case}" for case, (_, is_padded) in cases.items() if is_padded)
    return f"""
extension FileEntry {{
    /// Identifies the tool icon without changing storage ownership or removal rules.
    /// Each case comes from the `aiTool` of a tool file.
    public enum AITool: String, Sendable, CaseIterable {{
{tool_lines}
    }}
}}

extension AIStorageSection {{
    /// The heading that groups the storage of one tool. Each case comes from the `owner` of a tool file.
    public enum Owner: String, Sendable {{
{owner_lines}

        public var tool: FileEntry.AITool {{
            switch self {{
{switch_lines}
            }}
        }}
    }}
}}

/// The desktop application of each AI tool, for its icon.
public enum ToolIcons {{
    /// The first bundle identifier of the first tool file with the tool.
    public static let bundleIdentifiers: [FileEntry.AITool: String] = [
{identifier_lines}
    ]

    /// Tools whose bundled fallback icon already includes the padding of an application icon.
    public static let paddedFallbacks: Set<FileEntry.AITool> = [{padded}]
}}
"""


def render_model_stores(sections, tools):
    home, cache, part, stores = [], [], {}, {}
    for _, tool, storage in rows(sections, tools):
        if storage.get("table") != "localModelStores":
            continue
        for path in storage_paths(storage):
            if storage.get("claimed", True):
                claim = model_claim(path)
                if claim[0] == "home":
                    home.append(claim[1])
                elif claim[0] == "cache":
                    cache.append(claim[1])
                else:
                    part.setdefault(claim[1], []).append(claim[2])
            if storage.get("store"):
                stores.setdefault(storage["store"], []).append(swift_base(path)[1])
    part_lines = ", ".join(f"{swift_string(folder)}: [{', '.join(swift_string(c) for c in children)}]" for folder, children in part.items())
    store_lines = "\n".join(f"    static let {name}Stores: [String] = {swift_list(paths)}" for name, paths in stores.items())
    return f"""    /// Home dot folders that the model readers claim whole.
    public static let homeDotFolders: Set<String> = [{', '.join(swift_string(n) for n in home)}]
    /// Children of `~/.cache` that the model readers claim whole.
    public static let dotCacheFolders: Set<String> = [{', '.join(swift_string(n) for n in cache)}]
    /// Folders that the model readers claim in part, with the claimed child names.
    public static let partlyClaimedFolders: [String: Set<String>] = [{part_lines or ':'}]
{store_lines}"""


def render_editors(sections, tools):
    lines = []
    for _, tool, storage in rows(sections, tools):
        if storage.get("table") != "editorExtensionStores":
            continue
        for path in storage_paths(storage):
            dot_folder = components(path)[1]
            lines.append(f"        Editor(name: {swift_string(storage['name'])}, dotFolder: {swift_string(dot_folder)}, "
                         f"bundleIdentifier: {swift_string(tool['bundleIdentifiers'][0])}),")
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

extension AIToolStorage {{
    /// AI tool storage. Each root comes from a rule with `"table": "aiToolStorage"`. A rule below a root is one of its parts.
    static let roots: [Root] = [
{render_ai_roots(sections, tools)}
    ]
}}

extension ApplicationsScanner {{
    /// Apps whose layout the Electron rule does not describe. Each curation comes from a rule with
    /// `"table": "curations"`, or from a curated AI tool root. The caches below it are the regenerable paths.
    static let curations: [String: AppDataCuration] = [
{render_curations(sections, tools)}
    ]
}}

extension LocalModelStores {{
    // Each path comes from a rule with `"table": "localModelStores"`. A `store` names the constant that its reader uses.
{render_model_stores(sections, tools)}
}}

extension EditorExtensionStores {{
    /// VS Code–family editors. Each editor comes from a rule with `"table": "editorExtensionStores"`.
    public static let editors: [Editor] = [
{render_editors(sections, tools)}
    ]
}}
{render_enums(sections, tools)}"""


# MARK: - Audit

VERSION = re.compile(r"\d+(?:\.\d+)+")
APPLICATION_FOLDERS = [Path("/Applications"), Path.home() / "Applications"]


def version_in(text):
    """The first version number in a text, as a tuple of integers, or None."""
    match = VERSION.search(text or "")
    return tuple(int(part) for part in match.group(0).split(".")) if match else None


def installed_applications(folders=None):
    """Bundle identifier to version, read from the `Info.plist` of each application bundle."""
    versions = {}
    for folder in folders or APPLICATION_FOLDERS:
        for bundle in sorted(folder.glob("*.app")) if folder.is_dir() else []:
            info = bundle / "Contents" / "Info.plist"
            try:
                plist = plistlib.loads(info.read_bytes())
            except (OSError, plistlib.InvalidFileException, ValueError):
                continue
            identifier, version = plist.get("CFBundleIdentifier"), plist.get("CFBundleShortVersionString")
            if identifier and version:
                versions.setdefault(identifier, str(version))
    return versions


def command_version(command, which=shutil.which, run=subprocess.run):
    """The version that a tool's command prints, or None when the tool is absent or silent."""
    executable = which(command[0])
    if not executable:
        return None
    try:
        result = run([executable] + command[1:], capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return (result.stdout or "") + (result.stderr or "")


def verifications(tool):
    """Each verification of a tool: date and version tuple, newest first."""
    records = [tool["verified"]] if tool.get("verified") else []
    records += [storage["verified"] for storage in tool["storage"] if storage.get("verified")]
    found = [(datetime.date.fromisoformat(record["date"]), version_in(record.get("tool"))) for record in records]
    return sorted(found, key=lambda item: item[0], reverse=True)


def unverified_rules(tool):
    """Offered rules of a tool with no verification record."""
    return [path for storage in tool["storage"] if "table" in storage and storage["treatment"] != "protect"
            and not storage.get("verified") for path in storage_paths(storage)]


def uncovered_paths(lines, tools):
    """Manifest entries directly below a root with deeper rules, where no deeper rule names the entry.

    A root with no rule is one line. A root whose rule has no deeper rule covers everything below it.
    """
    rule_paths = [path for tool in tools.values() for storage in tool["storage"] if "table" in storage
                  for path in storage_paths(storage)]
    roots, children = [], {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        entry = json.loads(line)
        if "root" not in entry or entry.get("summary") or entry.get("missing"):
            continue
        root = entry["root"]
        if root not in roots:
            roots.append(root)
        if "path" in entry and "/" not in entry["path"]:
            children.setdefault(root, []).append(entry["path"])
    report = []
    for root in roots:
        covering = [path for path in rule_paths if covers(path, root)]
        if not covering:
            report.append((root, None))
            continue
        deeper = [path for path in rule_paths if covers(root, path) and components(path) != components(root)]
        if not deeper:
            continue
        for child in children.get(root, []):
            full = root.rstrip("/") + "/" + child
            if not any(covers(path, full) or covers(full, path) for path in deeper):
                report.append((root, child))
    return report


def audit(sections, tools, applications=None, which=shutil.which, run=subprocess.run, manifest=None,
          today=None, older_than=180):
    """The audit report: newer tools, unverified rules, old verifications, and uncovered manifest paths."""
    applications = installed_applications() if applications is None else applications
    today = today or datetime.date.today()
    report = {"newer": [], "unverified": [], "old": [], "uncovered": [], "unknown": []}
    for _, tool, _ in rows(sections, tools):
        if any(entry[0] == tool["id"] for entry in report["unverified"] + report["old"] + report["newer"] + report["unknown"]):
            continue
        checks = verifications(tool)
        installed = None
        for identifier in tool.get("bundleIdentifiers", []):
            if identifier in applications:
                installed = version_in(applications[identifier])
        if installed is None and tool.get("versionCommand"):
            installed = version_in(command_version(tool["versionCommand"], which, run))
        if installed is not None:
            verified = [version for _, version in checks if version]
            if not verified:
                report["unknown"].append((tool["id"], ".".join(map(str, installed))))
            elif installed > max(verified):
                report["newer"].append((tool["id"], ".".join(map(str, installed)), ".".join(map(str, max(verified)))))
        for path in unverified_rules(tool):
            report["unverified"].append((tool["id"], path))
        if checks and (today - checks[0][0]).days > older_than:
            report["old"].append((tool["id"], checks[0][0].isoformat()))
    if manifest is not None:
        report["uncovered"] = uncovered_paths(manifest, tools)
    return report


def format_audit(report):
    lines = []
    if report["newer"]:
        lines.append("Tools that are newer than their verification:")
        lines += [f"  {tool}: installed {installed}, verified {verified}" for tool, installed, verified in report["newer"]]
    if report["unknown"]:
        lines.append("Installed tools with no version in their verification:")
        lines += [f"  {tool}: installed {installed}" for tool, installed in report["unknown"]]
    if report["unverified"]:
        lines.append("Offered rules without a verification record:")
        lines += [f"  {tool}: {path}" for tool, path in report["unverified"]]
    if report["old"]:
        lines.append("Tools whose last verification is old:")
        lines += [f"  {tool}: {date}" for tool, date in report["old"]]
    if report["uncovered"]:
        lines.append("Manifest paths that no rule covers:")
        lines += [f"  {root}: no rule" if child is None else f"  {root}/{child}" for root, child in report["uncovered"]]
    return "\n".join(lines) if lines else "Nothing to report."


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
    parser.add_argument("command", choices=["generate", "check", "audit"])
    parser.add_argument("--manifest", type=Path, help="A JSON Lines layout manifest from scripts/manifest.py")
    parser.add_argument("--older-than", type=int, default=180, help="Days after which a verification is old")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "generate":
            generate()
        elif arguments.command == "audit":
            sections, tools = load()
            manifest = arguments.manifest.read_text().splitlines() if arguments.manifest else None
            print(format_audit(audit(sections, tools, manifest=manifest, older_than=arguments.older_than)))
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
