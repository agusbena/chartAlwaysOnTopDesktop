import Foundation

protocol Indicator {
    func compute(series: [Candle], params: [String: Double]) -> [IndicatorPoint]
}

final class IndicatorEngine {
    private let implementations: [IndicatorType: Indicator]

    init(implementations: [IndicatorType: Indicator] = IndicatorEngine.defaultImplementations()) {
        self.implementations = implementations
    }

    static func defaultImplementations() -> [IndicatorType: Indicator] {
        [
            .ema: EMAIndicator(),
            .sma: SMAIndicator(),
            .vwap: VWAPIndicator(),
            .rsi: RSIIndicator()
        ]
    }

    func computeSeries(candles: [Candle], configs: [IndicatorConfig]) -> [IndicatorSeries] {
        configs
            .filter(\.enabled)
            .compactMap { config in
                guard let indicator = implementations[config.type] else { return nil }
                let points = indicator.compute(series: candles, params: config.params)
                return IndicatorSeries(id: config.id, colorHex: config.colorHex, points: points)
            }
    }
}

struct SMAIndicator: Indicator {
    func compute(series: [Candle], params: [String: Double]) -> [IndicatorPoint] {
        let period = Int(params["period"] ?? 14)
        guard period > 0, series.count >= period else { return [] }
        var result: [IndicatorPoint] = []
        for idx in (period - 1) ..< series.count {
            let slice = series[(idx - period + 1) ... idx]
            let mean = slice.reduce(0.0) { $0 + $1.close } / Double(period)
            result.append(IndicatorPoint(timestamp: series[idx].timestamp, value: mean))
        }
        return result
    }
}

struct EMAIndicator: Indicator {
    func compute(series: [Candle], params: [String: Double]) -> [IndicatorPoint] {
        let period = Int(params["period"] ?? 14)
        guard period > 0, series.count >= period else { return [] }

        let smoothing = 2.0 / (Double(period) + 1.0)
        let initial = series.prefix(period).reduce(0.0) { $0 + $1.close } / Double(period)

        var ema = initial
        var points: [IndicatorPoint] = [IndicatorPoint(timestamp: series[period - 1].timestamp, value: ema)]

        for idx in period ..< series.count {
            ema = (series[idx].close - ema) * smoothing + ema
            points.append(IndicatorPoint(timestamp: series[idx].timestamp, value: ema))
        }
        return points
    }
}

struct VWAPIndicator: Indicator {
    func compute(series: [Candle], params: [String: Double]) -> [IndicatorPoint] {
        _ = params
        var cumulativePV = 0.0
        var cumulativeV = 0.0
        return series.compactMap { candle in
            let typical = (candle.high + candle.low + candle.close) / 3.0
            cumulativePV += typical * candle.volume
            cumulativeV += candle.volume
            guard cumulativeV > 0 else { return nil }
            return IndicatorPoint(timestamp: candle.timestamp, value: cumulativePV / cumulativeV)
        }
    }
}

struct RSIIndicator: Indicator {
    func compute(series: [Candle], params: [String: Double]) -> [IndicatorPoint] {
        let period = Int(params["period"] ?? 14)
        guard period > 0, series.count > period else { return [] }

        var gains = 0.0
        var losses = 0.0
        for i in 1 ... period {
            let delta = series[i].close - series[i - 1].close
            if delta >= 0 {
                gains += delta
            } else {
                losses -= delta
            }
        }

        var avgGain = gains / Double(period)
        var avgLoss = losses / Double(period)
        var points: [IndicatorPoint] = []

        func rsi(_ g: Double, _ l: Double) -> Double {
            guard l > 0 else { return 100.0 }
            let rs = g / l
            return 100.0 - (100.0 / (1.0 + rs))
        }

        points.append(IndicatorPoint(timestamp: series[period].timestamp, value: rsi(avgGain, avgLoss)))

        guard series.count > (period + 1) else { return points }

        for i in (period + 1) ..< series.count {
            let delta = series[i].close - series[i - 1].close
            let gain = max(delta, 0)
            let loss = max(-delta, 0)
            avgGain = ((avgGain * Double(period - 1)) + gain) / Double(period)
            avgLoss = ((avgLoss * Double(period - 1)) + loss) / Double(period)
            points.append(IndicatorPoint(timestamp: series[i].timestamp, value: rsi(avgGain, avgLoss)))
        }

        return points
    }
}
