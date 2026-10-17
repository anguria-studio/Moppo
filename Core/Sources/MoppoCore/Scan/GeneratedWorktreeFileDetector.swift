import Foundation
import Darwin

/// Recognizes generated files without treating local settings or project bundles as caches.
struct GeneratedWorktreeFileDetector {
    let root: URL

    func recognizes(_ url: URL, isDirectory: Bool) -> Bool {
        if isDirectory {
            if children(of: url, limit: 1)?.isEmpty == true { return true }
            if url.lastPathComponent == ".next" {
                return isNextProject(url.deletingLastPathComponent())
                    && (isNextOutput(url) || isNextOutput(url.appendingPathComponent("dev")))
            }
            if url.lastPathComponent == "xcuserdata", isXcodeUserData(url) {
                var budget = 64
                return isDisposableXcodeTree(url, budget: &budget)
            }
            return false
        }

        switch url.lastPathComponent {
        case ".DS_Store":
            return read(url, limit: 8, prefixOnly: true) == Data([0, 0, 0, 1, 66, 117, 100, 49])
        case "next-env.d.ts":
            return isNextTypeDeclaration(url)
        case "xcschememanagement.plist", "UserInterfaceState.xcuserstate":
            return isXcodeUserData(url) && isDisposableXcodeFile(url)
        default:
            return url.pathExtension == "tsbuildinfo" && isTypeScriptBuildInfo(url)
        }
    }

    private func isNextProject(_ directory: URL) -> Bool {
        guard let manifest = json(directory.appendingPathComponent("package.json")) else { return false }
        return ["dependencies", "devDependencies"].contains {
            guard let packages = manifest[$0] as? [String: Any], let version = packages["next"] as? String else { return false }
            return !version.isEmpty
        }
    }

    private func isNextOutput(_ directory: URL) -> Bool {
        guard json(directory.appendingPathComponent("package.json"))?["type"] as? String == "commonjs",
              let manifest = json(directory.appendingPathComponent("build-manifest.json")),
              manifest["pages"] is [String: Any], manifest["rootMainFiles"] is [String],
              let server = children(of: directory.appendingPathComponent("server"), limit: 1) else { return false }
        return !server.isEmpty
    }

    private func isNextTypeDeclaration(_ url: URL) -> Bool {
        guard isNextProject(url.deletingLastPathComponent()), let data = read(url, limit: 16 * 1024),
              let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let references: Set<String> = [
            "/// <reference types=\"next\" />",
            "/// <reference types=\"next/image-types/global\" />",
            "/// <reference types=\"next/navigation-types/compat/navigation\" />"
        ]
        let notice = "// NOTE: This file should not be edited"
        guard lines.contains("/// <reference types=\"next\" />"), lines.contains(notice) else { return false }
        return lines.allSatisfy { line in
            if line.isEmpty || references.contains(line) || line == notice { return true }
            if line.hasPrefix("// see https://nextjs.org/docs/"), line.hasSuffix(" for more information.") { return true }
            return line.range(of: #"^import "\./\.next/(dev/)?types/(routes\.d\.ts|root-params\.d\.ts|cache-life\.d\.ts|validator\.ts|link\.d\.ts)";$"#,
                              options: .regularExpression) != nil
        }
    }

