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
    case s1 = "1s"
    case m1 = "1m"
    case m3 = "3m"
    case m5 = "5m"
    // Decode legacy files so validation can explain how to fix this unsupported interval.
    case m10 = "10m"
    case m15 = "15m"
    case m30 = "30m"
    case h1 = "1h"
    case h2 = "2h"
    case h4 = "4h"
    case h6 = "6h"
    case h8 = "8h"
    case h12 = "12h"
    case d1 = "1d"
    case d3 = "3d"
    case w1 = "1w"
    case month1 = "1M"

    static let binanceIntervals: [Timeframe] = allCases.filter { $0 != .m10 }

    func adjacent(_ direction: Int) -> Timeframe {
        guard let index = Self.binanceIntervals.firstIndex(of: self) else { return .m1 }
        return Self.binanceIntervals[min(max(index + direction, 0), Self.binanceIntervals.count - 1)]
    }

    // Month duration is only an estimate; bucket arithmetic below uses calendar months.
    var seconds: TimeInterval {
        switch self {
        case .s1: return 1
        case .m1: return 60
        case .m3: return 180
        case .m5: return 300
        case .m10: return 600
        case .m15: return 900
        case .m30: return 1800
        case .h1: return 3600
        case .h2: return 7200
        case .h4: return 14400
        case .h6: return 21600
        case .h8: return 28800
        case .h12: return 43200
        case .d1: return 86400
        case .d3: return 259200
        case .w1: return 604800
        case .month1: return 30 * 86400
        }
    }

    func bucketStart(for date: Date) -> Date {
        if self == .month1 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar.dateInterval(of: .month, for: date)!.start
        }
        // Binance weeks start Monday, whereas the Unix epoch starts Thursday.
        let anchor: TimeInterval = self == .w1 ? 4 * 86400 : 0
        let bucket = floor((date.timeIntervalSince1970 - anchor) / seconds) * seconds + anchor
        return Date(timeIntervalSince1970: bucket)
    }

    func nextBucket(after date: Date) -> Date {
        let start = bucketStart(for: date)
        if self == .month1 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar.date(byAdding: .month, value: 1, to: start)!
        }
        return start.addingTimeInterval(seconds)
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
    var timeframe: Timeframe = .m1
    var isLoading: Bool = false
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
