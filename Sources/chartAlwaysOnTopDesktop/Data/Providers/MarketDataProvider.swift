import Foundation

protocol MarketDataProvider {
    func fetchHistoricalCandles(symbol: String, timeframe: Timeframe, limit: Int) async throws -> [Candle]
    func fetchLatestTick(symbol: String) async throws -> Tick
    func providerCapabilities() -> ProviderCapabilities
}

enum MarketDataError: Error {
    case invalidResponse
    case unsupportedTimeframe
    case decoding
}
