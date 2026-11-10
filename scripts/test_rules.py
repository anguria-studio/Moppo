"""Check the rule registry generator."""
import datetime
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("rules", Path(__file__).with_name("rules.py"))
RULES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RULES)


def storage(**changes):
    entry = {
        "path": "/opt/homebrew/var/mysql",
        "type": "userData",
        "table": "databaseStorage",
        "owner": "hiddenSystemData",
        "treatment": "protect",
        "name": "MySQL data",
        "identifiedBy": ["ibdata1", "mysql/"],
        "recognition": "`ibdata1` or `mysql` folder",
        "removal": "Never offer",
        "restore": "Not possible",
        "verified": {"date": "2026-11-02", "tool": "MySQL 26.10", "macos": "27.2"},
    }
    entry.update(changes)
    for key in [key for key, value in entry.items() if value is None]:
        del entry[key]
    return entry


def tool(**changes):
    entry = {"id": "mysql", "name": "MySQL", "section": "databases", "storage": [storage()]}
    entry.update(changes)
    return entry


SECTIONS = {"databases": {"title": "Databases", "document": "docs/tool-catalog.md", "tools": ["mysql"]}}


class ValidationTests(unittest.TestCase):
    def rejects(self, message, tools=None, sections=SECTIONS):
        with self.assertRaises(RULES.RuleError) as raised:
            RULES.validate(sections, tools if tools is not None else {"mysql": tool()})
        self.assertIn(message, str(raised.exception))

    def test_accepts_a_complete_rule(self):
        RULES.validate(SECTIONS, {"mysql": tool()})

    def test_a_tool_is_in_one_section_of_a_format(self):
        sections = {"databases": SECTIONS["databases"], "other": {**SECTIONS["databases"], "title": "Other"}}
        self.rejects("same format", {"mysql": tool()}, sections)

    def test_section_must_list_each_tool(self):
        self.rejects("does not list this tool", {"mysql": tool(), "redis": tool(id="redis", name="Redis")})

    def test_unknown_values(self):
        self.rejects("type must be", {"mysql": tool(storage=[storage(type="junk")])})
        self.rejects("owner must be", {"mysql": tool(storage=[storage(owner="junk")])})
        self.rejects("treatment must be", {"mysql": tool(storage=[storage(treatment="junk")])})
        self.rejects("table must be", {"mysql": tool(storage=[storage(table="junk")])})
        self.rejects("coverage must be", {"mysql": tool(storage=[storage(table=None, owner=None, treatment=None, coverage="junk")])})

    def test_a_rule_computes_its_coverage(self):
        self.rejects("Remove coverage", {"mysql": tool(storage=[storage(coverage="no")])})

    def test_user_data_is_never_offered(self):
        self.rejects("never offered", {"mysql": tool(storage=[storage(treatment="offer")])})

    def test_an_offered_path_needs_evidence(self):
        cache = storage(path="~/.cache/example", type="cache", identifiedBy=[], verified=None, status="Not verified.")
        self.rejects("needs identifiedBy or check", {"mysql": tool(storage=[storage(), {**cache, "treatment": "offer"}])})
        cache["identifiedBy"] = ["CACHEDIR.TAG"]
        # A status that starts with "Not verified" records the gap. Any other text is not evidence.
        RULES.validate(SECTIONS, {"mysql": tool(storage=[storage(), {**cache, "treatment": "offer"}])})
        self.rejects("needs a verified record", {"mysql": tool(storage=[storage(), {**cache, "treatment": "offer", "status": "Unknown."}])})

    def test_a_path_has_one_owner(self):
        self.rejects("is also in", {
            "mysql": tool(),
            "mariadb": tool(id="mariadb", name="MariaDB", storage=[storage(name="MariaDB data")]),
        }, {"databases": {**SECTIONS["databases"], "tools": ["mysql", "mariadb"]}})

    def test_project_folders_may_repeat_across_tools(self):
        vendor = storage(path="<project>/vendor", type="download", table=None, owner=None, treatment=None, coverage="row")
        RULES.validate({"databases": {**SECTIONS["databases"], "tools": ["mysql", "mariadb"]}}, {
            "mysql": tool(storage=[storage(), vendor]),
            "mariadb": tool(id="mariadb", name="MariaDB", storage=[dict(vendor)]),
        })

    def test_an_offered_folder_never_holds_protected_data(self):
        offered = storage(path="/opt/homebrew/var", type="cache", treatment="offer", identifiedBy=["x"], name="Var")
        self.rejects("is protected", {"mysql": tool(storage=[storage(), offered])})

    def test_placeholders_match_one_component(self):
        self.assertTrue(RULES.covers("/opt/homebrew/var/postgresql@<version>", "/opt/homebrew/var/postgresql@*/base"))
        self.assertTrue(RULES.covers("~/.rustup", "~/.rustup/toolchains/<name>"))
        self.assertFalse(RULES.covers("~/.rustup/toolchains", "~/.rustup"))
        self.assertFalse(RULES.covers("~/.cabal", "~/.cache/cabal"))

    def test_verified_record(self):
        self.rejects("verified.date", {"mysql": tool(storage=[storage(verified={"date": "yesterday", "tool": "x"})])})
        self.rejects("needs verified or status", {"mysql": tool(storage=[storage(verified=None)])})

    def test_container_cache_requires_verification_and_matching_bundle(self):
        cache = storage(
            path="~/Library/Containers/org.example.app/Data/Library/WebKit/WebsiteDataStore/*/NetworkCache",
            type="cache", table="containerCaches", owner="systemCaches", treatment="offer",
            name="Network cache", identifiedBy=None, removal="Trash", restore="Next launch"
        )
        app = tool(bundleIdentifiers=["org.example.app"], storage=[cache])
        RULES.validate(SECTIONS, {"mysql": app})
        self.rejects("below its bundle", {"mysql": {**app, "bundleIdentifiers": ["org.other.app"]}})
        found = {**cache, "verified": {**cache["verified"], "kind": "found"}}
        self.rejects("needs a name and verified record", {"mysql": {**app, "storage": [found]}})