    private func isTypeScriptBuildInfo(_ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        let configs = ["tsconfig.json", url.deletingPathExtension().lastPathComponent + ".json"]
        guard configs.contains(where: { read(directory.appendingPathComponent($0), limit: 128 * 1024)?.isEmpty == false }),
              let object = json(url, limit: 2 * 1024 * 1024),
              let version = object["version"] as? String,
              version.range(of: #"^\d+\.\d+\.\d+([-.].+)?$"#, options: .regularExpression) != nil else { return false }
        let program = object["program"] as? [String: Any] ?? object
        guard let names = program["fileNames"] as? [String], !names.isEmpty,
              let infos = program["fileInfos"] as? [Any], infos.count == names.count else { return false }
        return infos.allSatisfy { info in
            if let version = info as? String { return !version.isEmpty }
            return (info as? [String: Any])?["version"] is String
        }
    }

    private func isXcodeUserData(_ url: URL) -> Bool {
        var directory = url
        while directory.path != root.path, directory.path.hasPrefix(root.path + "/") {
            if directory.lastPathComponent == "xcuserdata" {
                let owner = directory.deletingLastPathComponent()
                return ["xcodeproj", "xcworkspace"].contains(owner.pathExtension)
                    || (owner.lastPathComponent == "xcode" && owner.deletingLastPathComponent().lastPathComponent == ".swiftpm")
            }
            directory.deleteLastPathComponent()
        }
        return false
    }

    private func isDisposableXcodeTree(_ url: URL, budget: inout Int) -> Bool {
        guard let entries = children(of: url, limit: budget + 1), entries.count <= budget else { return false }
        budget -= entries.count
        for child in entries {
            guard let values = safeValues(child) else { return false }
            if values.isDirectory == true {
                guard child.pathExtension == "xcuserdatad" || child.lastPathComponent == "xcschemes",
                      isDisposableXcodeTree(child, budget: &budget) else { return false }
            } else if !isDisposableXcodeFile(child) {
                return false
            }
        }
        return true
    }

    private func isDisposableXcodeFile(_ url: URL) -> Bool {
        guard ["xcschememanagement.plist", "UserInterfaceState.xcuserstate"].contains(url.lastPathComponent),
              let data = read(url, limit: 512 * 1024),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        if url.lastPathComponent == "UserInterfaceState.xcuserstate" {
            return url.deletingLastPathComponent().pathExtension == "xcuserdatad"
                && object["$archiver"] as? String == "NSKeyedArchiver"
                && object["$objects"] is [Any] && object["$top"] is [String: Any]
        }
        guard url.lastPathComponent == "xcschememanagement.plist",
              url.deletingLastPathComponent().lastPathComponent == "xcschemes",
              Set(object.keys) == ["SchemeUserState"], let schemes = object["SchemeUserState"] as? [String: Any] else { return false }
        return schemes.allSatisfy { name, value in
            guard name.hasSuffix(".xcscheme_^#shared#^_"), let settings = value as? [String: Any],
                  Set(settings.keys).isSubset(of: ["orderHint", "isShown"]) else { return false }
            return settings.values.allSatisfy { $0 is NSNumber }
        }
    }

    /// Checks every path component inside the worktree before reading evidence.
    private func safeValues(_ input: URL) -> URLResourceValues? {
        let url = input.standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/"), !Task.isCancelled else { return nil }
        var current = url
        while true {
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink == false else { return nil }
            if current.path == root.path { break }
            current.deleteLastPathComponent()
        }
        return try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
    }

    private func children(of url: URL, limit: Int) -> [URL]? {
        guard safeValues(url)?.isDirectory == true else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard let directory = fdopendir(descriptor) else { close(descriptor); return nil }
        defer { closedir(directory) }
        var entries: [URL] = []
        while entries.count < limit {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? entries : nil }
            guard let name = withUnsafeBytes(of: entry.pointee.d_name, { bytes in
                String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
            }) else { return nil }
            if name != ".", name != ".." { entries.append(url.appendingPathComponent(name)) }
        }
        return entries
    }

    /// Limits evidence reads and rejects links, special files, and unreadable data.
    private func read(_ url: URL, limit: Int, prefixOnly: Bool = false) -> Data? {
        guard safeValues(url)?.isRegularFile == true else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              prefixOnly || info.st_size <= limit,
              let data = try? handle.read(upToCount: prefixOnly ? limit : limit + 1), data.count <= limit else { return nil }
        return data
    }

    private func json(_ url: URL, limit: Int = 128 * 1024) -> [String: Any]? {
        guard let data = read(url, limit: limit) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
