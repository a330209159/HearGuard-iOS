import SwiftUI

/// Standard Clinical Bilateral Pure-Tone Audiogram View (ISO 8253-1 / 中华医学会规范)
/// X-Axis: 125 Hz -> 8000 Hz (Logarithmic Octave Scale)
/// Y-Axis: -10 dB HL (top) -> 100 dB HL (bottom)
/// Right Ear: Red (#DC2626) Circle 'O' / Masked Triangle '△'
/// Left Ear: Blue (#2563EB) Cross '✕' / Masked Square '□'
public struct AudiogramCanvasView: View {
    public let results: BilateralResults
    public var baselineResults: BilateralResults? = nil
    public var baselineLabel: String = "对比基线"
    public var showSeverityBands: Bool = true
    public var showSpeechBanana: Bool = false
    public var showAsymmetryShade: Bool = true
    public var showExtendedGrid: Bool = false
    public var activeHighlightFreq: Int? = nil
    public var selectedFreq: Int? = nil
    public var onSelectFrequency: ((Int) -> Void)? = nil

    private let minFreq: Double = 125.0
    private let maxFreq: Double = 8000.0
    private let minDb: Double = -10.0
    private let maxDb: Double = 100.0

    private let rightColor = Color(red: 0.86, green: 0.15, blue: 0.15) // Clinical Red
    private let leftColor = Color(red: 0.15, green: 0.39, blue: 0.92)  // Clinical Blue

    public init(
        results: BilateralResults,
        baselineResults: BilateralResults? = nil,
        baselineLabel: String = "对比基线",
        showSeverityBands: Bool = true,
        showSpeechBanana: Bool = false,
        showAsymmetryShade: Bool = true,
        showExtendedGrid: Bool = false,
        activeHighlightFreq: Int? = nil,
        selectedFreq: Int? = nil,
        onSelectFrequency: ((Int) -> Void)? = nil
    ) {
        self.results = results
        self.baselineResults = baselineResults
        self.baselineLabel = baselineLabel
        self.showSeverityBands = showSeverityBands
        self.showSpeechBanana = showSpeechBanana
        self.showAsymmetryShade = showAsymmetryShade
        self.showExtendedGrid = showExtendedGrid
        self.activeHighlightFreq = activeHighlightFreq
        self.selectedFreq = selectedFreq
        self.onSelectFrequency = onSelectFrequency
    }

    private var gridFrequencies: [Int] {
        let interOctaves = [750, 1500, 3000, 6000]
        let hasInter = interOctaves.contains { f in
            results.left[f] != nil || results.right[f] != nil ||
            baselineResults?.left[f] != nil || baselineResults?.right[f] != nil
        }
        return (showExtendedGrid || hasInter)
            ? FrequencySetMode.extendedFrequencies
            : FrequencySetMode.standardFrequencies
    }

    private func freqToX(_ freq: Double, left: CGFloat, width: CGFloat) -> CGFloat {
        let totalOct = log2(maxFreq / minFreq) // 6 octaves
        let oct = log2(max(minFreq, min(maxFreq, freq)) / minFreq)
        return left + CGFloat(oct / totalOct) * width
    }