class TableTests(unittest.TestCase):
    def test_package_caches_and_the_go_module_cache(self):
        tools = {"mysql": tool(storage=[
            storage(path="~/.npm/_cacache", type="cache", table="packageManagerCaches", owner="packageManagers",
                    treatment="offer", name="npm cache", identifiedBy=None, verified=None, status="Not verified. Old rule."),
            storage(path="~/.cache/cabal", type="download", table="packageManagerCaches", owner="packageManagers",
                    treatment="review", name="Cabal packages (XDG)", identifiedBy=None, caveat="cabal update downloads it again."),
            storage(path="~/go/pkg/mod", type="download", table="packageManagerCaches", owner="packageManagers",
                    treatment="review", name="Go module cache", identifiedBy=None, check="goModuleCache"),
        ])}
        RULES.validate(SECTIONS, tools)
        swift = RULES.render_swift(SECTIONS, tools)
        self.assertIn('CacheRoot(label: "npm cache", components: [".npm", "_cacache"]),', swift)
        self.assertIn('CacheRoot(label: "Cabal packages (XDG)", components: [".cache", "cabal"], '
                      'reviewCaveat: "cabal update downloads it again.")\n', swift)
        self.assertIn('static let goModuleCache = "go/pkg/mod"', swift)
        with self.assertRaises(RULES.RuleError):
            RULES.validate(SECTIONS, {"mysql": tool(storage=[storage(check="goModuleCache")])})

    def test_application_data_folders(self):
        app = tool(id="dbeaver", name="DBeaver", bundleIdentifiers=["org.jkiss.dbeaver.core.product"], storage=[
            storage(path="~/Library/DBeaverData", name="DBeaver data", applicationData=True),
            storage(path="~/dbeaver", type="userData", table="applicationDataFolders", owner="applications",
                    treatment="protect", identifiedBy=["workspace"], verified=None, status="Found."),
        ])
        sections = {"databases": {**SECTIONS["databases"], "tools": ["dbeaver"]}}
        RULES.validate(sections, {"dbeaver": app})
        swift = RULES.render_swift(sections, {"dbeaver": app})
        self.assertIn('"org.jkiss.dbeaver.core.product": [Folder(path: "Library/DBeaverData"), '
                      'Folder(path: "dbeaver", identifiedBy: ["workspace"])]', swift)
        with self.assertRaises(RULES.RuleError):
            RULES.validate(sections, {"dbeaver": {**app, "bundleIdentifiers": []}})
        with self.assertRaises(RULES.RuleError):
            RULES.validate(sections, {"dbeaver": {**app, "storage": [storage(table=None, owner=None, treatment=None, coverage="no", applicationData=True)]}})


