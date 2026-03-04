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

    override func mouseDragged(with event: NSEvent) {
        let dx = Int(event.deltaX / 3)
        stateQueue.sync {
            let total = state.frame?.candles.count ?? 0
            viewport.pan(by: dx, totalCandles: total)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        stateQueue.sync {
            let total = state.frame?.candles.count ?? 0
            viewport.zoom(by: event.deltaY, totalCandles: total)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            acknowledgePersistentBlink()
        }
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

        let snapshot = stateQueue.sync { () -> (ChartFrame?, PriceRange, Float, Bool, Date?) in
            (state.frame, state.range, state.backgroundOpacity, state.persistentBlinkActive, state.blinkUntil)
        }

        let vertices = buildVertices(
            frame: snapshot.0,
            range: snapshot.1,
            backgroundOpacity: snapshot.2,
            persistentBlinkActive: snapshot.3,
            blinkUntil: snapshot.4
        )
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
        [xAxisLabel, yAxisTopLabel, yAxisBottomLabel, staleLabel, currentPriceLabel].forEach {
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

        staleLabel.textColor = NSColor.systemOrange
        currentPriceLabel.textColor = NSColor.systemGreen
        layoutLabels()
    }

    private func layoutLabels() {
        xAxisLabel.frame = CGRect(x: 8, y: 6, width: bounds.width - 16, height: 14)
        yAxisTopLabel.frame = CGRect(x: 8, y: bounds.height - 18, width: 150, height: 14)
        yAxisBottomLabel.frame = CGRect(x: 8, y: 22, width: 150, height: 14)
        currentPriceLabel.frame = CGRect(x: 170, y: bounds.height - 18, width: 220, height: 14)
        staleLabel.frame = CGRect(x: bounds.width - 140, y: bounds.height - 18, width: 130, height: 14)
        alertLabels[0].frame = CGRect(x: bounds.width - 220, y: 40, width: 310, height: 14)
        alertLabels[1].frame = CGRect(x: bounds.width - 220, y: 24, width: 310, height: 14)
        alertLabels[2].frame = CGRect(x: bounds.width - 220, y: 8, width: 310, height: 14)
    }

    private func updateLabels() {
        let snapshot = stateQueue.sync { () -> (ChartFrame?, PriceRange, [String]) in
            (state.frame, state.range, state.latestAlerts)
        }
        guard let frame = snapshot.0 else { return }
        let slice = viewport.visibleSlice(for: frame.candles)
        let range = snapshot.1
        let latestAlerts = snapshot.2
        yAxisTopLabel.stringValue = String(format: "%.4f", range.max)
        yAxisBottomLabel.stringValue = String(format: "%.4f", range.min)
        currentPriceLabel.stringValue = String(format: "Price: %.4f", frame.candles.last?.close ?? 0)

        if let first = slice.first?.timestamp, let last = slice.last?.timestamp {
            xAxisLabel.stringValue = "\(dateFormatter.string(from: first)) - \(dateFormatter.string(from: last))  \(frame.symbol)"
        } else {
            xAxisLabel.stringValue = frame.symbol
        }

        staleLabel.stringValue = frame.isStale ? "STALE DATA" : ""
        for idx in 0 ..< alertLabels.count {
            alertLabels[idx].stringValue = idx < latestAlerts.count ? latestAlerts[idx] : ""
        }
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
        guard candles.count > 1 else { return [] }

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
            let x = -0.9 + (Float(index) / Float(candles.count - 1)) * 1.8
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

        let byTime = Dictionary(uniqueKeysWithValues: series.points.map { ($0.timestamp, $0.value) })
        var points: [(Float, Float)] = []
        points.reserveCapacity(candles.count)
        for (idx, candle) in candles.enumerated() {
            guard let value = byTime[candle.timestamp] else { continue }
            let x = -0.9 + (Float(idx) / Float(max(candles.count - 1, 1))) * 1.8
            let y = mapPriceToY(value, range: range)
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
