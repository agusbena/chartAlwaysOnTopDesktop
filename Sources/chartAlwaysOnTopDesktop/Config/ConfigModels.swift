import CoreGraphics
import Foundation

struct AppConfig: Codable {
    let polling: PollingConfig
    let window: WindowConfig
    let assets: [AssetConfig]
    let indicators: [IndicatorConfig]
    let alerts: [AlertConfig]
    let ui: UIConfig

    func validate() throws {
        guard polling.defaultPollSeconds >= 1 else {
            throw ConfigError.validation("polling.defaultPollSeconds must be >= 1")
        }

        let enabledAssets = assets.filter(\.enabled)
        guard !enabledAssets.isEmpty else {
            throw ConfigError.validation("At least one asset must be enabled")
        }

        var ids = Set<String>()
        for asset in assets {
            guard ids.insert(asset.id).inserted else {
                throw ConfigError.validation("Duplicate asset id: \(asset.id)")
            }
            if let pollSeconds = asset.pollSeconds, pollSeconds < 1 {
                throw ConfigError.validation("asset.pollSeconds must be >= 1 for \(asset.id)")
            }
        }

        ids.removeAll(keepingCapacity: true)
        for indicator in indicators {
            guard ids.insert(indicator.id).inserted else {
                throw ConfigError.validation("Duplicate indicator id: \(indicator.id)")
            }
        }

        ids.removeAll(keepingCapacity: true)
        for alert in alerts {
            guard ids.insert(alert.id).inserted else {
                throw ConfigError.validation("Duplicate alert id: \(alert.id)")
            }
            guard assets.contains(where: { $0.id == alert.assetId }) else {
                throw ConfigError.validation("Alert \(alert.id) references unknown asset \(alert.assetId)")
            }
            if case .indicator(let indicatorId) = alert.source,
               !indicators.contains(where: { $0.id == indicatorId }) {
                throw ConfigError.validation("Alert \(alert.id) references unknown indicator \(indicatorId)")
            }
            guard !alert.thresholds.isEmpty else {
                throw ConfigError.validation("Alert \(alert.id) must define at least one threshold")
            }
        }

        guard (0 ... 1).contains(ui.backgroundOpacity) else {
            throw ConfigError.validation("ui.backgroundOpacity must be between 0 and 1")
        }
    }
}

struct PollingConfig: Codable {
    let defaultPollSeconds: Int
    let staleAfterSeconds: Int
}

struct WindowConfig: Codable {
    let opacity: Double
    let originX: Double
    let originY: Double
    let width: Double
    let height: Double
    let clickThroughByDefault: Bool
}

struct UIConfig: Codable {
    let yAxisPaddingFraction: Double
    let maxCandles: Int
    let backgroundOpacity: Double
    let keepBlinkingUntilCtrlClick: Bool

    init(yAxisPaddingFraction: Double, maxCandles: Int, backgroundOpacity: Double, keepBlinkingUntilCtrlClick: Bool) {
        self.yAxisPaddingFraction = yAxisPaddingFraction
        self.maxCandles = maxCandles
        self.backgroundOpacity = backgroundOpacity
        self.keepBlinkingUntilCtrlClick = keepBlinkingUntilCtrlClick
    }

    private enum CodingKeys: String, CodingKey {
        case yAxisPaddingFraction
        case maxCandles
        case backgroundOpacity
        case keepBlinkingUntilCtrlClick
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        yAxisPaddingFraction = try container.decode(Double.self, forKey: .yAxisPaddingFraction)
        maxCandles = try container.decode(Int.self, forKey: .maxCandles)
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.1
        keepBlinkingUntilCtrlClick = try container.decodeIfPresent(Bool.self, forKey: .keepBlinkingUntilCtrlClick) ?? false
    }
}

struct AssetConfig: Codable {
    let id: String
    let symbol: String
    let enabled: Bool
    let provider: String
    let timeframe: Timeframe?
    let pollSeconds: Int?
}

enum IndicatorType: String, Codable {
    case ema
    case sma
    case vwap
    case rsi
}

struct IndicatorConfig: Codable {
    let id: String
    let type: IndicatorType
    let enabled: Bool
    let colorHex: String
    let params: [String: Double]
}

struct AlertConfig: Codable {
    let id: String
    let assetId: String
    let source: AlertSource
    let `operator`: AlertOperator
    let thresholds: [Double]
    let enabled: Bool
    let soundId: String
    let blinkEnabled: Bool

    var threshold: Double {
        thresholds.first ?? 0
    }

    init(
        id: String,
        assetId: String,
        source: AlertSource,
        operator: AlertOperator,
        threshold: Double,
        enabled: Bool,
        soundId: String,
        blinkEnabled: Bool
    ) {
        self.id = id
        self.assetId = assetId
        self.source = source
        self.operator = `operator`
        self.thresholds = [threshold]
        self.enabled = enabled
        self.soundId = soundId
        self.blinkEnabled = blinkEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case assetId
        case source
        case `operator`
        case threshold
        case enabled
        case soundId
        case blinkEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        assetId = try container.decode(String.self, forKey: .assetId)
        source = try container.decode(AlertSource.self, forKey: .source)
        `operator` = try container.decode(AlertOperator.self, forKey: .operator)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        soundId = try container.decode(String.self, forKey: .soundId)
        blinkEnabled = try container.decode(Bool.self, forKey: .blinkEnabled)

        if let single = try? container.decode(Double.self, forKey: .threshold) {
            thresholds = [single]
        } else {
            thresholds = try container.decode([Double].self, forKey: .threshold)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(assetId, forKey: .assetId)
        try container.encode(source, forKey: .source)
        try container.encode(`operator`, forKey: .operator)
        if thresholds.count == 1 {
            try container.encode(thresholds[0], forKey: .threshold)
        } else {
            try container.encode(thresholds, forKey: .threshold)
        }
        try container.encode(enabled, forKey: .enabled)
        try container.encode(soundId, forKey: .soundId)
        try container.encode(blinkEnabled, forKey: .blinkEnabled)
    }
}

enum AlertSource: Codable {
    case price
    case indicator(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case indicatorId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "price":
            self = .price
        case "indicator":
            self = .indicator(try container.decode(String.self, forKey: .indicatorId))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown alert source kind")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .price:
            try container.encode("price", forKey: .kind)
        case .indicator(let id):
            try container.encode("indicator", forKey: .kind)
            try container.encode(id, forKey: .indicatorId)
        }
    }
}

enum AlertOperator: String, Codable {
    case greaterThanOrEqual = ">="
    case lessThanOrEqual = "<="
    case crossUp
    case crossDown
}

enum ConfigError: Error, LocalizedError {
    case missingConfig(URL)
    case decode(String)
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig(let url):
            return "Missing config at \(url.path)"
        case .decode(let message):
            return "Config decode failed: \(message)"
        case .validation(let message):
            return "Config validation failed: \(message)"
        }
    }
}

extension WindowConfig {
    var frame: CGRect {
        CGRect(x: originX, y: originY, width: width, height: height)
    }
}
