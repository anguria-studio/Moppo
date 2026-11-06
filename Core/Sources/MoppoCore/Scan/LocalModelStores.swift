import Foundation

/// One locally stored machine-learning model, as its runtime's store describes it.
public struct LocalModel: Sendable, Equatable {
    /// The downloaded repository name, such as `org/repo`. For a set of models
    /// that share their weights, the names joined — see `LocalModelStores.grouped`.
    public var name: String {
        memberNames.count <= 2
            ? memberNames.joined(separator: " + ")
            : "\(memberNames[0]) + \(memberNames.count - 1) more"
    }
    /// One name, or every model in a set.
    public let memberNames: [String]
    public let runtime: String
    /// The repository folder or model file that represents the model in its store.
    public let primary: URL
    /// Every manifest or repository folder represented by this row.
    public let memberPaths: [URL]
    /// Files only this model refers to. They go with it.
    public let exclusive: [URL]
    /// Bytes in files this model shares with another. They stay, and the row says so.
    public let sharedBytes: Int64
    /// The store folder that holds the model.
    public internal(set) var folder: ModelStoreFolder? = nil
}

/// Reads the Hugging Face, LM Studio, PyTorch Hub, Whisper, Keras, and GPT4All model stores.
/// Ollama, Hugging Face, PyTorch Hub, Whisper, and Keras stores can also be at a folder that a variable sets.
/// Shared files remain outside removal targets unless every owner belongs to the selected group.
/// Ollama models remain protected inventory until ownership and runtime checks support their storage.
/// See THIRD_PARTY_NOTICES.md for source credits.
public enum LocalModelStores {

    public static func all(home: URL, context: ScanContext = ScanContext()) -> [LocalModel] {
        all(ModelStoreFolders(home: home, environment: context.environment), context: context)
    }

    static func all(_ folders: ModelStoreFolders, context: ScanContext) -> [LocalModel] {
        let home = folders.home
        let plain = lmStudio(home: home) + pyTorchHub(folders) + whisper(folders)
            + keras(folders) + gpt4All(home: home)
        return huggingFace(folders, context: context) + plain.filter { !context.isExcluded($0.primary) }
    }

    // The claim sets and the store paths are in `Generated/ToolRules.swift`. Change a rule in `rules/<tool>.json`.

    /// Every path that AI Tools claims for local models, with the folders that variables set.
    public static func claimedPaths(home: URL, environment: [String: String] = [:]) -> [String] {
        homeDotFolders.map { home.appendingPathComponent($0).path }
            + dotCacheFolders.map { home.appendingPathComponent(".cache/" + $0).path }
            + partlyClaimedFolders.flatMap { folder, children in
                children.map { home.appendingPathComponent(folder).appendingPathComponent($0).path }
            }
            + ModelStoreFolders(home: home, environment: environment).claimedPaths
    }

