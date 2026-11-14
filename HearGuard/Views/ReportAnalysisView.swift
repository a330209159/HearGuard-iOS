import SwiftUI
import UIKit

@MainActor
public struct ReportAnalysisView: View {
    @ObservedObject var audio: iOSAudioEngine
    @ObservedObject var store: SessionStore

    @State private var showSeverityBands: Bool = true
    @State private var showSpeechBanana: Bool = false
    @State private var showAsymmetryShade: Bool = true
    @State private var inspectedFreq: Int? = nil

    @State private var sessionNote: String = ""
    @State private var showingHospitalSheet: Bool = false
    @State private var exportedShareImage: Image? = nil
    @State private var exportedUIImage: UIImage? = nil

    private let quickTags = ["耳闷存在", "耳闷减轻", "低调嗡鸣", "高调蝉鸣", "激素治疗中", "鼓室注射后", "高压氧后"]

    public init(audio: iOSAudioEngine, store: SessionStore) {
        self.audio = audio
        self.store = store
    }

    private var activeBaselineSession: AudiogramSession? {
        guard let id = store.selectedBaselineSessionId else { return nil }
        return store.sessions.first { $0.id == id }
    }

    public var body: some View {
        let biReport = ClinicalAnalyzer.analyzeBilateral(results: store.currentResults, profile: audio.headphoneProfile)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Demo Preview Bar if user hasn't tested yet
                if store.currentResults.isEmpty || store.isDemoPreview {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.isDemoPreview ? "当前展示临床典型突聋示例曲线（非个人档案）：" : "尚无测听曲线，可前往「测听」开始，或先预览典型曲线样式：")
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                        HStack(spacing: 8) {
                            Button("预览低频突聋") { store.loadDemoLowFrequencySSNHL() }
                                .buttonStyle(.bordered)
                            Button("预览高频突聋") { store.loadDemoHighFrequencySSNHL() }
                                .buttonStyle(.bordered)
                            if !store.currentResults.isEmpty {
                                Button("清空") {
                                    store.currentResults = BilateralResults()
                                    store.isDemoPreview = false
                                }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                            }
                        }
                        .font(.caption.bold())
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(12)
                }

