import SwiftUI

@MainActor
public struct HistoryAndTinnitusView: View {
    @ObservedObject var audio: iOSAudioEngine
    @ObservedObject var store: SessionStore

    @State private var trendEar: EarSide = .left
    @State private var tinSliderPos: Double = 0.79 // 0..1 -> 125..10000 Hz (~4000 Hz default)
    @State private var tinDbHL: Double = 30.0
    @State private var tinIsNarrowBand: Bool = false
    @State private var tinEarChoice: String = "right"
    @State private var tinVasScore: Int = 4
    @State private var isPlayingTinnitus: Bool = false

    public init(audio: iOSAudioEngine, store: SessionStore) {
        self.audio = audio
        self.store = store
    }

    private var currentTinHz: Int {
        let hz = 125.0 * pow(10000.0 / 125.0, tinSliderPos)
        return Int(hz.rounded())
    }

    private func setTinHz(_ targetHz: Int) {
        let clamped = max(125.0, min(10000.0, Double(targetHz)))
        tinSliderPos = log(clamped / 125.0) / log(10000.0 / 125.0)
        syncTinnitusPlayback()
    }

    private func syncTinnitusPlayback() {
        guard isPlayingTinnitus else { return }
        audio.startOrUpdateTinnitusTone(
            freqHz: currentTinHz,
            dbHL: tinDbHL,
            earChoice: tinEarChoice,
            isNarrowBand: tinIsNarrowBand
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Longitudinal Recovery Trajectory Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("突聋纵向恢复趋势图")
                                .font(.headline)
                            Text("青线: 低频(125-500) · 主线: 四频PTA · 橙线: 高频(2k-8k)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("耳别", selection: $trendEar) {
                            Text("左耳 ✕").tag(EarSide.left)
                            Text("右耳 O").tag(EarSide.right)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 125)
                    }

                    RecoveryTrendCanvasView(sessions: store.sessions, focusEar: trendEar)
                        .frame(height: 195)
                }
                .padding(14)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)

                // 2. Tinnitus Pitch & Loudness Matcher
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("伴随耳鸣频率与响度匹配", systemImage: "waveform.circle")
                            .font(.headline)
                        Spacer()
                        Text("防八度混淆")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.14))
                            .foregroundColor(.purple)
                            .cornerRadius(8)
                    }

                    Text("约 80% 突聋患者合并耳鸣（主频常对应耳蜗受损频段）。在好耳播放对比音匹配您的耳鸣音高，有助于复诊汇报并在纯音测听时剥离耳鸣。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Picker("音色", selection: $tinIsNarrowBand) {
                            Text("纯音(蝉鸣/哨音)").tag(false)
                            Text("窄带(蒸汽/嗡声)").tag(true)
                        }
                        .pickerStyle(.segmented)

                        Picker("播放耳", selection: $tinEarChoice) {
                            Text("右耳").tag("right")
                            Text("左耳").tag("left")
                            Text("双耳").tag("both")
                        }
                        .pickerStyle(.menu)
                    }
                    .onChange(of: tinIsNarrowBand) { _ in syncTinnitusPlayback() }
                    .onChange(of: tinEarChoice) { _ in syncTinnitusPlayback() }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("匹配频率 (125 – 10000 Hz)：")
                                .font(.caption)
                            Spacer()
                            Text("\(currentTinHz) Hz")
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundColor(.blue)
                        }
                        Slider(value: $tinSliderPos, in: 0...1)
                            .onChange(of: tinSliderPos) { _ in syncTinnitusPlayback() }
                    }

                    HStack(spacing: 8) {
                        Button("÷2 低八度") {
                            setTinHz(max(125, currentTinHz / 2))
                        }
                        .buttonStyle(.bordered)

                        Button {
                            if isPlayingTinnitus {
                                audio.stopAllAudio()
                                isPlayingTinnitus = false
                            } else {
                                isPlayingTinnitus = true
                                syncTinnitusPlayback()
                            }
                        } label: {
                            Label(isPlayingTinnitus ? "停止播放" : "播放匹配音", systemImage: isPlayingTinnitus ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isPlayingTinnitus ? .red : .blue)

                        Button("×2 高八度") {
                            setTinHz(min(10000, currentTinHz * 2))
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.caption.bold())

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("匹配响度：")
                                .font(.caption)
                            Spacer()
                            Text("\(Int(tinDbHL)) dB HL")
                                .font(.caption.monospacedDigit().bold())
                        }
                        Slider(value: $tinDbHL, in: 0...75, step: 1)
                            .onChange(of: tinDbHL) { _ in syncTinnitusPlayback() }
                    }

                    HStack {
                        Picker("困扰度", selection: $tinVasScore) {
                            Text("轻度 (VAS 2/10)").tag(2)
                            Text("中轻 (VAS 4/10)").tag(4)
                            Text("中度 (VAS 6/10)").tag(6)
                            Text("显著 (VAS 8/10)").tag(8)
                        }
                        .pickerStyle(.menu)

                        Spacer()

                        Button("记录耳鸣") {
                            audio.stopAllAudio()
                            isPlayingTinnitus = false
                            store.addTinnitusRecord(
                                freqHz: currentTinHz,
                                dbHL: tinDbHL,
                                isNarrowBand: tinIsNarrowBand,
                                vas: tinVasScore
                            )
                        }
                        .font(.caption.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }

                    if !store.tinnitusLogs.isEmpty {
                        Divider()
                        ForEach(store.tinnitusLogs.prefix(4)) { log in
                            HStack {
                                Text(log.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(log.freqHz)Hz · \(log.isNarrowBandNoise ? "窄带" : "纯音") · \(Int(log.dbHL))dB (VAS \(log.vasScore))")
                                    .font(.caption2.bold())
                            }
                        }
                    }
                }
                .padding(14)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)

                // 3. Saved Audiogram Archive
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("历史测听与医院报告档案 (\(store.sessions.count))")
                            .font(.headline)
                        Spacer()
                        if !store.sessions.isEmpty {
                            ShareLink(
                                item: store.exportBackupJSONString(),
                                subject: Text("HearGuard 突发性耳聋随访数据备份"),
                                preview: SharePreview("HearGuard_Backup.json")
                            ) {
                                Label("备份JSON", systemImage: "square.and.arrow.up")
                                    .font(.caption.bold())
                            }
                        }
                    }

                    if store.sessions.isEmpty {
                        Text("尚无已保存档案。测听完成后在「听力图」页面底部点击保存即可。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.sessions) { sess in
                            let bi = ClinicalAnalyzer.analyzeBilateral(results: sess.results, profile: sess.headphoneProfile)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(sess.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(sess.source.badgeText)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(sess.source == .hospitalImport ? Color.purple.opacity(0.14) : Color.blue.opacity(0.12))
                                        .foregroundColor(sess.source == .hospitalImport ? .purple : .blue)
                                        .cornerRadius(8)
                                }

                                Text("右O PTA: \(bi.right.pta4.map { "\($0)dB" } ?? "--") (低频 \(bi.right.lowAvg.map { "\($0)" } ?? "--"))  |  左✕ PTA: \(bi.left.pta4.map { "\($0)dB" } ?? "--") (低频 \(bi.left.lowAvg.map { "\($0)" } ?? "--"))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if !sess.note.isEmpty {
                                    Text("备注：\(sess.note)")
                                        .font(.caption2)
                                        .foregroundColor(.primary)
                                }

                                HStack(spacing: 10) {
                                    Button("载入查看") {
                                        store.currentResults = sess.results
                                        store.isDemoPreview = false
                                        store.selectedTab = 2
                                    }
                                    .buttonStyle(.bordered)

                                    Button("设为对比基线") {
                                        store.selectedBaselineSessionId = sess.id
                                        store.selectedTab = 2
                                        store.showToast("已设为虚线对比基线")
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer()

                                    Button(role: .destructive) {
                                        store.deleteSession(sess.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .font(.caption2.bold())
                            }
                            .padding(12)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(10)
                        }
                    }
                }
                .padding(14)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .onAppear {
            if store.settings.affectedSide == .right {
                trendEar = .right
                tinEarChoice = "left"
            } else {
                trendEar = .left
                tinEarChoice = "right"
            }
        }
        .onDisappear {
            if isPlayingTinnitus {
                audio.stopAllAudio()
                isPlayingTinnitus = false
            }
        }
    }
}

