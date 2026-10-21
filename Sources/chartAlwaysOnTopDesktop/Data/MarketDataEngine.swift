import Foundation

final class MarketDataEngine: @unchecked Sendable {
    struct AssetState {
        let config: AssetConfig
        var timeframe: Timeframe
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
    private var generation = 0
    private var isSuspended = false
    private var needsHistory = true
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
        self.state = AssetState(
            config: initialAsset,
            timeframe: initialAsset.timeframe ?? .m1,
            pollSeconds: initialAsset.pollSeconds ?? config.polling.defaultPollSeconds,
            candles: [], latestPrice: nil, lastUpdate: nil, isStale: false
        )
    }

    func start(
        indicatorEngine: IndicatorEngine,
        indicatorConfigs: [IndicatorConfig],
        alerts: [AlertConfig],
        alertEngine: AlertEngine
    ) {
        queue.sync {
            self.indicatorEngine = indicatorEngine
            self.indicatorConfigs = indicatorConfigs
            self.alerts = alerts
            self.alertEngine = alertEngine
        }
        restartPolling()
    }

    func stop() {
        queue.sync {
            generation += 1
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func suspend() {
        queue.sync { isSuspended = true }
        stop()
    }

    func resume() {
        queue.sync { isSuspended = false }
        refreshHistory()
    }

    func refreshHistory() {
        queue.sync { needsHistory = true }
        restartPolling()
    }

    func changeTimeframe(by direction: Int) {
        let changed = queue.sync { () -> Bool in
            let next = state.timeframe.adjacent(direction)
            guard next != state.timeframe else { return false }
            // Invalidate old responses before publishing the new interval, even during sleep.
            generation += 1
            state.timeframe = next
            alertEngine?.resetIndicatorComparisons(alerts: alerts)
            state.candles = []
            state.latestPrice = nil
            state.lastUpdate = nil
            state.isStale = false
            needsHistory = true
            publishFrameAndAlerts(evaluateAlerts: false)
            return true
        }
        if changed { restartPolling() }
    }

    private func restartPolling() {
        queue.sync {
            generation += 1
            pollTask?.cancel()
            pollTask = nil
            needsHistory = true
            reconnectBackoffSeconds = 1
            guard !isSuspended, indicatorEngine != nil else { return }
            let currentGeneration = generation
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.pollOnce(generation: currentGeneration)
                    let wait = self.queue.sync { max(self.state.pollSeconds, self.reconnectBackoffSeconds) }
                    do {
                        try await Task.sleep(for: .seconds(wait))
                    } catch { return }
                }
            }
        }
    }

    // Internal entry point also allows deterministic recovery tests without timers or live requests.
    func pollOnce(now: Date = .now, generation expectedGeneration: Int? = nil) async {
        let context = queue.sync { (state, generation, needsHistory) }
        let snapshot = context.0
        let requestGeneration = expectedGeneration ?? context.1
        guard queue.sync(execute: { generation == requestGeneration && !isSuspended }),
              !Task.isCancelled,
              let provider = providerRegistry.provider(for: snapshot.config.provider) else { return }
        let gap = snapshot.lastUpdate.map { now.timeIntervalSince($0) > Double(max(snapshot.pollSeconds * 3, staleAfterSeconds)) } ?? true
        let crossedMultipleBuckets = snapshot.candles.last.map {
            snapshot.timeframe.bucketStart(for: now) > snapshot.timeframe.nextBucket(after: $0.timestamp)
        } ?? true
        let fullRefresh = context.2 || gap || crossedMultipleBuckets || snapshot.candles.isEmpty

        do {
            // Refresh the current and previous bucket on every poll so even normally sampled
            // candles get the exchange's true OHLCV. A recovery replaces the entire retained range.
            let candles = try await provider.fetchHistoricalCandles(
                symbol: snapshot.config.symbol,
                timeframe: snapshot.timeframe,
                limit: fullRefresh ? min(maxCandles, 1000) : 2
            )
            guard !candles.isEmpty else { throw MarketDataError.invalidResponse }
            queue.sync {
                // A canceled request may still complete after sleep or a reconnect.
                guard !Task.isCancelled, generation == requestGeneration, !isSuspended else { return }
                if fullRefresh {
                    state.candles = Array(candles.suffix(maxCandles))
                } else {
                    var byTimestamp = Dictionary(uniqueKeysWithValues: state.candles.map { ($0.timestamp, $0) })
                    for candle in candles { byTimestamp[candle.timestamp] = candle }
                    state.candles = Array(byTimestamp.values.sorted { $0.timestamp < $1.timestamp }.suffix(maxCandles))
                }
                state.latestPrice = state.candles.last?.close
                state.lastUpdate = now
                state.isStale = false
                needsHistory = false
                reconnectBackoffSeconds = 1
                publishFrameAndAlerts()
            }
        } catch {
            queue.sync {
                guard !Task.isCancelled, generation == requestGeneration, !isSuspended else { return }
                needsHistory = true
                state.isStale = state.lastUpdate.map { now.timeIntervalSince($0) > Double(staleAfterSeconds) } ?? true
                reconnectBackoffSeconds = min(reconnectBackoffSeconds * 2, 60)
                publishFrameAndAlerts(evaluateAlerts: false)
                print("Candle fetch failed: \(error.localizedDescription)")
            }
        }
    }

    // Called only on the state queue, including callbacks, to preserve frame ordering.
    private func publishFrameAndAlerts(evaluateAlerts: Bool = true) {
        let series = indicatorEngine?.computeSeries(candles: state.candles, configs: indicatorConfigs) ?? []
        if evaluateAlerts, let price = state.latestPrice, let alertEngine {
            let values = Dictionary(uniqueKeysWithValues: series.compactMap { item in
                item.points.last.map { (item.id, $0.value) }
            })
            onAlertEvents?(alertEngine.evaluate(alerts: alerts, assetId: state.config.id, price: price, indicatorValues: values))
        }
        onFrame?(ChartFrame(symbol: state.config.symbol, candles: state.candles, indicators: series, isStale: state.isStale, timeframe: state.timeframe, isLoading: needsHistory && state.candles.isEmpty))
    }

    func snapshot() -> AssetState {
        queue.sync { state }
    }
}
