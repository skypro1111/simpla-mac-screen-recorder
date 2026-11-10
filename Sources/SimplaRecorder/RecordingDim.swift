// While recording, slightly dims everything outside the recorded region so it is
// obvious what ends up in the video. The overlay is click-through and is not captured.
import AppKit

@MainActor
final class RecordingDim {
    static let shared = RecordingDim()

    private var windows: [NSWindow] = []
    private var timer: Timer?

    /// `frame` is the recorded region in AppKit global coordinates.
    func show(target: CaptureTarget, frame: NSRect) {
        hide()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.sharingType = .none
            // Above normal windows and the Dock, below the menu bar (the stop button stays bright).
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = DimView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.orderFrontRegardless()
            windows.append(window)
        }
        setHole(frame)

        // A recorded window can be moved or resized; keep the clear region on it.
        if case .window(let id) = target {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let frame = Self.frame(ofWindow: id) { self?.setHole(frame) }
                }
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
    }

    private func setHole(_ frame: NSRect) {
        for window in windows {
            guard let view = window.contentView as? DimView else { continue }
            let local = frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            if view.hole != local {
                view.hole = local
                view.needsDisplay = true
            }
        }
    }

    /// Current frame of a window in AppKit global coordinates.
    private static func frame(ofWindow id: CGWindowID) -> NSRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let b = CGRect(dictionaryRepresentation: dict as CFDictionary),
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
    }
}

@MainActor
private final class DimView: NSView {
    var hole: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        NSColor.clear.setFill()
        hole.intersection(bounds).fill(using: .copy)
    }
}
