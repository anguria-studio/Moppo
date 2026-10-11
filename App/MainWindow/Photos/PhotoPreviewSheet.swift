import AppKit
import Photos
import SwiftUI
import MoppoCore

/// Presents a floating preview above the dimmed main window.
struct PhotoPreviewWindowPresenter: NSViewRepresentable {
    let item: PhotoDuplicatesModel.Preview?
    let model: PhotoDuplicatesModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(item: item, model: model, parent: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var panel: PreviewPanel?
        private var hostingView: NSHostingView<AnyView>?
        private var itemID: String?
        private var backdropClickMonitor: Any?
        private weak var model: PhotoDuplicatesModel?
        private weak var parentWindow: NSWindow?

        func update(item: PhotoDuplicatesModel.Preview?, model: PhotoDuplicatesModel, parent: NSWindow?) {
            self.model = model
            guard let item else { close(); return }
            guard let parent else { return }
            parentWindow = parent
            let identity = "\(item.groupID):\(item.id)"
            guard itemID != identity else { return }
            let content = AnyView(PhotoPreviewContent(
                item: item,
                model: model,
                thumbnails: model.thumbnails,
                onClose: { [weak self] in self?.dismiss() }
            ).id(item.groupID))

            if let panel, let hostingView {
                hostingView.rootView = content
                panel.makeKeyAndOrderFront(nil)
            } else {
                let panel = PreviewPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 790, height: 570),
                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.title = "Photo preview"
                panel.titleVisibility = .hidden
                panel.titlebarAppearsTransparent = true
                panel.isFloatingPanel = true
                panel.level = .floating
                panel.hidesOnDeactivate = true
                panel.isReleasedWhenClosed = false
                panel.isMovableByWindowBackground = true
                panel.contentMinSize = NSSize(width: 680, height: 460)
                panel.collectionBehavior = [.fullScreenAuxiliary]
                panel.appearance = parent.appearance
                for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    panel.standardWindowButton(button)?.isHidden = true
                }
                let hostingView = NSHostingView(rootView: content)
                panel.contentView = hostingView
                panel.delegate = self
                self.hostingView = hostingView
                self.panel = panel
                let bounds = parent.screen?.visibleFrame ?? parent.frame
                let x = min(max(parent.frame.midX - panel.frame.width / 2, bounds.minX), bounds.maxX - panel.frame.width)
                let y = min(max(parent.frame.midY - panel.frame.height / 2, bounds.minY), bounds.maxY - panel.frame.height)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                panel.makeKeyAndOrderFront(nil)
                installBackdropClickMonitor()
            }
            itemID = identity
        }

        private func installBackdropClickMonitor() {
            backdropClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, event.window === self.parentWindow else { return false }
                    panel.makeKeyAndOrderFront(nil)
                    return true
                }
                // Keep keyboard focus in the preview when the user clicks the dimmed window.
                return consumed ? nil : event
            }
        }

        private func dismiss() {
            model?.preview = nil
            close()
        }

        func windowWillClose(_ notification: Notification) {
            model?.preview = nil
            removeMonitor()
            panel = nil
            hostingView = nil
            itemID = nil
            parentWindow = nil
        }

        func close() {
            removeMonitor()
            panel?.delegate = nil
            panel?.close()
            panel = nil
            hostingView = nil
            itemID = nil
            parentWindow = nil
        }

        private func removeMonitor() {
            if let backdropClickMonitor { NSEvent.removeMonitor(backdropClickMonitor) }
            backdropClickMonitor = nil
        }
    }
}

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows a photo in a movable preview window.
struct PhotoPreviewContent: View {
    let item: PhotoDuplicatesModel.Preview
    @Bindable var model: PhotoDuplicatesModel
    let thumbnails: PhotoThumbnailLoader
    let onClose: () -> Void

    @State private var filename: String?

    private var shown: PhotoAsset { item.asset }

    private var group: DuplicateGroup? { model.groups.first { $0.id == item.groupID } }

    private var isKeeper: Bool { shown.id == group?.keeper.id }
    private var isSelected: Bool { model.selection.contains(shown.id) }
    private var siblings: [PhotoAsset] { group?.assets ?? [shown] }