    /// The children of a partly claimed folder that its claim leaves to other categories.
    /// AI Tools storage rules can also claim part of a folder, such as `~/.config/goose`.
    /// Returns nil when no reader claims part of `folder`.
    public static func unclaimedChildren(of folder: URL, home: URL) -> [URL]? {
        let base = home.standardizedFileURL.path + "/"
        let path = folder.standardizedFileURL.path
        let relative = String(path.dropFirst(base.count))
        guard path.hasPrefix(base),
              let claimed = partlyClaimedFolders[relative] ?? AIToolStorage.partlyClaimedFolders[relative]
        else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !claimed.contains($0) }.sorted().map { folder.appendingPathComponent($0) }
    }

    // MARK: - Hugging Face hub

    /// `~/.cache/huggingface/hub/models--<org>--<repo>` (and `datasets--`,
    /// `spaces--`). Two layouts exist and both are read:
    ///
    /// * **classic** — the repository's `blobs/` holds the files, `snapshots/` links
    ///   to them. The folder is the model.
    /// * **shared blobs** — the repository's `blobs/<hash>` is a link into
    ///   `hub/blobs/<aa>/<hash>`, and `<hash>.refs` beside the target lists, one per
    ///   line, the repository paths that use it. A target is exclusive when every
    ///   line belongs to this repository. Its `.refs` and `.lock` go with it, so no
    ///   record is left pointing at a file that is gone.
    ///
    /// The hub carries `CACHEDIR.TAG`: the tool itself declares all of this a cache.
    /// The worst a wrong reading can cost is a download.
    static func huggingFace(home: URL, context: ScanContext = ScanContext()) -> [LocalModel] {
        huggingFace(ModelStoreFolders(home: home, environment: context.environment), context: context)
    }

    /// Each hub is read alone. Two hubs do not share blobs.
    static func huggingFace(_ folders: ModelStoreFolders, context: ScanContext) -> [LocalModel] {
        folders.folders("huggingFaceHub", defaults: huggingFaceHubStores).flatMap { folder in
            huggingFaceHub(folder.url, context: context).map { $0.stored(in: folder) }
        }
    }

    private static func huggingFaceHub(_ hub: URL, context: ScanContext) -> [LocalModel] {
        let sharedStore = hub.appendingPathComponent("blobs", isDirectory: true)
            .standardizedFileURL.path
        let fm = FileManager.default

        let kinds = ["models--": "", "datasets--": "dataset ", "spaces--": "space "]
        var members: [Member] = []
        var folderIndex: [String: Int] = [:]
        for folder in directoryNames(hub) {
            guard let kind = kinds.first(where: { folder.hasPrefix($0.key) }) else { continue }
            folderIndex[folder] = members.count
            members.append(Member(
                name: kind.value + folder.dropFirst(kind.key.count).replacingOccurrences(of: "--", with: "/"),
                primary: hub.appendingPathComponent(folder, isDirectory: true)
            ))
        }

        // Who links to each blob is seen on the way, whatever its `.refs` says.
        var targets: [String: URL] = [:]
        var linkers: [String: Set<Int>] = [:]
        for (folder, member) in folderIndex {
            let repositoryBlobs = hub.appendingPathComponent(folder).appendingPathComponent("blobs", isDirectory: true)
            for blobName in directoryNames(repositoryBlobs) {
                let link = repositoryBlobs.appendingPathComponent(blobName)
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path)
                else { continue }   // classic layout: a real file, measured with the folder
                let target = URL(fileURLWithPath: destination, relativeTo: repositoryBlobs)
                    .standardizedFileURL
                if target.path.hasPrefix(sharedStore + "/"), isRegularFile(target) {
                    targets[target.path] = target
                    linkers[target.path, default: []].insert(member)
                }
            }
        }

        let sharedBlobs = targets.keys.sorted().compactMap { path -> Blob? in
            guard let target = targets[path] else { return nil }
            let refs = URL(fileURLWithPath: path + ".refs")
            let lines = ((try? String(contentsOf: refs, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).map(String.init)
            let folders = lines.compactMap { $0.split(separator: "/").first.map(String.init) }
            let recorded = Set(folders.compactMap { folderIndex[$0] })
            let users = recorded.union(linkers[path] ?? [])
            var files = [target, refs]
            let lock = URL(fileURLWithPath: path + ".lock")
            if fm.fileExists(atPath: lock.path) { files.append(lock) }
            return Blob(
                files: files, bytes: allocatedSize(target), users: users,
                // No record, or a record naming a repository that is not here, is not
                // evidence that nobody else uses the blob.
                usersAreComplete: !lines.isEmpty && recorded.count == Set(folders).count
            )
        }
        return grouped(members, sharedBlobs, runtime: "Hugging Face", context: context)
    }

    // MARK: - LM Studio

    /// `<store>/<publisher>/<repository>/` holds a model's files as plain files,
    /// with nothing shared between two of them. The store is `~/.lmstudio/models`,
    /// and `~/.cache/lm-studio/models` on installs from before it moved.
    static func lmStudio(home: URL) -> [LocalModel] {
        lmStudioStores.flatMap { relative -> [LocalModel] in
            let store = home.appendingPathComponent(relative, isDirectory: true).appendingPathComponent("models", isDirectory: true)
            return directoryNames(store).flatMap { publisher -> [LocalModel] in
                let publisherURL = store.appendingPathComponent(publisher, isDirectory: true)
                return directoryNames(publisherURL).compactMap { repository in
                    let url = publisherURL.appendingPathComponent(repository, isDirectory: true)
                    guard isDirectory(url) else { return nil }
                    return plainModel(url, name: "\(publisher)/\(repository)", runtime: "LM Studio")
                }
            }
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Stores of plain files

    /// `~/.cache/torch/hub` holds weight files in `checkpoints/` and one folder for each
    /// downloaded repository, named `<owner>_<repository>_<ref>`. GitHub owner names
    /// contain no underscore. A ref with an underscore keeps its first part in the name.
    static func pyTorchHub(_ folders: ModelStoreFolders) -> [LocalModel] {
        folders.folders("pyTorchHub", defaults: pyTorchHubStores).flatMap { folder in
            pyTorchHub(folder.url).map { $0.stored(in: folder) }
        }
    }

    private static func pyTorchHub(_ hub: URL) -> [LocalModel] {
        let checkpoints = hub.appendingPathComponent("checkpoints", isDirectory: true)
        let weights = directoryNames(checkpoints).map { checkpoints.appendingPathComponent($0) }
            .filter(isRegularFile)
            .map { plainModel($0, name: $0.lastPathComponent, runtime: "PyTorch") }
        let repositories = directoryNames(hub).filter { $0 != "checkpoints" }.compactMap { folder -> LocalModel? in
            let url = hub.appendingPathComponent(folder, isDirectory: true)
            let parts = folder.split(separator: "_", omittingEmptySubsequences: false)
            guard parts.count >= 3, isDirectory(url) else { return nil }
            let repository = parts[1..<(parts.count - 1)].joined(separator: "_")
            return plainModel(url, name: "\(parts[0])/\(repository)", runtime: "PyTorch")
        }
        return (weights + repositories).sorted { $0.name < $1.name }
    }

    /// `~/.cache/whisper/<name>.pt`. Each file is one model.
    static func whisper(_ folders: ModelStoreFolders) -> [LocalModel] {
        folders.folders("whisper", defaults: whisperStores).flatMap { folder in
            whisper(folder.url).map { $0.stored(in: folder) }
        }
    }

    private static func whisper(_ store: URL) -> [LocalModel] {
        directoryNames(store).filter { $0.hasSuffix(".pt") }
            .map { store.appendingPathComponent($0) }
            .filter(isRegularFile)
            .map { plainModel($0, name: $0.deletingPathExtension().lastPathComponent, runtime: "Whisper") }
            .sorted { $0.name < $1.name }
    }

    /// `~/.keras/models/<item>` and `~/.keras/datasets/<item>`. An item is a file or an
    /// extracted folder. `~/.keras/keras.json` holds settings and is never read.
    static func keras(_ folders: ModelStoreFolders) -> [LocalModel] {
        return folders.folders("keras", defaults: kerasStores).flatMap { folder -> [LocalModel] in
            let store = folder.url
            let prefix = store.lastPathComponent == "datasets" ? "dataset " : ""
            return directoryNames(store).map { store.appendingPathComponent($0) }
                .filter { isRegularFile($0) || isDirectory($0) }
                .map { plainModel($0, name: prefix + $0.lastPathComponent, runtime: "Keras").stored(in: folder) }
        }
        .sorted { $0.name < $1.name }
    }

    /// `~/Library/Application Support/nomic.ai/GPT4All/*.gguf`. Settings, chats, and
    /// LocalDocs databases in the same folder are never read.
    /// GPT4All can use another download folder. Its `modelPath` setting changed its name
    /// in GPT4All 2.4.11, so Moppo reads only the default folder. Issue #66 records this gap.
    static func gpt4All(home: URL) -> [LocalModel] {
        guard let relative = gpt4AllStores.first else { return [] }
        let store = home.appendingPathComponent(relative, isDirectory: true)
        return directoryNames(store).filter { $0.lowercased().hasSuffix(".gguf") }
            .map { store.appendingPathComponent($0) }
            .filter(isRegularFile)
            .map { plainModel($0, name: $0.lastPathComponent, runtime: "GPT4All") }
            .sorted { $0.name < $1.name }
    }

    /// The Ollama model folders: the default folder, then the folder that `OLLAMA_MODELS` sets.
    static func ollama(_ folders: ModelStoreFolders) -> [ModelStoreFolder] {
        folders.folders("ollama", defaults: ollamaStores)
    }

    /// The Hugging Face home folders. Their files other than the hubs stay protected.
    static func huggingFaceHomes(_ folders: ModelStoreFolders) -> [ModelStoreFolder] {
        folders.folders("huggingFace", defaults: huggingFaceStores)
    }

    /// A model that is one file or folder, with nothing shared with another model.
    private static func plainModel(_ url: URL, name: String, runtime: String) -> LocalModel {
        LocalModel(memberNames: [name], runtime: runtime, primary: url,
                   memberPaths: [url], exclusive: [], sharedBytes: 0)
    }

    /// Symbolic links that LM Studio keeps, such as `lms import --symbolic-link` models.
    struct ExternalLinks: Sendable, Equatable {
        /// Each link target, as written and with all links resolved.
        var targets: Set<String> = []
        /// False when a folder could not be read. Missing links then do not prove independence.
        var isComplete = true

        /// True when a link target is `url` or is inside it.
        func reach(_ url: URL) -> Bool {
            let paths = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().path])
            return targets.contains { target in
                paths.contains { target == $0 || target.hasPrefix($0 + "/") }
            }
        }
    }

    /// Limits the entries read through LM Studio folders and their directory links.
    static let linkEntryLimit = 200_000

    /// Reads every symbolic link in the LM Studio folders, with or without a model row.
    /// Directory links are read once each, so a link cycle stops.
    static func lmStudioLinks(home: URL, entryLimit: Int = linkEntryLimit) -> ExternalLinks {
        var links = ExternalLinks()
        let fm = FileManager.default
        var pending = lmStudioStores.map {
            home.appendingPathComponent($0, isDirectory: true).resolvingSymlinksInPath()
        }
        var visited: Set<String> = []
        var entries = 0
        while let root = pending.popLast() {
            guard visited.insert(root.standardizedFileURL.path).inserted,
                  fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [],
                errorHandler: { _, _ in links.isComplete = false; return true }
            ) else { links.isComplete = false; continue }
            for case let url as URL in enumerator {
                entries += 1
                guard entries <= entryLimit else { links.isComplete = false; return links }
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) else {
                    links.isComplete = false
                    continue
                }
                let resolved = url.resolvingSymlinksInPath()
                links.targets.insert(URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent())
                    .standardizedFileURL.path)
                links.targets.insert(resolved.path)
                // The enumerator does not follow directory links, so read their targets next.
                var info = stat()
                if stat(url.path, &info) == 0 {
                    if info.st_mode & S_IFMT == S_IFDIR { pending.append(resolved) }
                } else if errno != ENOENT {
                    links.isComplete = false
                }
            }
        }
        return links
    }

    // MARK: - Sets

    struct Member { let name: String; let primary: URL }

    /// A content-addressed file and the models that refer to it.
    struct Blob {
        /// The blob, and any record kept beside it that goes when it goes.
        let files: [URL]
        let bytes: Int64
        let users: Set<Int>
        /// False when who uses it could not be fully read. Such a blob is never
        /// anybody's to remove.
        let usersAreComplete: Bool
    }

    /// Groups models that share files of at least 1 MiB.
    static let setThreshold: Int64 = 1024 * 1024

    /// Keeps excluded owners in reference counts but outside removal groups.
    /// Files with other owners remain on disk.
    static func grouped(
        _ members: [Member], _ blobs: [Blob], runtime: String, context: ScanContext = ScanContext()
    ) -> [LocalModel] {
        let excluded = Set(members.indices.filter { context.isExcluded(members[$0].primary) })
        var parent = Array(members.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        for blob in blobs where blob.usersAreComplete && blob.bytes >= setThreshold {
            let eligible = blob.users.subtracting(excluded)
            guard let first = eligible.min() else { continue }
            for user in eligible { parent[root(user)] = root(first) }
        }

        var sets: [Int: [Int]] = [:]
        for index in members.indices where !excluded.contains(index) { sets[root(index), default: []].append(index) }

        return sets.values.map { $0.sorted { members[$0].name < members[$1].name } }
            .sorted { members[$0[0]].name < members[$1[0]].name }
            .map { set in
                let inside = Set(set)
                var exclusive = set.dropFirst().map { members[$0].primary }
                var shared: Int64 = 0
                for blob in blobs where !blob.users.isDisjoint(with: inside) {
                    if blob.usersAreComplete, blob.users.isSubset(of: inside) {
                        exclusive += blob.files
                    } else {
                        shared += blob.bytes
                    }
                }
                return LocalModel(
                    memberNames: set.map { members[$0].name }, runtime: runtime,
                    primary: members[set[0]].primary, memberPaths: set.map { members[$0].primary },
                    exclusive: exclusive, sharedBytes: shared
                )
            }
    }

    // MARK: - Support

    private static func directoryNames(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func allocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
}

extension LocalModel {
    /// The model with the store folder that holds it.
    func stored(in folder: ModelStoreFolder) -> LocalModel {
        var model = self
        model.folder = folder
        return model
    }
}
