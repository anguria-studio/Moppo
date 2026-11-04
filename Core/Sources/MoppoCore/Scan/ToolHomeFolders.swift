import Foundation

/// Home dot folders that hold installed toolchains, virtual machines, or credentials.
/// A name with `.config/` is a folder in `~/.config`, which Hidden System Data lists child by child.
///
/// Hidden System Data lists large home dot folders, and a listed folder could move to
/// the Trash as one item. For these folders, that removed Rust toolchains, container
/// volumes, and registry tokens (#321). Hidden System Data now shows each of these
/// folders with its size and locks it.
///
/// Only caches that `docs/tool-catalog.md` verified for a Trash move become separate
/// rows. Moppo offers such a cache only when the tool layout is present, because a
/// folder name alone does not identify the tool.
enum ToolHomeFolders {
    struct Folder: Sendable {
        let name: String
        let explanation: String
        /// Items in the folder that identify the tool layout. Each one must exist before Moppo offers a cache.
        var layout: [String] = []
        var caches: [Cache] = []
    }

    struct Cache: Sendable {
        let path: String
        /// An item in the cache that identifies its layout.
        var marker: String?
        /// True when the tool makes the cache again without a network connection.
        let isRegenerable: Bool
        let caveat: String?

        static func cache(_ path: String) -> Self {
            Cache(path: path, isRegenerable: true, caveat: nil)
        }

        static func download(_ path: String, marker: String? = nil, caveat: String) -> Self {
            Cache(path: path, marker: marker, isRegenerable: false, caveat: caveat)
        }
    }

