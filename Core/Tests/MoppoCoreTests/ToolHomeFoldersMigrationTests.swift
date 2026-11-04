import Testing
@testable import MoppoCore

/// The generated `ToolHomeFolders.all` and `locations` equal the tables that `ToolHomeFolders.swift` held before #352.
/// This test leaves with the old tables, after the pull request records that it passed.
@Suite("Tool home folders migration")
struct ToolHomeFoldersMigrationTests {
    private typealias Folder = ToolHomeFolders.Folder
    private typealias Location = ToolHomeFolders.Location

    private static let oldFolders: [Folder] = [
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
        Folder(name: ".colima",
               explanation: "Colima keeps its virtual machines and container data disks here. Use colima delete after review."),
        Folder(name: ".lima",
               explanation: "Lima keeps its virtual machines and its SSH key here. Use limactl delete after review."),
        Folder(name: ".aws", explanation: "The AWS tools keep settings, credentials, and sign-in tokens here."),
        Folder(name: ".azure", explanation: "The Azure CLI keeps settings and sign-in tokens here."),
        Folder(name: ".config/gcloud", explanation: "The Google Cloud CLI keeps its settings and credentials here."),
        Folder(name: ".config/gh", explanation: "The GitHub CLI keeps its settings and sign-in tokens here."),
        Folder(name: ".docker", explanation: "Docker keeps its settings here. config.json can contain registry credentials."),
        Folder(name: ".gnupg", explanation: "GnuPG keeps your keys and settings here."),
        Folder(name: ".kube", explanation: "kubectl keeps cluster settings and credentials here."),
        Folder(name: ".ssh", explanation: "SSH keeps your keys and settings here.")
    ]

    private static let oldLocations: [Location] = [
        Location(path: ".local/share/containers/podman/machine", name: "Podman machines",
                 identifiedBy: ["machine.pub", "applehv", "libkrun"],
                 explanation: "Podman keeps its virtual machines, their disks, and an SSH key here. Use podman machine rm after review.",
                 layout: ["machine.pub"],
                 caches: [.download("applehv/cache", marker: "*.raw.zst",
                                    caveat: "The next podman machine init downloads it again. A network connection is necessary.")]),
        Location(path: ".local/share/mise", name: "mise tool versions", identifiedBy: ["installs"],
                 explanation: "mise keeps the installed tool versions here. Use mise uninstall to remove a version."),
        Location(path: ".local/share/NuGet", name: "NuGet data", identifiedBy: ["http-cache", "Migrations"],
                 explanation: "NuGet keeps its HTTP cache here. Use dotnet nuget locals http-cache --clear to remove the cache."),
        Location(path: ".local/share/gem", name: "RubyGems user gems", identifiedBy: ["ruby/*/specifications"],
                 explanation: "RubyGems keeps the gems from gem install --user-install here. Use gem uninstall --user-install to remove a gem."),
        Location(path: ".local/state/cabal", name: "cabal package store", identifiedBy: ["store/ghc-*"],
                 explanation: "cabal keeps built packages here. Projects and programs from cabal install can need them."),
        Location(path: "Library/Android/sdk", name: "Android SDK",
                 identifiedBy: [".knownPackages", "platform-tools", "build-tools", "cmdline-tools"],
                 explanation: "The Android SDK keeps build tools, platforms, system images, the NDK, and the emulator here. Use sdkmanager --uninstall to remove a package."),
        Location(path: "DBngin", name: "DBngin server versions", base: .sharedFolder, identifiedBy: ["*/*/bin"],
                 explanation: "DBngin keeps its database server versions here. Use DBngin to remove a version."),
        Location(path: "Library/Application Support/multimodal-models", name: "ai-coustics audio models",
                 identifiedBy: ["ai-coustics/*/*.aicmodel"],
                 explanation: "An application keeps ai-coustics audio models here. Moppo cannot identify the application, so it keeps the models protected.")
    ]

    private static func description(_ cache: ToolHomeFolders.Cache) -> String {
        "\(cache.path)|\(cache.marker ?? "-")|\(cache.isRegenerable)|\(cache.caveat ?? "-")"
    }

    private static func description(_ folder: Folder) -> String {
        "\(folder.name) | \(folder.explanation) | \(folder.layout) | \(folder.caches.map(description).sorted())"
    }

    private static func description(_ location: Location) -> String {
        "\(location.base) \(location.path) | \(location.name) | \(location.identifiedBy) | \(description(location.folder))"
    }

    @Test("the generated folders equal the old table")
    func generatedFoldersEqualOldTable() {
        #expect(ToolHomeFolders.all.map(Self.description).sorted() == Self.oldFolders.map(Self.description).sorted())
    }

    @Test("the generated locations equal the old table")
    func generatedLocationsEqualOldTable() {
        #expect(ToolHomeFolders.locations.map(Self.description).sorted() == Self.oldLocations.map(Self.description).sorted())
    }
}
