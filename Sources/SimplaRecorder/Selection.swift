// Capture picker: full-screen overlays to pick a screen, window or area (phase 1),
// then a small HUD to toggle audio sources and start recording (phase 2).
import AppKit
import CoreGraphics

@MainActor
enum CapturePicker {
    /// Shows the picker; returns nil if cancelled. Only one picker at a time (a second call while one is open cancels the old one, which returns nil).
    static func pick(defaultMicrophone: Bool, defaultSystemAudio: Bool) async -> CaptureChoice? {
        current?.finish(nil)
        var mine: PickerSession?
        let choice: CaptureChoice? = await withCheckedContinuation { continuation in
            let session = PickerSession(microphone: defaultMicrophone, systemAudio: defaultSystemAudio,
                                        continuation: continuation)
            mine = session
            current = session
            session.start()
        }
        if current === mine { current = nil }
        // The overlays are already closed; let the window server remove them before capture starts.
        if choice != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        return choice
    }

    private static var current: PickerSession?
}

// MARK: - Session

@MainActor
private final class PickerSession: NSObject {
    private typealias WindowEntry = (id: CGWindowID, frame: NSRect)

    private var continuation: CheckedContinuation<CaptureChoice?, Never>?
    private var microphone: Bool
    private var systemAudio: Bool

    private var overlays: [OverlayWindow] = []
    /// On-screen windows (AppKit global coordinates), front to back. Snapshot taken at start.
    private var windowList: [WindowEntry] = []
    private var hovered: WindowEntry?
    private var dragView: OverlayView?
    private var dragRect: NSRect?
    /// Phase 2 state: the chosen target and its frame in AppKit global coordinates.
    private var chosen: (target: CaptureTarget, frame: NSRect)?
    private var hud: HUDView?
    /// Overlay showing the HUD (phase 2).
    private weak var chosenWindow: OverlayWindow?
    /// Area rect (view coordinates) when a move via the HUD started.
    private var moveOrigin: NSRect?

