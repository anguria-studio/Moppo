import Foundation

/// Every pair of photographs close enough to matter at *any* setting the similarity
/// picker offers, with the distance between them.
///
/// This exists because comparing was being redone for a number that only ever
/// filters. Measured on a real library of 11,220 fingerprints — 62,938,590 pairs —
/// the pairs within the loosest setting number **12,695: 0.02% of them, 148 KB**.
/// The sub-counts are what the picker actually selects between: 56 pairs at 0.15,
/// 109 at 0.25, 263 at 0.35, 2,295 at 0.45, 12,695 at 0.55. So the comparison is
/// done once, at the ceiling, and every setting after that is a filter over a list
/// small enough to fit in a cache line budget.
///
/// The graph is exact, not an approximation. It holds every pair within `ceiling`,
/// so for any threshold at or below it, "are these two within t" is answered by
/// lookup with the same result the arithmetic would have given.
public struct PhotoNeighbourGraph: Sendable, Equatable {

    /// The largest threshold this graph can answer for. Asking beyond it would
    /// return false for pairs that were never examined, which is not "no" — it is
    /// "not asked" — so `DuplicateGrouper` refuses rather than guessing.
    public let ceiling: Float

    /// Assets that were successfully fingerprinted. An asset outside this set was
    /// never compared with anything, and is not the same as an asset compared and
    /// found to match nothing.
    public let fingerprinted: Set<String>

    /// Symmetric adjacency: both directions are stored, because the clustering asks
    /// in whichever order the ids happen to sort.
    private let neighbours: [String: [String: Float]]

    public init(ceiling: Float, fingerprinted: Set<String>, edges: [(String, String, Float)]) {
        self.ceiling = ceiling
        self.fingerprinted = fingerprinted
        var table: [String: [String: Float]] = [:]
        for (a, b, distance) in edges {
            table[a, default: [:]][b] = distance
            table[b, default: [:]][a] = distance
        }
        self.neighbours = table
    }

    public var edgeCount: Int {
        neighbours.values.reduce(0) { $0 + $1.count } / 2
    }

    public func isWithin(_ threshold: Float, _ a: String, _ b: String) -> Bool {
        guard let distance = neighbours[a]?[b] else { return false }
        return distance <= threshold
    }

    public func distance(_ a: String, _ b: String) -> Float? {
        neighbours[a]?[b]
    }

    /// Everything within `threshold` of this photograph.
    ///
    /// This is what makes a regroup instant rather than merely quicker. Clustering
    /// asked "does this belong in any existing cluster" by walking every cluster
    /// there was — 11,220 photographs against a growing list of them, tens of
    /// millions of questions, and answering each from the graph instead of by
    /// arithmetic still took five seconds because the questions themselves were the
    /// cost. Almost none of them could have been yes: 12,695 edges over 11,220
    /// photographs is about two neighbours each, and most have none at all. A
    /// cluster containing no neighbour of this photograph cannot accept it under
    /// complete linkage, so those clusters never need to be asked.
    public func neighbours(within threshold: Float, of id: String) -> [String] {
        guard let adjacent = neighbours[id] else { return [] }
        return adjacent.compactMap { $0.value <= threshold ? $0.key : nil }
    }

    // MARK: - Building