    static let all: [Folder] = [
        // Installed toolchains and versions. Remove a version with the tool command.
        Folder(name: ".rustup",
               explanation: "rustup keeps the Rust toolchains here. Use rustup toolchain uninstall to remove a toolchain.",
               layout: ["settings.toml", "toolchains"], caches: [.cache("downloads"), .cache("tmp")]),
        Folder(name: ".goenv",
               explanation: "goenv keeps the installed Go versions here. Use goenv uninstall to remove a version.",
               layout: ["versions", "shims"],
               caches: [.cache("releases-cache.json"),
                        .download("shared/go-mod", marker: "cache/download",
                                  caveat: "The next goenv install downloads it again. A network connection is necessary.")]),
        Folder(name: ".pyenv",
               explanation: "pyenv keeps the installed Python versions here. Use pyenv uninstall to remove a version."),
        Folder(name: ".rbenv",
               explanation: "rbenv keeps the installed Ruby versions here. Use rbenv uninstall to remove a version."),
        Folder(name: ".rvm",
               explanation: "RVM keeps Ruby versions and gems here. Use rvm remove or rvm cleanup all."),
        Folder(name: ".rubies",
               explanation: "chruby uses the Ruby versions here. Projects can need these versions."),
        Folder(name: ".plenv",
               explanation: "plenv keeps the installed Perl versions here. Use plenv uninstall to remove a version.",
               layout: ["versions"],
               caches: [.cache("build"),
                        .download("cache", caveat: "The next plenv install downloads it again. A network connection is necessary.")]),
        Folder(name: ".cpanm",
               explanation: "cpanm keeps build files and links to them here. Only the work folder can be removed.",
               layout: ["latest-build"], caches: [.cache("work")]),
        Folder(name: ".ghcup",
               explanation: "ghcup keeps GHC, cabal, and other Haskell tools here. Use ghcup rm or ghcup gc to remove them."),
        Folder(name: ".stack",
               explanation: "Stack keeps GHC versions, package indexes, and your config.yaml settings here.",
               layout: ["config.yaml", "stack.sqlite3"],
               caches: [.download("snapshots", caveat: "The next stack build makes it again."),
                        .download("pantry", caveat: "The next stack build downloads it again. A network connection is necessary."),
                        .download("setup-exe-cache",
                                  caveat: "The next stack build downloads it again. A network connection is necessary.")]),
        Folder(name: ".sdkman",
               explanation: "SDKMAN keeps the installed JVM tools here. Use sdk uninstall or sdk flush to remove them."),
        Folder(name: ".sbt",
               explanation: "sbt keeps settings, plugins, and downloads here. Only the boot folder can be removed.",
               layout: ["1.0"],
               caches: [.download("boot", caveat: "sbt 1 downloads it again. A network connection is necessary.")]),
        // Maven 3.10 writes `.meta` in its repository. An older layout gets no offer.
        Folder(name: ".m2",
               explanation: "Maven keeps downloads and settings here. settings.xml can contain repository passwords.",
               caches: [.download("repository", marker: ".meta",
                                  caveat: "Maven downloads it again. Artifacts from mvn install do not come back.")]),
        Folder(name: ".composer",
               explanation: "Composer keeps global packages and settings here. auth.json can contain registry tokens."),
        Folder(name: ".config/composer",
               explanation: "Composer keeps global packages and settings here. auth.json can contain registry tokens."),
        Folder(name: ".asdf",
               explanation: "asdf keeps the installed tool versions here. Use asdf uninstall to remove a version.",
               layout: ["installs", "plugins"], caches: [.cache("downloads")]),
        Folder(name: ".mix",
               explanation: "Mix keeps installed archives, such as Hex, here."),
        Folder(name: ".android",
               explanation: "Android tools keep emulators and adb keys here. Use avdmanager to delete an emulator.",
               caches: [.cache("cache")]),

        // Virtual machines and container data.
        Folder(name: ".colima",
               explanation: "Colima keeps its virtual machines and container data disks here. Use colima delete after review."),
        Folder(name: ".lima",
               explanation: "Lima keeps its virtual machines and its SSH key here. Use limactl delete after review."),

        // Credentials.
        Folder(name: ".aws", explanation: "The AWS tools keep settings, credentials, and sign-in tokens here."),
        Folder(name: ".azure", explanation: "The Azure CLI keeps settings and sign-in tokens here."),
        Folder(name: ".config/gcloud", explanation: "The Google Cloud CLI keeps its settings and credentials here."),
        Folder(name: ".config/gh", explanation: "The GitHub CLI keeps its settings and sign-in tokens here."),
        Folder(name: ".docker", explanation: "Docker keeps its settings here. config.json can contain registry credentials."),
        Folder(name: ".gnupg", explanation: "GnuPG keeps your keys and settings here."),
        Folder(name: ".kube", explanation: "kubectl keeps cluster settings and credentials here."),
        Folder(name: ".ssh", explanation: "SSH keeps your keys and settings here.")
    ]

    static let names: Set<String> = Set(all.map(\.name))

    static func folder(named name: String) -> Folder? {
        all.first { $0.name == name }
    }

    /// The caches that Moppo can offer in `url`. A link is never a cache.
    static func offeredCaches(of folder: Folder, in url: URL) -> [(url: URL, cache: Cache)] {
        guard folder.layout.allSatisfy({ exists(url.appendingPathComponent($0)) }) else { return [] }
        return folder.caches.compactMap { cache in
            let cacheURL = url.appendingPathComponent(cache.path)
            guard isOwned(cacheURL, under: url),
                  cache.marker.map({ exists(cacheURL.appendingPathComponent($0)) }) ?? true
            else { return nil }
            return (cacheURL, cache)
        }
    }

    /// Does not follow a link, so a link with no target still counts.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// The item and each folder between it and `root` exist and are not links.
    private static func isOwned(_ url: URL, under root: URL) -> Bool {
        var current = url
        while current.path.count > root.path.count {
            guard let type = (try? FileManager.default.attributesOfItem(atPath: current.path))?[.type] as? FileAttributeType,
                  type != .typeSymbolicLink else { return false }
            current.deleteLastPathComponent()
        }
        return true
    }
}
