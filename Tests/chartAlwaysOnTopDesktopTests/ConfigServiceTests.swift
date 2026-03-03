import XCTest
@testable import chartAlwaysOnTopDesktop

final class ConfigServiceTests: XCTestCase {
    func testConfigValidationRejectsDuplicateAssets() throws {
        let config = AppConfig(
            polling: PollingConfig(defaultPollSeconds: 2, staleAfterSeconds: 10),
            window: WindowConfig(opacity: 0.8, originX: 0, originY: 0, width: 400, height: 300, clickThroughByDefault: true),
            assets: [
                AssetConfig(id: "a", symbol: "BTCUSDT", enabled: true, provider: "binance", timeframe: .m1, pollSeconds: 2),
                AssetConfig(id: "a", symbol: "ETHUSDT", enabled: true, provider: "binance", timeframe: .m1, pollSeconds: 2)
            ],
            indicators: [],
            alerts: [],
            ui: UIConfig(yAxisPaddingFraction: 0.05, maxCandles: 300)
        )

        XCTAssertThrowsError(try config.validate())
    }
}
