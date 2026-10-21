import AppKit
import Foundation
import Network

@MainActor
public final class AppCoordinator: NSObject, NSApplicationDelegate {
    private var overlayWindowManager: OverlayWindowManager?
    private var inputController: InputModeController?
    private var chartRenderer: ChartRenderer?

    private var configService: ConfigService?
    private var currentConfig: AppConfig?

    private var dataEngine: MarketDataEngine?
    private let networkMonitor = NWPathMonitor()
    private var wasNetworkAvailable: Bool?

    private let indicatorEngine = IndicatorEngine()
    private let alertEngine = AlertEngine()
    private let alertPresenter = AlertPresenter()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

        do {
            let configURL = Self.defaultConfigURL()
            let configService = ConfigService(configURL: configURL)
            self.configService = configService

            if let seedConfig = Bundle.module.url(forResource: "default_config", withExtension: "json", subdirectory: "Resources") {
                try configService.ensureDefaultConfigIfMissing(defaultContents: Data(contentsOf: seedConfig))
            }

            let config = try configService.load()
            currentConfig = config

            try bootstrapUI(config: config)
            try bootstrapData(config: config)

            configService.onConfigReload = { [weak self] result in
                Task { @MainActor in
                    self?.handleConfigReload(result)
                }
            }
            configService.startWatching()
        } catch {
            fatalError("Failed to bootstrap app: \(error.localizedDescription)")
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        inputController?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        networkMonitor.cancel()
        dataEngine?.stop()
        configService?.stopWatching()
    }

    private func bootstrapUI(config: AppConfig) throws {
        guard let screenFrame = NSScreen.main?.frame else {
            throw NSError(domain: "screen", code: 1)
        }

        let viewport = ChartViewportController(initialVisibleCount: min(config.ui.maxCandles, 180), maximumVisible: config.ui.maxCandles)
        let rendererFrame = CGRect(origin: .zero, size: config.window.frame.size)
        let renderer = ChartRenderer(
            frame: rendererFrame,
            viewport: viewport,
            yPadding: config.ui.yAxisPaddingFraction,
            backgroundOpacity: config.ui.backgroundOpacity,
            keepBlinkingUntilCtrlClick: config.ui.keepBlinkingUntilCtrlClick
        )
        renderer.frame = rendererFrame
        chartRenderer = renderer

        let manager = OverlayWindowManager()
        let safeFrame = config.window.frame.intersection(screenFrame).isNull ? config.window.frame : config.window.frame.intersection(screenFrame)
        _ = manager.buildWindow(
            frame: safeFrame,
            contentView: renderer,
            opacity: config.window.opacity
        )
        manager.show()
        overlayWindowManager = manager

        alertPresenter.onBlinkPulse = { [weak renderer] in
            renderer?.triggerBlinkPulse()
        }

        let input = InputModeController()
        input.onCtrlStateChange = { [weak manager] isCtrlDown in
            manager?.setClickThrough(!isCtrlDown)
        }
        input.start()
        inputController = input
    }

    private func bootstrapData(config: AppConfig) throws {
        guard let activeAsset = config.assets.first(where: \.enabled) else {
            throw ConfigError.validation("No enabled assets")
        }

        let registry = ProviderRegistry.live()
        let engine = MarketDataEngine(providerRegistry: registry, config: config, initialAsset: activeAsset)
        dataEngine = engine
        chartRenderer?.onTimeframeStep = { [weak engine] direction in
            engine?.changeTimeframe(by: direction)
        }

        engine.onFrame = { [weak self] frame in
            DispatchQueue.main.async {
                self?.chartRenderer?.update(frame: frame)
            }
        }
        engine.onAlertEvents = { [weak self] events in
            DispatchQueue.main.async {
                events.forEach {
                    self?.chartRenderer?.pushAlert($0)
                    self?.alertPresenter.present($0)
                }
            }
        }

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let reconnected = self.wasNetworkAvailable == false && available
                self.wasNetworkAvailable = available
                if reconnected { self.dataEngine?.refreshHistory() }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "market.network.monitor"))
        engine.start(
            indicatorEngine: indicatorEngine,
            indicatorConfigs: config.indicators,
            alerts: config.alerts,
            alertEngine: alertEngine
        )
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        dataEngine?.suspend()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        dataEngine?.resume()
    }

    private func handleConfigReload(_ result: Result<AppConfig, Error>) {
        switch result {
        case .success(let config):
            currentConfig = config
            if let opacity = overlayWindowManager?.window?.alphaValue {
                let target = CGFloat(config.window.opacity)
                if opacity != target {
                    overlayWindowManager?.window?.alphaValue = target
                }
            }
            chartRenderer?.setBackgroundOpacity(config.ui.backgroundOpacity)
            chartRenderer?.setKeepBlinkingUntilCtrlClick(config.ui.keepBlinkingUntilCtrlClick)
            overlayWindowManager?.setClickThrough(!NSEvent.modifierFlags.contains(.control))
            print("Config reloaded")
        case .failure(let error):
            print("Config reload failed: \(error.localizedDescription)")
        }
    }

    static func defaultConfigURL() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("chart-always-on-top", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }
}
