import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let recorder = Recorder.shared
    private var statusItem: NSStatusItem!
    private var stateObserver: AnyCancellable?
    private var timer: Timer?
    private var settingsWindow: NSWindow?
    /// True while the capture picker is open or a recording is starting.
    private var isPicking = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

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

    private func updateStatusItem(for state: Recorder.State) {
        guard let button = statusItem.button else { return }
        timer?.invalidate()
        timer = nil

        switch state {
        case .idle:
            button.image = statusIcon()
            button.contentTintColor = nil
            button.title = ""
        case .recording(let since):
            button.image = statusIcon()
            button.contentTintColor = .systemRed
            button.title = " " + Self.elapsed(since: since)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.statusItem.button?.title = " " + Self.elapsed(since: since)
                }
            }
        case .finishing:
            button.image = statusIcon()
            button.contentTintColor = .systemOrange
            button.title = ""
        }
    }

    /// Bundled camera glyph as a template image, so it follows the menu bar colour
    /// (and can be tinted while recording). Falls back to an SF Symbol outside a bundle.
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
        switch recorder.state {
        case .idle:
            menu.addItem(item("Record Screen", #selector(recordScreen)))
            menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        case .recording:
            menu.addItem(item("Stop Recording", #selector(stopRecording)))
        case .finishing:
            let saving = NSMenuItem(title: "Saving…", action: nil, keyEquivalent: "")
            saving.isEnabled = false
            menu.addItem(saving)
        }
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
