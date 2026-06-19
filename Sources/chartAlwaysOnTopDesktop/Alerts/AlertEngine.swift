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
    private var latestAlertKey: String = ""; // Ptobably you should clean it after N minutes....

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

            for threshold in alert.thresholds {
                let key = runtimeKey(for: alert, threshold: threshold)
                if latestAlertKey == key {
                    continue
                }
                let shouldTrigger = isTriggered(
                    operator: alert.operator,
                    threshold: threshold,
                    value: value,
                    previous: previousValues[key]
                )
                if shouldTrigger {
                    if !activeCrossing.contains(key) {
                        events.append(
                            AlertEvent(
                                alertId: alert.id,
                                assetId: alert.assetId,
                                value: value,
                                threshold: threshold,
                                soundId: alert.soundId,
                                blinkEnabled: alert.blinkEnabled
                            )
                        )
                        activeCrossing.insert(key)
                        latestAlertKey = key;
                    }
                } else {
                    activeCrossing.remove(key)
                }
                previousValues[key] = value
            }
        }

        return events
    }

    private func runtimeKey(for alert: AlertConfig, threshold: Double) -> String {
        "\(alert.id)|\(operatorToken(alert.operator))|\(threshold)"
    }

    private func operatorToken(_ op: AlertOperator) -> String {
        switch op {
        case .greaterThanOrEqual: return "gte"
        case .lessThanOrEqual: return "lte"
        case .crossUp: return "crossUp"
        case .crossDown: return "crossDown"
        }
    }

    private func isTriggered(operator op: AlertOperator, threshold: Double, value: Double, previous: Double?) -> Bool {
        switch op {
        case .greaterThanOrEqual:
            return value >= threshold
        case .lessThanOrEqual:
            return value <= threshold
        case .crossUp:
            guard let prev = previous else { return false }
            return prev < threshold && value >= threshold
        case .crossDown:
            guard let prev = previous else { return false }
            return prev > threshold && value <= threshold
        }
    }
}