class AITableTests(unittest.TestCase):
    SECTIONS = {
        "ai-tools": {"title": "Current coverage", "document": "docs/ai-storage.md", "format": "aiCoverage", "tools": ["claude-desktop", "claude-code"]},
        "ai-identifiers": {"title": "Identifiers", "document": "docs/ai-storage.md", "format": "bundleIdentifiers", "tools": ["claude-desktop"]},
    }

    def tools(self):
        root = {"path": "~/Library/Application Support/Claude", "type": "userData", "table": "aiToolStorage", "owner": "aiTools",
                "treatment": "protect", "name": "Claude desktop data", "curated": True, "remainderName": "Claude settings and data",
                "electronCaches": True, "section": {"title": "Desktop data", "summary": "Desktop profiles and caches."}}
        part = {"path": "~/Library/Application Support/Claude/vm_bundles/*/rootfs.img", "type": "userData", "table": "aiToolStorage",
                "owner": "aiTools", "treatment": "protect", "name": "Claude VM system disk", "explanation": "Linux and tools."}
        cache = {"path": "~/Library/Application Support/Claude/Partitions/*/Cache", "type": "cache", "table": "curations",
                 "owner": "applications", "treatment": "offer"}
        code = {"path": "~/.claude", "type": "userData", "table": "aiToolStorage", "owner": "aiTools", "treatment": "protect",
                "name": "Claude Code data", "reviewsWorktrees": False, "explanation": "Protected.",
                "section": {"title": "Task data", "summary": "Conversations."}}
        return {
            "claude-desktop": {"id": "claude-desktop", "name": "Claude", "documentName": "Claude desktop", "section": "ai-tools",
                               "aiTool": {"case": "claude", "rawValue": "Claude"}, "owner": {"case": "claude", "name": "Claude"},
                               "bundleIdentifiers": ["com.anthropic.claudefordesktop"], "removalRules": "Caches are selectable.",
                               "verified": {"date": "2026-11-03", "kind": "found", "tool": "Claude 2.31", "macos": "27.2"},
                               "storage": [root, part, cache]},
            "claude-code": {"id": "claude-code", "name": "Claude Code", "section": "ai-tools",
                            "aiTool": {"case": "claude", "rawValue": "Claude"}, "owner": {"case": "claudeCode", "name": "Claude Code"},
                            "removalRules": "Everything stays protected.", "storage": [code]},
        }

    def test_roots_parts_curations_and_enums(self):
        tools = self.tools()
        RULES.validate(self.SECTIONS, tools)
        swift = RULES.render_swift(self.SECTIONS, tools)
        self.assertIn('Root(path: "Library/Application Support/Claude", name: "Claude desktop data", '
                      'section: .init(owner: .claude, title: "Desktop data", summary: "Desktop profiles and caches."), '
                      'curationIdentifier: "com.anthropic.claudefordesktop", parts: [\n'
                      '            Part(path: "vm_bundles/*/rootfs.img", name: "Claude VM system disk", explanation: "Linux and tools.")\n'
                      '        ]),', swift)
        self.assertIn('Root(path: ".claude", name: "Claude Code data", section: .init(owner: .claudeCode, title: "Task data", '
                      'summary: "Conversations."), explanation: "Protected.", reviewsWorktrees: false)', swift)
        self.assertIn('"com.anthropic.claudefordesktop": AppDataCuration(root: "Library/Application Support/Claude", '
                      'regenerable: electronRegenerable + ["Partitions/*/Cache"], remainderName: "Claude settings and data")', swift)
        self.assertIn('        case claude = "Claude"\n', swift)
        self.assertIn('        case claudeCode = "Claude Code"\n', swift)
        self.assertIn('            case .claudeCode: .claude\n', swift)
        self.assertIn('        .claude: "com.anthropic.claudefordesktop"', swift)
        self.assertIn('paddedFallbacks: Set<FileEntry.AITool> = []', swift)

    def test_a_curation_can_share_the_path_of_the_ai_root(self):
        tools = self.tools()
        tools["claude-code"]["bundleIdentifiers"] = ["com.anthropic.claudecode"]
        tools["claude-code"]["storage"].append({"path": "~/.claude", "type": "userData", "table": "curations", "owner": "applications",
                                                "treatment": "protect", "name": "Claude Code settings and data"})
        RULES.validate(self.SECTIONS, tools)
        swift = RULES.render_swift(self.SECTIONS, tools)
        self.assertIn('"com.anthropic.claudecode": AppDataCuration(root: ".claude", regenerable: [], remainderName: "Claude Code settings and data")', swift)
        self.assertEqual(RULES.rule_paths(tools["claude-code"], self.SECTIONS, tools), ["~/.claude"])
        tools["claude-code"]["storage"].append({"path": "~/.claude", "type": "userData", "coverage": "protected"})
        with self.assertRaises(RULES.RuleError):
            RULES.validate(self.SECTIONS, tools)

    def test_ai_documents(self):
        tools = self.tools()
        tools["claude-desktop"]["note"] = "A note in the Notes column."
        coverage = RULES.render_section("ai-tools", self.SECTIONS, tools)
        self.assertIn("| Tool | Default paths | Removal rules | Notes |", coverage)
        self.assertIn("| Claude desktop | `~/Library/Application Support/Claude` | Caches are selectable. | A note in the Notes column. |", coverage)
        self.assertIn("| Claude Code | `~/.claude` | Everything stays protected. |  |", coverage)
        self.assertNotIn("**Claude desktop.**", coverage)
        identifiers = RULES.render_section("ai-identifiers", self.SECTIONS, tools)
        self.assertIn("| Claude 2.31 | `com.anthropic.claudefordesktop` |", identifiers)
        self.assertNotIn("A note in the Notes column.", identifiers)

    def test_ai_rules_need_their_fields(self):
        tools = self.tools()
        del tools["claude-code"]["owner"]
        with self.assertRaises(RULES.RuleError):
            RULES.validate(self.SECTIONS, tools)
        tools = self.tools()
        del tools["claude-desktop"]["storage"][0]["section"]
        with self.assertRaises(RULES.RuleError):
            RULES.validate(self.SECTIONS, tools)
        tools = self.tools()
        tools["claude-code"]["aiTool"]["rawValue"] = "Other"
        with self.assertRaises(RULES.RuleError):
            RULES.render_swift(self.SECTIONS, tools)


