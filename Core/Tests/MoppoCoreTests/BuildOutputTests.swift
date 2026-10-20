import Foundation
import Testing
@testable import MoppoCore

/// Build output is recognised by shape and offered as regenerable, wherever the
/// project put it; and a folder used this morning is listed like any other.
@Suite("Build output")
struct BuildOutputTests {

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("moppo-build-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 4_096) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        @discardableResult
        func directory(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// One derived-data root as `-derivedDataPath` produces it.
        @discardableResult
        func derivedData(_ relative: String, bytes: Int = 4_096) throws -> URL {
            try file("\(relative)/Build/Products/Debug/app.o", bytes: bytes)
            try file("\(relative)/info.plist", bytes: 64)
            return home.appendingPathComponent(relative)
        }

        func verifiedDerivedData(_ relative: String, bytes: Int = 4_096) throws -> URL {
            let root = try derivedData(relative, bytes: bytes)
            let info = try PropertyListSerialization.data(fromPropertyList:
                ["WorkspacePath": "/Projects/Demo/Demo.xcodeproj/project.xcworkspace"], format: .xml, options: 0)
            try info.write(to: root.appendingPathComponent("info.plist"))
            return root
        }

        @discardableResult
        func testResultsMetadata(_ relative: String) throws -> URL {
            let url = try file("\(relative)/TestResults/metadata.db")
            let metadata: [String: Any] = ["FormatVersion": 1,
                "Store": ["DemoTests": ["ExampleTests": ["example": ["mrnet": 0.01]]]]]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: url)
            return url
        }
    }

    // MARK: - Detector

