import XCTest
@testable import chartAlwaysOnTopDesktop

final class AlertEngineTests: XCTestCase {
    func testCrossUpTriggersOnceUntilReset() {
        let alert = AlertConfig(
            id: "a1",
            assetId: "btc",
            source: .price,
            operator: .crossUp,
            threshold: 100,
            enabled: true,
            soundId: "Glass",
            blinkEnabled: true
        )

        let engine = AlertEngine()

        var events = engine.evaluate(alerts: [alert], assetId: "btc", price: 99, indicatorValues: [:])
        XCTAssertTrue(events.isEmpty)

        events = engine.evaluate(alerts: [alert], assetId: "btc", price: 101, indicatorValues: [:])
        XCTAssertEqual(events.count, 1)

        events = engine.evaluate(alerts: [alert], assetId: "btc", price: 102, indicatorValues: [:])
        XCTAssertTrue(events.isEmpty)

        events = engine.evaluate(alerts: [alert], assetId: "btc", price: 98, indicatorValues: [:])
        XCTAssertTrue(events.isEmpty)

        events = engine.evaluate(alerts: [alert], assetId: "btc", price: 100, indicatorValues: [:])
        XCTAssertEqual(events.count, 1)
    }
}
