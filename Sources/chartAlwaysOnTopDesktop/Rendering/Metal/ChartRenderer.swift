import AppKit
import Metal
import MetalKit
import simd

private struct Vertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

private final class RendererState {
    var frame: ChartFrame?
    var range = PriceRange(min: 0, max: 1)
    var backgroundOpacity: Float = 0.1
    var keepBlinkingUntilCtrlClick = false
    var persistentBlinkActive = false
    var latestAlerts: [String] = []
    var blinkUntil: Date?
}

final class ChartRenderer: NSView, MTKViewDelegate {
    private let mtkView: MTKView
    private let xAxisLabel = NSTextField(labelWithString: "")
    private let yAxisTopLabel = NSTextField(labelWithString: "")
    private let yAxisBottomLabel = NSTextField(labelWithString: "")
    private let staleLabel = NSTextField(labelWithString: "")
    private let currentPriceLabel = NSTextField(labelWithString: "")
    private let timeframeLabel = NSTextField(labelWithString: "")
    private let timeframeUpLabel = NSTextField(labelWithString: "↑")
    private let timeframeDownLabel = NSTextField(labelWithString: "↓")
    var onTimeframeStep: ((Int) -> Void)?

    private let alertLabels = [
        NSTextField(labelWithString: ""),
        NSTextField(labelWithString: ""),
        NSTextField(labelWithString: "")
    ]

    private let state = RendererState()
    private let stateQueue = DispatchQueue(label: "renderer.state.queue")

    private let viewport: ChartViewportController
    private let yPadding: Double

    private var deviceRef: MTLDevice?
    private var queueRef: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(
        frame frameRect: CGRect,
        viewport: ChartViewportController,
        yPadding: Double,
        backgroundOpacity: Double,
        keepBlinkingUntilCtrlClick: Bool
    ) {
        self.viewport = viewport
        self.yPadding = yPadding
        self.mtkView = MTKView(frame: frameRect)
        super.init(frame: frameRect)
        state.backgroundOpacity = Float(backgroundOpacity)
        state.keepBlinkingUntilCtrlClick = keepBlinkingUntilCtrlClick

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false

        configureMetal()
        configureAxisLabels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        mtkView.frame = bounds
        layoutLabels()
    }