    @Test("derived data, package builds and aggregates are recognised; sources are not")
    func detectorRecognisesShapes() throws {
        let sandbox = try Sandbox()
        let derived = try sandbox.derivedData("Proj/DD")
        let package = try sandbox.file("Proj/Core/.build/workspace-state.json")
            .deletingLastPathComponent()
        // One `build` folder holding a root per scheme, as `-derivedDataPath build/<name>` makes.
        try sandbox.derivedData("Proj/build/Release")
        try sandbox.derivedData("Proj/build/calendar")
        let aggregate = sandbox.home.appendingPathComponent("Proj/build")
        // Looks like source, is source.
        let sources = try sandbox.file("Proj/Sources/main.swift").deletingLastPathComponent()
        // Named `build`, but holding something that is not build output: left alone.
        let decoy = try sandbox.file("Other/build/notes.txt").deletingLastPathComponent()

        #expect(BuildOutputDetector.kind(of: derived) == .xcodeDerivedData)
        #expect(BuildOutputDetector.kind(of: package) == .swiftPackageBuild)
        #expect(BuildOutputDetector.kind(of: aggregate) == .xcodeDerivedData)
        #expect(BuildOutputDetector.kind(of: sources) == nil)
        #expect(BuildOutputDetector.kind(of: decoy) == nil,
                "a name is not evidence — the shape test failed")
    }

    @Test("dependency stores are recognised by name and shape; bare names are not enough")
    func detectorRecognisesDependencyStores() throws {
        let sandbox = try Sandbox()
        let modules = try sandbox.file("Proj/node_modules/left-pad/index.js").deletingLastPathComponent()
            .deletingLastPathComponent()
        let venv = try sandbox.file("Proj/.venv/pyvenv.cfg").deletingLastPathComponent()
        let pods = try sandbox.file("Proj/Pods/Manifest.lock").deletingLastPathComponent()
        try sandbox.file("Rust/Cargo.toml")
        let cargo = try sandbox.file("Rust/target/debug/app").deletingLastPathComponent()
            .deletingLastPathComponent()
        let bareTarget = try sandbox.file("Archery/target/scores.txt").deletingLastPathComponent()
        let bareVenv = try sandbox.file("Other/venv/notes.txt").deletingLastPathComponent()

        #expect(BuildOutputDetector.kind(of: modules) == .dependencyStore("npm dependencies"))
        #expect(BuildOutputDetector.kind(of: venv) == .dependencyStore("Python environment"))
        #expect(BuildOutputDetector.kind(of: pods) == .dependencyStore("CocoaPods dependencies"))
        #expect(BuildOutputDetector.kind(of: cargo) == .dependencyStore("Cargo build output"))
        #expect(BuildOutputDetector.kind(of: bareTarget) == nil, "no Cargo.toml: somebody's folder")
        #expect(BuildOutputDetector.kind(of: bareVenv) == nil, "no pyvenv.cfg: not an environment")
        #expect(BuildOutputDetector.kind(of: modules)?.isXcodeOutput == false)
    }

    @Test("each store names the record that lets it be put back, or has none")
    func reinstallEvidenceByStore() throws {
        let sandbox = try Sandbox()
        func store(_ path: String, beside files: [String] = []) throws -> URL {
            let url = sandbox.home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files {
                try Data("x".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent(file))
            }
            return url
        }
        let evidence = { (url: URL) in BuildOutputDetector.reinstallEvidence(for: url) }

        #expect(evidence(try store("a/node_modules", beside: ["yarn.lock"])) == "yarn.lock")
        #expect(evidence(try store("b/node_modules", beside: ["pnpm-lock.yaml"])) == "pnpm-lock.yaml")
        // A manifest says what was asked for, not what was installed.
        #expect(evidence(try store("c/node_modules", beside: ["package.json"])) == nil)
        #expect(evidence(try store("d/Pods", beside: ["Podfile.lock"])) == "Podfile.lock")
        #expect(evidence(try store("e/Pods", beside: ["Podfile"])) == nil)

        #expect(evidence(try store("f/.venv", beside: ["uv.lock"])) == "uv.lock")
        // Hand-kept, so it is somebody's intention and not a record.
        #expect(evidence(try store("g/venv", beside: ["requirements.txt"])) == nil)

        #expect(evidence(try store("h/target", beside: ["Cargo.toml", "Cargo.lock"])) == "Cargo.lock")
        // A library often leaves `Cargo.lock` out of version control.
        #expect(evidence(try store("i/target", beside: ["Cargo.toml"])) == nil)
        // Both files: recognition calls it Cargo's, so Cargo's lockfile is the one asked for.
        #expect(evidence(try store("j/target", beside: ["Cargo.toml", "pom.xml"])) == nil)
        #expect(evidence(try store("k/target", beside: ["pom.xml"])) == "pom.xml")

        // Rebuilt from what is beside them, with no network.
        #expect(evidence(try store("l/__pycache__", beside: ["tool.py"])) == "Python sources")
        #expect(evidence(try store("m/__pycache__")) == nil)
        #expect(evidence(try store("n/.gradle", beside: ["build.gradle.kts"])) == "build.gradle.kts")
        #expect(evidence(try store("o/.gradle")) == nil)

        // No lockfile exists to find.
        #expect(evidence(try store("p/bower_components", beside: ["bower.json"])) == nil)
        #expect(evidence(try store("q/.tox", beside: ["tox.ini"])) == nil)
    }

    /// mypy, pytest and ruff each write the Cache Directory Tagging Specification's
    /// marker into their cache and rebuild it from the sources beside it, with no
    /// network. The name says what to look for; the tag is the tool saying yes.
    @Test("a tool's analysis cache is recognised on its tag, and the tag is its evidence")
    func taggedToolCaches() async throws {
        let sandbox = try Sandbox()
        func tag(_ folder: String, signature: String = CacheDirectoryTag.signature) throws {
            let url = sandbox.home.appendingPathComponent(folder).appendingPathComponent("CACHEDIR.TAG")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data((signature + "\n").utf8).write(to: url)
        }
        try sandbox.file("Documents/py/src/app.py", bytes: 2 * 1024 * 1024)
        let mypy = try sandbox.file("Documents/py/.mypy_cache/3.12/app.data.json", bytes: 9 * 1024 * 1024)
            .deletingLastPathComponent().deletingLastPathComponent()
        try tag("Documents/py/.mypy_cache")
        // The name without the tag is somebody's folder.
        let bare = try sandbox.file("Documents/py/.ruff_cache/notes.txt", bytes: 3 * 1024 * 1024)
            .deletingLastPathComponent()
        let forged = try sandbox.file("Documents/py/.pytest_cache/v/cache", bytes: 3 * 1024 * 1024)
            .deletingLastPathComponent().deletingLastPathComponent()
        try tag("Documents/py/.pytest_cache", signature: "Signature: something-else")
        // virtualenv tags its environments too, and a tag does not make one safe:
        // putting it back needs the network and a lockfile.
        try sandbox.file("Documents/py/.venv/pyvenv.cfg", bytes: 64)
        try sandbox.file("Documents/py/.venv/lib/site.bin", bytes: 4 * 1024 * 1024)
        try tag("Documents/py/.venv")

        #expect(BuildOutputDetector.kind(of: mypy) == .dependencyStore("mypy cache"))
        #expect(BuildOutputDetector.reinstallEvidence(for: mypy) == "CACHEDIR.TAG")
        #expect(BuildOutputDetector.kind(of: bare) == nil)
        #expect(BuildOutputDetector.kind(of: forged) == nil)

        let result = try await DocumentsFilesScanner(home: sandbox.home).scan(context: ScanContext())
        let project = try #require(result.entries.first { $0.url.lastPathComponent == "py" })
        let safe = project.children.filter(\.regeneratesSafely).map(\.url.lastPathComponent)
        #expect(safe == [".mypy_cache"])
        let venv = try #require(project.children.first { $0.url.lastPathComponent == ".venv" })
        #expect(venv.safetyCaveat == "no lockfile")
    }

    /// A workspace keeps one lockfile at its root for every package under it, so a
    /// package's own `node_modules` has none beside it. A lockfile somewhere above is
    /// not enough: the root has to *declare* a workspace that covers the package.
    /// Both shapes below were read off this Mac on 20 Sep 2026.
    @Test("a workspace's root lockfile covers the packages its declaration names, and no others")
    func workspaceLockfile() throws {
        let sandbox = try Sandbox()
        func store(_ path: String) throws -> URL {
            let url = sandbox.home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ path: String, _ text: String) throws {
            let url = sandbox.home.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        let evidence = BuildOutputDetector.reinstallEvidence(for:within:)

        // npm, as `Ambrogio` has it: `"workspaces": ["packages/**"]` beside the lockfile.
        let npm = sandbox.home.appendingPathComponent("npm")
        try write("npm/package.json", #"{"name":"root","workspaces":["packages/**","!packages/legacy"]}"#)
        try write("npm/package-lock.json", "{}")
        #expect(evidence(try store("npm/packages/api/node_modules"), npm)
            == "package-lock.json at the workspace root")
        #expect(evidence(try store("npm/packages/web/ui/node_modules"), npm)
            == "package-lock.json at the workspace root")
        // Inside the repository and outside the workspace: installed on its own.
        #expect(evidence(try store("npm/examples/demo/node_modules"), npm) == nil)
        #expect(evidence(try store("npm/packages/legacy/node_modules"), npm) == nil)

        // pnpm, with a real `packages:` list. One `*` is one level.
        let pnpm = sandbox.home.appendingPathComponent("pnpm")
        try write("pnpm/pnpm-workspace.yaml", "packages:\n  - 'apps/*'\n  - \"libs/*\"\nallowBuilds:\n  sharp: false\n")
        try write("pnpm/pnpm-lock.yaml", "")
        #expect(evidence(try store("pnpm/apps/site/node_modules"), pnpm)
            == "pnpm-lock.yaml at the workspace root")
        #expect(evidence(try store("pnpm/apps/site/nested/node_modules"), pnpm) == nil)

        // As `AnguriaStudio` has it: the file exists and declares no packages.
        let settings = sandbox.home.appendingPathComponent("settings")
        try write("settings/pnpm-workspace.yaml", "allowBuilds:\n  sharp: false\n")
        try write("settings/pnpm-lock.yaml", "")
        #expect(evidence(try store("settings/tools/x/node_modules"), settings) == nil)

        // The search stops at the project: a lockfile above it is somebody else's.
        try write("package-lock.json", "{}")
        try write("package.json", #"{"workspaces":["**"]}"#)
        let lone = sandbox.home.appendingPathComponent("lone")
        #expect(evidence(try store("lone/pkg/node_modules"), lone) == nil)
        // And a lockfile beside the store is still the first thing looked for.
        try write("npm/packages/api/package-lock.json", "{}")
        #expect(evidence(try store("npm/packages/api/node_modules"), npm) == "package-lock.json")
    }

    @Test("in a scan, a workspace package's store is a safe child on the root's lockfile")
    func workspacePackageInAScan() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/mono/package-lock.json", bytes: 4_096)
        let manifest = sandbox.home.appendingPathComponent("Documents/mono/package.json")
        try Data(#"{"workspaces":["packages/*"]}"#.utf8).write(to: manifest)
        try sandbox.file("Documents/mono/packages/api/src/index.js", bytes: 2 * 1024 * 1024)
        try sandbox.file("Documents/mono/packages/api/node_modules/dep/blob", bytes: 12 * 1024 * 1024)

        let result = try await DocumentsFilesScanner(home: sandbox.home).scan(context: ScanContext())

        let project = try #require(result.entries.first { $0.url.lastPathComponent == "mono" })
        let store = try #require(project.children.first)
        #expect(store.url.path.hasSuffix("packages/api/node_modules"))
        #expect(store.regeneratesSafely)
        #expect(store.parentDisplay.hasSuffix("package-lock.json at the workspace root"))
    }

    @Test("a dependency store becomes a removable child of its project")
    func dependencyStoreBecomesProjectChild() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/old-project/src/index.js", bytes: 2 * 1024 * 1024)
        try sandbox.file("Documents/old-project/node_modules/big/blob", bytes: 30 * 1024 * 1024)

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext())

        let project = try #require(result.entries.first {
            $0.url.lastPathComponent == "old-project"
        })
        let modules = try #require(project.children.first {
            $0.url.lastPathComponent == "node_modules"
        })

        // Whether it is *regenerable* is the lockfile's question, asked below.
        #expect(modules.kind == .cache)
        #expect(modules.parentDisplay.contains("npm dependencies"))
        #expect(!modules.isRemovalLocked)
        #expect(modules.allocatedBytes >= 30 * 1024 * 1024)
        #expect(!result.entries.contains { $0.url == modules.url })

        #expect(!project.isRegenerable, "the code is the user's")
        #expect(project.allocatedBytes < 10 * 1024 * 1024, "and it no longer carries the modules")
        #expect(project.rowDisplayBytes == project.totalBytesIncludingChildren)
        #expect(result.totalBytes == project.displayBytes)
        #expect(CleanupService.removalTargets(
            for: project,
            removeProtectedAppData: false
        ).map(\.id) == [modules.id, project.id])
    }

    /// Regenerable children have counted as safe since 18 Sep 2026, and a dependency
    /// store was a regenerable child on its name alone — so every `node_modules` on
    /// the disk was promised as safe and ticked for the user, lockfile or none.
    @Test("a dependency store is safe only beside the lockfile its installer wrote")
    func dependencyStoreNeedsALockfileToBeSafe() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/pinned/src/index.js", bytes: 2 * 1024 * 1024)
        try sandbox.file("Documents/pinned/package-lock.json", bytes: 4_096)
        try sandbox.file("Documents/pinned/node_modules/big/blob", bytes: 30 * 1024 * 1024)
        try sandbox.file("Documents/loose/src/index.js", bytes: 2 * 1024 * 1024)
        try sandbox.file("Documents/loose/node_modules/big/blob", bytes: 20 * 1024 * 1024)

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext())

        func modules(of project: String) throws -> FileEntry {
            let row = try #require(result.entries.first { $0.url.lastPathComponent == project })
            return try #require(row.children.first { $0.url.lastPathComponent == "node_modules" })
        }
        let pinned = try modules(of: "pinned")
        let loose = try modules(of: "loose")

        #expect(pinned.regeneratesSafely)
        #expect(pinned.parentDisplay.hasSuffix("npm dependencies · package-lock.json"))
        // Listed and removable, as before. What is withdrawn is the word *safe*.
        #expect(!loose.regeneratesSafely)
        #expect(!loose.isRemovalLocked)
        #expect(loose.parentDisplay.hasSuffix("npm dependencies · no lockfile"))
        #expect(loose.safetyCaveat == "no lockfile")
        #expect(pinned.safetyCaveat == nil)
        #expect(result.safeToRemoveBytes == pinned.allocatedBytes)
        #expect(result.tileRows(safeToRemove: true).map(\.url) == [pinned.url])
    }

    @Test("an excluded dependency store is neither carved nor listed")
    func excludedStoreStaysInsideItsProject() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/proj/src/index.js", bytes: 2 * 1024 * 1024)
        let modules = try sandbox.file("Documents/proj/node_modules/big/blob", bytes: 30 * 1024 * 1024)
            .deletingLastPathComponent().deletingLastPathComponent()

        let result = try await DocumentsFilesScanner(home: sandbox.home).scan(
            context: ScanContext(excludedPaths: [modules.standardizedFileURL.path])
        )

        #expect(!result.entries.contains { $0.url == modules })
        // And the project itself is not offered either: a folder that contains an
        // exclusion is never removable, because removing it would remove the
        // excluded store with it. Hands off means the whole project.
        #expect(!result.entries.contains { $0.url.lastPathComponent == "proj" })
    }

    @Test("a bundle in Downloads is a downloaded app, not an installed one")
    func downloadedAppIsAFile() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(
            "Downloads/logioptionsplus_installer.app/Contents/MacOS/installer",
            bytes: 12 * 1024 * 1024
        )

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext())
        let row = try #require(result.entries.first {
            $0.url.lastPathComponent == "logioptionsplus_installer.app"
        })

        #expect(row.kind == .downloadedApp)
        #expect(row.kind != .appBundle, "only installed applications route to the uninstaller")
        #expect(!row.isRemovalLocked)
        #expect(!CleanupService.alwaysMovesToTrash(row), "it is a file: the Trash setting applies")
    }

    @Test("roots are found up to three levels down and not inside dependency stores")
    func detectorFindsRoots() throws {
        let sandbox = try Sandbox()
        let project = try sandbox.directory("Proj")
        try sandbox.derivedData("Proj/build/Debug")
        try sandbox.file("Proj/Core/.build/workspace-state.json")
        try sandbox.derivedData("Proj/node_modules/pkg/build/x")   // never descended
        try sandbox.derivedData("Proj/a/b/c/build/deep")            // too deep
        // A workspace package's store: one folder further down than a plain project's.
        try sandbox.file("Proj/packages/api/node_modules/dep/index.js")

        let roots = BuildOutputDetector.roots(under: project)

        // `node_modules` is reported as a root of its own and never entered, so
        // the derived data planted inside it is not found.
        #expect(roots.map(\.url.lastPathComponent)
            == [".build", "build", "node_modules", "node_modules"])
        #expect(roots.map(\.kind) == [
            .swiftPackageBuild, .xcodeDerivedData,
            .dependencyStore("npm dependencies"), .dependencyStore("npm dependencies"),
        ])
        #expect(roots.last?.url.path.hasSuffix("Proj/packages/api/node_modules") == true)
    }

    // MARK: - Xcode scanner

    @Test("a project's build folder becomes a regenerable Xcode row")
    func projectBuildOutputIsOffered() async throws {
        let sandbox = try Sandbox()
        let documents = try sandbox.directory("Documents")
        try sandbox.derivedData("Documents/Renewals/build/Release", bytes: 2 * 1024 * 1024)
        try sandbox.file("Documents/Renewals/App/main.swift")
        try sandbox.file("Documents/Renewals/node_modules/x/y", bytes: 2 * 1024 * 1024)
        let emptyDeveloper = try sandbox.directory("Library/Developer")

        let result = try await XcodeScanner(
            developerRoot: emptyDeveloper,
            projectRoots: [documents],
            // Every root this scanner reads has to come from the fixture. Left at
            // its default, the machine's own /Library/Developer/CoreSimulator was
            // still scanned, and on a Mac with an iOS runtime installed the result
            // carried a 3.69 GB manual-removal row this test never planted — so
            // "everything found here is safe" failed for a true reason about the
            // machine rather than a false one about the code.
            systemSimulatorRoot: sandbox.home.appendingPathComponent("no-simulators"), temporaryRoots: []
        ).scan(context: ScanContext())

        let row = try #require(result.entries.first { $0.displayName == "Renewals build output" })
        #expect(row.isRegenerable)
        #expect(row.kind == .cache)
        #expect(row.url.lastPathComponent == "build")
        #expect(row.parentDisplay.hasSuffix("Xcode derived data"))
        #expect(row.allocatedBytes >= 2 * 1024 * 1024)
        #expect(result.safeToRemoveBytes == result.totalBytes)
        #expect(!result.entries.contains { $0.url.lastPathComponent == "node_modules" },
                "dependency stores are Documents' to list, not Xcode's")
    }

    // MARK: - Documents scanner

    @Test("Temporary builds expose cache children and preserve other contents")
    func temporaryBuildCaches() async throws {
        let sandbox = try Sandbox()
        let temporary = try sandbox.directory("Temporary")
        let root = try sandbox.verifiedDerivedData("Temporary/agent-job")
        let kept = ["notes.txt", "SourcePackages/checkouts/local.swift", "Tests.xcresult/report", "Release.xcarchive/app"]
        for path in kept { try sandbox.file("Temporary/agent-job/" + path) }
        try sandbox.file("Temporary/agent-job/ModuleCache.noindex/cache")
        try sandbox.file("Temporary/agent-job/Index.noindex/index")
        try sandbox.verifiedDerivedData("Temporary/another-job/DerivedData")
        try sandbox.derivedData("Temporary/unknown")
        let linked = try sandbox.verifiedDerivedData("Elsewhere")
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("linked"), withDestinationURL: linked)
        var scanner = XcodeScanner(developerRoot: sandbox.home.appendingPathComponent("no-developer"),
            projectRoots: [], systemSimulatorRoot: sandbox.home.appendingPathComponent("no-simulators"),
            temporaryRoots: [temporary, temporary])
        scanner.captureBuildActivity = { WorktreeActivity(roots: $0, processes: [:]) }
        let context = ScanContext(excludedPaths: [root.appendingPathComponent("Index.noindex").path])
        let xcode = FileEntry.RunningOwner(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", bundlePath: "/Applications/Xcode.app")
        let running = try await scanner.scan(context: ScanContext(
            excludedPaths: context.excludedPaths, runningApplications: [xcode]))
        #expect(running.entries.allSatisfy { FileEntryPresentation(entry: $0).runningOwner == xcode })
        #expect(running.entries.allSatisfy { $0.inUseBy == xcode && $0.isRemovalLocked })
        #expect(running.safeToRemoveBytes == 0)
        #expect(running.filtered(safeToRemove: true).entries.isEmpty)
        #expect(running.entries.flatMap(\.children).filter(\.isRegenerable).allSatisfy {
            $0.inUseBy == xcode && FileEntryPresentation(entry: $0).runningGuidance?.contains("Close Xcode, then scan again") == true
        })

        let result = try await scanner.scan(context: context)
        #expect(result.entries.count == 2)
        #expect(result.entries.allSatisfy { FileEntryPresentation(entry: $0).runningOwner == nil })
        let summaries = result.entries.map { FileEntryPresentation(entry: $0).summary }
        #expect(Set(summaries).count == 2)
        #expect(summaries.contains(FileEntry.abbreviate(root.path)))
        #expect(summaries.contains(FileEntry.abbreviate(temporary.appendingPathComponent("another-job/DerivedData").path)))
        #expect(Set(result.entries.flatMap(\.children).map(\.id)) == Set(running.entries.flatMap(\.children).map(\.id)))
        #expect(result.entries.flatMap(\.children).allSatisfy { FileEntryPresentation(entry: $0).runningGuidance == nil })
        let group = try #require(result.entries.first { $0.url.path == root.path })
        #expect(group.displayName == "Demo — temporary build cache")
        #expect(group.isRemovalLocked)
        #expect(Set(group.children.map(\.url.lastPathComponent)) ==
            ["Build", "ModuleCache.noindex", "info.plist", "notes.txt", "SourcePackages", "Tests.xcresult", "Release.xcarchive"])
        #expect(result.totalBytes > result.safeToRemoveBytes)
        let keptRoots = Set(kept.compactMap { $0.split(separator: "/").first.map(String.init) })
        #expect(group.children.filter { keptRoots.contains($0.url.lastPathComponent) }.allSatisfy { $0.isRemovalLocked })
        #expect(result.filtered(safeToRemove: true).entries.count == 3)
        #expect(result.entries.flatMap(\.children).filter(\.regeneratesSafely).allSatisfy { $0.xcodeBuildCacheReview != nil })
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
        #expect(try XcodeBuildCache.temporaryCaches(under: [temporary],
            context: ScanContext(excludedPaths: [temporary.path])).isEmpty)
        let task = Task {
            try Task.checkCancellation()
            return try XcodeBuildCache.temporaryCaches(under: [temporary], context: context)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Nested release caches belong to Xcode and leave archives in the project total", arguments: ["dist/releases", "build/releases", "releases"])
    func releaseBuildCaches(container: String) async throws {
        let sandbox = try Sandbox()
        let documents = try sandbox.directory("Documents")
        let project = try sandbox.directory("Documents/Demo")
        try sandbox.file("Documents/Demo/source.swift", bytes: 2 * 1024 * 1024)
        let release = "Documents/Demo/\(container)/build-1"
        try sandbox.verifiedDerivedData(release + "/DerivedData", bytes: 4 * 1024 * 1024)
        let archive = try sandbox.file(release + "/Demo.xcarchive/dSYMs/data", bytes: 2 * 1024 * 1024)
        try sandbox.file(release + "/Demo.dmg", bytes: 2 * 1024 * 1024)
        var scanner = XcodeScanner(developerRoot: sandbox.home.appendingPathComponent("no-developer"),
            projectRoots: [documents], systemSimulatorRoot: sandbox.home.appendingPathComponent("no-simulators"), temporaryRoots: [])
        scanner.captureBuildActivity = { WorktreeActivity(roots: $0, processes: [:]) }
        let xcode = try await scanner.scan(context: ScanContext())
        let documentsResult = try await DocumentsFilesScanner(home: sandbox.home).scan(context: ScanContext())
        let row = try #require(documentsResult.entries.first {
            $0.url.resolvingSymlinksInPath().path == project.resolvingSymlinksInPath().path
        })
        #expect(xcode.entries.map(\.displayName) == ["Demo — release build cache"])
        #expect(xcode.totalBytes >= 4 * 1024 * 1024)
        #expect(row.allocatedBytes >= 6 * 1024 * 1024)
        let total = try await AllocatedSizeMeasurer().measure(project).allocatedBytes
        #expect(row.allocatedBytes + xcode.totalBytes == total)
        #expect(!row.regeneratesSafely)
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test("Open files and incomplete checks protect discovered build caches",
          arguments: ["active", "incomplete-activity", "incomplete-contents"])
    func activeBuildCaches(problem: String) async throws {
        let sandbox = try Sandbox()
        let temporary = try sandbox.directory("Temporary")
        let root = try sandbox.verifiedDerivedData("Temporary/job")
        if problem == "incomplete-contents" {
            try sandbox.directory("Temporary/job/Build/" + Array(repeating: "d", count: 129).joined(separator: "/"))
        }
        let identity = try #require(FileIdentity.of(root.appendingPathComponent("Build/Products/Debug/app.o")))
        var scanner = XcodeScanner(developerRoot: sandbox.home.appendingPathComponent("no-developer"),
            projectRoots: [], systemSimulatorRoot: sandbox.home.appendingPathComponent("no-simulators"), temporaryRoots: [temporary])
        scanner.captureBuildActivity = {
            WorktreeActivity(roots: $0, processes: problem == "active" ? [identity: ["swift-frontend"]] : [:],
                             issue: problem == "incomplete-activity" ? "Incomplete process information." : nil)
        }
        let result = try await scanner.scan(context: ScanContext())
        let group = try #require(result.entries.first)
        let child = try #require(result.entries.first?.children.first)
        #expect(FileEntryPresentation(entry: group).summary == FileEntry.abbreviate(root.path))
        #expect(!CleanupService.removalAllowed(group, userDataRemovalOverrides: [group.id]))
        if problem == "incomplete-contents" {
            #expect(!XcodeBuildCache.isCurrent(try #require(group.xcodeBuildCacheReview)))
        }
        #expect(child.protectionReason == (problem == "active" ? .running : .inventory))
        #expect(FileEntryPresentation(entry: child).runningGuidance == (problem == "active" ? child.protectionExplanation : nil))
        #expect(result.safeToRemoveBytes == 0)
        #expect(!CleanupService.removalAllowed(child, userDataRemovalOverrides: [child.id]))
    }

    @Test("Complete build folders include reviewed logs, test results, and metadata without automatic selection")
    func completeBuildFolder() async throws {
        let sandbox = try Sandbox()
        let temporary = try sandbox.directory("Temporary")
        let root = try sandbox.verifiedDerivedData("Temporary/reviewed-folder")
        try sandbox.file("Temporary/reviewed-folder/Logs/Build/LogStoreManifest.plist")
        try sandbox.file("Temporary/reviewed-folder/Logs/Build/first.xcactivitylog")
        try sandbox.file("Temporary/reviewed-folder/Logs/Test/Tests.xcresult/Info.plist")
        try sandbox.testResultsMetadata("Temporary/reviewed-folder")
        var scanner = XcodeScanner(developerRoot: sandbox.home.appendingPathComponent("no-developer"),
            projectRoots: [], systemSimulatorRoot: sandbox.home.appendingPathComponent("no-simulators"), temporaryRoots: [temporary])
        scanner.captureBuildActivity = { WorktreeActivity(roots: $0, processes: [:]) }
        let category = try await scanner.scan(context: ScanContext())
        let group = try #require(category.entries.first)
        #expect(!group.isRemovalLocked)
        #expect(!group.regeneratesSafely)
        #expect(group.xcodeBuildCacheReview?.isWholeFolder == true)
        #expect(Set(group.children.map(\.url.lastPathComponent)) == ["Build", "Logs", "TestResults", "info.plist"])
        let measured = try await AllocatedSizeMeasurer().measure(root)
        #expect(group.displayBytes == measured.allocatedBytes)
        let cache = try #require(group.children.first { $0.url.lastPathComponent == "Build" })
        #expect(category.filtered(safeToRemove: true).entries.map(\.id) == [cache.id])
        let reviewed = group.children.filter { $0.url.lastPathComponent != "Build" }
        #expect(reviewed.allSatisfy { !$0.isRemovalLocked && !$0.regeneratesSafely && $0.safetyCaveat == nil })
        let testResults = try #require(reviewed.first { $0.url.lastPathComponent == "TestResults" })
        let testReview = try #require(testResults.xcodeBuildCacheReview)
        #expect(XcodeBuildCache.isCurrent(testReview))
        #expect(CleanupService.alwaysMovesToTrash(testResults))
        let testMeasurement = try await XcodeBuildCache.measureForRemoval(testReview, with: AllocatedSizeMeasurer(), capture: {
            WorktreeActivity(roots: $0, processes: [:])
        })
        #expect(testMeasurement?.allocatedBytes == testResults.allocatedBytes)
        let selected = Set(group.children.map(\.id)).union([group.id])
        #expect(CleanupSelection.ids(in: [category], selected: selected, scope: .safe) == [cache.id])
        #expect(CleanupSelection.ids(in: [category], selected: selected, scope: .all) == [group.id])
        let targets = CleanupService.removalTargets(for: group, removeProtectedAppData: false)
        #expect(targets.map(\.id) == [group.id])
        #expect(targets.first?.allocatedBytes == measured.allocatedBytes)
        #expect(targets.first?.children.isEmpty == true)
        #expect(CleanupService.alwaysMovesToTrash(group))

        let log = RemovalLog(directory: sandbox.home.appendingPathComponent("receipts"))
        defer {
            for record in log.recentEntries() where record.originalPath == root.path {
                if let path = record.trashedPath { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        let service = CleanupService(measureSize: { try await AllocatedSizeMeasurer().measure($0) }, log: log, reviewBuildCache: { review in
            try await XcodeBuildCache.measureForRemoval(review, with: AllocatedSizeMeasurer(), capture: {
                WorktreeActivity(roots: $0, processes: [:])
            })
        })
        let outcome = try await service.remove(entries: [group], trashFirst: false)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.removedCount == 1)
        #expect(outcome.trashedCount == 1)
        #expect(outcome.removedBytes == measured.allocatedBytes)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let receipt = try #require(log.recentEntries().first)
        let trashed = URL(fileURLWithPath: try #require(receipt.trashedPath))
        #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("Logs/Build/first.xcactivitylog").path))
        #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("TestResults/metadata.db").path))
    }

    @Test("Test results remain protected when metadata, contents, or activity checks fail",
          arguments: ["invalid-metadata", "wrong-version", "wrong-store", "unknown-file", "link", "active", "incomplete"])
    func protectedTestResults(problem: String) async throws {
        let sandbox = try Sandbox()
        let temporary = try sandbox.directory("Temporary")
        _ = try sandbox.verifiedDerivedData("Temporary/job")
        let metadata = try sandbox.testResultsMetadata("Temporary/job")
        switch problem {
        case "invalid-metadata": try Data("not a property list".utf8).write(to: metadata)
        case "wrong-version", "wrong-store":
            let value: [String: Any] = problem == "wrong-version"
                ? ["FormatVersion": 2, "Store": [:]] : ["FormatVersion": 1, "Store": "unknown"]
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: metadata)
        case "unknown-file": try sandbox.file("Temporary/job/TestResults/source.swift")
        case "link":
            try FileManager.default.createSymbolicLink(at: metadata.deletingLastPathComponent().appendingPathComponent("alias"),
                withDestinationURL: sandbox.home)
        default: break
        }
        let identity = try #require(FileIdentity.of(metadata))
        var scanner = XcodeScanner(developerRoot: sandbox.home.appendingPathComponent("no-developer"),
            projectRoots: [], systemSimulatorRoot: sandbox.home.appendingPathComponent("no-simulators"), temporaryRoots: [temporary])
        scanner.captureBuildActivity = {
            WorktreeActivity(roots: $0, processes: problem == "active" ? [identity: ["xcodebuild"]] : [:],
                issue: problem == "incomplete" ? "Incomplete process information." : nil)
        }
        let category = try await scanner.scan(context: ScanContext())
        let group = try #require(category.entries.first)
        let results = try #require(group.children.first { $0.url.lastPathComponent == "TestResults" })
        #expect(group.isRemovalLocked)
        #expect(results.protectionReason == (problem == "active" ? .running : .inventory))
        #expect(!CleanupService.removalAllowed(results, userDataRemovalOverrides: [results.id]))
        #expect(!category.filtered(safeToRemove: true).entries.contains { $0.id == results.id })
    }

    @Test("Build folder links must stay within the same verified cache", arguments: [false, true])
    func buildFolderLinks(external: Bool) async throws {
        let sandbox = try Sandbox()
        let temporary = try sandbox.directory("Temporary")
        let root = try sandbox.verifiedDerivedData("Temporary/job")
        let target = external ? try sandbox.file("source.swift")
            : root.appendingPathComponent("Build/Products/Debug/app.o")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Build/alias"), withDestinationURL: target)
        var scanner = XcodeScanner(developerRoot: sandbox.home.appendingPathComponent("no-developer"),
            projectRoots: [], systemSimulatorRoot: sandbox.home.appendingPathComponent("no-simulators"), temporaryRoots: [temporary])
        scanner.captureBuildActivity = { WorktreeActivity(roots: $0, processes: [:]) }
        let category = try await scanner.scan(context: ScanContext())
        let group = try #require(category.entries.first)
        let cache = try #require(group.children.first { $0.url.lastPathComponent == "Build" })
        #expect(group.isRemovalLocked == external)
        #expect(cache.regeneratesSafely == !external)
        #expect(XcodeBuildCache.isCurrent(try #require(group.xcodeBuildCacheReview)) == !external)
    }

    @Test("Whole-folder removal rejects changed contents and incomplete activity checks",
          arguments: ["new-file", "changed-log", "changed-test-results", "link", "replaced-folder", "active", "incomplete"])
    func changedBuildFolder(change: String) async throws {
        let sandbox = try Sandbox()
        let temporary = try sandbox.directory("Temporary")
        let root = try sandbox.verifiedDerivedData("Temporary/job")
        let log = try sandbox.file("Temporary/job/Logs/Build/first.xcactivitylog")
        let testMetadata = try sandbox.testResultsMetadata("Temporary/job")
        var scanner = XcodeScanner(developerRoot: sandbox.home.appendingPathComponent("no-developer"),
            projectRoots: [], systemSimulatorRoot: sandbox.home.appendingPathComponent("no-simulators"), temporaryRoots: [temporary])
        scanner.captureBuildActivity = { WorktreeActivity(roots: $0, processes: [:]) }
        let category = try await scanner.scan(context: ScanContext())
        let group = try #require(category.entries.first)
        let review = try #require(group.xcodeBuildCacheReview)
        let identity = try #require(FileIdentity.of(log))
        switch change {
        case "new-file": try sandbox.file("Temporary/job/source.swift")
        case "changed-log": try Data("new build log".utf8).write(to: log)
        case "changed-test-results":
            let results = try #require(group.children.first { $0.url.lastPathComponent == "TestResults" })
            let resultsReview = try #require(results.xcodeBuildCacheReview)
            let changed: [String: Any] = ["FormatVersion": 1, "Store": ["NewTests": [:]]]
            try PropertyListSerialization.data(fromPropertyList: changed, format: .xml, options: 0).write(to: testMetadata)
            let measured = try await XcodeBuildCache.measureForRemoval(resultsReview, with: AllocatedSizeMeasurer(), capture: {
                WorktreeActivity(roots: $0, processes: [:])
            })
            #expect(measured == nil)
        case "link":
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: sandbox.home)
        case "replaced-folder":
            try FileManager.default.moveItem(at: root, to: sandbox.home.appendingPathComponent("old-job"))
            _ = try sandbox.verifiedDerivedData("Temporary/job")
        default: break
        }
        let measured = try await XcodeBuildCache.measureForRemoval(review, with: AllocatedSizeMeasurer(), capture: {
            WorktreeActivity(roots: $0, processes: change == "active" ? [identity: ["xcodebuild"]] : [:],
                             issue: change == "incomplete" ? "Incomplete process information." : nil)
        })
        #expect(measured == nil)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Build cache removal rechecks activity and identities while preserving neighboring files")
    func buildCacheRemoval() async throws {
        let sandbox = try Sandbox()
        let root = try sandbox.verifiedDerivedData("Temporary/job")
        try sandbox.file("Temporary/job/ModuleCache.noindex/cache")
        let notes = try sandbox.file("Temporary/job/notes.txt")
        let reviews = XcodeBuildCache.reviews(in: root)
        #expect(reviews.count == 2)
        let entries = reviews.map { FileEntry(url: $0.url, kind: .cache, allocatedBytes: 1,
            isRegenerable: true, xcodeBuildCacheReview: $0) }
        let identity = try #require(FileIdentity.of(root.appendingPathComponent("Build/Products/Debug/app.o")))
        let log = RemovalLog(directory: sandbox.home.appendingPathComponent("logs"))
        let busy = CleanupService(measureSize: { try await AllocatedSizeMeasurer().measure($0) }, log: log,
            reviewBuildCache: { review in
                try await XcodeBuildCache.measureForRemoval(review, with: AllocatedSizeMeasurer(), capture: {
                    WorktreeActivity(roots: $0, processes: [identity: ["xcodebuild"]])
                })
            })
        let first = try #require(entries.first { $0.url.lastPathComponent == "Build" })
        let refused = try await busy.remove(entries: [first], trashFirst: false)
        #expect(refused.removedCount == 0)
        #expect(refused.failed == [first.url.path])
        let idle = CleanupService(measureSize: { try await AllocatedSizeMeasurer().measure($0) }, log: log,
            reviewBuildCache: { review in
                try await XcodeBuildCache.measureForRemoval(review, with: AllocatedSizeMeasurer(), capture: {
                    WorktreeActivity(roots: $0, processes: [:])
                })
            })
        let removed = try await idle.remove(entries: entries, trashFirst: false)
        #expect(removed.removedCount == 2)
        #expect(removed.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: notes.path))
        _ = try sandbox.verifiedDerivedData("Temporary/job")
        #expect(!XcodeBuildCache.isCurrent(try #require(reviews.first { $0.url.lastPathComponent == "Build" })))
    }

    /// The scanner once skipped anything used in the last 30 days, which hid the
    /// disk's largest folder — an 11 GB build, made that morning.
    @Test("a folder written seconds ago is listed, unlocked and unlabelled")
    func recentFolderIsListedNotHidden() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/Thesis/draft.txt", bytes: 2 * 1024 * 1024)

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext())
        let row = try #require(result.entries.first { $0.url.lastPathComponent == "Thesis" })

        #expect(row.protectionReason == nil)
        #expect(!row.isRemovalLocked)
        #expect(!row.isRegenerable, "and it is never counted as safe")
    }

    /// The recency filter used to hide these by accident. Now they are refused on
    /// purpose: a Photos library is the user's photographs, not clutter.
    @Test("Apple's media libraries are never offered, however recent")
    func mediaLibrariesAreNeverOffered() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(
            "Pictures/Photos Library.photoslibrary/originals/1/IMG_0001.HEIC",
            bytes: 2 * 1024 * 1024
        )
        try sandbox.file("Music/Music/Media/song.m4a", bytes: 2 * 1024 * 1024)
        try sandbox.file("Movies/TV/Media/episode.m4v", bytes: 2 * 1024 * 1024)
        try sandbox.file("Pictures/Holiday/IMG_0002.HEIC", bytes: 2 * 1024 * 1024)

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext())
        let names = Set(result.entries.map(\.url.lastPathComponent))

        #expect(!names.contains("Photos Library.photoslibrary"))
        #expect(!names.contains("Music"))
        #expect(!names.contains("TV"))
        #expect(names.contains("Holiday"), "an ordinary folder beside them is still listed")
    }

    @Test("a project's row no longer carries its build output")
    func buildOutputIsCarvedOutOfTheProject() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Documents/Renewals/App/main.swift", bytes: 3 * 1024 * 1024)
        try sandbox.derivedData("Documents/Renewals/build/Release", bytes: 40 * 1024 * 1024)

        let result = try await DocumentsFilesScanner(home: sandbox.home)
            .scan(context: ScanContext())
        let row = try #require(result.entries.first { $0.url.lastPathComponent == "Renewals" })

        // The project keeps what the user made; the 40 MB of products left with
        // the Xcode row. Allocation rounds up, so bound rather than equate.
        #expect(row.allocatedBytes >= 3 * 1024 * 1024)
        #expect(row.allocatedBytes < 10 * 1024 * 1024)
    }
}
