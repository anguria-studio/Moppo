import Testing
@testable import MoppoCore

/// The generated `PackageManagerScanner.roots` and `ApplicationDataFolders.byBundleIdentifier` equal the
/// tables that the Swift files held before #352, and the derived skip sets equal the old literal sets.
/// This test leaves with the old tables, after the pull request records that it passed.
@Suite("Package caches migration")
struct PackageCachesMigrationTests {
    private typealias CacheRoot = PackageManagerScanner.CacheRoot
    private typealias Folder = ApplicationDataFolders.Folder

    private static let oldRoots: [CacheRoot] = [
        // npm's content-addressable cache. `~/.npm/_logs` is deliberately left
        // alone: it is kilobytes, and it is what `npm` asks users to attach to bug
        // reports.
        CacheRoot(label: "npm cache", components: [".npm", "_cacache"]),

        // ADDED: Yarn 1 on macOS defaults to `~/Library/Caches/Yarn`, not the two
        // paths the Electron version listed — those are the Linux/XDG layouts. The
        // original therefore missed the Yarn cache on the platform this app ships
        // for. All four are kept, since a machine can carry any of them.
        CacheRoot(label: "Yarn cache", components: ["Library", "Caches", "Yarn"]),
        CacheRoot(label: "Yarn cache (classic)", components: [".yarn", "cache"]),
        // Taken off this list at integration and put back on 20 Sep 2026.
        // `HiddenDataScanner` claimed `~/.cache` as a single row then, so a child
        // claimed here was offered twice. `SystemCachesScanner` lists the folder child
        // by child now and skips the names claimed here — see its
        // `packageManagerOwnedDotCacheNames`.
        // The XDG layout is Linux's, but a Yarn run with `XDG_CACHE_HOME` set, or one
        // carried over in a migrated home, leaves it on a Mac too.
        CacheRoot(label: "Yarn cache (XDG)", components: [".cache", "yarn"]),
        // ADDED: Yarn Berry's global cache, used by every non-zero-install repo.
        CacheRoot(label: "Yarn Berry cache", components: [".yarn", "berry", "cache"]),

        // ADDED: pnpm, absent from the original entirely despite usually being the
        // largest single item in this category. See the note on upper bounds above —
        // these entries are hard-linked into project `node_modules`.
        CacheRoot(label: "pnpm store", components: ["Library", "pnpm", "store"]),
        CacheRoot(label: "pnpm store (legacy)", components: [".pnpm-store"]),
        CacheRoot(label: "pnpm metadata cache", components: ["Library", "Caches", "pnpm"]),

        CacheRoot(label: "pip cache", components: ["Library", "Caches", "pip"]),

        // `~/Library/Caches/Homebrew` belongs to *this* category, not System Caches.
        // It sits inside `~/Library/Caches`, which the System Caches scanner
        // enumerates, so that scanner carves this path out and the two categories
        // stay disjoint. Without the carve-out the same bytes appear twice and the
        // Dashboard's "Safe to remove" total is inflated — the exact double count the
        // storage breakdown had to correct for. The same argument applies to the
        // other `~/Library/Caches` roots listed here (Yarn, pnpm, pip, CocoaPods,
        // Playwright): disjointness is enforced on the System Caches side, since only
        // that scanner can decide what to skip while walking the directory.
        CacheRoot(label: "Homebrew cache", components: ["Library", "Caches", "Homebrew"]),

        // `~/.cocoapods/repos` is deliberately excluded: it is a git clone of the
        // spec index, and while technically regenerable, re-cloning it costs a
        // multi-gigabyte download. "Safe to remove" here means removable without
        // consequence, not merely reproducible.
        CacheRoot(label: "CocoaPods cache", components: ["Library", "Caches", "CocoaPods"]),

        CacheRoot(label: "Gradle cache", components: [".gradle", "caches"]),
        // ADDED: the Gradle wrapper keeps a full distribution per project-pinned
        // version under `dists`, which routinely outgrows `caches` itself.
        CacheRoot(label: "Gradle distributions", components: [".gradle", "wrapper", "dists"]),

        // ADDED: Playwright's macOS default is `~/Library/Caches/ms-playwright`; the
        // original listed only the Linux path, so it never found the browsers.
        CacheRoot(label: "Playwright browsers", components: ["Library", "Caches", "ms-playwright"]),
        // Back for the same reason as `~/.cache/yarn` above.
        CacheRoot(label: "Playwright browsers (XDG)", components: [".cache", "ms-playwright"]),

        // uv keeps its cache at `~/.cache/uv` on macOS as on Linux — 2.0 GB on this
        // Mac, the largest thing in `~/.cache`, and until the split offered only as
        // part of that folder's single row. `uv cache clean` is the tool's own
        // instruction; environments are linked or cloned out of it, so they survive.
        CacheRoot(label: "uv cache", components: [".cache", "uv"]),

        // ADDED 20 Sep 2026, after reading Purge (github.com/jithin-sabu/purge-app),
        // which offers most of these. `~/.cargo`, `~/.bun` and the rest were left out
        // whole because each mixes a cache with an installed toolchain. That was the
        // right reason to refuse the folder and the wrong reason to refuse the cache
        // inside it: every root below is the tool's own download cache by its
        // documented default, never the folder that holds the tool.
        //
        // Inside a home dot-folder. `HiddenDataScanner.dotDirectorySkipList` names
        // each of these folders, or that scanner lists it whole and the two
        // categories offer the same bytes; `DisjointCategoriesTests` holds the two
        // lists together.
        CacheRoot(label: "Bun install cache", components: [".bun", "install", "cache"]),
        // `registry` is the index, the downloaded crates and their unpacked source;
        // `git` is the same for git dependencies. `~/.cargo/bin` — what
        // `cargo install` put there — is not touched.
        CacheRoot(label: "Cargo registry", components: [".cargo", "registry"]),
        CacheRoot(label: "Cargo git dependencies", components: [".cargo", "git"]),
        // `~/.ivy2/local` holds what the user published with `publishLocal` and is
        // not a download, so only `cache` is named.
        CacheRoot(label: "Ivy cache", components: [".ivy2", "cache"]),
        CacheRoot(label: "Bundler cache", components: [".bundle", "cache"]),
        // Projects build against this folder directly, so the next build restores
        // it; `dotnet nuget locals all --clear` is Microsoft's own instruction.
        CacheRoot(label: "NuGet packages", components: [".nuget", "packages"]),
        CacheRoot(label: "Hex packages", components: [".hex", "packages"]),
        CacheRoot(label: "Cabal packages", components: [".cabal", "packages"]),
        // cabal 3.16 uses the XDG layout and does not create `~/.cabal` (#323). Without this
        // folder, a build fails until `cabal update` downloads the package index again.
        CacheRoot(label: "Cabal packages (XDG)", components: [".cache", "cabal"],
                  reviewCaveat: "cabal update downloads it again. A network connection is necessary."),
        // `~/.pub-cache/bin` and `global_packages` are what `pub global activate`
        // installed, so the two download folders are named and the root is not.
        CacheRoot(label: "Dart pub cache", components: [".pub-cache", "hosted"]),
        CacheRoot(label: "Dart pub git dependencies", components: [".pub-cache", "git"]),

        // Under `~/Library/Caches`, where System Caches had been offering each as a
        // safe row named for its folder. Nothing becomes safe that was not; the row
        // gains a name a person can read and the category it belongs to. Mirrored in
        // `SystemCachesScanner.packageManagerOwnedCacheNames`.
        CacheRoot(label: "Deno cache", components: ["Library", "Caches", "deno"]),
        CacheRoot(label: "Go build cache", components: ["Library", "Caches", "go-build"]),
        CacheRoot(label: "Coursier cache", components: ["Library", "Caches", "Coursier"]),
        CacheRoot(label: "Composer cache", components: ["Library", "Caches", "composer"]),
        CacheRoot(label: "Pipenv cache", components: ["Library", "Caches", "pipenv"]),
        // Poetry's folder is not one cache. `cache` and `artifacts` are downloads;
        // `virtualenvs`, beside them, holds the environment of every Poetry project
        // on the disk. System Caches listed the folder whole, as one safe row, so
        // those environments were offered and ticked as a cache. The two downloads
        // are named here, System Caches skips the folder, and the environments are
        // offered by nobody: whether one can be put back is its project's lockfile's
        // to say, and the project is somewhere else.
        CacheRoot(label: "Poetry cache", components: ["Library", "Caches", "pypoetry", "cache"]),
        CacheRoot(label: "Poetry artifacts", components: ["Library", "Caches", "pypoetry", "artifacts"]),
        CacheRoot(label: "SwiftPM cache", components: ["Library", "Caches", "org.swift.swiftpm"]),
        CacheRoot(label: "Carthage cache", components: ["Library", "Caches", "org.carthage.CarthageKit"]),
        CacheRoot(label: "node-gyp headers", components: ["Library", "Caches", "node-gyp"]),
        CacheRoot(label: "Electron downloads", components: ["Library", "Caches", "electron"]),
        CacheRoot(label: "electron-builder cache", components: ["Library", "Caches", "electron-builder"]),
        // The same kind of thing as Playwright's browsers above: the test runner's
        // own binary, fetched again by `cypress install`.
        CacheRoot(label: "Cypress binaries", components: ["Library", "Caches", "Cypress"]),
        CacheRoot(label: "ccache", components: ["Library", "Caches", "ccache"])

        // Looked at and left out, each for a reason a name does not show:
        // * `~/.m2/repository` — also holds what the user built with `mvn install`,
        //   which no server can give back.
        // * `~/.gem` — installed gems, not a cache. `~/.sbt`, `~/.stack`, `~/.rustup`,
        //   `~/.nvm`, `~/.deno` — toolchains, with or without a cache beside them.
        // * `~/.vagrant.d/boxes` — a box may have been packaged on this Mac, and the
        //   rest are multi-gigabyte downloads, the CocoaPods-repos argument again.
        // * `~/.terraform.d/plugin-cache` — working directories link into it, so
        //   removal leaves them broken until the next `terraform init`.
        // * rebar3, `act`, pre-commit, Puppeteer — under `~/.cache`, never seen on this
        //   Mac. System Caches lists each as a row of its own, safe only on its tool's
        //   `CACHEDIR.TAG`, which is where a cache nobody has looked at belongs.
    ]


