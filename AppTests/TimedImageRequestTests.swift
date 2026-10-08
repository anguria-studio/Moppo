import AppKit
import Foundation
import Photos
import Testing

@Suite("Photo request completion")
struct TimedImageRequestTests {
    @Test("An interrupted download times out and ignores a late callback")
    func timeout() async {
        let transport = ImageTransport()
        let request = TimedImageRequest(cancelRequest: { transport.cancel($0) })
        let image = await request.image(timeout: 0.02) { transport.start($0) }
        #expect(image == nil)
        #expect(transport.cancelled == [42])
        transport.complete(NSImage(size: NSSize(width: 10, height: 10)))
        #expect(transport.cancelled == [42])
    }

    @Test("Cancellation releases an active download before its deadline")
    func cancellation() async throws {
        let transport = ImageTransport()
        let request = TimedImageRequest(cancelRequest: { transport.cancel($0) })
        let task = Task { await request.image(timeout: 60) { transport.start($0) } }
        let deadline = ContinuousClock.now + .seconds(2)
        while !transport.started, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(transport.started)
        task.cancel()
        #expect(await task.value == nil)
        #expect(transport.cancelled == [42])
        transport.complete(nil)
    }

    @Test("A synchronous callback completes exactly once")
    func synchronousCompletion() async {
        let image = await TimedImageRequest(cancelRequest: { _ in }).image(timeout: 1) { complete in
            complete(NSImage(size: NSSize(width: 10, height: 10)))
            complete(nil)
            return 42
        }
        #expect(image != nil)
    }
}

private final class ImageTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (NSImage?) -> Void)?
    private var cancellations: [PHImageRequestID] = []
    var started: Bool { lock.withLock { completion != nil } }
    var cancelled: [PHImageRequestID] { lock.withLock { cancellations } }
    func start(_ completion: @escaping @Sendable (NSImage?) -> Void) -> PHImageRequestID {
        lock.withLock { self.completion = completion }
        return 42
    }
    func cancel(_ id: PHImageRequestID) { lock.withLock { cancellations.append(id) } }
    func complete(_ image: NSImage?) {
        let callback = lock.withLock { completion }
        callback?(image)
    }
}
