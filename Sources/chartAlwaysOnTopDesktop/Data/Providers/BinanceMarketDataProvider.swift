import Foundation

final class BinanceMarketDataProvider: MarketDataProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func providerCapabilities() -> ProviderCapabilities {
        ProviderCapabilities(supportsHistorical: true, supportsTickVolume: true)
    }

    func fetchHistoricalCandles(symbol: String, timeframe: Timeframe, limit: Int) async throws -> [Candle] {
        guard Timeframe.binanceIntervals.contains(timeframe) else { throw MarketDataError.unsupportedTimeframe }
        let interval = timeframe.rawValue

        var comps = URLComponents(string: "https://api.binance.com/api/v3/klines")
        comps?.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let url = comps?.url else { throw MarketDataError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw MarketDataError.invalidResponse
        }

        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw MarketDataError.decoding
        }

        return rows.compactMap { row in
            guard row.count > 5,
                  let openTs = row[0] as? Double,
                  let open = Double(String(describing: row[1])),
                  let high = Double(String(describing: row[2])),
                  let low = Double(String(describing: row[3])),
                  let close = Double(String(describing: row[4])),
                  let volume = Double(String(describing: row[5])) else {
                return nil
            }
            return Candle(
                timestamp: Date(timeIntervalSince1970: openTs / 1000.0),
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume
            )
        }
    }

    func fetchLatestTick(symbol: String) async throws -> Tick {
        var comps = URLComponents(string: "https://api.binance.com/api/v3/ticker/24hr")
        comps?.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        guard let url = comps?.url else { throw MarketDataError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw MarketDataError.invalidResponse
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lastPriceRaw = payload["lastPrice"],
              let lastPrice = Double(String(describing: lastPriceRaw)),
              let volumeRaw = payload["volume"],
              let volume = Double(String(describing: volumeRaw)) else {
            throw MarketDataError.decoding
        }

        return Tick(timestamp: .now, price: lastPrice, volume: volume)
    }
}