    init(microphone: Bool, systemAudio: Bool, continuation: CheckedContinuation<CaptureChoice?, Never>) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.continuation = continuation
    }

    var isConfirming: Bool { chosen != nil }

    /// True when a dragged area is chosen: it can still be resized and moved.
    var isAreaChosen: Bool {
        if case .area = chosen?.target { return true }
        return false
    }

    func start() {
        NSApp.activate()
        windowList = Self.snapshotWindows()
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, session: self)
            window.orderFrontRegardless()
            overlays.append(window)
        }
        if let key = overlays.first(where: { $0.frame.contains(mouse) }) ?? overlays.first {
            key.makeKeyAndOrderFront(nil)
            key.makeFirstResponder(key.overlay)
        }
        NSCursor.crosshair.set()
        updateHover()
    }

    /// Closes all windows and resumes the continuation exactly once.
    func finish(_ result: CaptureChoice?) {
        guard let continuation else { return }
        self.continuation = nil
        let closing = overlays
        for window in closing { window.orderOut(nil); window.close() }
        overlays.removeAll()
        hud = nil
        NSCursor.arrow.set()
        // Keep the windows alive until the current event (e.g. a button click inside them) has been fully handled.
        DispatchQueue.main.async { _ = closing }
        continuation.resume(returning: result)
    }

    // MARK: Phase 1

    func updateHover() {
        guard chosen == nil, dragRect == nil else { return }
        NSCursor.crosshair.set()
        let point = NSEvent.mouseLocation
        let hit = windowList.first { $0.frame.contains(point) }
        if hit?.id != hovered?.id {
            hovered = hit
            refresh()
        }
    }

    func dragChanged(in view: OverlayView, rect: NSRect) {
        hovered = nil
        dragView = view
        dragRect = rect
        refresh()
    }

    func dragEnded(in view: OverlayView, rect: NSRect) {
        dragView = nil
        dragRect = nil
        guard rect.width >= 10, rect.height >= 10,
              let window = view.window as? OverlayWindow, let id = window.displayID else {
            refresh()
            updateHover()
            return
        }
        let area = Self.areaChoice(rect, in: view, window: window, displayID: id)
        confirm(area.target, frame: area.frame, on: window)
    }

    /// View rect (bottom-left origin) -> capture target (display-local, top-left origin, integral)
    /// plus the same rect in AppKit global coordinates.
    private static func areaChoice(_ rect: NSRect, in view: OverlayView, window: OverlayWindow,
                                   displayID: CGDirectDisplayID) -> (target: CaptureTarget, frame: NSRect) {
        let flipped = CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            .integral.intersection(CGRect(origin: .zero, size: view.bounds.size))
        let global = NSRect(x: flipped.minX, y: view.bounds.height - flipped.maxY,
                            width: flipped.width, height: flipped.height)
            .offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        return (.area(displayID: displayID, rect: flipped), global)
    }

    /// Phase 2: the chosen area was resized or moved (rect in the chosen overlay's view coordinates).
    func setArea(_ rect: NSRect) {
        guard isAreaChosen, let window = chosenWindow, let id = window.displayID else { return }
        chosen = Self.areaChoice(rect, in: window.overlay, window: window, displayID: id)
        refresh()
        positionHUD()
    }

    /// Dragging the HUD moves the chosen area around its screen.
    func moveBegan() {
        guard isAreaChosen, let window = chosenWindow, let frame = chosen?.frame else { return }
        moveOrigin = local(frame, in: window)
    }

    func moveChanged(dx: CGFloat, dy: CGFloat) {
        guard let origin = moveOrigin, let bounds = chosenWindow?.overlay.bounds else { return }
        var rect = origin.offsetBy(dx: dx, dy: dy)
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        setArea(rect)
    }

    func moveEnded() { moveOrigin = nil }

    func clicked() {
        guard let hovered else { return }
        let best = overlays.max { a, b in
            Self.area(a.frame.intersection(hovered.frame)) < Self.area(b.frame.intersection(hovered.frame))
        }
        guard let best else { return }
        confirm(.window(hovered.id), frame: hovered.frame, on: best)
    }

    func selectDisplay(_ window: OverlayWindow) {
        guard let id = window.displayID else { return }
        confirm(.display(id), frame: window.frame, on: window)
    }

    func cancel() { finish(nil) }

    // MARK: Phase 2

    private func confirm(_ target: CaptureTarget, frame: NSRect, on window: OverlayWindow) {
        chosen = (target, frame)
        chosenWindow = window
        hovered = nil
        NSCursor.arrow.set()
        refresh()

        let hud = makeHUD()
        let view = window.overlay
        view.addSubview(hud)
        self.hud = hud
        positionHUD()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Centres the HUD on the chosen region, keeping it fully on screen.
    private func positionHUD() {
        guard let hud, let window = chosenWindow, let frame = chosen?.frame else { return }
        let view = window.overlay
        let size = hud.fittingSize
        let region = frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY).intersection(view.bounds)
        let margin: CGFloat = 12
        var origin = NSPoint(x: region.midX - size.width / 2, y: region.midY - size.height / 2)
        if region.width < size.width + 2 * margin || region.height < size.height + 2 * margin {
            // Tiny region: place the HUD just below it, or above if there is no room below.
            origin.y = region.minY - size.height - margin
            if origin.y < view.bounds.minY + margin { origin.y = region.maxY + margin }
        }
        origin.x = min(max(origin.x, margin), view.bounds.maxX - size.width - margin)
        origin.y = min(max(origin.y, margin), view.bounds.maxY - size.height - margin)
        hud.frame = NSRect(origin: origin, size: size)
    }

    /// Back to phase 1 (user clicked the dimmed area outside the HUD).
    func reselect() {
        hud?.removeFromSuperview()
        hud = nil
        chosen = nil
        chosenWindow = nil
        moveOrigin = nil
        refresh()
        updateHover()
    }

    private func makeHUD() -> HUDView {
        let mic = ToggleButton(on: "mic.fill", off: "mic.slash.fill", tooltip: "Microphone", isOn: microphone,
                               target: self, action: #selector(toggleMicrophone(_:)))
        let audio = ToggleButton(on: "speaker.wave.2.fill", off: "speaker.slash.fill", tooltip: "System Audio",
                                 isOn: systemAudio, target: self, action: #selector(toggleSystemAudio(_:)))

        // Grey pill button: record glyph + title. Return triggers it.
        let start = NSButton(title: "", target: self, action: #selector(startRecording))
        start.isBordered = false
        start.attributedTitle = NSAttributedString(string: " Start Recording", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: HUDColor.icon,
        ])
        start.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        start.imagePosition = .imageLeading
        start.contentTintColor = HUDColor.icon
        start.wantsLayer = true
        start.layer?.backgroundColor = HUDColor.fill.cgColor
        start.layer?.cornerRadius = 17
        start.keyEquivalent = "\r"
        start.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            start.heightAnchor.constraint(equalToConstant: 34),
            start.widthAnchor.constraint(equalToConstant: start.intrinsicContentSize.width + 28),
        ])

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel") ?? NSImage(),
                             target: self, action: #selector(cancelPressed))
        close.isBordered = false
        close.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        close.toolTip = "Cancel"

        let stack = NSStackView(views: [mic, audio, start, close])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let hud = HUDView()
        hud.session = self
        hud.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: hud.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: hud.trailingAnchor),
            stack.topAnchor.constraint(equalTo: hud.topAnchor),
            stack.bottomAnchor.constraint(equalTo: hud.bottomAnchor),
        ])
        return hud
    }

    @objc private func toggleMicrophone(_ sender: ToggleButton) {
        microphone.toggle()
        sender.isOn = microphone
    }

    @objc private func toggleSystemAudio(_ sender: ToggleButton) {
        systemAudio.toggle()
        sender.isOn = systemAudio
    }

    @objc private func startRecording() {
        guard let chosen else { return }
        finish(CaptureChoice(target: chosen.target, microphone: microphone, systemAudio: systemAudio))
    }

    @objc private func cancelPressed() { finish(nil) }

    // MARK: Drawing state

    /// Pushes the current phase state into every overlay view.
    private func refresh() {
        for window in overlays {
            let view = window.overlay
            view.promptHidden = chosen != nil
            view.showSize = false
            view.borderColor = .controlAccentColor
            if let chosen {
                view.hole = local(chosen.frame, in: window)
                if isAreaChosen {
                    view.borderColor = .white
                    view.showSize = true
                }
            } else if let dragRect {
                view.hole = view === dragView ? dragRect : nil
                view.borderColor = .white
                view.showSize = true
            } else if let hovered {
                view.hole = local(hovered.frame, in: window)
            } else {
                view.hole = nil
            }
            view.needsDisplay = true
        }
    }

    /// Global AppKit rect -> overlay view coordinates, nil if it is not on that screen.
    private func local(_ frame: NSRect, in window: OverlayWindow) -> NSRect? {
        guard frame.intersects(window.frame) else { return nil }
        return frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    private static func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Normal on-screen windows of other apps, front to back, converted from CG global coordinates
    /// (top-left origin of the primary display) to AppKit global coordinates (bottom-left origin).
    private static func snapshotWindows() -> [WindowEntry] {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return infos.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  b.width >= 60, b.height >= 60
            else { return nil }
            return (id, NSRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height))
        }
    }
}

