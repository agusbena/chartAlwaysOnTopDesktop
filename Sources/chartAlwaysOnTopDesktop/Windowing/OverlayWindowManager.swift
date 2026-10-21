import AppKit

private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class OverlayWindowManager {
    private(set) var window: NSWindow?

    func buildWindow(frame: CGRect, contentView: NSView, opacity: Double) -> NSWindow {
        let window = OverlayWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.hidesOnDeactivate = false
        window.isOpaque = true
        window.backgroundColor = NSColor.clear
        window.alphaValue = CGFloat(opacity)
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = !NSEvent.modifierFlags.contains(.control)
        window.contentView = contentView

        self.window = window
        return window
    }

    func setClickThrough(_ enabled: Bool) {
        window?.ignoresMouseEvents = enabled
        if enabled { window?.resignKey() }
    }

    func show() {
        window?.orderFrontRegardless()
    }
}