class StoreTests(unittest.TestCase):
    def test_model_stores_and_editors(self):
        sections = {"ai-tools": {"title": "Coverage", "document": "docs/ai-storage.md", "format": "aiCoverage", "tools": ["whisper", "vscode"]}}
        tools = {
            "whisper": {"id": "whisper", "name": "Whisper", "section": "ai-tools", "removalRules": "One row for each model file.",
                        "aiTool": {"case": "whisper", "rawValue": "Whisper"}, "owner": {"case": "whisper", "name": "Whisper"},
                        "storage": [
                            {"path": "~/.cache/whisper", "type": "download", "table": "localModelStores", "owner": "aiTools",
                             "treatment": "review", "store": "whisper"},
                            {"path": "~/.ollama", "type": "download", "table": "localModelStores", "owner": "aiTools", "treatment": "protect"},
                            {"path": "~/.keras/models", "type": "download", "table": "localModelStores", "owner": "aiTools",
                             "treatment": "review", "store": "keras"},
                            {"path": "~/Library/Application Support/nomic.ai/GPT4All", "type": "download", "table": "localModelStores",
                             "owner": "aiTools", "treatment": "review", "store": "gpt4All", "claimed": False},
                        ]},
            "vscode": {"id": "vscode", "name": "Visual Studio Code", "section": "ai-tools", "removalRules": "Old versions.",
                       "bundleIdentifiers": ["com.microsoft.VSCode"],
                       "storage": [{"path": "~/.vscode/extensions", "type": "installed", "table": "editorExtensionStores",
                                    "owner": "packageManagers", "treatment": "offer", "check": "editorObsolete", "name": "Visual Studio Code"}]},
        }
        RULES.validate(sections, tools)
        swift = RULES.render_swift(sections, tools)
        self.assertIn('public static let homeDotFolders: Set<String> = [".ollama"]', swift)
        self.assertIn('public static let dotCacheFolders: Set<String> = ["whisper"]', swift)
        self.assertIn('public static let partlyClaimedFolders: [String: Set<String>] = [".keras": ["models"]]', swift)
        self.assertIn('static let whisperStores: [String] = [".cache/whisper"]', swift)
        self.assertIn('static let gpt4AllStores: [String] = ["Library/Application Support/nomic.ai/GPT4All"]', swift)
        self.assertIn('Editor(name: "Visual Studio Code", dotFolder: ".vscode", bundleIdentifier: "com.microsoft.VSCode")', swift)
        tools["whisper"]["storage"][3].pop("claimed")
        with self.assertRaises(RULES.RuleError):
            RULES.validate(sections, tools)
        tools["whisper"]["storage"][3]["claimed"] = False
        tools["vscode"]["storage"][0]["path"] = "~/.vscode"
        with self.assertRaises(RULES.RuleError):
            RULES.validate(sections, tools)

    def test_custom_locations(self):
        sections = {"ai-tools": {"title": "Coverage", "document": "docs/ai-storage.md", "format": "aiCoverage", "tools": ["whisper"]}}
        custom = {"variables": [{"name": "XDG_CACHE_HOME", "append": "whisper"}], "identifiedBy": ["*.pt"]}
        store = {"path": "~/.cache/whisper", "type": "download", "table": "localModelStores", "owner": "aiTools",
                 "treatment": "review", "store": "whisper", "custom": custom}
        tools = {"whisper": {"id": "whisper", "name": "Whisper", "section": "ai-tools", "removalRules": "One row for each model file.",
                             "aiTool": {"case": "whisper", "rawValue": "Whisper"}, "owner": {"case": "whisper", "name": "Whisper"},
                             "storage": [store]}}
        RULES.validate(sections, tools)
        swift = RULES.render_swift(sections, tools)
        self.assertIn('CustomLocation(tool: "whisper", store: "whisper", defaultPath: ".cache/whisper", '
                      'variables: [.init(name: "XDG_CACHE_HOME", append: "whisper")], identifiedBy: ["*.pt"])', swift)
        self.assertIn('public static let locationVariables: [String] = ["XDG_CACHE_HOME"]', swift)
        self.assertIn('static let storePathsByTool: [String: [String]] = ["whisper": [".cache/whisper"]]', swift)
        for change in ({"identifiedBy": []}, {"variables": [{"name": "xdg"}]}, {"variables": [{"name": "A", "append": "../x"}]},
                       {"expandsHome": "yes"}, {"follows": True}):
            store["custom"] = {**custom, **change}
            with self.assertRaises(RULES.RuleError, msg=str(change)):
                RULES.validate(sections, tools)
        store["custom"] = custom
        store.pop("store")
        with self.assertRaises(RULES.RuleError):
            RULES.validate(sections, tools)