    // All chart decorations route mouse events to this view, including the Metal surface.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        event?.modifierFlags.contains(.control) == true
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return }
        stateQueue.sync {
            viewport.pan(by: Int(event.deltaX / 3), totalCandles: state.frame?.candles.count ?? 0)
            updateRange()
        }
        updateLabels()
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return }
        stateQueue.sync {
            viewport.zoom(by: event.scrollingDeltaY, totalCandles: state.frame?.candles.count ?? 0)
            updateRange()
        }
        updateLabels()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        acknowledgePersistentBlink()
        let point = convert(event.locationInWindow, from: nil)
        if timeframeUpLabel.frame.contains(point) { onTimeframeStep?(1) }
        if timeframeDownLabel.frame.contains(point) { onTimeframeStep?(-1) }
    }

    override func rightMouseDown(with event: NSEvent) {
        mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), event.keyCode == 126 || event.keyCode == 125 {
            onTimeframeStep?(event.keyCode == 126 ? 1 : -1)
        } else {
            super.keyDown(with: event)
        }
    }

    // Call with stateQueue held so zoom/pan immediately updates the price scale.
    private func updateRange() {
        state.range = viewport.visibleRange(for: state.frame?.candles ?? [], paddingFraction: yPadding)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let pipelineState,
              let queueRef,
              let commandBuffer = queueRef.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let vertices = stateQueue.sync {
            buildVertices(
                frame: state.frame,
                range: state.range,
                backgroundOpacity: state.backgroundOpacity,
                persistentBlinkActive: state.persistentBlinkActive,
                blinkUntil: state.blinkUntil
            )
        }
        if !vertices.isEmpty, let buffer = deviceRef?.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count) {
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        _ = size
    }

    func update(frame: ChartFrame) {
        stateQueue.sync {
            if state.frame?.timeframe != frame.timeframe { viewport.resetToLatest() }
            state.frame = frame
            state.range = viewport.visibleRange(for: frame.candles, paddingFraction: yPadding)
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateLabels()
        }
    }

    func triggerBlinkPulse() {
        stateQueue.sync {
            if state.keepBlinkingUntilCtrlClick {
                state.persistentBlinkActive = true
            } else {
                state.blinkUntil = Date().addingTimeInterval(0.35)
            }
        }
    }

    func setBackgroundOpacity(_ value: Double) {
        stateQueue.sync {
            state.backgroundOpacity = Float(Swift.max(0, Swift.min(1, value)))
        }
    }

    func setKeepBlinkingUntilCtrlClick(_ enabled: Bool) {
        stateQueue.sync {
            state.keepBlinkingUntilCtrlClick = enabled
            if !enabled {
                state.persistentBlinkActive = false
            }
        }
    }

    func pushAlert(_ event: AlertEvent) {
        stateQueue.sync {
            let line = "\(event.alertId): \(event.threshold)"
            state.latestAlerts.insert(line, at: 0)
            if state.latestAlerts.count > 3 {
                state.latestAlerts = Array(state.latestAlerts.prefix(3))
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.updateLabels()
        }
    }

    private func acknowledgePersistentBlink() {
        stateQueue.sync {
            state.persistentBlinkActive = false
        }
    }

    private func configureMetal() {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Vertex {
            float2 position;
            float4 color;
        };

        struct Out {
            float4 position [[position]];
            float4 color;
        };

        vertex Out v_main(const device Vertex* vertices [[buffer(0)]], uint id [[vertex_id]]) {
            Out out;
            out.position = float4(vertices[id].position, 0.0, 1.0);
            out.color = vertices[id].color;
            return out;
        }

        fragment float4 f_main(Out in [[stage_in]]) {
            return in.color;
        }
        """

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device unavailable")
        }

        deviceRef = device
        queueRef = device.makeCommandQueue()
        mtkView.device = device
        mtkView.delegate = self
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.layer?.isOpaque = false
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 30
        mtkView.framebufferOnly = false
        addSubview(mtkView)

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "v_main")
            descriptor.fragmentFunction = library.makeFunction(name: "f_main")
            descriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha 
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha            
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create metal pipeline: \(error)")
        }
    }

    private func configureAxisLabels() {
        [xAxisLabel, yAxisTopLabel, yAxisBottomLabel, staleLabel, currentPriceLabel, timeframeLabel, timeframeUpLabel, timeframeDownLabel].forEach {
            $0.isBezeled = false
            $0.drawsBackground = false
            $0.textColor = NSColor.white.withAlphaComponent(0.9)
            $0.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            $0.lineBreakMode = .byClipping
            addSubview($0)
        }
        alertLabels.forEach {
            $0.isBezeled = false
            $0.drawsBackground = false
            $0.textColor = NSColor.systemYellow.withAlphaComponent(0.95)
            $0.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            $0.lineBreakMode = .byTruncatingTail
            addSubview($0)
        }

        // Footer text may span several lines; its layout grows upward from the bottom.
        [currentPriceLabel, timeframeLabel, xAxisLabel, staleLabel].forEach {
            $0.maximumNumberOfLines = 0
            $0.lineBreakMode = .byWordWrapping
            $0.cell?.wraps = true
            $0.cell?.usesSingleLineMode = false
        }

        staleLabel.textColor = NSColor.systemOrange
        currentPriceLabel.textColor = NSColor.systemGreen
        [timeframeLabel, timeframeUpLabel, timeframeDownLabel].forEach { $0.textColor = currentPriceLabel.textColor }
        timeframeUpLabel.toolTip = "Control-click: larger timeframe"
        timeframeDownLabel.toolTip = "Control-click: smaller timeframe"
        layoutLabels()
    }

    private func layoutLabels() {
        let margin: CGFloat = 8
        let bottom: CGFloat = 6
        let gap: CGFloat = 8
        let rowGap: CGFloat = 3
        let availableWidth = max(bounds.width - margin * 2, 1)

        struct FooterItem {
            let labels: [NSTextField]
            let sizes: [CGSize]
            var spacing: CGFloat = 0
            var width: CGFloat { sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(labels.count - 1, 0)) }
            var height: CGFloat { sizes.map(\.height).max() ?? 0 }
        }

        func textSize(_ label: NSTextField, maximumWidth: CGFloat? = nil) -> CGSize {
            let attributes: [NSAttributedString.Key: Any] = [.font: label.font ?? NSFont.systemFont(ofSize: 11)]
            let text = label.stringValue as NSString
            // NSTextField reserves a small horizontal inset for its cell.
            let naturalWidth = ceil(text.size(withAttributes: attributes).width) + 6
            // Preserve the controls' position when the price disappears during a reload.
            let width = min(label === currentPriceLabel ? max(naturalWidth, 220) : naturalWidth, maximumWidth ?? availableWidth)
            let measured = text.boundingRect(
                with: CGSize(width: max(width - 6, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            return CGSize(width: width, height: max(20, ceil(measured.height) + 6))
        }

        let controls = FooterItem(
            labels: [timeframeUpLabel, timeframeDownLabel, timeframeLabel],
            sizes: [CGSize(width: 20, height: 20), CGSize(width: 20, height: 20), textSize(timeframeLabel)]
        )
        // Treat the asset, price, arrows and interval as one item so wrapping
        // cannot put the asset on a different row from its controls.
        let priceWidth = max(availableWidth - controls.width - gap, 1)
        let header = FooterItem(
            labels: [currentPriceLabel] + controls.labels,
            sizes: [textSize(currentPriceLabel, maximumWidth: priceWidth)] + controls.sizes,
            spacing: gap / 3
        )
        var items = [header]
        items.append(FooterItem(labels: [xAxisLabel], sizes: [textSize(xAxisLabel)]))
        if !staleLabel.stringValue.isEmpty {
            items.append(FooterItem(labels: [staleLabel], sizes: [textSize(staleLabel)]))
        } else {
            staleLabel.frame = .zero
        }

        var rows: [[FooterItem]] = [[]]
        var rowWidth: CGFloat = 0
        for item in items {
            let spacing: CGFloat = rows[rows.count - 1].isEmpty ? 0 : gap
            // The range/status wraps underneath the header, which always stays first.
            if (rows.count == 1 || rowWidth + spacing + item.width > availableWidth), !rows[rows.count - 1].isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rowWidth += (rows[rows.count - 1].isEmpty ? 0 : gap) + item.width
            rows[rows.count - 1].append(item)
        }

        // AppKit coordinates grow upward: position the final row first so the entire
        // footer stays pinned to the bottom and extra rows cannot fall below the window.
        var y = bottom
        for row in rows.reversed() {
            let height = row.map(\.height).max() ?? 20
            var x = margin
            for item in row {
                for (label, size) in zip(item.labels, item.sizes) {
                    label.frame = CGRect(x: x, y: y + (height - size.height) / 2, width: size.width, height: size.height)
                    x += size.width + item.spacing
                }
                x += gap - item.spacing
            }
            y += height + rowGap
        }

        yAxisTopLabel.frame = CGRect(x: margin, y: bounds.height - 18, width: min(150, availableWidth), height: 14)
        yAxisBottomLabel.frame = CGRect(x: margin, y: y, width: min(150, availableWidth), height: 14)
        // Alerts occupy their own rows above the footer, within the window's width.
        for (index, label) in alertLabels.enumerated() {
            label.frame = CGRect(x: margin, y: y + 18 + CGFloat(alertLabels.count - index - 1) * 16, width: availableWidth, height: 14)
        }
    }

    private func updateLabels() {
        let snapshot = stateQueue.sync { () -> (ChartFrame?, PriceRange, [String], [Candle]) in
            (state.frame, state.range, state.latestAlerts, Array(viewport.visibleSlice(for: state.frame?.candles ?? [])))
        }
        guard let frame = snapshot.0 else { return }
        let slice = snapshot.3
        let range = snapshot.1
        let latestAlerts = snapshot.2
        yAxisTopLabel.stringValue = String(format: "%.4f", range.max)
        yAxisBottomLabel.stringValue = String(format: "%.4f", range.min)
        currentPriceLabel.stringValue = frame.candles.last.map { "\(frame.symbol) " + String(format: "%.4f", $0.close) } ?? frame.symbol
        timeframeLabel.stringValue = frame.timeframe.rawValue
        timeframeUpLabel.alphaValue = frame.timeframe == Timeframe.binanceIntervals.last ? 0.35 : 1
        timeframeDownLabel.alphaValue = frame.timeframe == Timeframe.binanceIntervals.first ? 0.35 : 1
        dateFormatter.dateFormat = frame.timeframe == .s1 ? "HH:mm:ss" : (frame.timeframe.seconds < 86400 ? "MMM d HH:mm" : "yyyy-MM-dd")

        if let first = slice.first?.timestamp, let last = slice.last?.timestamp {
            xAxisLabel.stringValue = "\(dateFormatter.string(from: first)) - \(dateFormatter.string(from: last))  \(slice.count)/\(viewport.maximumVisible) candles"
        } else {
            xAxisLabel.stringValue = frame.symbol
        }

        staleLabel.stringValue = frame.isLoading ? (frame.isStale ? "RETRYING…" : "LOADING…") : (frame.isStale ? "STALE DATA" : "")
        for idx in 0 ..< alertLabels.count {
            alertLabels[idx].stringValue = idx < latestAlerts.count ? latestAlerts[idx] : ""
        }
        layoutLabels()
    }

    private func buildVertices(
        frame: ChartFrame?,
        range: PriceRange,
        backgroundOpacity: Float,
        persistentBlinkActive: Bool,
        blinkUntil: Date?
    ) -> [Vertex] {
        guard let frame else { return [] }
        let candles = Array(viewport.visibleSlice(for: frame.candles))
        guard !candles.isEmpty else { return [] }

        var vertices: [Vertex] = []
        vertices.reserveCapacity(candles.count * 12)

        if backgroundOpacity > 0 {
            let bgColorLevel: Float = 0.35
            addQuad(
                vertices: &vertices,
                x0: -1,
                y0: -1,
                x1: 1,
                y1: 1,
                color: SIMD4<Float>(bgColorLevel, bgColorLevel, bgColorLevel, backgroundOpacity)
            )
        }

        if persistentBlinkActive {
            let phase = Int(Date().timeIntervalSinceReferenceDate * 4) % 2 == 0
            if phase {
                addQuad(
                    vertices: &vertices,
                    x0: -1,
                    y0: -1,
                    x1: 1,
                    y1: 1,
                    color: SIMD4<Float>(1, 0, 0, 0.14)
                )
            }
        } else if let blinkUntil, Date() < blinkUntil {
            addQuad(
                vertices: &vertices,
                x0: -1,
                y0: -1,
                x1: 1,
                y1: 1,
                color: SIMD4<Float>(1, 0, 0, 0.12)
            )
        }

        let candleWidth = 1.8 / Float(candles.count)
        let volumeBaseY: Float = -0.95
        let volumeTopY: Float = -0.55
        let maxVolume = max(candles.map(\.volume).max() ?? 1.0, 1.0)

        for (index, candle) in candles.enumerated() {
            let x: Float = candles.count == 1 ? 0 : -0.9 + (Float(index) / Float(candles.count - 1)) * 1.8
            let openY = mapPriceToY(candle.open, range: range)
            let closeY = mapPriceToY(candle.close, range: range)
            let highY = mapPriceToY(candle.high, range: range)
            let lowY = mapPriceToY(candle.low, range: range)
            let up = candle.close >= candle.open
            //let color = up ? SIMD4<Float>(0.2, 0.85, 0.35, 0.92) : SIMD4<Float>(0.95, 0.25, 0.25, 0.92)// Candle sticks colors.
            let color = up ? SIMD4<Float>(0.2, 0.85, 0.35, 1) : SIMD4<Float>(0.95, 0.25, 0.25, 1)

            addQuad(vertices: &vertices, x0: x - 0.004, y0: lowY, x1: x + 0.004, y1: highY, color: color)
            addQuad(vertices: &vertices, x0: x - candleWidth / 2, y0: min(openY, closeY), x1: x + candleWidth / 2, y1: max(openY, closeY), color: color)

            let volumeHeight = Float(candle.volume / maxVolume) * (volumeTopY - volumeBaseY)
            addQuad(vertices: &vertices, x0: x - candleWidth / 2, y0: volumeBaseY, x1: x + candleWidth / 2, y1: volumeBaseY + volumeHeight, color: SIMD4<Float>(0.3, 0.6, 1.0, 0.6))
        }

        for series in frame.indicators {
            addIndicatorVertices(into: &vertices, candles: candles, series: series, range: range)
        }

        return vertices
    }

    private func addIndicatorVertices(into vertices: inout [Vertex], candles: [Candle], series: IndicatorSeries, range: PriceRange) {
        let color = nsColor(from: series.colorHex)
        let rgba = SIMD4<Float>(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent), 1.0/*0.95*/)
        guard series.points.count > 1 else { return }
        
        let isRsi = series.id == "rsi_main" //"rsi"

        let byTime = Dictionary(uniqueKeysWithValues: series.points.map { ($0.timestamp, $0.value) })
        var points: [(Float, Float)] = []
        points.reserveCapacity(candles.count)
        for (idx, candle) in candles.enumerated() {
            guard let value = byTime[candle.timestamp] else { continue }
            let x = -0.9 + (Float(idx) / Float(max(candles.count - 1, 1))) * 1.8
            var y : Float = 0.0
            if isRsi {
                y = Float(value+0.5) * 200.0 //mapPriceToY(value * 20.0 + range.min, range: range)
            } else {
                y = mapPriceToY(value, range: range)
            }
            points.append((x, y))
        }

        guard points.count > 1 else { return }
        for i in 1 ..< points.count {
            let p0 = points[i - 1]
            let p1 = points[i]
            addLineSegment(vertices: &vertices, from: p0, to: p1, thickness: 0.007, color: rgba)
        }
    }

    private func mapPriceToY(_ price: Double, range: PriceRange) -> Float {
        let normalized = (price - range.min) / range.span
        return Float((normalized * 1.4) - 0.35)
    }

    private func addQuad(vertices: inout [Vertex], x0: Float, y0: Float, x1: Float, y1: Float, color: SIMD4<Float>) {
        let v0 = Vertex(position: SIMD2<Float>(x0, y0), color: color)
        let v1 = Vertex(position: SIMD2<Float>(x1, y0), color: color)
        let v2 = Vertex(position: SIMD2<Float>(x1, y1), color: color)
        let v3 = Vertex(position: SIMD2<Float>(x0, y1), color: color)

        vertices.append(contentsOf: [v0, v1, v2, v0, v2, v3])
    }

    private func addLineSegment(
        vertices: inout [Vertex],
        from p0: (Float, Float),
        to p1: (Float, Float),
        thickness: Float,
        color: SIMD4<Float>
    ) {
        let start = SIMD2<Float>(p0.0, p0.1)
        let end = SIMD2<Float>(p1.0, p1.1)
        let direction = end - start
        let length = simd_length(direction)
        guard length > 0.000_001 else { return }

        let unit = direction / length
        let normal = SIMD2<Float>(-unit.y, unit.x) * (thickness / 2)

        let a = start + normal
        let b = end + normal
        let c = end - normal
        let d = start - normal

        vertices.append(contentsOf: [
            Vertex(position: a, color: color),
            Vertex(position: b, color: color),
            Vertex(position: c, color: color),
            Vertex(position: a, color: color),
            Vertex(position: c, color: color),
            Vertex(position: d, color: color)
        ])
    }

    private func nsColor(from hex: String) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)

        switch cleaned.count {
        case 6:
            let r = CGFloat((int >> 16) & 0xFF) / 255
            let g = CGFloat((int >> 8) & 0xFF) / 255
            let b = CGFloat(int & 0xFF) / 255
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        default:
            return NSColor.systemYellow
        }
    }
}