                // Main Bilateral Clinical Audiogram Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("左右耳标准纯音听力曲线图")
                                .font(.headline)
                            Text("125Hz → 8000Hz · 点击图上任意频点可试听或微调")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("+ 医院测听单") {
                            showingHospitalSheet = true
                        }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                    }

                    // Layer Checkboxes
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            layerChip("分级色带", isOn: $showSeverityBands)
                            layerChip("言语香蕉图", isOn: $showSpeechBanana)
                            layerChip("双耳差阴影", isOn: $showAsymmetryShade)
                        }
                    }

                    // Baseline Overlay Picker
                    if !store.sessions.isEmpty {
                        HStack {
                            Text("叠加基线对比：")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Picker("基线对比", selection: $store.selectedBaselineSessionId) {
                                Text("不叠加").tag(UUID?.none)
                                ForEach(store.sessions) { sess in
                                    let dStr = sess.timestamp.formatted(date: .numeric, time: .shortened)
                                    let prefix = sess.source == .hospitalImport ? "[医院]" : "[自测]"
                                    Text("\(prefix) \(dStr)").tag(UUID?.some(sess.id))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    AudiogramCanvasView(
                        results: store.currentResults,
                        baselineResults: activeBaselineSession?.results,
                        showSeverityBands: showSeverityBands,
                        showSpeechBanana: showSpeechBanana,
                        showAsymmetryShade: showAsymmetryShade,
                        showExtendedGrid: store.settings.frequencySetMode == .extended11,
                        selectedFreq: inspectedFreq,
                        onSelectFrequency: { f in
                            inspectedFreq = f
                        }
                    )
                    .frame(height: 360)

                    // Tapped Frequency Inspector Bar
                    if let f = inspectedFreq {
                        let lPt = store.currentResults.left[f]
                        let rPt = store.currentResults.right[f]
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("已选频点：\(f) Hz (\(FrequencyMetadata.info(for: f).bandName))")
                                    .font(.caption.bold())
                                Spacer()
                                Text("左✕: \(lPt.map { "\($0.formattedShort)dB" } ?? "--")  |  右O: \(rPt.map { "\($0.formattedShort)dB" } ?? "--")")
                                    .font(.caption.bold())
                                Button {
                                    inspectedFreq = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                            HStack(spacing: 8) {
                                Button("试听左耳") {
                                    audio.playStimulus(freq: f, dbHL: lPt?.db ?? 25, ear: .left, waveform: .pulsed)
                                }
                                .buttonStyle(.bordered)
                                .tint(.blue)

                                Button("试听右耳") {
                                    audio.playStimulus(freq: f, dbHL: rPt?.db ?? 25, ear: .right, waveform: .pulsed)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)

                                Button("微调左耳") {
                                    store.jumpToManualRetest(ear: .left, freq: f, audio: audio)
                                }
                                .buttonStyle(.bordered)

                                Button("微调右耳") {
                                    store.jumpToManualRetest(ear: .right, freq: f, audio: audio)
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.caption2.bold())
                        }
                        .padding(10)
                        .background(Color.cyan.opacity(0.10))
                        .cornerRadius(10)
                    }

                    // Threshold Comparison Table (125 Hz -> 8000 Hz)
                    thresholdTableSection

                    // Export & Save Image Row
                    HStack(spacing: 10) {
                        Button {
                            saveReportImageToPhotos()
                        } label: {
                            Label("保存高清报告到相册", systemImage: "photo.badge.arrow.down")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)

                        if let shareImg = exportedShareImage {
                            ShareLink(item: shareImg, preview: SharePreview("左右耳纯音听力曲线报告", image: shareImg)) {
                                Label("发送/分享图片", systemImage: "square.and.arrow.up")
                                    .font(.caption.bold())
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                prepareShareImage()
                            } label: {
                                Label("生成分享图", systemImage: "square.and.arrow.up")
                                    .font(.caption.bold())
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(14)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)

                // Baseline Efficacy Comparison Banner
                if let baseSess = activeBaselineSession {
                    let effItems = ClinicalAnalyzer.compareWithBaseline(
                        current: store.currentResults,
                        baseline: baseSess.results
                    )
                    ForEach(effItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("疗效对比（vs \(baseSess.timestamp.formatted(date: .abbreviated, time: .omitted)) \(baseSess.source.badgeText)）：\(item.efficacyGrade)")
                                .font(.footnote.bold())
                                .foregroundColor(.green)
                            Text(item.summary)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.35), lineWidth: 1))
                        .cornerRadius(12)
                    }
                }

                // Asymmetry & Cross-Hearing Alerts
                if !biReport.consecutive20dBPairs.isEmpty {
                    let first = biReport.consecutive20dBPairs[0]
                    VStack(alignment: .leading, spacing: 4) {
                        Text("⚠️ 检测到双耳相邻频率差值 ≥20 dB（\(first.ear.title) \(first.f1)–\(first.f2)Hz 等）")
                            .font(.footnote.bold())
                            .foregroundColor(.orange)
                        Text("符合《突发性聋诊断和治疗指南》相邻至少两频点下降 ≥20 dB 的听力图特征。若为新发或较前波动加重，请及时复诊耳鼻喉科。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.10))
                    .cornerRadius(12)
                }

                ForEach(biReport.shadowRisks) { risk in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("交叉听力复核提示：\(risk.ear.title) \(risk.freq)Hz")
                                .font(.caption.bold())
                                .foregroundColor(.purple)
                            Text("与对侧好耳差距达 \(Int(risk.diffDb)) dB（≥耳间衰减 \(Int(risk.iaDb)) dB），建议加窄带掩蔽复核以排除颅骨传声假阈值。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("掩蔽复核") {
                            store.jumpToManualRetest(ear: risk.ear, freq: risk.freq, forceMasking: true, audio: audio)
                        }
                        .font(.caption2.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }
                    .padding(12)
                    .background(Color.purple.opacity(0.09))
                    .cornerRadius(12)
                }

                // Clinical Summary Cards for Right Ear & Left Ear
                earAnalysisCard(ear: .right, summary: biReport.right, accent: .red)
                earAnalysisCard(ear: .left, summary: biReport.left, accent: .blue)

                // Save to Longitudinal Recovery Log
                VStack(alignment: .leading, spacing: 10) {
                    Text("保存本次双耳曲线至康复档案")
                        .font(.subheadline.bold())

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(quickTags, id: \.self) { tag in
                                Button(tag) {
                                    if !sessionNote.contains(tag) {
                                        sessionNote = sessionNote.isEmpty ? tag : "\(sessionNote) · \(tag)"
                                    }
                                }
                                .font(.caption2.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(99)
                            }
                        }
                    }

                    TextField("备注病程天数、耳鸣耳闷变化或用药（如：第4天 激素+高压氧）", text: $sessionNote)
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        store.saveCurrentSession(audio: audio, note: sessionNote, source: .homeTest)
                        sessionNote = ""
                    } label: {
                        Text("保存本次测听档案")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .padding(14)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .sheet(isPresented: $showingHospitalSheet) {
            HospitalImportSheet(audio: audio, store: store)
        }
        .onChange(of: store.currentResults) { _ in
            exportedShareImage = nil
            exportedUIImage = nil
        }
    }

    private func layerChip(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                Text(label)
            }
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn.wrappedValue ? Color.blue.opacity(0.14) : Color(UIColor.secondarySystemBackground))
            .foregroundColor(isOn.wrappedValue ? .blue : .secondary)
            .cornerRadius(99)
        }
    }

    private var thresholdTableSection: some View {
        let hasInter = [750, 1500, 3000, 6000].contains { f in
            store.currentResults.left[f] != nil || store.currentResults.right[f] != nil
        }
        let freqs = (store.settings.frequencySetMode == .extended11 || hasInter)
            ? FrequencySetMode.extendedFrequencies
            : FrequencySetMode.standardFrequencies

        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("频率Hz").frame(width: 64, alignment: .leading).font(.caption2.bold())
                    ForEach(freqs, id: \.self) { f in
                        Text(FrequencyMetadata.info(for: f).shortLabel)
                            .frame(width: 42)
                            .font(.caption2.bold())
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(Color(UIColor.secondarySystemBackground))

                HStack(spacing: 0) {
                    Text("右耳 O").frame(width: 64, alignment: .leading).font(.caption2.bold()).foregroundColor(.red)
                    ForEach(freqs, id: \.self) { f in
                        let pt = store.currentResults.right[f]
                        Text(pt != nil ? "\(pt!.formattedShort)\(pt!.masked ? "△" : "")" : "--")
                            .frame(width: 42)
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)

                HStack(spacing: 0) {
                    Text("左耳 ✕").frame(width: 64, alignment: .leading).font(.caption2.bold()).foregroundColor(.blue)
                    ForEach(freqs, id: \.self) { f in
                        let pt = store.currentResults.left[f]
                        Text(pt != nil ? "\(pt!.formattedShort)\(pt!.masked ? "□" : "")" : "--")
                            .frame(width: 42)
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundColor(.blue)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(Color(UIColor.secondarySystemBackground).opacity(0.45))
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25), lineWidth: 1))
            .cornerRadius(8)
        }
    }

    private func earAnalysisCard(ear: EarSide, summary: SingleEarAnalysis, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(ear.unmaskedSymbol) \(ear.title)临床评估")
                    .font(.subheadline.bold())
                    .foregroundColor(accent)
                Spacer()
                Text(summary.grade.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.12))
                    .foregroundColor(accent)
                    .cornerRadius(99)
            }

            HStack(spacing: 8) {
                metricBox(title: "四频 PTA", val: summary.pta4.map { "\($0)dB" } ?? "--", sub: "500–4kHz")
                metricBox(title: "低频均值", val: summary.lowAvg.map { "\($0)dB" } ?? "--", sub: "125–500Hz")
                metricBox(title: "高频均值", val: summary.highAvg.map { "\($0)dB" } ?? "--", sub: "2k–8kHz")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("曲线构型：\(summary.curveType)")
                    .font(.caption.bold())
                Text(summary.curveDetail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let warn = summary.focalWarning {
                    Text(warn)
                        .font(.caption2.bold())
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
        }
        .padding(14)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(14)
    }

    private func metricBox(title: String, val: String, sub: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
            Text(val).font(.system(size: 15, weight: .heavy, design: .rounded))
            Text(sub).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
    }

    // MARK: - High-DPI Report Image Rendering

    private func renderReportUIImage() -> UIImage? {
        let card = PrintableAudiogramReportCard(
            results: store.currentResults,
            baselineResults: activeBaselineSession?.results,
            profile: audio.headphoneProfile,
            note: sessionNote
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3.0
        return renderer.uiImage
    }

    private func prepareShareImage() {
        if let uiImg = renderReportUIImage() {
            exportedUIImage = uiImg
            exportedShareImage = Image(uiImage: uiImg)
            store.showToast("已生成高清报告图，可点击「发送/分享图片」")
        }
    }

    private func saveReportImageToPhotos() {
        guard !store.currentResults.isEmpty else {
            store.showToast("暂无测听曲线可导出")
            return
        }
        guard let uiImg = renderReportUIImage() else {
            store.showToast("渲染图片失败")
            return
        }
        exportedUIImage = uiImg
        exportedShareImage = Image(uiImage: uiImg)
        UIImageWriteToSavedPhotosAlbum(uiImg, nil, nil, nil)
        store.showToast("已将高清双耳听力图报告保存至 iPhone 相册！")
    }
}

/// Modal Sheet for entering paper Hospital Pure-Tone Audiogram numbers
@MainActor
struct HospitalImportSheet: View {
    @ObservedObject var audio: iOSAudioEngine
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var rightInputs: [Int: String] = [:]
    @State private var leftInputs: [Int: String] = [:]
    @State private var noteText: String = "医院隔声室纯音测听基线"

    private let freqs = FrequencySetMode.standardFrequencies

    var body: some View {
        NavigationStack {
            Form {
                Section("说明") {
                    Text("填入您在医院耳鼻喉科测得的纯音气导分贝值（dB HL，留空表示未测），保存后即可作为权威虚线基线与居家康复曲线叠加比对。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("右耳气导 O (dB HL)") {
                    ForEach(freqs, id: \.self) { f in
                        HStack {
                            Text("\(f) Hz")
                                .font(.subheadline.bold())
                                .foregroundColor(.red)
                            Spacer()
                            TextField("例如 15", text: Binding(
                                get: { rightInputs[f] ?? "" },
                                set: { rightInputs[f] = $0 }
                            ))
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        }
                    }
                }

                Section("左耳气导 ✕ (dB HL)") {
                    ForEach(freqs, id: \.self) { f in
                        HStack {
                            Text("\(f) Hz")
                                .font(.subheadline.bold())
                                .foregroundColor(.blue)
                            Spacer()
                            TextField("例如 50", text: Binding(
                                get: { leftInputs[f] ?? "" },
                                set: { leftInputs[f] = $0 }
                            ))
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        }
                    }
                }

                Section("检查备注") {
                    TextField("医院与检查日期备注", text: $noteText)
                }
            }
            .navigationTitle("录入医院测听报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存为基线") {
                        saveHospitalEntry()
                    }
                }
            }
        }
    }

    private func saveHospitalEntry() {
        var res = BilateralResults()
        var count = 0
        for f in freqs {
            if let str = rightInputs[f]?.trimmingCharacters(in: .whitespaces),
               let val = Double(str), val >= -10, val <= 120 {
                res.right[f] = ThresholdPoint(freq: f, db: val)
                count += 1
            }
            if let str = leftInputs[f]?.trimmingCharacters(in: .whitespaces),
               let val = Double(str), val >= -10, val <= 120 {
                res.left[f] = ThresholdPoint(freq: f, db: val)
                count += 1
            }
        }
        guard count > 0 else {
            store.showToast("请至少填写一个频点的分贝值")
            return
        }
        let prevCurrent = store.currentResults
        let wasEmptyOrDemo = prevCurrent.isEmpty || store.isDemoPreview
        store.currentResults = res
        store.isDemoPreview = false
        store.saveCurrentSession(audio: audio, note: noteText, source: .hospitalImport)
        if !wasEmptyOrDemo {
            store.currentResults = prevCurrent
        }
        dismiss()
    }
}