    private func dbToY(_ db: Double, top: CGFloat, height: CGFloat) -> CGFloat {
        let clamped = max(minDb, min(maxDb, db))
        return top + CGFloat((clamped - minDb) / (maxDb - minDb)) * height
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let padLeft: CGFloat = 40
            let padRight: CGFloat = size.width >= 360 ? 44 : 18
            let padTop: CGFloat = 34
            let padBottom: CGFloat = 28
            let plotW = max(120, size.width - padLeft - padRight)
            let plotH = max(140, size.height - padTop - padBottom)

            Canvas { context, canvasSize in
                // 1. White chart background
                let fullRect = CGRect(origin: .zero, size: canvasSize)
                context.fill(Path(fullRect), with: .color(.white))

                // 2. Severity Color Bands
                if showSeverityBands {
                    let bands: [(Double, Double, Color, String)] = [
                        (-10, 25, Color.green.opacity(0.08), "正常"),
                        (25, 40, Color.yellow.opacity(0.11), "轻度"),
                        (40, 55, Color.orange.opacity(0.11), "中度"),
                        (55, 70, Color.red.opacity(0.10), "中重"),
                        (70, 90, Color.red.opacity(0.16), "重度"),
                        (90, 100, Color.purple.opacity(0.16), "极重")
                    ]
                    for (bMin, bMax, col, tag) in bands {
                        let y1 = dbToY(bMin, top: padTop, height: plotH)
                        let y2 = dbToY(bMax, top: padTop, height: plotH)
                        let rect = CGRect(x: padLeft, y: y1, width: plotW, height: y2 - y1)
                        context.fill(Path(rect), with: .color(col))

                        if size.width >= 360 {
                            let labelText = Text(tag)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.secondary)
                            context.draw(
                                labelText,
                                at: CGPoint(x: padLeft + plotW + 6, y: (y1 + y2) * 0.5),
                                anchor: .leading
                            )
                        }
                    }
                }

                // 3. Speech Banana Envelope
                if showSpeechBanana {
                    let banana: [(Double, Double, Double)] = [
                        (180, 28, 52), (250, 22, 55), (500, 20, 58),
                        (1000, 18, 55), (2000, 16, 48), (4000, 14, 42), (6000, 18, 36)
                    ]
                    var poly = Path()
                    for (idx, item) in banana.enumerated() {
                        let p = CGPoint(
                            x: freqToX(item.0, left: padLeft, width: plotW),
                            y: dbToY(item.1, top: padTop, height: plotH)
                        )
                        if idx == 0 { poly.move(to: p) } else { poly.addLine(to: p) }
                    }
                    for item in banana.reversed() {
                        let p = CGPoint(
                            x: freqToX(item.0, left: padLeft, width: plotW),
                            y: dbToY(item.2, top: padTop, height: plotH)
                        )
                        poly.addLine(to: p)
                    }
                    poly.closeSubpath()
                    context.fill(poly, with: .color(Color.yellow.opacity(0.24)))
                    context.stroke(
                        poly,
                        with: .color(Color.orange.opacity(0.55)),
                        style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
                    )

                    let phonemes: [(Double, Double, String)] = [
                        (250, 38, "m/n"), (500, 42, "a/o/u"),
                        (1000, 35, "i/l/r"), (2000, 31, "g/k/zh"), (4000, 24, "f/s/sh")
                    ]
                    for ph in phonemes {
                        let pt = CGPoint(
                            x: freqToX(ph.0, left: padLeft, width: plotW),
                            y: dbToY(ph.1, top: padTop, height: plotH)
                        )
                        context.draw(
                            Text(ph.2).font(.system(size: 9.5, weight: .bold)).foregroundColor(.brown),
                            at: pt
                        )
                    }
                }

                // 4. Horizontal dB Grid Lines (-10 to 100 dB HL)
                var db = -10
                while db <= 100 {
                    let y = dbToY(Double(db), top: padTop, height: plotH)
                    var line = Path()
                    line.move(to: CGPoint(x: padLeft, y: y))
                    line.addLine(to: CGPoint(x: padLeft + plotW, y: y))

                    if db == 0 {
                        context.stroke(line, with: .color(Color(white: 0.25)), lineWidth: 1.4)
                    } else if db == 25 {
                        context.stroke(
                            line,
                            with: .color(Color.green.opacity(0.75)),
                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                        )
                    } else if db % 10 == 0 {
                        context.stroke(line, with: .color(Color(white: 0.84)), lineWidth: 0.9)
                    } else {
                        context.stroke(line, with: .color(Color(white: 0.94)), lineWidth: 0.6)
                    }

                    if db % 10 == 0 {
                        let lbl = Text("\(db)")
                            .font(.system(size: 10, weight: db == 0 ? .bold : .medium))
                            .foregroundColor(Color(white: 0.32))
                        context.draw(lbl, at: CGPoint(x: padLeft - 6, y: y), anchor: .trailing)
                    }
                    db += 5
                }

                // 5. Vertical Frequency Grid Lines (125 Hz -> 8000 Hz)
                let freqs = gridFrequencies
                for f in freqs {
                    let x = freqToX(Double(f), left: padLeft, width: plotW)
                    let isStd = FrequencySetMode.standardFrequencies.contains(f)
                    let isHighlighted = (activeHighlightFreq == f) || (selectedFreq == f)

                    var vLine = Path()
                    vLine.move(to: CGPoint(x: x, y: padTop))
                    vLine.addLine(to: CGPoint(x: x, y: padTop + plotH))

                    if isHighlighted {
                        context.stroke(vLine, with: .color(Color.cyan.opacity(0.85)), lineWidth: 2.2)
                    } else if isStd {
                        context.stroke(vLine, with: .color(Color(white: 0.84)), lineWidth: 0.9)
                    } else {
                        context.stroke(
                            vLine,
                            with: .color(Color(white: 0.88)),
                            style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])
                        )
                    }

