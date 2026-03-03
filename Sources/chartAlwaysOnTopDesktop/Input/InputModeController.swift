import AppKit

final class InputModeController {
    private var localMonitor: Any?
    private var globalMonitor: Any?

    var onCtrlStateChange: ((Bool) -> Void)?

    func start() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let isCtrlDown = event.modifierFlags.contains(.control)
        onCtrlStateChange?(isCtrlDown)
    }
}
