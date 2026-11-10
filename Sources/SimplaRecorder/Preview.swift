// Small floating thumbnail shown after a recording stops. It shows a random frame,
// offers Save / Copy / Delete on hover, and fades out after a few seconds; the
// recording is already on disk, so letting it disappear keeps the file.
import AVFoundation
import AppKit
import CoreImage

@MainActor
final class RecordingPreview {
    private static var current: RecordingPreview?
    private static let lifetime: TimeInterval = 5

    /// Shows the preview for a finished recording, replacing any preview still on screen.
    static func show(url: URL) {
        Task { @MainActor in
            let frame = await randomFrame(of: url)
            current?.close(animated: false)
            current = RecordingPreview(url: url, frame: frame)
        }
    }

    private let url: URL
    private let panel: NSPanel
    private let view: PreviewView
    private var timer: Timer?
    private var closing = false
    /// Set once an action was taken; hovering no longer affects the countdown.
    private var settled = false

    private init(url: URL, frame: CGImage?) {
        self.url = url

        // Thumbnail size: fixed width, height from the frame's aspect ratio (clamped).
        let width: CGFloat = 170
        let aspect = frame.map { CGFloat($0.height) / CGFloat($0.width) } ?? 0.625
        let size = NSSize(width: width, height: min(max(width * aspect, 80), 150).rounded())

        // Bottom-left corner of the screen the pointer is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.minX + 20, y: area.minY + 20)

        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none   // never show up in a following recording

        view = PreviewView(frame: NSRect(origin: .zero, size: size), image: frame)
        panel.contentView = view
        view.onHover = { [weak self] hovering in self?.hoverChanged(hovering) }
        view.onSave = { [weak self] in self?.save() }
        view.onCopy = { [weak self] in self?.copy() }
        view.onDelete = { [weak self] in self?.delete() }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        scheduleClose(after: Self.lifetime)
    }

    // MARK: Lifetime

    private func scheduleClose(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: true) }
        }
    }

    /// The countdown pauses while the pointer is over the preview.
    private func hoverChanged(_ hovering: Bool) {
        guard !closing, !settled else { return }
        if hovering {
            timer?.invalidate()
            timer = nil
        } else {
            scheduleClose(after: Self.lifetime)
        }
    }

    private func close(animated: Bool) {
        guard !closing else { return }
        closing = true
        timer?.invalidate()
        timer = nil
        let panel = self.panel
        let finish = {
            panel.orderOut(nil)
            panel.close()
            if Self.current === self { Self.current = nil }
        }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated(finish) })
    }

    // MARK: Actions

    /// The file is already saved; "Save" confirms it right away and shows it in Finder.
    private func save() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        close(animated: true)
    }

    /// Puts the video file on the clipboard so it can be pasted into Finder, chats, mail, etc.
    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        view.showMessage("Copied")
        settled = true
        scheduleClose(after: 0.9)
    }

    /// Moves the recording to the Trash (recoverable).
    private func delete() {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            close(animated: true)
        } catch {
            view.showMessage("Couldn't delete")
            settled = true
            scheduleClose(after: 1.5)
        }
    }

    // MARK: Thumbnail

    private static func randomFrame(of url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let time = CMTime(seconds: seconds > 0 ? seconds * Double.random(in: 0.1...0.9) : 0, preferredTimescale: 600)
        if let image = try? await generator.image(at: time).image { return image }
        return try? await generator.image(at: .zero).image
    }
}

// MARK: - Views

@MainActor
private final class PreviewView: NSView {
    var onHover: ((Bool) -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?

    /// Greyscale, darkened copy of the frame, faded in on hover.
    private let dimView = NSView()
    private let buttons = NSView()
    private let message = NSTextField(labelWithString: "")

    init(frame: NSRect, image: CGImage?) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.contentsGravity = .resizeAspectFill
        layer?.contents = image

        // A real subview (not a bare sublayer) so AppKit keeps it above the frame and below the buttons.
        dimView.frame = bounds
        dimView.wantsLayer = true
        dimView.layer?.contentsGravity = .resizeAspectFill
        dimView.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        dimView.layer?.contents = image.flatMap(Self.dimmed)
        dimView.alphaValue = 0
        addSubview(dimView)

        // Three buttons in a centred row (fixed manual layout).
        let specs: [(String, String, Selector)] = [
            ("square.and.arrow.down", "Save", #selector(savePressed)),
            ("doc.on.doc", "Copy", #selector(copyPressed)),
            ("trash", "Delete", #selector(deletePressed)),
        ]
        let size = PreviewButton.size, spacing: CGFloat = 6
        let rowWidth = CGFloat(specs.count) * size.width + CGFloat(specs.count - 1) * spacing
        buttons.frame = NSRect(x: ((bounds.width - rowWidth) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                               width: rowWidth, height: size.height)
        for (index, spec) in specs.enumerated() {
            let button = PreviewButton(symbol: spec.0, title: spec.1, target: self, action: spec.2)
            button.frame = NSRect(x: CGFloat(index) * (size.width + spacing), y: 0, width: size.width, height: size.height)
            buttons.addSubview(button)
        }
        buttons.alphaValue = 0
        addSubview(buttons)

        message.font = .systemFont(ofSize: 13, weight: .semibold)
        message.textColor = .white
        message.alignment = .center
        message.frame = NSRect(x: 0, y: ((bounds.height - 20) / 2).rounded(), width: bounds.width, height: 20)
        message.isHidden = true
        addSubview(message)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func dimmed(_ image: CGImage) -> CGImage? {
        let output = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
        ]).applyingFilter("CIColorMatrix", parameters: [
            // Compress everything into a dark grey band so the change is obvious on dark and
            // bright frames alike. Values are in linear light: black -> ~20% grey, white -> ~42%.
            "inputRVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.12, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.12, w: 0),
            "inputBiasVector": CIVector(x: 0.03, y: 0.03, z: 0.03, w: 0),
        ])
        return CIContext().createCGImage(output, from: output.extent)
    }

    func setHovering(_ hovering: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            dimView.animator().alphaValue = hovering || !message.isHidden ? 1 : 0
            buttons.animator().alphaValue = hovering && message.isHidden ? 1 : 0
        }
    }

    /// Replaces the buttons with a short status text (e.g. "Copied").
    func showMessage(_ text: String) {
        message.stringValue = text
        message.isHidden = false
        buttons.isHidden = true
        dimView.alphaValue = 1
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
        onHover?(false)
    }

    @objc private func savePressed() { onSave?() }
    @objc private func copyPressed() { onCopy?() }
    @objc private func deletePressed() { onDelete?() }
}

/// Self-drawn button: SF Symbol above a small label, on a translucent rounded tile.
@MainActor
private final class PreviewButton: NSView {
    static let size = NSSize(width: 46, height: 42)

    private let symbol: String
    private let title: NSAttributedString
    private weak var target: AnyObject?
    private let action: Selector
    private var pressed = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, target: AnyObject, action: Selector) {
        self.symbol = symbol
        self.target = target
        self.action = action
        self.title = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: pressed ? 0.34 : (hovered ? 0.24 : 0.14)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = icon.size
            icon.draw(in: NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: 17 + ((22 - size.height) / 2).rounded(),
                                 width: size.width, height: size.height))
        }
        let textSize = title.size()
        title.draw(at: NSPoint(x: ((bounds.width - textSize.width) / 2).rounded(), y: 4))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { _ = NSApp.sendAction(action, to: target, from: self) }
    }
}