class AuditTests(unittest.TestCase):
    def tools(self):
        go = tool(id="go", name="Go", versionCommand=["go", "version"], storage=[
            storage(path="~/go/pkg/mod", type="download", table="packageManagerCaches", owner="packageManagers", treatment="review",
                    name="Go module cache", identifiedBy=None, check="goModuleCache", caveat="Permanent.",
                    verified={"date": "2026-11-02", "tool": "Go 1.27.3", "macos": "27.2"}),
            storage(path="~/go/pkg/mod/cache", type="cache", table="packageManagerCaches", owner="packageManagers", treatment="offer",
                    name="Go download cache", identifiedBy=None, verified=None, status="Not verified. Old rule."),
        ])
        app = tool(id="claude-desktop", name="Claude", bundleIdentifiers=["com.anthropic.claudefordesktop"],
                   verified={"date": "2026-05-01", "kind": "found", "tool": "Claude 2.31", "macos": "27.2"},
                   storage=[storage(path="~/Library/Application Support/Claude", name="Claude data", verified=None, status="Found.")])
        return {"go": go, "claude-desktop": app}

    def test_report(self):
        sections = {"databases": {**SECTIONS["databases"], "tools": ["go", "claude-desktop"]}}
        tools = self.tools()
        RULES.validate(sections, tools)
        report = RULES.audit(sections, tools, applications={"com.anthropic.claudefordesktop": "2.40.1"},
                             which=lambda name: "/usr/bin/go" if name == "go" else None,
                             run=lambda *_, **__: type("R", (), {"stdout": "go version go1.28.0 darwin/arm64", "stderr": ""})(),
                             today=datetime.date(2026, 11, 4),
                             manifest=['{"root": "~/go/pkg/mod", "path": "cache", "type": "dir"}',
                                       '{"root": "~/go/pkg/mod", "path": "github.com", "type": "dir"}',
                                       '{"root": "~/.unknown", "path": "x", "type": "file"}',
                                       '{"root": "~/go/pkg/mod", "summary": true}'])
        self.assertEqual(report["newer"], [("go", "1.28.0", "1.27.3"), ("claude-desktop", "2.40.1", "2.31")])
        self.assertEqual(report["unverified"], [("go", "~/go/pkg/mod/cache")])
        self.assertEqual(report["old"], [("claude-desktop", "2026-05-01")])
        self.assertEqual(report["uncovered"], [("~/go/pkg/mod", "github.com"), ("~/.unknown", None)])
        text = RULES.format_audit(report)
        self.assertIn("  go: installed 1.28.0, verified 1.27.3", text)
        self.assertIn("  ~/go/pkg/mod/github.com", text)
        self.assertIn("  ~/.unknown: no rule", text)
        self.assertEqual(RULES.format_audit({"newer": [], "unverified": [], "old": [], "uncovered": [], "unknown": []}), "Nothing to report.")

    def test_version_command_shape(self):
        for bad in (["go version"], ["/usr/bin/go"], ["go", "version; rm"], ["go", "a", "b", "c"], "go"):
            with self.assertRaises(RULES.RuleError):
                RULES.validate(SECTIONS, {"mysql": tool(versionCommand=bad)})
        RULES.validate(SECTIONS, {"mysql": tool(versionCommand=["mysql", "--version"])})

    def test_absent_tool_has_no_version(self):
        self.assertIsNone(RULES.command_version(["nothing-here", "--version"], which=lambda name: None))
        self.assertIsNone(RULES.version_in(None))
        self.assertEqual(RULES.version_in("Python 3.12.6"), (3, 12, 6))


