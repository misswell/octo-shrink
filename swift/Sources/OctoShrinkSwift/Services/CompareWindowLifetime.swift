import AppKit

/// Owns the one compare window and drops its SwiftUI tree when the window closes,
/// including closes initiated by AppKit's red button.
final class CompareWindowLifetime: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?

    func retain(_ window: NSWindow) {
        self.window?.close()
        self.window = window
        window.delegate = self
    }

    func close() {
        guard let window else { return }
        window.close()
        // `windowWillClose` normally clears these synchronously. Keep cleanup
        // deterministic if a future window implementation changes that detail.
        window.contentViewController = nil
        if self.window === window { self.window = nil }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        closingWindow.contentViewController = nil
        if window === closingWindow { window = nil }
    }
}
