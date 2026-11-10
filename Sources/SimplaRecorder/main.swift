// Plain AppKit bootstrap: menu-bar only (accessory) app.
import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // NSApplication.delegate is weak; keep the delegate alive for the app's lifetime.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
