import AppKit
import SwiftUI
import Testing
import MoppoCore

@Suite("Protected selection controls", .serialized)
@MainActor
struct ProtectedSelectionControlTests {
    @Test("Unlocking a group leaves regular checkboxes empty and selection does not change their size", arguments: [false, true])
    func groupControls(dark: Bool) async throws {
        var child = FileEntry(url: URL(fileURLWithPath: "/moppo-fixture/history"),
            displayName: "History", kind: .file, allocatedBytes: 64, protectionReason: .userData)
        child.isRegenerable = false
        let group = FileEntry(url: URL(fileURLWithPath: "/moppo-fixture/sessions"),
            displayName: "Sessions", kind: .folder, allocatedBytes: 0,
            protectionReason: .inventory, children: [child])
        let cleanup = CleanupModel(operations: OperationCoordinator())
        let now = Date()
        cleanup.scanResults = .init(categories: [.init(categoryID: .aiTools, entries: [group])],
            startedAt: now, finishedAt: now)
        let host = NSHostingView(rootView: Controls(cleanup: cleanup, group: group)
            .padding(20).background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 140, height: 70),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        cleanup.unlockChildren(in: group)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.userDataRemovalOverrides == [child.id])
        let buttons = nativeButtons(in: host)
        #expect(buttons.count == 2)
        let parent = try #require(buttons.first { $0.accessibilityLabel() == "Select child items in Sessions" })
        #expect(buttons.allSatisfy { $0.state == .off && $0.controlSize == .regular })
        let frames = buttons.map(\.frame)
        for button in buttons {
            #expect(button.bounds.width >= 15 && button.bounds.height >= 15)
            button.highlight(true)
            button.displayIfNeeded()
            button.highlight(false)
        }
        host.layoutSubtreeIfNeeded()
        #expect(buttons.map(\.frame) == frames)
        parent.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(cleanup.scannerSelection == [child.id])
        #expect(buttons.allSatisfy { $0.state == .on })
        parent.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.userDataRemovalOverrides == [child.id])
        #expect(buttons.allSatisfy { $0.state == .off })
        #expect(buttons.map(\.frame) == frames)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/moppo-unlock-controls-\(dark ? "dark" : "light").png"))
    }

    private struct Controls: View {
        @Bindable var cleanup: CleanupModel
        let group: FileEntry

        var body: some View {
            HStack(spacing: 20) {
                ProtectedSelectionControl(entry: group, isSelected: false,
                    selectionState: group.children.allSatisfy { cleanup.scannerSelection.contains($0.id) } ? .on : .off,
                    hasUserDataOverride: false,
                    hasUnlockedChildren: group.unlockableChildren.allSatisfy { cleanup.userDataRemovalOverrides.contains($0.id) },
                    onUnlockChildren: { cleanup.unlockChildren(in: group) }, help: "Unlock child items.",
                    onToggle: { cleanup.setChildrenSelected($0, in: group.id) }, onRequestUserDataOverride: {})
                ForEach(group.children) { child in
                    ProtectedSelectionControl(entry: child, isSelected: cleanup.scannerSelection.contains(child.id),
                        hasUserDataOverride: cleanup.userDataRemovalOverrides.contains(child.id), help: "Select history.",
                        onToggle: { if $0 { cleanup.scannerSelection.insert(child.id) } else { cleanup.scannerSelection.remove(child.id) } },
                        onRequestUserDataOverride: {})
                }
            }
        }
    }

    private func nativeButtons(in view: NSView) -> [NSButton] {
        if let button = view as? NSButton { return [button] }
        return view.subviews.flatMap(nativeButtons)
    }
}
