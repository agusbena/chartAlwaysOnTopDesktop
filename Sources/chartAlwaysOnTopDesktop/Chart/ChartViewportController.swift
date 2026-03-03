import Foundation

final class ChartViewportController {
    private(set) var visibleCount: Int
    private(set) var offsetFromLatest: Int
    private let minimumVisible = 20

    init(initialVisibleCount: Int = 120) {
        self.visibleCount = max(initialVisibleCount, minimumVisible)
        self.offsetFromLatest = 0
    }

    func pan(by candleDelta: Int, totalCandles: Int) {
        offsetFromLatest = min(max(offsetFromLatest + candleDelta, 0), max(totalCandles - minimumVisible, 0))
    }

    func zoom(by delta: Double, totalCandles: Int) {
        let scale = delta > 0 ? 0.9 : 1.1
        visibleCount = max(minimumVisible, min(Int(Double(visibleCount) * scale), max(totalCandles, minimumVisible)))
        offsetFromLatest = min(offsetFromLatest, max(totalCandles - visibleCount, 0))
    }

    func visibleSlice(for candles: [Candle]) -> ArraySlice<Candle> {
        guard !candles.isEmpty else { return [] }
        let end = max(candles.count - offsetFromLatest, 0)
        let start = max(end - visibleCount, 0)
        return candles[start ..< end]
    }

    func visibleRange(for candles: [Candle], paddingFraction: Double) -> PriceRange {
        let slice = visibleSlice(for: candles)
        let lows = slice.map(\.low)
        let highs = slice.map(\.high)

        guard let minValue = lows.min(), let maxValue = highs.max() else {
            return PriceRange(min: 0, max: 1)
        }

        let span = max(maxValue - minValue, 0.000_000_1)
        let padding = span * max(0, paddingFraction)
        return PriceRange(min: minValue - padding, max: maxValue + padding)
    }
}