                    let shortHz = FrequencyMetadata.info(for: f).shortLabel
                    let topText = Text(shortHz)
                        .font(.system(size: isStd ? 10.5 : 9.0, weight: isStd ? .bold : .regular))
                        .foregroundColor(isStd ? Color(white: 0.12) : .secondary)
                    context.draw(topText, at: CGPoint(x: x, y: padTop - 6), anchor: .bottom)

                    let botText = Text(shortHz)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.secondary)
                    context.draw(botText, at: CGPoint(x: x, y: padTop + plotH + 5), anchor: .top)
                }

                // Plot frame border
                let frameRect = CGRect(x: padLeft, y: padTop, width: plotW, height: plotH)
                context.stroke(Path(frameRect), with: .color(Color(white: 0.45)), lineWidth: 1.2)

                // Top header labels
                context.draw(
                    Text("频率 (Hz) 低频→高频")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary),
                    at: CGPoint(x: padLeft, y: 4),
                    anchor: .topLeading
                )
                context.draw(
                    Text("右耳 O (红)   左耳 ✕ (蓝)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(white: 0.25)),
                    at: CGPoint(x: padLeft + plotW, y: 4),
                    anchor: .topTrailing
                )

                // 6. Interaural Asymmetry Polygon Shading
                if showAsymmetryShade {
                    let shared = results.left.keys.filter { results.right[$0] != nil }.sorted()
                    if shared.count >= 2 {
                        let maxGap = shared.map { abs(results.left[$0]!.db - results.right[$0]!.db) }.max() ?? 0
                        if maxGap >= 15.0 {
                            var shade = Path()
                            for (idx, f) in shared.enumerated() {
                                let p = CGPoint(
                                    x: freqToX(Double(f), left: padLeft, width: plotW),
                                    y: dbToY(results.left[f]!.db, top: padTop, height: plotH)
                                )
                                if idx == 0 { shade.move(to: p) } else { shade.addLine(to: p) }
                            }
                            for f in shared.reversed() {
                                let p = CGPoint(
                                    x: freqToX(Double(f), left: padLeft, width: plotW),
                                    y: dbToY(results.right[f]!.db, top: padTop, height: plotH)
                                )
                                shade.addLine(to: p)
                            }
                            shade.closeSubpath()
                            context.fill(shade, with: .color(Color.purple.opacity(0.10)))
                        }
                    }
                }

                // 7. Baseline Dashed Curves (if selected)
                if let base = baselineResults {
                    drawEarSeries(
                        context: &context,
                        pointsMap: base.right,
                        ear: .right,
                        color: rightColor.opacity(0.35),
                        isBaseline: true,
                        padLeft: padLeft, padTop: padTop, plotW: plotW, plotH: plotH
                    )
                    drawEarSeries(
                        context: &context,
                        pointsMap: base.left,
                        ear: .left,
                        color: leftColor.opacity(0.35),
                        isBaseline: true,
                        padLeft: padLeft, padTop: padTop, plotW: plotW, plotH: plotH
                    )
                }

                // 8. Primary Right & Left Ear Clinical Curves
                drawEarSeries(
                    context: &context,
                    pointsMap: results.right,
                    ear: .right,
                    color: rightColor,
                    isBaseline: false,
                    padLeft: padLeft, padTop: padTop, plotW: plotW, plotH: plotH
                )
                drawEarSeries(
                    context: &context,
                    pointsMap: results.left,
                    ear: .left,
                    color: leftColor,
                    isBaseline: false,
                    padLeft: padLeft, padTop: padTop, plotW: plotW, plotH: plotH
                )

                // Empty state prompt
                if results.isEmpty && baselineResults == nil {
                    let center = CGPoint(x: padLeft + plotW / 2, y: padTop + plotH / 2)
                    context.draw(
                        Text("佩戴耳机测听后在此绘制左右耳听力曲线 (125Hz→8000Hz)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.secondary),
                        at: center
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard let callback = onSelectFrequency else { return }
                        let tapX = value.location.x
                        let candidates = gridFrequencies
                        var bestF: Int? = nil
                        var bestDist: CGFloat = 28
                        for f in candidates {
                            let fx = freqToX(Double(f), left: padLeft, width: plotW)
                            let d = abs(fx - tapX)
                            if d < bestDist {
                                bestDist = d
                                bestF = f
                            }
                        }
                        if let hit = bestF {
                            callback(hit)
                        }
                    }
            )
        }
    }

    private func drawEarSeries(
        context: inout GraphicsContext,
        pointsMap: [Int: ThresholdPoint],
        ear: EarSide,
        color: Color,
        isBaseline: Bool,
        padLeft: CGFloat,
        padTop: CGFloat,
        plotW: CGFloat,
        plotH: CGFloat
    ) {
        let sorted = pointsMap.values.sorted { $0.freq < $1.freq }
        guard !sorted.isEmpty else { return }

        // Connecting line (skip NR gaps per ISO 8253-1)
        var linePath = Path()
        var penDown = false
        for pt in sorted {
            if pt.noResponse && !isBaseline {
                penDown = false
                continue
            }
            let p = CGPoint(
                x: freqToX(Double(pt.freq), left: padLeft, width: plotW),
                y: dbToY(pt.db, top: padTop, height: plotH)
            )
            if !penDown {
                linePath.move(to: p)
                penDown = true
            } else {
                linePath.addLine(to: p)
            }
        }
        if isBaseline {
            context.stroke(linePath, with: .color(color), style: StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
        } else {
            context.stroke(linePath, with: .color(color), lineWidth: 2.3)
        }

        // Clinical Symbols
        let r: CGFloat = isBaseline ? 4.8 : 6.6
        for pt in sorted {
            let cx = freqToX(Double(pt.freq), left: padLeft, width: plotW)
            let cy = dbToY(pt.db, top: padTop, height: plotH)

            if !isBaseline {
                let halo = Path(ellipseIn: CGRect(x: cx - r - 2, y: cy - r - 2, width: (r + 2) * 2, height: (r + 2) * 2))
                context.fill(halo, with: .color(.white.opacity(0.85)))
            }

            let lw: CGFloat = isBaseline ? 1.6 : 2.2
            if ear == .right {
                if pt.masked {
                    // Right Masked Air Conduction: Triangle '△'
                    var tri = Path()
                    tri.move(to: CGPoint(x: cx, y: cy - r - 1))
                    tri.addLine(to: CGPoint(x: cx - r - 0.5, y: cy + r * 0.85))
                    tri.addLine(to: CGPoint(x: cx + r + 0.5, y: cy + r * 0.85))
                    tri.closeSubpath()
                    context.stroke(tri, with: .color(color), lineWidth: lw)
                } else {
                    // Right Unmasked Air Conduction: Circle 'O'
                    let circle = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                    context.stroke(circle, with: .color(color), lineWidth: lw)
                }
            } else {
                if pt.masked {
                    // Left Masked Air Conduction: Square '□'
                    let sq = Path(CGRect(x: cx - r + 0.5, y: cy - r + 0.5, width: (r - 0.5) * 2, height: (r - 0.5) * 2))
                    context.stroke(sq, with: .color(color), lineWidth: lw)
                } else {
                    // Left Unmasked Air Conduction: Cross '✕'
                    let s = r * 0.88
                    var cross = Path()
                    cross.move(to: CGPoint(x: cx - s, y: cy - s))
                    cross.addLine(to: CGPoint(x: cx + s, y: cy + s))
                    cross.move(to: CGPoint(x: cx + s, y: cy - s))
                    cross.addLine(to: CGPoint(x: cx - s, y: cy + s))
                    context.stroke(cross, with: .color(color), lineWidth: lw)
                }
            }

            // No-Response Diagonal Arrow
            if pt.noResponse {
                let dir: CGFloat = (ear == .right) ? 1.0 : -1.0
                var arr = Path()
                let p1 = CGPoint(x: cx + dir * r * 0.7, y: cy + r * 0.7)
                let p2 = CGPoint(x: cx + dir * r * 1.85, y: cy + r * 1.85)
                arr.move(to: p1)
                arr.addLine(to: p2)
                arr.move(to: p2)
                arr.addLine(to: CGPoint(x: p2.x - dir * 4.0, y: p2.y - 1.0))
                arr.move(to: p2)
                arr.addLine(to: CGPoint(x: p2.x - dir * 1.0, y: p2.y - 4.0))
                context.stroke(arr, with: .color(color), lineWidth: lw)
            }
        }
    }
}

