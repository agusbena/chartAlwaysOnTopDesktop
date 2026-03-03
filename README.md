# chartAlwaysOnTopDesktop

Native macOS overlay chart app (Swift + AppKit + Metal) for always-on-top, semi-transparent candlestick rendering.

## Run

```bash
swift run
```

The app seeds config at:

`~/.config/chart-always-on-top/config.json`

Edit that file to enable assets, indicators, and alerts.

## Notes

- Hold `Ctrl` to interact with the chart (pan/zoom).
- Release `Ctrl` to return to full click-through mode.
- Default provider is Binance public API.