/// Tab 5: Literature Survey & Safe iPhone Headphone Testing Guide
public struct ResearchGuideView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                guideCard(
                    icon: "1.circle.fill",
                    title: "为什么严格从 125 Hz 低频往 8000 Hz 高频测？",
                    bodyText: "普通听力筛查软件常跳过 125 Hz 甚至 250 Hz。然而中华医学会《突发性聋诊断和治疗指南 (2015)》明确指出：低频下降型突聋（膜迷路积水）核心受累区正是耳蜗顶回对应的 125–1000 Hz（常表现为耳闷塞感、轰鸣声、自声回音，而 2000 Hz 以上正常）。从 125 Hz 递进至 8000 Hz 可完整测绘耳蜗从顶回到底回的全频毛细胞恢复动态。"
                )

                guideCard(
                    icon: "2.circle.fill",
                    title: "ISO 389 RETSPL 补偿与防低频谐波失真",
                    bodyText: "人耳在 125 Hz 处的基准听阈声压级（RETSPL）比 1000 Hz 高出 21–38 dB。本应用内置入耳硅胶塞、包耳头戴、EarPods 半入耳及压耳式四套等响补偿模型，并设置 -1.0 dBFS 零削波上限保护——防止低频大振幅正弦波削波产生 375 Hz/625 Hz 奇次谐波，避免低频耳聋患者误听到中频谐波得出假正常结果。"
                )

                guideCard(
                    icon: "3.circle.fill",
                    title: "改良 Hughson-Westlake 升降法与抗耳鸣信号",
                    bodyText: "采用 ISO 8253-1 临床标准“听见降 10 dB、未听见升 5 dB”自动收敛协议，配合 35ms 升余弦（Raised-Cosine）平滑包络消除咔嗒瞬态声。针对 80% 突聋患者合并耳鸣的特点，提供三连脉冲纯音与 ±5% 调频啭音（Warble Tone），大幅降低将自身耳鸣误判为测试音的假阳性。"
                )

                guideCard(
                    icon: "4.circle.fill",
                    title: "交叉听力（影子曲线）与对侧窄带掩蔽",
                    bodyText: "单侧重度突聋测听时，若患耳测试声超过健耳听阈 40–55 dB（耳间衰减 IA），声音会经颅骨传到对侧好耳造成“偷听”。系统支持先测健耳建立个体基线，并在差距达标时自动向健耳投送 1/3 倍频程窄带掩蔽噪声（NBN），在听力图上规范绘制临床掩蔽符号（右耳 △、左耳 □）。"
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("iPhone 戴耳机居家复测 5 条金律")
                        .font(.headline)
                        .foregroundColor(.green)
                    Text("1. 固定使用同一副耳机（优先推荐 AirPods Pro 关闭降噪/通透设为“关闭”模式，或密封良好的有线入耳式耳机）。\n2. 每次测试保持 iPhone 音量固定在 50%，并利用「健侧耳 1kHz 生物校准」锚定基准。\n3. 关闭 iOS 控制中心音量长按菜单里的「空间音频」，并开启「专注/勿扰模式」。\n4. 测 125Hz/250Hz 时暂时关掉风扇与空调，减少低频掩蔽。\n5. 若发现相邻两频点较前恶化 ≥15 dB 或眩晕耳闷加重，请立即前往医院耳鼻喉科复诊。")
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineSpacing(3)
                }
                .padding(14)
                .background(Color.green.opacity(0.10))
                .cornerRadius(14)
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    private func guideCard(icon: String, title: String, bodyText: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                Text(title)
                    .font(.subheadline.bold())
            }
            Text(bodyText)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(2.5)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(14)
    }
}