    private static let oldFolders: [String: [Folder]] = [
        // AnythingLLM 1.19.0, team 35S2NMU3G4. The Electron package name is `anythingllm-desktop`.
        "com.anythingllm": [Folder(path: "Library/Application Support/anythingllm-desktop")],
        // Cherry Studio 2.1.10, team 87242QY66T. The Electron package name is `CherryStudio`.
        // `~/.cherrystudio` holds the downloaded tools and the `config` folder of the application.
        "com.kangfenmao.CherryStudio": [
            Folder(path: "Library/Application Support/CherryStudio"),
            Folder(path: ".cherrystudio")
        ],
        // Stability Matrix 2.16.5, team 78LBV9V26G. The folder holds `global.json` and the logs.
        "ai.lykos.stabilitymatrix": [Folder(path: "Library/Application Support/StabilityMatrix")],
        // VoiceInk 2.21, team V6J6A3VWY2. VoiceInk also uses its bundle identifier folder.
        "com.prakashjoshipax.VoiceInk": [Folder(path: "Library/Application Support/VoiceInk")],
        // T3 Code 0.1.6, team ARK85ZXQ4Z. The application sets this folder. Its package name is `t3code`.
        // `~/.t3` is not here: the T3 Code command-line server also uses it.
        "com.t3tools.t3code": [Folder(path: "Library/Application Support/t3code-v2")],
        // DBeaver, team 42B6MDKMW8. The folder holds the workspace, drivers, and settings.
        "org.jkiss.dbeaver.core.product": [Folder(path: "Library/DBeaverData")],
        // Superwhisper 3.1.0, team XDP69BYUP9. `~/superwhisper` holds settings, modes, and recordings.
        "com.superduper.superwhisper": [
            Folder(path: "Library/Application Support/superwhisper"),
            Folder(path: "superwhisper", identifiedBy: ["settings/settings.json", "modes"])
        ]
    ]


