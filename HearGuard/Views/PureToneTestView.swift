import SwiftUI

@MainActor
public struct PureToneTestView: View {
    @ObservedObject var audio: iOSAudioEngine
    @ObservedObject var store: SessionStore

    @State private var isPressingPad: Bool = false

    public init(audio: iOSAudioEngine, store: SessionStore) {
        self.audio = audio
        self.store = store
    }

    private var activeFrequencies: [Int] {
        store.settings.frequencySetMode.frequencies
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Headphone Guard Warning if disconnected
                if !audio.isHeadphonesConnected {
                    HStack(spacing: 10) {
                        Image(systemName: "headphones.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前未检测到耳机（输出：\(audio.connectedPortName)）")
                                .font(.footnote.bold())
                                .foregroundColor(.red)
                            Text("纯音测听必须佩戴耳机以隔离左右耳声道，请连接 AirPods 或有线耳机。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.10))
                    .cornerRadius(12)
                }

                // Mode Switcher & Configuration (disabled while actively auto-testing)
                if !store.isAutoTesting {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("测听模式", selection: $store.useManualMode) {
                            Text("临床自动升降法 (推荐)").tag(false)
                            Text("手动 5dB 精细定阈").tag(true)
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("频点序列 (低→高)").font(.caption2.bold()).foregroundColor(.secondary)
                                Picker("频点序列", selection: $store.settings.frequencySetMode) {
                                    ForEach(FrequencySetMode.allCases) { m in
                                        Text(m.label).tag(m)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            Spacer()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("耳别顺序").font(.caption2.bold()).foregroundColor(.secondary)
                                Picker("耳别顺序", selection: $store.settings.earTestOrder) {
                                    ForEach(EarTestOrder.allCases) { ord in
                                        Text(ord.label).tag(ord)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("测试信号音（突聋伴耳鸣推荐脉冲音或啭音）").font(.caption2.bold()).foregroundColor(.secondary)
                            Picker("测试信号音", selection: $store.settings.toneWaveform) {
                                ForEach(ToneWaveform.allCases) { w in
                                    Text(w.label).tag(w)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        Toggle(isOn: $store.settings.enableAutoMasking) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("智能对侧窄带噪声掩蔽")
                                    .font(.caption.bold())
                                Text("双耳差 ≥45dB 时向好耳播轻柔沙沙声，防止颅骨交叉“偷听”")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tint(.blue)
                    }
                    .padding(14)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(14)
                }

                // Low -> High Frequency Progress Strip (125 Hz -> 8000 Hz)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("低频 → 高频测绘轨迹")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Spacer()
                        if store.isAutoTesting {
                            Text("进度 \(min(store.activeStepIndex + 1, store.activeQueue.count)) / \(store.activeQueue.count)")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundColor(.blue)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            let highlightFreq = store.isAutoTesting
                                ? store.activeStateMachine?.freq
                                : (store.useManualMode ? store.manualFreq : nil)

                            ForEach(activeFrequencies, id: \.self) { f in
                                let isCurr = (highlightFreq == f)
                                let lPt = store.currentResults.left[f]
                                let rPt = store.currentResults.right[f]

                                Button {
                                    guard !store.isAutoTesting else { return }
                                    store.useManualMode = true
                                    store.manualFreq = f
                                    store.manualDb = store.currentResults[store.manualEar][f]?.db
                                        ?? min(30.0, audio.maxSafeDbHL(for: f))
                                } label: {
                                    VStack(spacing: 3) {
                                        Text("\(FrequencyMetadata.info(for: f).shortLabel)Hz")
                                            .font(.system(size: 11.5, weight: .bold))
                                            .foregroundColor(.primary)
                                        HStack(spacing: 4) {
                                            Text("✕\(lPt?.formattedShort ?? "-")")
                                                .foregroundColor(lPt != nil ? .blue : .secondary.opacity(0.5))
                                            Text("O\(rPt?.formattedShort ?? "-")")
                                                .foregroundColor(rPt != nil ? .red : .secondary.opacity(0.5))
                                        }
                                        .font(.system(size: 9.5, weight: .semibold))
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(isCurr ? Color.blue.opacity(0.14) : Color(UIColor.secondarySystemBackground))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(isCurr ? Color.blue : Color.clear, lineWidth: 1.5)
                                    )
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)

                // Active Testing Arena (Automated vs Manual)
                if !store.useManualMode {
                    automatedArenaCard
                } else {
                    manualFineTuneCard
                }

                // Live Real-Time Bilateral Audiogram Preview
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("实时左右耳听力曲线预览")
                            .font(.subheadline.bold())
                        Spacer()
                        Button("查看完整报告 →") {
                            store.selectedTab = 2
                        }
                        .font(.caption.bold())
                    }

                    AudiogramCanvasView(
                        results: store.currentResults,
                        showSeverityBands: true,
                        showAsymmetryShade: true,
                        showExtendedGrid: store.settings.frequencySetMode == .extended11,
                        activeHighlightFreq: store.isAutoTesting
                            ? store.activeStateMachine?.freq
                            : (store.useManualMode ? store.manualFreq : nil)
                    )
                    .frame(height: 290)
                }
                .padding(14)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    // MARK: - Automated Modified Hughson-Westlake Card

    private var automatedArenaCard: some View {
        VStack(spacing: 14) {
            if !store.isAutoTesting {
                VStack(spacing: 12) {
                    Image(systemName: "ear.and.waveform")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    Text("从 125 Hz 低频往 8000 Hz 高频自动寻阈")
                        .font(.headline)
                    Text("采用临床金标准改良 Hughson-Westlake（听见降 10 dB，未听见升 5 dB）。测试中可闭上眼睛放松专注听音，每次触碰圆盘均有轻柔触感反馈。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        store.startAutomatedAudiometry(audio: audio)
                    } label: {
                        HStack {
                            Image(systemName: "play.circle.fill")
                            Text("开始 125Hz → 8000Hz 自动测听")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 14)
            } else {
                let currentEar = store.activeStateMachine?.ear ?? .right
                let currentFreq = store.activeStateMachine?.freq ?? 125
                let meta = FrequencyMetadata.info(for: currentFreq)

                HStack {
                    Text(currentEar.fullLabel)
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(currentEar == .right ? Color.red.opacity(0.14) : Color.blue.opacity(0.14))
                        .foregroundColor(currentEar == .right ? .red : .blue)
                        .cornerRadius(99)

                    Spacer()

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(currentFreq) Hz")
                            .font(.title2.weight(.heavy))
                        Text(meta.bandName)
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                    }
                }

                Text(meta.clinicalNote)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Giant Tactile Response Circle (Immediate Touch-Down Registration + Haptics)
                ZStack {
                    Circle()
                        .stroke(Color.cyan.opacity(0.32), lineWidth: 5)
                        .frame(width: 224, height: 224)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isPressingPad
                                    ? [Color.green, Color(red: 0.02, green: 0.52, blue: 0.35)]
                                    : [Color(red: 0.05, green: 0.60, blue: 0.92), Color(red: 0.02, green: 0.38, blue: 0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 206, height: 206)
                        .shadow(color: Color.blue.opacity(0.28), radius: 14, x: 0, y: 8)
                        .scaleEffect(isPressingPad ? 0.95 : 1.0)

                    VStack(spacing: 6) {
                        Image(systemName: "hand.tap.fill")
                            .font(.title)
                            .foregroundColor(.white.opacity(0.92))
                        Text("我听到了")
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundColor(.white)
                        Text("听到微弱嘀-嘀-嘀即轻触\n(可闭眼盲按)")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.88))
                    }
                }
                .padding(.vertical, 6)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPressingPad {
                                isPressingPad = true
                                store.registerHeardButtonTap(audio: audio)
                            }
                        }
                        .onEnded { _ in
                            isPressingPad = false
                        }
                )

                Text(store.liveStatusMessage)
                    .font(.footnote.bold())
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    Text("第 \((store.activeStateMachine?.trialCount ?? 0) + 1) 次寻阈给声")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if store.activeMaskingIndicator {
                        Text("好耳窄带掩蔽中")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.14))
                            .foregroundColor(.purple)
                            .cornerRadius(6)
                    }
                }

                // Secondary Controls
                HStack(spacing: 8) {
                    Button(store.isAutoPaused ? "继续" : "暂停") {
                        store.togglePauseAutomated(audio: audio)
                    }
                    .buttonStyle(.bordered)

                    Button("重测此频点") {
                        store.restartCurrentFrequency(audio: audio)
                    }
                    .buttonStyle(.bordered)

                    Button("听不见·下一频") {
                        store.skipCurrentFrequencyAsNoResponse(audio: audio)
                    }
                    .buttonStyle(.bordered)

                    Button("结束") {
                        store.stopAutomatedAudiometry(audio: audio)
                        store.selectedTab = 2
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .font(.caption.bold())
            }
        }
        .padding(16)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(14)
    }

    // MARK: - Interactive Manual 5 dB Fine-Tune Card

    private var manualFineTuneCard: some View {
        let maxDb = audio.maxSafeDbHL(for: store.manualFreq)
        let meta = FrequencyMetadata.info(for: store.manualFreq)

        return VStack(spacing: 14) {
            // Ear Switch
            HStack(spacing: 10) {
                Button {
                    store.manualEar = .left
                    if let exist = store.currentResults.left[store.manualFreq]?.db {
                        store.manualDb = exist
                    }
                } label: {
                    Text("左耳 (✕)")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(store.manualEar == .left ? Color.blue : Color.blue.opacity(0.12))
                        .foregroundColor(store.manualEar == .left ? .white : .blue)
                        .cornerRadius(10)
                }

                Button {
                    store.manualEar = .right
                    if let exist = store.currentResults.right[store.manualFreq]?.db {
                        store.manualDb = exist
                    }
                } label: {
                    Text("右耳 (O)")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(store.manualEar == .right ? Color.red : Color.red.opacity(0.12))
                        .foregroundColor(store.manualEar == .right ? .white : .red)
                        .cornerRadius(10)
                }
            }

            // Frequency Stepper Low -> High
            HStack {
                Button("← 低频") {
                    stepManualFreq(by: -1)
                }
                .buttonStyle(.bordered)
                .font(.caption.bold())

                Spacer()
                VStack(spacing: 2) {
                    Text("\(store.manualFreq) Hz")
                        .font(.title2.weight(.heavy))
                    Text(meta.bandName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()

                Button("高频 →") {
                    stepManualFreq(by: 1)
                }
                .buttonStyle(.bordered)
                .font(.caption.bold())
            }

            // Attenuator Display
            VStack(spacing: 4) {
                Text("当前输出听力级")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(Int(store.manualDb)) dB HL")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("当前频点无失真上限：\(Int(maxDb)) dB HL")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)

            // Step & Play Controls
            HStack(spacing: 8) {
                Button("-10") { nudgeManualDb(-10, maxDb: maxDb) }
                    .buttonStyle(.bordered)
                Button("-5") { nudgeManualDb(-5, maxDb: maxDb) }
                    .buttonStyle(.bordered)

                Button {
                    playManualCurrent(ear: store.manualEar)
                } label: {
                    Label("播放测试音", systemImage: "play.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Button("+5") { nudgeManualDb(5, maxDb: maxDb) }
                    .buttonStyle(.bordered)
                Button("+10") { nudgeManualDb(10, maxDb: maxDb) }
                    .buttonStyle(.bordered)
            }
            .font(.caption.bold())

            HStack {
                Button("在对侧耳播放同音量对比") {
                    playManualCurrent(ear: store.manualEar.opposite, allowMask: false)
                    store.showToast("正在【\(store.manualEar.opposite.title)】播放 \(Int(store.manualDb)) dB 对比")
                }
                .font(.caption.bold())
                .buttonStyle(.bordered)

                Spacer()

                Toggle("对侧掩蔽", isOn: $store.manualUseMasking)
                    .font(.caption.bold())
                    .fixedSize()
            }

            HStack(spacing: 10) {
                Button("上限仍无声 (NR)") {
                    store.manualDb = maxDb
                    commitManualThreshold(noResponse: true)
                }
                .font(.caption.bold())
                .buttonStyle(.bordered)
                .tint(.red)

                Button {
                    commitManualThreshold(noResponse: false)
                } label: {
                    Text("确认为听阈，升至下一高频 →")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(16)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(14)
    }

    private func stepManualFreq(by delta: Int) {
        let freqs = activeFrequencies
        let idx = freqs.firstIndex(of: store.manualFreq) ?? 0
        let nextIdx = max(0, min(freqs.count - 1, idx + delta))
        store.manualFreq = freqs[nextIdx]
        let maxDb = audio.maxSafeDbHL(for: store.manualFreq)
        store.manualDb = min(maxDb, store.currentResults[store.manualEar][store.manualFreq]?.db ?? 30.0)
    }

    private func nudgeManualDb(_ delta: Double, maxDb: Double) {
        store.manualDb = max(AcousticMath.minTestDbHL, min(maxDb, store.manualDb + delta))
        playManualCurrent(ear: store.manualEar)
    }

    private func playManualCurrent(ear: EarSide, allowMask: Bool = true) {
        var maskDb: Double? = nil
        if allowMask && store.manualUseMasking {
            let oppBase = store.currentResults[ear.opposite][store.manualFreq]?.db ?? 15.0
            maskDb = min(65.0, max(25.0, oppBase + 20.0))
        }
        audio.playStimulus(
            freq: store.manualFreq,
            dbHL: store.manualDb,
            ear: ear,
            waveform: store.settings.toneWaveform,
            maskingDbHL: maskDb
        )
    }

    private func commitManualThreshold(noResponse: Bool) {
        if store.isDemoPreview {
            store.currentResults = BilateralResults()
            store.isDemoPreview = false
        }
        let pt = ThresholdPoint(
            freq: store.manualFreq,
            db: store.manualDb,
            noResponse: noResponse,
            masked: store.manualUseMasking,
            lowConfidence: false
        )
        var map = store.currentResults[store.manualEar]
        map[store.manualFreq] = pt
        store.currentResults[store.manualEar] = map

        let freqs = activeFrequencies
        if let idx = freqs.firstIndex(of: store.manualFreq), idx < freqs.count - 1 {
            store.manualFreq = freqs[idx + 1]
            let nextMax = audio.maxSafeDbHL(for: store.manualFreq)
            store.manualDb = min(nextMax, store.currentResults[store.manualEar][store.manualFreq]?.db ?? max(20.0, min(35.0, pt.db)))
        } else {
            let other = store.manualEar.opposite
            if store.currentResults[other].isEmpty {
                store.manualEar = other
                store.manualFreq = freqs.first ?? 125
                store.manualDb = 30.0
                store.showToast("\(pt.freq)Hz 已保存！自动切换至\(other.title) 125Hz 起点")
            } else {
                store.showToast("双耳全频段记录完成！")
                store.selectedTab = 2
            }
        }
    }
}