/// Longitudinal Recovery Trajectory Canvas (Inverted dB Y-axis: higher = better hearing)
public struct RecoveryTrendCanvasView: View {
    public let sessions: [AudiogramSession]
    public let focusEar: EarSide

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let ordered = sessions.sorted { $0.timestamp < $1.timestamp }

            if ordered.count < 2 {
                VStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("保存 ≥2 次测听档案后自动生成恢复趋势折线\n（曲线向上抬升 = 听阈分贝降低、听力恢复好转）")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { context, size in
                    let padL: CGFloat = 38
                    let padR: CGFloat = 18
                    let padT: CGFloat = 26
                    let padB: CGFloat = 26
                    let pw = max(100, w - padL - padR)
                    let ph = max(80, h - padT - padB)

                    func dbY(_ db: Double) -> CGFloat {
                        let c = max(-10.0, min(90.0, db))
                        return padT + CGFloat((c - -10.0) / 100.0) * ph
                    }

                    for gDb in [0, 20, 40, 60, 80] {
                        let y = dbY(Double(gDb))
                        var p = Path()
                        p.move(to: CGPoint(x: padL, y: y))
                        p.addLine(to: CGPoint(x: padL + pw, y: y))
                        context.stroke(
                            p,
                            with: .color(gDb == 20 ? Color.green.opacity(0.45) : Color(white: 0.88)),
                            lineWidth: 0.9
                        )
                        context.draw(
                            Text("\(gDb)").font(.system(size: 9.5)).foregroundColor(.secondary),
                            at: CGPoint(x: padL - 5, y: y),
                            anchor: .trailing
                        )
                    }

                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM/dd"

                    for (idx, s) in ordered.enumerated() {
                        let x = padL + CGFloat(idx) / CGFloat(ordered.count - 1) * pw
                        if ordered.count <= 6 || idx == 0 || idx == ordered.count - 1 || idx % 2 == 0 {
                            context.draw(
                                Text(formatter.string(from: s.timestamp))
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary),
                                at: CGPoint(x: x, y: padT + ph + 5),
                                anchor: .top
                            )
                        }
                    }

                    let seriesList: [(String, Color, (SingleEarAnalysis) -> Double?)] = [
                        ("低频(125-500)", .cyan, { $0.lowAvg }),
                        ("四频PTA", focusEar == .right ? .red : .blue, { $0.pta4 }),
                        ("高频(2k-8k)", .orange, { $0.highAvg })
                    ]

                    for (_, col, getter) in seriesList {
                        var path = Path()
                        var started = false
                        for (idx, sess) in ordered.enumerated() {
                            let analysis = ClinicalAnalyzer.analyzeEar(earData: sess.results[focusEar])
                            if let val = getter(analysis) {
                                let pt = CGPoint(
                                    x: padL + CGFloat(idx) / CGFloat(ordered.count - 1) * pw,
                                    y: dbY(val)
                                )
                                if !started {
                                    path.move(to: pt)
                                    started = true
                                } else {
                                    path.addLine(to: pt)
                                }
                                let dot = Path(ellipseIn: CGRect(x: pt.x - 3.2, y: pt.y - 3.2, width: 6.4, height: 6.4))
                                context.fill(dot, with: .color(col))
                            }
                        }
                        context.stroke(path, with: .color(col), lineWidth: 2.0)
                    }
                }
            }
        }
    }
}