    private static let packageManagerOwnedCacheNames: Set<String> = [
        "Homebrew", "pip", "CocoaPods",
        // Added at integration: PackageManagerScanner claims these too, and the
        // original three-name list would have double-counted them.
        "Yarn", "pnpm", "ms-playwright",
        // Added with the 20 Sep 2026 roots. Each was a row here, named for its
        // folder; it is a row there now, named for its tool.
        "deno", "go-build", "Coursier", "composer", "pipenv", "pypoetry", "org.swift.swiftpm",
        "org.carthage.CarthageKit", "node-gyp", "electron", "electron-builder",
        "Cypress", "ccache"
    ]

    private static let packageManagerOwnedDotCacheNames: Set<String> = [
        "uv", "yarn", "ms-playwright", "cabal"
    ]

    private static let dotDirectorySkipList: Set<String> = [
        ".Trash", ".cache", ".npm", ".yarn", ".gradle", ".local",
        ".pnpm-store",
        ".bun", ".cargo", ".ivy2", ".bundle", ".nuget", ".hex", ".cabal", ".pub-cache"
    ]

    private static func description(_ root: CacheRoot) -> String {
        "\(root.label) | \(root.components) | \(root.reviewCaveat ?? "-")"
    }

    @Test("the generated package cache roots equal the old table")
    func generatedRootsEqualOldTable() {
        #expect(PackageManagerScanner.roots.map(Self.description).sorted() == Self.oldRoots.map(Self.description).sorted())
        #expect(PackageManagerScanner.goModuleCache == "go/pkg/mod")
    }

    @Test("the generated application data folders equal the old table")
    func generatedFoldersEqualOldTable() {
        let generated = ApplicationDataFolders.byBundleIdentifier.mapValues { $0.map { "\($0.path) \($0.identifiedBy)" }.sorted() }
        let old = Self.oldFolders.mapValues { $0.map { "\($0.path) \($0.identifiedBy)" }.sorted() }
        #expect(generated == old)
    }

    @Test("the derived skip sets equal the old literal sets")
    func derivedSetsEqualOldSets() {
        #expect(SystemCachesScanner.packageManagerOwnedCacheNames == Self.packageManagerOwnedCacheNames)
        #expect(SystemCachesScanner.packageManagerOwnedDotCacheNames == Self.packageManagerOwnedDotCacheNames)
        #expect(HiddenDataScanner.dotDirectorySkipList == Self.dotDirectorySkipList)
    }
}
