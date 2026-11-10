import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let recorder = Recorder.shared
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var stateObserver: AnyCancellable?
    private var timer: Timer?
    private var settingsWindow: NSWindow?
    /// True while the capture picker is open or a recording is starting.
    private var isPicking = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        menu.delegate = self

        // `$state` emits in willSet, so use the delivered value rather than reading `state`.
        stateObserver = recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.updateStatusItem(for: state) }
            }

        recorder.onUnexpectedStop = { [weak self] url, error in
            if let error { self?.showError(error) }
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.state != .idle else { return .terminateNow }
        // Finalize the recording before quitting so the file is not left corrupted.
        Task { @MainActor in
            if case .recording = recorder.state {
                _ = try? await recorder.stop()
            }
            var waited = 0
            while recorder.state != .idle && waited < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Status item

    /// Idle: camera icon that opens the menu. Recording: the item itself is a red stop
    /// button with the elapsed time; one click stops the recording (no menu).
    private func updateStatusItem(for state: Recorder.State) {
        guard let button = statusItem.button else { return }
        timer?.invalidate()
        timer = nil

        switch state {
        case .idle:
            button.image = statusIcon()
            button.attributedTitle = NSAttributedString()
            button.toolTip = "Simpla Recorder"
            button.action = nil
            statusItem.menu = menu
        case .recording(let since):
            button.image = Self.symbol("stop.circle.fill", color: .systemRed)
            button.attributedTitle = Self.label(Self.elapsed(since: since), color: .systemRed)
            button.toolTip = "Stop Recording"
            statusItem.menu = nil
            button.action = #selector(stopRecording)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.statusItem.button?.attributedTitle = Self.label(Self.elapsed(since: since), color: .systemRed)
                }
            }
        case .finishing:
            button.image = Self.symbol("arrow.down.circle.fill", color: .systemOrange)
            button.attributedTitle = Self.label("Saving…", color: .systemOrange)
            button.toolTip = "Saving…"
            statusItem.menu = nil
            button.action = nil
        }
    }

    /// Explicitly coloured (non-template) symbol, so it stays visible on any menu bar.
    private static func symbol(_ name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    private static func label(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: color,
        ])
    }

    /// Bundled camera glyph as a template image, so it follows the menu bar colour.
    /// Falls back to an SF Symbol outside a bundle.
    private func statusIcon() -> NSImage? {
        let image = Bundle.main.image(forResource: "StatusIcon")
            ?? NSImage(systemSymbolName: "video", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = "Simpla Recorder"
        return image
    }

    private static func elapsed(since: Date) -> String {
        let total = max(0, Int(Date().timeIntervalSince(since)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Only shown while idle: during a recording the status item is the stop button.
        menu.addItem(item("Record Screen", #selector(recordScreen)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Open Recordings Folder", #selector(openRecordingsFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func recordScreen() {
        guard !isPicking else { return }
        isPicking = true
        Task { @MainActor in
            defer { isPicking = false }
            let settings = AppSettings.shared
            guard let choice = await CapturePicker.pick(defaultMicrophone: settings.captureMicrophone,
                                                        defaultSystemAudio: settings.captureSystemAudio)
            else { return }
            // The choice applies to this recording only; saved settings stay the defaults.
            var options = settings.recordingOptions
            options.captureMicrophone = choice.microphone
            options.captureSystemAudio = choice.systemAudio
            do {
                try await recorder.start(target: choice.target, options: options)
            } catch {
                showError(error)
            }
        }
    }

    @objc private func stopRecording() {
        guard case .recording = recorder.state else { return }
        Task { @MainActor in
            do {
                let url = try await recorder.stop()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                showError(error)
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    @objc private func openRecordingsFolder() {
        let folder = AppSettings.shared.outputDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Errors

    private func showError(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        if Self.isPermissionDenied(error) {
            alert.messageText = "No permission to record the screen"
            alert.informativeText = "Enable Simpla Recorder in System Settings → Privacy & Security → Screen & System Audio Recording, then restart the app.\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.messageText = "Recording Error"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        if let scError = error as? SCStreamError, scError.code == .userDeclined { return true }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue { return true }
        let text = "\(ns.domain) \(ns.localizedDescription) \(ns.userInfo)".lowercased()
        return text.contains("tcc") || text.contains("declined") || text.contains("not authorized")
    }
}
