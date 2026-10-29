import Foundation
import Testing
@testable import MoppoCore

@Suite("Administrator Trash moves")
struct AdministratorTrashRequestTests {
    enum Change: CaseIterable { case none, source, parent, symbolicParent, destination, danglingDestination }

    @Test("Approved moves retain identity and refuse replacements", arguments: Change.allCases)
    func move(change: Change) throws {
        let box = try AllocatedSizeMeasurerTests.Sandbox()
        let root = box.root.resolvingSymlinksInPath()
        let parent = try box.directory("source").resolvingSymlinksInPath()
        let source = try box.directory("source/Library ' $()\n").resolvingSymlinksInPath()
        let trash = try box.directory("Trash").resolvingSymlinksInPath()
        let destination = trash.appendingPathComponent("Library")
        let identity = try #require(FileIdentity.of(source))
        let request = try AdministratorTrashRequest(source: source, destination: destination, identity: identity)
        let saved = root.appendingPathComponent("Saved")
        switch change {
        case .source:
            try FileManager.default.moveItem(at: source, to: saved)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        case .parent, .symbolicParent:
            try FileManager.default.moveItem(at: parent, to: saved)
            if change == .symbolicParent {
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: saved)
            } else {
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            }
        case .destination:
            try Data("Keep".utf8).write(to: destination)
        case .danglingDestination:
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("Missing"))
        case .none: break
        }
        if change == .none {
            try request.moveWithoutReplacing()
            #expect(FileIdentity.isAbsent(source))
            #expect(FileIdentity.of(destination) == identity)
            try AdministratorTrashRequest(source: destination, destination: source, identity: identity).moveWithoutReplacing()
            #expect(FileIdentity.of(source) == identity)
        } else {
            #expect(throws: (any Error).self) { try request.moveWithoutReplacing() }
            #expect(!FileIdentity.isAbsent(source))
        }
    }

    @Test("The production helper rejects paths outside the sound library scope")
    func restrictedScope() async throws {
        let box = try AllocatedSizeMeasurerTests.Sandbox()
        let source = try box.directory("source").resolvingSymlinksInPath()
        let destination = box.root.resolvingSymlinksInPath().appendingPathComponent("destination")
        let request = try AdministratorTrashRequest(source: source, destination: destination,
                                                   identity: #require(FileIdentity.of(source)))
        await #expect(throws: AdministratorTrashError.invalidRequest) { try await request.perform() }
        #expect(!FileIdentity.isAbsent(source))
    }

    @Test("The helper rejects public requests and symbolic request files", arguments: [false, true])
    func unsafeRequestFile(link: Bool) throws {
        let box = try AllocatedSizeMeasurerTests.Sandbox()
        let source = try box.directory("source")
        let destination = box.root.appendingPathComponent("destination")
        let request = try AdministratorTrashRequest(source: source, destination: destination,
                                                   identity: #require(FileIdentity.of(source)))
        let file = box.root.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: link ? 0o600 : 0o644], ofItemAtPath: file.path)
        let input: URL
        if link {
            input = box.root.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: input, withDestinationURL: file)
        } else { input = file }
        #expect(throws: AdministratorTrashError.invalidRequest) { try AdministratorTrashRequest.read(from: input.path) }
    }
}