    var body: some View {
        VStack(spacing: 0) {
            header
            image
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Token.Fill.cardContent)
        .ignoresSafeArea()
        .background(PhotoPreviewKeyboardHandler(onClose: onClose, onStep: step))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo preview")
        .task(id: shown.id) {
            filename = shown.filename
            guard filename == nil else { return }
            let id = shown.id
            let name = await Task.detached(priority: .userInitiated) {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return Optional<String>.none }
                return PHAssetResource.assetResources(for: asset).first?.originalFilename
            }.value
            guard !Task.isCancelled else { return }
            filename = name
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Token.Text.secondary)
            .background(Token.Fill.control, in: Circle())
            .accessibilityLabel("Close preview")
            .help("Close preview (Space or Escape)")

            VStack(alignment: .leading, spacing: 2) {
                if let date = shown.creationDate {
                    Text(date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(.mcControlLabel)
                        .foregroundStyle(Token.Text.primary)
                } else {
                    Text("Photo preview")
                        .font(.mcControlLabel)
                        .foregroundStyle(Token.Text.primary)
                }
                Text([filename, "\(shown.pixelWidth) × \(shown.pixelHeight)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
            }
            .lineLimit(1)
            if shown.isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundStyle(Token.textColor(.red))
                    .accessibilityLabel("Favorite")
            }

            Spacer(minLength: 12)
            if let index = siblings.firstIndex(where: { $0.id == shown.id }) {
                Text("\(index + 1) of \(siblings.count)")
                    .font(.mcSubtitle.monospacedDigit())
                    .foregroundStyle(Token.Text.secondary)
                HStack(spacing: 0) {
                    navigationButton("Previous photo", symbol: "chevron.left", direction: -1)
                    Rectangle().fill(Token.Fill.boxBorder).frame(width: 1, height: 14)
                    navigationButton("Next photo", symbol: "chevron.right", direction: 1)
                }
                .background(Token.Fill.button, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(WindowDragHandle())
    }

    private func navigationButton(_ title: String, symbol: String, direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: symbol)
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(siblings.count < 2)
        .accessibilityLabel(title)
        .help(title)
    }

    private var image: some View {
        ZStack {
            Token.Fill.well
            if let nsImage = thumbnails.preview(for: shown.id) {
                PhotoZoomView(image: nsImage, assetID: shown.id)
                    .padding(12)
                    .accessibilityLabel("Photo \(siblings.firstIndex(where: { $0.id == shown.id }).map { $0 + 1 } ?? 1)")
                    .help("Pinch to zoom. Use two fingers to pan. Double-tap with two fingers to reset the zoom.")
            }
            if thumbnails.isPreviewLoading(shown.id) {
                VStack(spacing: 8) {
                    if let fraction = thumbnails.downloadProgress[shown.id], fraction > 0 {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 160)
                        Text("Downloading from iCloud… \(Int(fraction * 100))%")
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Loading full resolution…")
                    }
                }
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.secondary)
                .padding(14)
                .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: Token.Radius.box))
            } else if thumbnails.unavailablePreviews.contains(shown.id) {
                VStack(spacing: 8) {
                    Text("The full-resolution photo is unavailable.")
                    Text("Check your connection and photo download settings.")
                    Button("Try Again") { thumbnails.loadPreview(shown.id) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.secondary)
                .multilineTextAlignment(.center)
                .padding(14)
                .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: Token.Radius.box))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: shown.id) { thumbnails.loadPreview(shown.id) }
        .onChange(of: shown.id) { previous, _ in thumbnails.cancelPreview(previous) }
        .onDisappear { thumbnails.cancelPreview(shown.id) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("In this group")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(siblings) { asset in
                            Button { show(asset) } label: {
                                PhotoReviewThumbnail(
                                    asset: asset, thumbnails: thumbnails, size: 48,
                                    isKeeper: asset.id == group?.keeper.id,
                                    isSelected: model.selection.contains(asset.id),
                                    isHighlighted: asset.id == shown.id
                                )
                                .overlay(alignment: .topTrailing) {
                                    if model.selection.contains(asset.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Token.color(.accent))
                                            .font(.system(size: 13))
                                            .padding(3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .id(asset.id)
                            .accessibilityLabel(asset.filename ?? "Photo \(siblings.firstIndex(where: { $0.id == asset.id }).map { $0 + 1 } ?? 1)")
                            .accessibilityValue(asset.id == group?.keeper.id ? "Kept photo" : (model.selection.contains(asset.id) ? "Selected for deletion" : "Not selected"))
                            .accessibilityAddTraits(asset.id == shown.id ? .isSelected : [])
                        }
                    }
                    .padding(5)
                }
                .frame(width: min(CGFloat(siblings.count) * 56 + 2, 170), height: 58)
                .onAppear { proxy.scrollTo(shown.id) }
                .onChange(of: shown.id) { _, id in proxy.scrollTo(id) }
            }
            Rectangle().fill(Token.Fill.boxBorder).frame(width: 1, height: 30)
            if isKeeper {
                Label("Kept photo", systemImage: "checkmark.circle.fill")
                    .font(.mcCaption)
                    .foregroundStyle(Token.textColor(.green))
            } else {
                Button { model.toggle(shown.id) } label: {
                    Label(
                        isSelected ? "Selected for deletion" : "Not selected",
                        systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.mcCaption)
                    .foregroundStyle(isSelected ? Token.color(.accent) : Token.Text.secondary)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Deselect photo" : "Select photo for deletion")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .help(isSelected ? "Deselect this photo" : "Select this photo for deletion")
            }
            Spacer(minLength: 0)
            if !isKeeper {
                Button("Keep instead") {
                    guard let group else { return }
                    model.keepInstead(groupID: group.id, assetID: shown.id)
                }
                .buttonStyle(PageActionButtonStyle(size: .small))
                Button(isSelected ? "Deselect" : "Select for deletion") { model.toggle(shown.id) }
                    .buttonStyle(PageActionButtonStyle(
                        tint: isSelected ? nil : Token.color(.accent),
                        size: .small,
                        fill: Token.Fill.buttonOnCard,
                        border: Token.Fill.controlBorder
                    ))
            }
        }
        .disabled(model.isBusyWithDisk || model.isRegrouping)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func show(_ asset: PhotoAsset) {
        model.preview = .init(groupID: item.groupID, asset: asset)
    }

    /// Moves through copies in the current group and returns to the first copy at the end.
    private func step(_ delta: Int) {
        guard siblings.count > 1,
              let index = siblings.firstIndex(where: { $0.id == shown.id })
        else { return }
        let next = (index + delta + siblings.count) % siblings.count
        show(siblings[next])
    }
}