// MARK: - Overlay window and view

@MainActor
private final class OverlayWindow: NSWindow {
    let overlay: OverlayView
    let displayID: CGDirectDisplayID?

    init(screen: NSScreen, session: PickerSession) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        displayID = number.map { CGDirectDisplayID($0.uint32Value) }
        overlay = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Set the frame explicitly so it is in global coordinates.
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        overlay.session = session
        contentView = overlay
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class OverlayView: NSView {
    weak var session: PickerSession?

    /// Region punched clear (view coordinates) with a border, or nil.
    var hole: NSRect?
    var borderColor: NSColor = .controlAccentColor
    var showSize = false
    var promptHidden = false { didSet { prompt.isHidden = promptHidden } }

    private let prompt = NSStackView()
    private var dragStart: NSPoint?
    private var dragging = false

    /// Phase 2 border resize of a dragged area.
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
    }
    private var resize: (edges: Edges, origin: NSRect, start: NSPoint)?

    /// Edges of the chosen area's border under `p` (empty when not on the border).
    private func edges(at p: NSPoint) -> Edges {
        let grab: CGFloat = 6
        guard let hole, session?.isAreaChosen == true, hole.insetBy(dx: -grab, dy: -grab).contains(p) else { return [] }
        var edges: Edges = []
        if abs(p.x - hole.minX) <= grab { edges.insert(.left) } else if abs(p.x - hole.maxX) <= grab { edges.insert(.right) }
        if abs(p.y - hole.minY) <= grab { edges.insert(.bottom) } else if abs(p.y - hole.maxY) <= grab { edges.insert(.top) }
        return edges
    }

