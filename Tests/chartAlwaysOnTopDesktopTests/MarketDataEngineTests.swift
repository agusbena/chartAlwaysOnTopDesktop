import Foundation
import XCTest
@testable import chartAlwaysOnTopDesktop

final class MarketDataEngineTests: XCTestCase {
    func testMergeRollsIntoSameBucketThenCreatesNextBucket() {
        let config = AppConfig(
            polling: PollingConfig(defaultPollSeconds: 2, staleAfterSeconds: 10),
            window: WindowConfig(opacity: 0.8, originX: 0, originY: 0, width: 400, height: 300, clickThroughByDefault: true),
            assets: [AssetConfig(id: "a", symbol: "BTCUSDT", enabled: true, provider: "binance", timeframe: .m1, pollSeconds: 2)],
            indicators: [],
            alerts: [],
            ui: UIConfig(yAxisPaddingFraction: 0.05, maxCandles: 300)
        )

        let engine = MarketDataEngine(
            providerRegistry: ProviderRegistry(providers: ["binance": MockProvider()]),
            config: config,
            initialAsset: config.assets[0]
        )

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        engine.merge(tick: Tick(timestamp: t0, price: 100, volume: 1))
        engine.merge(tick: Tick(timestamp: t0.addingTimeInterval(20), price: 105, volume: 2))
        engine.merge(tick: Tick(timestamp: t0.addingTimeInterval(70), price: 98, volume: 3))

        let snapshot = engine.snapshot()
        XCTAssertEqual(snapshot.candles.count, 2)
        XCTAssertEqual(snapshot.candles[0].high, 105)
        XCTAssertEqual(snapshot.candles[0].close, 105)
        XCTAssertEqual(snapshot.candles[0].volume, 3)
        XCTAssertEqual(snapshot.candles[1].open, 98)
    }
}

private final class MockProvider: MarketDataProvider {
    func fetchHistoricalCandles(symbol: String, timeframe: Timeframe, limit: Int) async throws -> [Candle] {
        _ = (symbol, timeframe, limit)
        return []
    }

    func fetchLatestTick(symbol: String) async throws -> Tick {
        _ = symbol
        return Tick(timestamp: .now, price: 0, volume: 0)
    }

    func providerCapabilities() -> ProviderCapabilities {
        ProviderCapabilities(supportsHistorical: true, supportsTickVolume: true)
    }
}
