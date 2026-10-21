import Foundation
import XCTest
@testable import chartAlwaysOnTopDesktop

final class MarketDataEngineTests: XCTestCase {
    private func makeEngine(_ provider: MockProvider) -> MarketDataEngine {
        let asset = AssetConfig(id: "a", symbol: "BTCUSDT", enabled: true, provider: "binance", timeframe: .m1, pollSeconds: 2)
        let config = AppConfig(
            polling: PollingConfig(defaultPollSeconds: 2, staleAfterSeconds: 10),
            window: WindowConfig(opacity: 0.8, originX: 0, originY: 0, width: 400, height: 300, clickThroughByDefault: true),
            assets: [asset], indicators: [], alerts: [],
            ui: UIConfig(yAxisPaddingFraction: 0.05, maxCandles: 300, backgroundOpacity: 0.1, keepBlinkingUntilCtrlClick: false)
        )
        return MarketDataEngine(providerRegistry: ProviderRegistry(providers: ["binance": provider]), config: config, initialAsset: asset)
    }

    private func candle(_ minute: Int, high: Double = 105, volume: Double = 10) -> Candle {
        Candle(timestamp: Date(timeIntervalSince1970: Double(minute * 60)), open: 100, high: high, low: 90, close: 101, volume: volume)
    }

    func testNormalPollingReplacesSampledOHLCVAndFinalizesPreviousBucket() async {
        let provider = MockProvider()
        let engine = makeEngine(provider)
        provider.candles = [candle(0), candle(1)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 119))
        provider.candles = [candle(1, high: 150, volume: 80), candle(2)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 121))
        XCTAssertEqual(provider.limits, [300, 2])
        XCTAssertEqual(engine.snapshot().candles, [candle(0), candle(1, high: 150, volume: 80), candle(2)])
    }

    func testMissedWakeNotificationDetectedByPollingGap() async {
        let provider = MockProvider()
        let engine = makeEngine(provider)
        provider.candles = [candle(0)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 1))
        provider.candles = [candle(10), candle(11)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 661))
        XCTAssertEqual(provider.limits, [300, 300])
        XCTAssertEqual(engine.snapshot().candles, provider.candles)
    }

    func testFailedRecoveryRetriesFullHistoryAndRetainsExistingChart() async {
        let provider = MockProvider()
        let engine = makeEngine(provider)
        provider.candles = [candle(0)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 1))
        provider.shouldFail = true
        await engine.pollOnce(now: Date(timeIntervalSince1970: 61))
        XCTAssertTrue(engine.snapshot().isStale)
        XCTAssertEqual(engine.snapshot().candles, [candle(0)])
        provider.shouldFail = false
        provider.candles = [candle(0, high: 140), candle(1)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 62))
        XCTAssertEqual(provider.limits, [300, 300, 300])
        XCTAssertEqual(engine.snapshot().candles, provider.candles)
        XCTAssertFalse(engine.snapshot().isStale)
    }

    func testSleepStopsRequestsAndWakeRequiresHistoryEvenForShortSleep() async {
        let provider = MockProvider()
        let engine = makeEngine(provider)
        provider.candles = [candle(0)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 1))
        engine.suspend()
        await engine.pollOnce(now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(provider.limits, [300])
        engine.resume()
        provider.candles = [candle(0, high: 170)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(provider.limits, [300, 300])
        XCTAssertEqual(engine.snapshot().candles, provider.candles)
    }

    func testReconnectAndEmptyResponseRequireFullHistory() async {
        let provider = MockProvider()
        let engine = makeEngine(provider)
        provider.candles = [candle(0)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 1))
        engine.refreshHistory()
        provider.candles = []
        await engine.pollOnce(now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(engine.snapshot().candles, [candle(0)])
        provider.candles = [candle(0, high: 160)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(provider.limits, [300, 300, 300])
        XCTAssertEqual(engine.snapshot().candles, provider.candles)
    }

    func testResponseStartedBeforeSleepCannotOverwriteRecoveredData() async {
        let provider = MockProvider()
        let engine = makeEngine(provider)
        provider.candles = [candle(0)]
        provider.beforeReturn = { engine.suspend(); engine.resume() }
        await engine.pollOnce(now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(engine.snapshot().candles.isEmpty)
        provider.beforeReturn = nil
        provider.candles = [candle(10)]
        await engine.pollOnce(now: Date(timeIntervalSince1970: 601))
        XCTAssertEqual(engine.snapshot().candles, provider.candles)
    }
}

private final class MockProvider: MarketDataProvider {
    var candles: [Candle] = []
    var limits: [Int] = []
    var shouldFail = false
    var beforeReturn: (() -> Void)?

    func fetchHistoricalCandles(symbol: String, timeframe: Timeframe, limit: Int) async throws -> [Candle] {
        limits.append(limit)
        if shouldFail { throw MarketDataError.invalidResponse }
        beforeReturn?()
        return candles
    }

    func fetchLatestTick(symbol: String) async throws -> Tick {
        XCTFail("The chart must use authoritative candles, not sampled ticks")
        throw MarketDataError.invalidResponse
    }

    func providerCapabilities() -> ProviderCapabilities {
        ProviderCapabilities(supportsHistorical: true, supportsTickVolume: true)
    }
}
