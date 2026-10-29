import Darwin
import Foundation
import MoppoCore

@main
struct AdministratorTrashMain {
    static func main() async {
        do {
            guard geteuid() == 0, CommandLine.arguments.count == 2 else {
                throw AdministratorTrashError.invalidRequest
            }
            let request = try AdministratorTrashRequest.read(from: CommandLine.arguments[1])
            try await request.perform()
        } catch {
            FileHandle.standardError.write(Data("Moppo could not complete the approved move.\n".utf8))
            exit(1)
        }
    }
}
