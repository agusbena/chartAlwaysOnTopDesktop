import Foundation

final class ProviderRegistry {
    private var providers: [String: MarketDataProvider]

    init(providers: [String: MarketDataProvider]) {
        self.providers = providers
    }

    func provider(for key: String) -> MarketDataProvider? {
        providers[key]
    }

    static func live() -> ProviderRegistry {
        ProviderRegistry(providers: [
            "binance": BinanceMarketDataProvider()
        ])
    }
}