/// High-Resolution Exportable Medical Audiogram Report Card for Photos / Share Sheet
public struct PrintableAudiogramReportCard: View {
    public let results: BilateralResults
    public let baselineResults: BilateralResults?
    public let profile: HeadphoneProfile
    public let note: String

    public var body: some View {
        let bi = ClinicalAnalyzer.analyzeBilateral(results: results, profile: profile)
        let freqs = FrequencySetMode.standardFrequencies

        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HearGuard 纯音气导听力图与突发性耳聋随访报告")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    Text("测绘序列：125Hz → 8000Hz  |  耳机配置：\(profile.name)  |  时间：\(Date().formatted(date: .numeric, time: .shortened))")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(white: 0.82))
                }
                Spacer()
            }
            .padding(16)
            .background(Color(red: 0.06, green: 0.09, blue: 0.16))
            .cornerRadius(12)

            // Main Bilateral Audiogram
            AudiogramCanvasView(
                results: results,
                baselineResults: baselineResults,
                showSeverityBands: true,
                showSpeechBanana: false,
                showAsymmetryShade: true
            )
            .frame(height: 390)
            .padding(8)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.25), lineWidth: 1))

            // Threshold Table 125 -> 8000 Hz
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("频率 (Hz)").frame(width: 96, alignment: .leading).font(.system(size: 11, weight: .bold))
                    ForEach(freqs, id: \.self) { f in
                        Text("\(f)").frame(maxWidth: .infinity).font(.system(size: 11, weight: .bold))
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color(white: 0.95))

                HStack(spacing: 0) {
                    Text("右耳 O (dB)").frame(width: 96, alignment: .leading).foregroundColor(.red).font(.system(size: 11, weight: .bold))
                    ForEach(freqs, id: \.self) { f in
                        Text(results.right[f]?.formattedShort ?? "--")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.red)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                HStack(spacing: 0) {
                    Text("左耳 ✕ (dB)").frame(width: 96, alignment: .leading).foregroundColor(.blue).font(.system(size: 11, weight: .bold))
                    ForEach(freqs, id: \.self) { f in
                        Text(results.left[f]?.formattedShort ?? "--")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color(white: 0.97))
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25), lineWidth: 1))

            // Ear Summaries
            HStack(alignment: .top, spacing: 12) {
                reportEarBox(title: "右耳评估 (Right · O)", color: .red, sum: bi.right)
                reportEarBox(title: "左耳评估 (Left · ✕)", color: .blue, sum: bi.left)
            }

            if !note.isEmpty {
                Text("病程与治疗备注：\(note)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.primary)
            }

            Text("医学声明：本报告由 iPhone 居家校准测听系统生成，仅供突发性耳聋恢复趋势自测与复诊沟通参考，不可替代医院标准隔声室诊断。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 720)
        .background(Color(white: 0.98))
    }

    private func reportEarBox(title: String, color: Color, sum: SingleEarAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(color)
            Text("四频 PTA: \(sum.pta4.map { "\($0) dB" } ?? "--") (\(sum.grade.shortName))")
                .font(.system(size: 11.5, weight: .semibold))
            Text("低频均值: \(sum.lowAvg.map { "\($0) dB" } ?? "--")  |  高频均值: \(sum.highAvg.map { "\($0) dB" } ?? "--")")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("曲线分型: \(sum.curveType)")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.35), lineWidth: 1))
    }
}
