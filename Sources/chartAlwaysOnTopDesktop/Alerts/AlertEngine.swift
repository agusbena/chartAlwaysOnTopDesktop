import Foundation

struct AlertEvent: Equatable {
    let alertId: String
    let assetId: String
    let value: Double
    let threshold: Double
    let soundId: String
    let blinkEnabled: Bool
}

final class AlertEngine {
    private var previousValues: [String: Double] = [:]
    private var activeCrossing: Set<String> = []

    func evaluate(alerts: [AlertConfig], assetId: String, price: Double, indicatorValues: [String: Double]) -> [AlertEvent] {
        var events: [AlertEvent] = []

        for alert in alerts where alert.enabled && alert.assetId == assetId {
            let currentValue: Double?
            switch alert.source {
            case .price:
                currentValue = price
            case .indicator(let indicatorId):
                currentValue = indicatorValues[indicatorId]
            }
            guard let value = currentValue else { continue }

            let shouldTrigger = isTriggered(alert: alert, value: value, previous: previousValues[alert.id])
            if shouldTrigger {
                if !activeCrossing.contains(alert.id) {
                    events.append(
                        AlertEvent(
                            alertId: alert.id,
                            assetId: alert.assetId,
                            value: value,
                            threshold: alert.threshold,
                            soundId: alert.soundId,
                            blinkEnabled: alert.blinkEnabled
                        )
                    )
                    activeCrossing.insert(alert.id)
                }
            } else {
                activeCrossing.remove(alert.id)
            }

            previousValues[alert.id] = value
        }

        return events
    }

    private func isTriggered(alert: AlertConfig, value: Double, previous: Double?) -> Bool {
        switch alert.operator {
        case .greaterThanOrEqual:
            return value >= alert.threshold
        case .lessThanOrEqual:
            return value <= alert.threshold
        case .crossUp:
            guard let prev = previous else { return false }
            return prev < alert.threshold && value >= alert.threshold
        case .crossDown:
            guard let prev = previous else { return false }
            return prev > alert.threshold && value <= alert.threshold
        }
    }
}