    /// Compares every pair inside each capture-time bucket, keeping the close ones.
    ///
    /// Bucketing is the same rule the grouping has always used and for the same
    /// reason: two identical shots a week apart are not duplicates of each other,
    /// they are the same subject photographed twice. It also keeps this quadratic.
    ///
    /// **Parallel**, because it is the one genuinely expensive thing left. Measured
    /// on the library above at a 0.55 ceiling: 18.02 s on one core, 4.96 s on four,
    /// **3.41 s on eight**, 3.92 s on twelve — this Mac has eight, and asking for
    /// more than the machine has costs time rather than saving it. The edge count is
    /// identical at every width, which is the point: the work is partitioned, not
    /// approximated.
    ///
    /// Rows are unequal — row `i` compares against `n - i` others — so workers stride
    /// by index rather than taking contiguous slices. A slice of the last rows is
    /// nearly free and would leave that worker idle while the first one finishes.
    ///
    /// `concurrentPerform` and not a detached dispatch: it runs the work on the
    /// calling thread as well as on workers, so it cannot starve itself the way
    /// dispatching to the global queue and then blocking on it starved the size
    /// measurer's workers.
    public static func build(
        assets: [PhotoAsset],
        fingerprints: [String: PhotoFingerprint],
        bucketInterval: TimeInterval,
        ceiling: Float,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> PhotoNeighbourGraph {
        let comparable = assets.filter {
            !$0.isHidden && $0.mediaType == .image && fingerprints[$0.id] != nil
        }
        let fingerprinted = Set(comparable.map(\.id))

        var buckets: [Int64: [PhotoAsset]] = [:]
        for asset in comparable {
            let key = Int64((asset.creationDate?.timeIntervalSince1970 ?? 0) / bucketInterval)
            buckets[key, default: []].append(asset)
        }

        // Count pairs across all buckets so large buckets can report progress while they run.
        let ordered = buckets.sorted { $0.key < $1.key }.map(\.value)
        let totalPairs = ordered.reduce(Int64(0)) {
            $0 + Int64($1.count) * Int64($1.count - 1) / 2
        }
        let progress = onProgress.map { ComparisonProgress(totalPairs: totalPairs, onProgress: $0) }
        if !isCancelled() { onProgress?(0) }

        var edges: [(String, String, Float)] = []
        for bucket in ordered {
            if isCancelled() { break }
            guard bucket.count > 1 else { continue }
            edges.append(contentsOf: compare(
                bucket, fingerprints: fingerprints, ceiling: ceiling,
                isCancelled: isCancelled, progress: progress
            ))
        }

        let graph = PhotoNeighbourGraph(
            ceiling: ceiling, fingerprinted: fingerprinted, edges: edges
        )
        if !isCancelled() { onProgress?(1) }
        return graph
    }

    /// Reports each percentage once. The lock keeps callbacks from parallel workers in order.
    private final class ComparisonProgress: @unchecked Sendable {
        private let lock = NSLock()
        private let totalPairs: Int64
        private let onProgress: @Sendable (Double) -> Void
        private var completedPairs: Int64 = 0
        private var reportedPercent = 0

        init(totalPairs: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
            self.totalPairs = totalPairs
            self.onProgress = onProgress
        }

        func advance(by count: Int) {
            lock.withLock {
                completedPairs += Int64(count)
                guard totalPairs > 0 else { return }
                // Reserve completion until all workers and graph construction finish.
                let percent = min(99, Int(100 * Double(completedPairs) / Double(totalPairs)))
                guard percent > reportedPercent else { return }
                reportedPercent = percent
                onProgress(Double(percent) / 100)
            }
        }
    }

    private static func compare(
        _ bucket: [PhotoAsset],
        fingerprints: [String: PhotoFingerprint],
        ceiling: Float,
        isCancelled: @Sendable () -> Bool,
        progress: ComparisonProgress?
    ) -> [(String, String, Float)] {
        // Hoisted out of the dictionary: the inner loop runs tens of millions of
        // times and the lookup dominated the comparison itself.
        let ordered = bucket.sorted { $0.id < $1.id }
        let ids = ordered.map(\.id)
        let prints = ids.map { fingerprints[$0]! }
        let workers = min(
            max(1, ProcessInfo.processInfo.activeProcessorCount),
            max(1, prints.count)
        )

        let lock = NSLock()
        nonisolated(unsafe) var collected: [(String, String, Float)] = []
        let idsRef = ids
        let printsRef = prints

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var local: [(String, String, Float)] = []
            var i = worker
            rows: while i < printsRef.count {
                if isCancelled() { break }
                for j in (i + 1)..<printsRef.count {
                    if j.isMultiple(of: 256), isCancelled() { break rows }
                    guard printsRef[i].isWithin(ceiling, of: printsRef[j]) else { continue }
                    // Only for the survivors — 0.02% of pairs — so the full
                    // 768-dimension distance here costs nothing next to the scan.
                    if let d = printsRef[i].distance(to: printsRef[j]) {
                        local.append((idsRef[i], idsRef[j], d))
                    }
                }
                if !isCancelled() { progress?.advance(by: printsRef.count - i - 1) }
                i += workers
            }
            lock.lock()
            collected.append(contentsOf: local)
            lock.unlock()
        }

        // Deliberately unsorted. Workers finish in whatever order they finish, and
        // it cannot matter: these become a dictionary, each pair appears once, and
        // the clustering sorts by id before it reads any of it. A sort here was
        // written first and removed after breaking it changed no test — determinism
        // was already guaranteed by the two things above, not by this.
        return collected
    }
}
