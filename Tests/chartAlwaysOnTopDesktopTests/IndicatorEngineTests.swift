import Foundation
import XCTest
@testable import chartAlwaysOnTopDesktop

final class IndicatorEngineTests: XCTestCase {
    func testSmaAndEmaProduceExpectedPointCounts() {
        let candles = (0 ..< 50).map { idx in
            Candle(
                timestamp: Date(timeIntervalSince1970: Double(idx) * 60),
                open: Double(idx),
                high: Double(idx) + 2,
                low: Double(idx) - 1,
                close: Double(idx),
                volume: 10
            )
        }

        let engine = IndicatorEngine()
        let configs = [
            IndicatorConfig(id: "sma", type: .sma, enabled: true, colorHex: "#FFFFFF", params: ["period": 10]),
            IndicatorConfig(id: "ema", type: .ema, enabled: true, colorHex: "#000000", params: ["period": 10])
        ]

        let series = engine.computeSeries(candles: candles, configs: configs)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].points.count, 41)
        XCTAssertEqual(series[1].points.count, 41)
    }
}
