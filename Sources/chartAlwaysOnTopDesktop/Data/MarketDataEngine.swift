import Foundation

final class MarketDataEngine: @unchecked Sendable {
    struct AssetState {
        let config: AssetConfig
        let timeframe: Timeframe
        let pollSeconds: Int
        var candles: [Candle]
        var latestPrice: Double?
        var lastUpdate: Date?
        var isStale: Bool
    }

    private let providerRegistry: ProviderRegistry
    private let staleAfterSeconds: Int
    private let maxCandles: Int
    private let queue = DispatchQueue(label: "market.data.engine.queue")

    private var state: AssetState
    private var pollTask: Task<Void, Never>?
    private var reconnectBackoffSeconds = 1

    private var indicatorEngine: IndicatorEngine?
    private var indicatorConfigs: [IndicatorConfig] = []
    private var alerts: [AlertConfig] = []
    private var alertEngine: AlertEngine?

    var onFrame: ((ChartFrame) -> Void)?
    var onAlertEvents: (([AlertEvent]) -> Void)?

    init(providerRegistry: ProviderRegistry, config: AppConfig, initialAsset: AssetConfig) {
        self.providerRegistry = providerRegistry
        self.staleAfterSeconds = config.polling.staleAfterSeconds
        self.maxCandles = config.ui.maxCandles

        let timeframe = initialAsset.timeframe ?? .m1
        let pollSeconds = initialAsset.pollSeconds ?? config.polling.defaultPollSeconds
        self.state = AssetState(
            config: initialAsset,
            timeframe: timeframe,
            pollSeconds: pollSeconds,
            candles: [],
            latestPrice: nil,
            lastUpdate: nil,
            isStale: false
        )
    }

    func bootstrap() async {
        guard let provider = queue.sync(execute: { providerRegistry.provider(for: state.config.provider) }) else {
            print("No provider for \(state.config.provider)")
            return
        }

        do {
            let snapshot = queue.sync { state }
            let candles = try await provider.fetchHistoricalCandles(
                symbol: snapshot.config.symbol,
                timeframe: snapshot.timeframe,
                limit: min(maxCandles, 500)
            )
            queue.sync {
                state.candles = candles
            }
            publishFrame(indicators: [])
        } catch {
            print("Historical fetch failed: \(error.localizedDescription)")
        }
    }

    func start(
        indicatorEngine: IndicatorEngine,
        indicatorConfigs: [IndicatorConfig],
        alerts: [AlertConfig],
        alertEngine: AlertEngine
    ) {
        self.indicatorEngine = indicatorEngine
        self.indicatorConfigs = indicatorConfigs
        self.alerts = alerts
        self.alertEngine = alertEngine
        pollTask?.cancel()

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                let waitSeconds = self.queue.sync { self.state.pollSeconds }
                try? await Task.sleep(for: .seconds(Double(waitSeconds)))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        guard let provider = queue.sync(execute: { providerRegistry.provider(for: state.config.provider) }) else { return }
        guard let indicatorEngine, let alertEngine else { return }
        let indicatorConfigs = self.indicatorConfigs
        let alerts = self.alerts

        do {
            let snapshot = queue.sync { state }
            let tick = try await provider.fetchLatestTick(symbol: snapshot.config.symbol)
            queue.sync {
                reconnectBackoffSeconds = 1
            }
            merge(tick: tick)

            let candles = queue.sync { state.candles }
            let indicatorSeries = indicatorEngine.computeSeries(candles: candles, configs: indicatorConfigs)
            let latestIndicatorValues = Dictionary(uniqueKeysWithValues: indicatorSeries.compactMap { series in
                series.points.last.map { (series.id, $0.value) }
            })

            if let price = queue.sync(execute: { state.latestPrice }) {
                let events = alertEngine.evaluate(
                    alerts: alerts,
                    assetId: queue.sync { state.config.id },
                    price: price,
                    indicatorValues: latestIndicatorValues
                )
                onAlertEvents?(events)
            }

            publishFrame(indicators: indicatorSeries)
        } catch {
            let snapshot = queue.sync { state }
            queue.sync {
                state.isStale = shouldMarkStale(lastUpdate: snapshot.lastUpdate)
            }
            publishFrame(indicators: [])
            let wait = queue.sync {
                let current = reconnectBackoffSeconds
                reconnectBackoffSeconds = min(reconnectBackoffSeconds * 2, 60)
                return current
            }
            try? await Task.sleep(for: .seconds(Double(wait)))
            print("poll error: \(error.localizedDescription)")
        }
    }

    private func publishFrame(indicators: [IndicatorSeries]) {
        let frame = ChartFrame(
            symbol: state.config.symbol,
            candles: state.candles,
            indicators: indicators,
            isStale: state.isStale
        )
        onFrame?(frame)
    }

    private func shouldMarkStale(lastUpdate: Date?) -> Bool {
        guard let lastUpdate else { return true }
        return Date().timeIntervalSince(lastUpdate) > Double(staleAfterSeconds)
    }

    func merge(tick: Tick) {
        queue.sync {
            state.latestPrice = tick.price
            state.lastUpdate = tick.timestamp
            state.isStale = false

            let bucketStart = state.timeframe.bucketStart(for: tick.timestamp)
            if var last = state.candles.last, state.timeframe.bucketStart(for: last.timestamp) == bucketStart {
                last.high = max(last.high, tick.price)
                last.low = min(last.low, tick.price)
                last.close = tick.price
                last.volume += tick.volume ?? 0
                state.candles[state.candles.count - 1] = last
            } else {
                let volume = tick.volume ?? 0
                let candle = Candle(
                    timestamp: bucketStart,
                    open: tick.price,
                    high: tick.price,
                    low: tick.price,
                    close: tick.price,
                    volume: volume
                )
                state.candles.append(candle)
                if state.candles.count > maxCandles {
                    state.candles.removeFirst(state.candles.count - maxCandles)
                }
            }
        }
    }

    func snapshot() -> AssetState {
        queue.sync { state }
    }
}