/// Uses native trackpad magnification and scrolling for the preview image.
private struct PhotoZoomView: NSViewRepresentable {
    let image: NSImage
    let assetID: String

    func makeNSView(context: Context) -> PhotoZoomScrollView {
        PhotoZoomScrollView()
    }

    func updateNSView(_ nsView: PhotoZoomScrollView, context: Context) {
        nsView.show(image, assetID: assetID)
    }
}

final class PhotoZoomScrollView: NSScrollView {
    private let photoView = PhotoZoomImageView()
    private var assetID: String?
    private var viewportSize = NSSize.zero

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 8
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        photoView.imageScaling = .scaleProportionallyUpOrDown
        photoView.imageAlignment = .alignCenter
        photoView.setAccessibilityLabel("Photo preview")
        documentView = photoView
    }

    required init?(coder: NSCoder) { nil }

    func show(_ image: NSImage, assetID: String) {
        if self.assetID != assetID {
            self.assetID = assetID
            magnification = 1
            contentView.scroll(to: .zero)
        }
        photoView.image = image
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = contentSize
        guard size != viewportSize, size.width > 0, size.height > 0 else { return }
        viewportSize = size
        photoView.setFrameSize(size)
        reflectScrolledClipView(contentView)
    }

    override func smartMagnify(with event: NSEvent) {
        let center = photoView.convert(event.locationInWindow, from: nil)
        setMagnification(magnification > 1 ? 1 : 2, centeredAt: center)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

private final class PhotoZoomImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Handles preview keys before the file grid or a focused button consumes them.
private struct PhotoPreviewKeyboardHandler: NSViewRepresentable {
    let onClose: () -> Void
    let onStep: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(in: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClose = onClose
        context.coordinator.onStep = onStep
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var onClose: (() -> Void)?
        var onStep: ((Int) -> Void)?
        private var monitor: Any?

        func install(in view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = view?.window,
                          event.window === window, window.attachedSheet == nil,
                          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                    else { return false }
                    switch event.keyCode {
                    case 49, 53: self.onClose?()
                    case 123: self.onStep?(-1)
                    case 124: self.onStep?(1)
                    default: return false
                    }
                    return true
                }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
