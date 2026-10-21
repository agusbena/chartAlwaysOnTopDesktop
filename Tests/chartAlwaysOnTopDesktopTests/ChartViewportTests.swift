import Foundation
import XCTest
@testable import chartAlwaysOnTopDesktop

final class ChartViewportTests: XCTestCase {
    private func candles(_ count: Int) -> [Candle] {
        (0 ..< count).map {
            Candle(timestamp: Date(timeIntervalSince1970: Double($0 * 60)), open: 10, high: Double($0 + 20), low: 1, close: 12, volume: 1)
        }
    }

    func testZoomCapsAtConfiguredLimitAndFillsWidth() {
        let viewport = ChartViewportController(initialVisibleCount: 180, maximumVisible: 300)
        let history = candles(300)
        for _ in 0 ..< 100 { viewport.zoom(by: -1, totalCandles: 300) }
        XCTAssertEqual(viewport.visibleCount, 300)
        XCTAssertEqual(viewport.visibleSlice(for: history).count, 300)
        for _ in 0 ..< 100 { viewport.zoom(by: 1, totalCandles: 300) }
        XCTAssertEqual(viewport.visibleCount, 20)
    }

    func testPanAndTimeframeResetPreserveCandleCount() {
        let viewport = ChartViewportController(initialVisibleCount: 60, maximumVisible: 300)
        let history = candles(300)
        viewport.pan(by: 1000, totalCandles: 300)
        XCTAssertEqual(viewport.offsetFromLatest, 240)
        XCTAssertEqual(viewport.visibleSlice(for: history).count, 60)
        viewport.resetToLatest()
        XCTAssertEqual(viewport.visibleCount, 60)
        XCTAssertEqual(viewport.visibleSlice(for: history).last, history.last)
        // A newly listed symbol may have fewer candles than the current zoom setting.
        XCTAssertEqual(viewport.visibleSlice(for: candles(3)).count, 3)
    }

    func testZeroScrollAndLoadingDoNotChangeZoom() {
        let viewport = ChartViewportController(initialVisibleCount: 180, maximumVisible: 300)
        viewport.zoom(by: 0, totalCandles: 300)
        viewport.zoom(by: -1, totalCandles: 0)
        XCTAssertEqual(viewport.visibleCount, 180)
    }

    func testSupportedTimeframesAndBoundaries() {
        XCTAssertEqual(Timeframe.binanceIntervals.map(\.rawValue), ["1s", "1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "6h", "8h", "12h", "1d", "3d", "1w", "1M"])
        XCTAssertEqual(Timeframe.s1.adjacent(-1), .s1)
        XCTAssertEqual(Timeframe.month1.adjacent(1), .month1)
        XCTAssertEqual(Timeframe.m5.adjacent(1), .m15)
    }

    func testMonthlyAndWeeklyBucketsUseUTCCalendarBoundaries() {
        let formatter = ISO8601DateFormatter()
        let leapDay = formatter.date(from: "2024-02-29T23:59:59Z")!
        XCTAssertEqual(Timeframe.month1.bucketStart(for: leapDay), formatter.date(from: "2024-02-01T00:00:00Z"))
        XCTAssertEqual(Timeframe.month1.nextBucket(after: leapDay), formatter.date(from: "2024-03-01T00:00:00Z"))
        XCTAssertEqual(Timeframe.w1.bucketStart(for: leapDay), formatter.date(from: "2024-02-26T00:00:00Z"))
        XCTAssertEqual(Timeframe.w1.nextBucket(after: leapDay), formatter.date(from: "2024-03-04T00:00:00Z"))
    }
    func testTimeframeResetDoesNotCreateAnIndicatorCrossing() {
        let engine = AlertEngine()
        let alert = AlertConfig(id: "rsi", assetId: "btc", source: .indicator("rsi"), operator: .crossUp, threshold: 50, enabled: true, soundId: "Glass", blinkEnabled: false)
        XCTAssertTrue(engine.evaluate(alerts: [alert], assetId: "btc", price: 100, indicatorValues: ["rsi": 40]).isEmpty)
        engine.resetIndicatorComparisons(alerts: [alert])
        XCTAssertTrue(engine.evaluate(alerts: [alert], assetId: "btc", price: 100, indicatorValues: ["rsi": 60]).isEmpty)
        // A genuine crossing within the new timeframe still works.
        XCTAssertTrue(engine.evaluate(alerts: [alert], assetId: "btc", price: 100, indicatorValues: ["rsi": 40]).isEmpty)
        XCTAssertEqual(engine.evaluate(alerts: [alert], assetId: "btc", price: 100, indicatorValues: ["rsi": 60]).count, 1)
    }

}