class RenderingTests(unittest.TestCase):
    def test_row_text(self):
        section = RULES.render_section("databases", SECTIONS, {"mysql": tool()})
        self.assertIn(
            "| `/opt/homebrew/var/mysql` | User data | `ibdata1` or `mysql` folder | Never offer | Not possible "
            "| Protected | Verified 2026-11-02, MySQL 26.10, macOS 27.2 |",
            section,
        )
        self.assertTrue(section.startswith("<!-- rules:begin databases -->\n| Path |"))
        self.assertTrue(section.endswith("<!-- rules:end databases -->"))

    def test_status_text(self):
        self.assertEqual(
            RULES.status_text(storage(verified={"date": "2026-11-02", "kind": "found", "tool": "DBngin 27.0.2"},
                                      status="Not verified. The app needs the desktop session.")),
            "Found 2026-11-02, DBngin 27.0.2. Not verified. The app needs the desktop session.")
        self.assertEqual(
            RULES.status_text(storage(verified={"date": "2026-11-02", "scope": "for `postgresql@18`",
                                                "tool": "PostgreSQL 18.6", "macos": "27.2"})),
            "Verified 2026-11-02 for `postgresql@18`, PostgreSQL 18.6, macOS 27.2")
        self.assertEqual(RULES.status_text(storage(verified=None, status="Not verified.")), "Not verified.")
        self.assertEqual(RULES.status_text(storage(verified={"date": "2026-11-02", "macos": "27.2"})), "Verified 2026-11-02, macOS 27.2")

    def test_coverage_text(self):
        self.assertEqual(RULES.coverage_text(storage()), "Protected")
        self.assertEqual(RULES.coverage_text(storage(treatment="review", type="download")), "Row")
        self.assertEqual(RULES.coverage_text(storage(table=None, owner=None, treatment=None, coverage="caches")), "Caches")
        self.assertEqual(RULES.coverage_text(storage(table=None, owner=None, treatment=None, coverage="#49")), "#49")

    def test_notes_follow_the_table_as_one_bullet_per_tool(self):
        tools = {"mysql": tool(note="MySQL keeps its error log in the data folder.", comment="MySQL 26.10, from Homebrew.",
                               storage=[storage(note="The data folder also holds the binary logs.", comment="Seen on the test Mac.")])}
        section = RULES.render_section("databases", SECTIONS, tools)
        self.assertTrue(section.endswith(
            "|\n\n**MySQL.** MySQL keeps its error log in the data folder. The data folder also holds the binary logs.\n"
            "<!-- rules:end databases -->"))
        self.assertNotIn("Seen on the test Mac", section)
        swift = RULES.render_swift(SECTIONS, tools)
        self.assertIn("        // The data folder also holds the binary logs. Seen on the test Mac.\n", swift)

    def test_swift_roots(self):
        tools = {"mysql": tool(storage=[
            storage(paths=["/opt/homebrew/var/postgresql@<version>", "~/Library/Application Support/Postgres/var-<version>"],
                    path=None, owner="applications", contents="PostgreSQL data files", note="Also an older version.")])}
        swift = RULES.render_swift(SECTIONS, tools)
        self.assertIn("// Generated by scripts/rules.py", swift)
        self.assertIn("        // Also an older version.\n"
                      '        Root(path: "var/postgresql@*", name: "MySQL data", base: .homebrew, '
                      'identifiedBy: ["ibdata1", "mysql/"], tool: "MySQL", contents: "PostgreSQL data files", '
                      "listedWithApplication: true),", swift)
        self.assertIn('Root(path: "Library/Application Support/Postgres/var-*", name: "MySQL data", base: .home, ', swift)
        self.assertIn("listedWithApplication: true)\n    ]\n}\n\nextension ToolHomeFolders {", swift)
        self.assertIn("static let all: [Folder] = [\n\n    ]", swift)

    def test_swift_strings_are_escaped(self):
        self.assertEqual(RULES.swift_string('a "quoted" \\ path'), '"a \\"quoted\\" \\\\ path"')

    def test_markers_must_exist_once(self):
        with self.assertRaises(RULES.RuleError):
            RULES.apply_section("no markers", "databases", "x")
        text = "before\n<!-- rules:begin databases -->\nold\n<!-- rules:end databases -->\nafter\n"
        self.assertEqual(RULES.apply_section(text, "databases", "NEW"), "before\nNEW\nafter\n")


class CommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="moppo-rules-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "rules").mkdir()
        (self.root / "docs").mkdir()
        (self.root / "rules/sections.json").write_text(json.dumps(SECTIONS))
        (self.root / "rules/mysql.json").write_text(json.dumps(tool()))
        (self.root / "docs/tool-catalog.md").write_text(
            "# Catalog\n\n<!-- rules:begin databases -->\nstale\n<!-- rules:end databases -->\n")

    def test_generate_writes_and_check_passes(self):
        self.assertEqual(len(RULES.check(self.root)), 2)
        RULES.generate(self.root)
        self.assertEqual(RULES.check(self.root), [])
        self.assertIn("| `/opt/homebrew/var/mysql` |", (self.root / "docs/tool-catalog.md").read_text())
        self.assertIn("MySQL data", (self.root / RULES.GENERATED_SWIFT).read_text())

    def test_check_finds_a_stale_file(self):
        RULES.generate(self.root)
        # The row name is in the Swift table only. The recognition text is in the document only.
        (self.root / "rules/mysql.json").write_text(json.dumps(tool(storage=[storage(name="MariaDB data")])))
        self.assertEqual([str(path) for path in RULES.check(self.root)], [str(RULES.GENERATED_SWIFT)])
        (self.root / "rules/mysql.json").write_text(json.dumps(tool(storage=[storage(recognition="`ibdata1` file")])))
        self.assertEqual([str(path) for path in RULES.check(self.root)], ["docs/tool-catalog.md"])

    def test_a_tool_file_name_is_its_id(self):
        (self.root / "rules/wrong.json").write_text(json.dumps(tool()))
        with self.assertRaises(RULES.RuleError):
            RULES.load(self.root / "rules")


if __name__ == "__main__":
    unittest.main()
