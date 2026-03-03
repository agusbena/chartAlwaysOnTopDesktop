import Foundation

struct Candle: Codable, Equatable {
    let timestamp: Date
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double
}

struct Tick: Codable, Equatable {
    let timestamp: Date
    let price: Double
    let volume: Double?
}

enum Timeframe: String, Codable, CaseIterable {
    case m1 = "1m"
    case m5 = "5m"

    var seconds: TimeInterval {
        switch self {
        case .m1: return 60
        case .m5: return 300
        }
    }

    func bucketStart(for date: Date) -> Date {
        let interval = seconds
        let ts = date.timeIntervalSince1970
        let bucket = floor(ts / interval) * interval
        return Date(timeIntervalSince1970: bucket)
    }
}

struct ProviderCapabilities {
    let supportsHistorical: Bool
    let supportsTickVolume: Bool
}

struct ChartFrame {
    let symbol: String
    let candles: [Candle]
    let indicators: [IndicatorSeries]
    let isStale: Bool
}

struct IndicatorPoint: Equatable {
    let timestamp: Date
    let value: Double
}

struct IndicatorSeries: Equatable {
    let id: String
    let colorHex: String
    let points: [IndicatorPoint]
}

struct PriceRange {
    let min: Double
    let max: Double

    var span: Double {
        Swift.max(self.max - self.min, 0.000_000_1)
    }
}
