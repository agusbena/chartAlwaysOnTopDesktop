import AppKit

@MainActor
final class OverlayWindowManager {
    private(set) var window: NSWindow?

    func buildWindow(frame: CGRect, contentView: NSView, opacity: Double, clickThroughByDefault: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.alphaValue = CGFloat(opacity)
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = clickThroughByDefault
        window.contentView = contentView

        self.window = window
        return window
    }

    func setClickThrough(_ enabled: Bool) {
        window?.ignoresMouseEvents = enabled
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
