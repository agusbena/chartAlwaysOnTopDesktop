import AppKit
import Foundation

final class AlertPresenter {
    var onBlinkPulse: (() -> Void)?

    func present(_ event: AlertEvent) {
        playSound(id: event.soundId)
        if event.blinkEnabled {
            onBlinkPulse?()
        }
    }

    private func playSound(id: String) {
        if let custom = Bundle.module.url(forResource: id, withExtension: "wav", subdirectory: "Resources/Sounds"),
           let sound = NSSound(contentsOf: custom, byReference: false) {
            sound.play()
            return
        }

        if let named = NSSound(named: NSSound.Name(id)) {
            named.play()
            return
        }

        NSSound.beep()
    }
}
