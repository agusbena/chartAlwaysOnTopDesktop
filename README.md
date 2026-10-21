# chartAlwaysOnTopDesktop

Native macOS overlay chart app (Swift + AppKit + Metal) for always-on-top, semi-transparent candlestick rendering.

## Run

```bash
swift run
```

## build

### Execute the build

```bash
swift build -c release
```

### Show where the build binary was generated

```bash
swift build --show-bin-path -c release
```

The app seeds config at:

`~/.config/chart-always-on-top/config.json`

Edit that file to enable assets, indicators, and alerts.

## Notes

- Hold `Ctrl` to interact with the chart (pan/zoom).
- Release `Ctrl` to return to full click-through mode.
- Default provider is Binance public API.

## Sleep and connection recovery

Polling pauses when macOS announces sleep and restarts immediately on wake.
Wake, a network reconnect, a failed request, or a long polling gap triggers a
fresh download of the latest configured candle range (up to 1,000 candles).
Existing chart data stays visible during retries, with the stale indicator
shown once `polling.staleAfterSeconds` elapses.

Normal polls fetch the latest two exchange candles and replace their OHLCV
values, including the previous candle's final values. Candles and volume are
no longer reconstructed from sampled ticker prices. Indicators are recomputed
from the corrected candles. Recovery does not replay alerts for missed candles;
alerts evaluate the latest available price and indicator values.

Run the tests with `swift test`.
