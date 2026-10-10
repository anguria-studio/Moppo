import Foundation
import MoppoCore

protocol StorageExplorerScanning: Sendable {
    func scan(
        directory: URL, excludedPaths: [String], excludedPatterns: [String],
        progress: (@Sendable (StorageExplorerSnapshot) -> Void)?
    ) async throws -> StorageExplorerSnapshot
    func reviewSelection(
        _ items: [StorageExplorerItem], in directory: URL,
        excludedPaths: [String], excludedPatterns: [String]
    ) async throws -> StorageExplorerSelectionReview
}

extension StorageExplorerService: StorageExplorerScanning {}

protocol StorageExplorerRemoving: Sendable {
    func remove(
        _ items: [StorageExplorerItem], from directory: URL, keepReceipt: Bool
    ) async throws -> CleanupOutcome
}

extension StorageExplorerRemovalService: StorageExplorerRemoving {}
