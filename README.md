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

## Runtime timeframe and zoom controls

The header shows `BTCUSDT <price> ↑ ↓ <timeframe>` in the price label's font
and color. Hold **Control** and click **↑** for the next larger Binance interval,
or **↓** for the next smaller one. The choices run from `1s` through `1M`
(monthly); arrows stop at either end. `10m` is not supported by Binance.
After Control-clicking the chart to focus it, **Control + Up/Down** also changes
intervals, if those shortcuts are not reserved by macOS.

Hold **Control** and scroll up to show fewer candles or down to show more.
Control-drag pans within the downloaded history. Releasing Control makes the
entire overlay click-through, including its arrows.

Timeframe changes preserve the visible candle count and return to the latest
candle. For example, 180 weekly candles becomes the latest 180 minute candles
when you switch to `1m`; the app does not try to preserve years of time range.
Each switch fetches fresh candles and recomputes indicators. While loading or
retrying, the selected interval remains visible without showing candles from
the previous interval.

`ui.maxCandles` in `~/.config/chart-always-on-top/config.json` is the maximum
history and zoom-out size (20–1,000, default 800). The app prefetches that bounded
history when loading an interval, so scrolling uses the cache without making a
request for every wheel event. If the symbol has less history, all available
candles fit the width. The bottom label shows the visible candle count and cap.
Restart after changing this limit. Runtime timeframe and zoom choices are
session-only; they never modify the configuration file.

The price, timeframe controls, time range, and status form a footer that wraps
to the window width. Its last row stays pinned to the bottom; additional rows
grow upward, with alerts placed above them.

The footer’s first row keeps the asset and price first, followed by the arrows
and selected timeframe. The time range and status wrap beneath that row.