    private func setCursor(for edges: Edges) {
        let horizontal = !edges.isDisjoint(with: [.left, .right])
        let vertical = !edges.isDisjoint(with: [.bottom, .top])
        switch (horizontal, vertical) {
        case (true, true): NSCursor.crosshair.set()
        case (true, false): NSCursor.resizeLeftRight.set()
        case (false, true): NSCursor.resizeUpDown.set()
        default: NSCursor.arrow.set()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildPrompt()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Centre message + "Entire Screen" button.
    private func buildPrompt() {
        let label = NSTextField(labelWithString: "Select screen, window, or drag area to record")
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        pill.layer?.cornerRadius = 14
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -22),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -12),
        ])

        let button = NSButton(title: "", target: self, action: #selector(entireScreen))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: "Entire Screen", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        button.layer?.cornerRadius = 14
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(equalToConstant: button.intrinsicContentSize.width + 32),
        ])

        prompt.orientation = .vertical
        prompt.alignment = .centerX
        prompt.spacing = 12
        prompt.addArrangedSubview(pill)
        prompt.addArrangedSubview(button)
        prompt.translatesAutoresizingMaskIntoConstraints = false
        addSubview(prompt)
        NSLayoutConstraint.activate([
            prompt.centerXAnchor.constraint(equalTo: centerXAnchor),
            prompt.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func entireScreen() {
        guard let window = window as? OverlayWindow else { return }
        session?.selectDisplay(window)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(for event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    override func mouseMoved(with event: NSEvent) {
        if session?.isAreaChosen == true {
            if hole != nil { setCursor(for: edges(at: convert(event.locationInWindow, from: nil))) }
        } else {
            session?.updateHover()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        guard let session else { return }
        let p = point(for: event)
        if session.isConfirming {
            let grabbed = edges(at: convert(event.locationInWindow, from: nil))
            if let hole, !grabbed.isEmpty {
                // Dragging the border of a dragged area resizes it.
                resize = (grabbed, hole, p)
            } else if !(hole?.contains(p) ?? false) {
                // Clicking the dimmed area goes back to phase 1; clicks inside the chosen region do nothing.
                session.reselect()
            }
            return
        }
        dragStart = p
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        if let resize {
            let p = point(for: event)
            let o = resize.origin, minSize: CGFloat = 20
            var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
            if resize.edges.contains(.left) { minX = min(max(o.minX + p.x - resize.start.x, bounds.minX), o.maxX - minSize) }
            if resize.edges.contains(.right) { maxX = max(min(o.maxX + p.x - resize.start.x, bounds.maxX), o.minX + minSize) }
            if resize.edges.contains(.bottom) { minY = min(max(o.minY + p.y - resize.start.y, bounds.minY), o.maxY - minSize) }
            if resize.edges.contains(.top) { maxY = max(min(o.maxY + p.y - resize.start.y, bounds.maxY), o.minY + minSize) }
            session?.setArea(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            return
        }
        guard let start = dragStart, let session else { return }
        let p = point(for: event)
        if !dragging && hypot(p.x - start.x, p.y - start.y) > 5 { dragging = true }
        guard dragging else { return }
        let rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                          width: abs(p.x - start.x), height: abs(p.y - start.y))
        session.dragChanged(in: self, rect: rect)
    }

    override func mouseUp(with event: NSEvent) {
        if resize != nil { resize = nil; return }
        guard let start = dragStart, let session else { return }
        dragStart = nil
        if dragging {
            dragging = false
            let p = point(for: event)
            let rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                              width: abs(p.x - start.x), height: abs(p.y - start.y))
            session.dragEnded(in: self, rect: rect)
        } else {
            session.clicked()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { session?.cancel() } else { super.keyDown(with: event) }  // 53 = Esc
    }

    override func cancelOperation(_ sender: Any?) {
        session?.cancel()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        guard let hole else { return }
        let rect = hole.intersection(bounds)
        guard !rect.isEmpty else { return }

        NSColor.clear.setFill()
        rect.fill(using: .copy)
        let lineWidth: CGFloat = showSize ? 1 : 3
        borderColor.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        border.lineWidth = lineWidth
        border.stroke()

        guard showSize else { return }
        // "W × H" label below the rect (or inside if there's no room).
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 4
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height - pad * 2 - 2)
        if origin.y < bounds.minY { origin.y = rect.minY + 2 }
        origin.x = min(origin.x, bounds.maxX - size.width - pad * 2)
        let bg = NSRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad * 2)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: bg.minX + pad, y: bg.minY + pad), withAttributes: attrs)
    }
}

// MARK: - HUD

/// Dark rounded HUD background. Swallows clicks so they don't fall through to the overlay (which would go back to phase 1).
@MainActor
private final class HUDView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    weak var session: PickerSession?
    private var dragStart: NSPoint?

    // Dragging the HUD background moves a dragged area (no-op for screens and windows).
    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        session?.moveBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        session?.moveChanged(dx: event.locationInWindow.x - dragStart.x, dy: event.locationInWindow.y - dragStart.y)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        session?.moveEnded()
    }
}

/// Neutral greys shared by the HUD controls.
@MainActor
private enum HUDColor {
    static let icon = NSColor(white: 0.82, alpha: 1)
    static let iconOff = NSColor(white: 0.55, alpha: 1)
    static let fill = NSColor(white: 1, alpha: 0.14)
    static let fillOff = NSColor(white: 1, alpha: 0.06)
}

/// Round grey icon button; crossed out when off.
@MainActor
private final class ToggleButton: NSButton {
    private let onSymbol: String
    private let offSymbol: String
    var isOn: Bool { didSet { update() } }

    init(on: String, off: String, tooltip: String, isOn: Bool, target: AnyObject, action: Selector) {
        onSymbol = on
        offSymbol = off
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        self.target = target
        self.action = action
        toolTip = tooltip
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 17
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 34),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func update() {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        image = NSImage(systemSymbolName: isOn ? onSymbol : offSymbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config)
        // Grey in both states; the "off" symbol is the crossed-out variant.
        contentTintColor = isOn ? HUDColor.icon : HUDColor.iconOff
        layer?.backgroundColor = (isOn ? HUDColor.fill : HUDColor.fillOff).cgColor
    }
}
