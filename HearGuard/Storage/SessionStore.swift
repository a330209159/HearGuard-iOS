import Foundation
import UIKit
import Combine

public struct PersistedAppSettings: Codable {
    public var headphoneProfile: HeadphoneProfile = .inEar
    public var calibrationMethod: CalibrationMethod = .preset
    public var fullScaleSPL1k: Double = HeadphoneProfile.inEar.defaultFullScaleSPL1k
    public var affectedSide: AffectedSidePreference = .left
    public var frequencySetMode: FrequencySetMode = .standard7
    public var earTestOrder: EarTestOrder = .healthyFirst
    public var toneWaveform: ToneWaveform = .pulsed
    public var enableAutoMasking: Bool = true
}

@MainActor
public final class SessionStore: ObservableObject {
    @Published public var settings = PersistedAppSettings()
    @Published public var sessions: [AudiogramSession] = []
    @Published public var tinnitusLogs: [TinnitusMatchRecord] = []

    // Current working audiogram on screen
    @Published public var currentResults = BilateralResults()
    @Published public var isDemoPreview: Bool = false
    @Published public var selectedBaselineSessionId: UUID? = nil

    // Automated Hughson-Westlake Test Runner State
    @Published public var isAutoTesting: Bool = false
    @Published public var isAutoPaused: Bool = false
    @Published public var activeQueue: [(ear: EarSide, freq: Int)] = []
    @Published public var activeStepIndex: Int = 0
    @Published public var activeStateMachine: HughsonWestlakeStateMachine? = nil
    @Published public var liveStatusMessage: String = "准备就绪"
    @Published public var activeMaskingIndicator: Bool = false
    @Published public var toastMessage: String? = nil

    // Navigation Tab Control (0=Prep, 1=Test, 2=Report, 3=History&Tinnitus, 4=ResearchGuide)
    @Published public var selectedTab: Int = 0

    // Jump-to-manual-point bridge
    @Published public var useManualMode: Bool = false
    @Published public var manualEar: EarSide = .left
    @Published public var manualFreq: Int = 125
    @Published public var manualDb: Double = 30.0
    @Published public var manualUseMasking: Bool = false

    private enum WindowPhase {
        case idle
        case silentPreDelay
        case listeningWindow
        case interTrial
    }

    private var windowPhase: WindowPhase = .idle
    private var stimulusStartUptime: TimeInterval = 0
    private var preDelayTask: Task<Void, Never>? = nil
    private var windowTimeoutTask: Task<Void, Never>? = nil
    private var toastTask: Task<Void, Never>? = nil

    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let successHaptic = UINotificationFeedbackGenerator()

    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private var settingsURL: URL { documentsDir.appendingPathComponent("hearguard_settings.json") }
    private var sessionsURL: URL { documentsDir.appendingPathComponent("hearguard_sessions.json") }
    private var tinnitusURL: URL { documentsDir.appendingPathComponent("hearguard_tinnitus.json") }

    public init() {
        loadFromDisk()
        if let latest = sessions.first {
            currentResults = latest.results
            if sessions.count >= 2 {
                let hosp = sessions.first(where: { $0.source == .hospitalImport })
                selectedBaselineSessionId = hosp?.id ?? sessions.last?.id
            }
        }
    }

    public func syncAudioEngineFromSettings(_ audio: iOSAudioEngine) {
        audio.headphoneProfile = settings.headphoneProfile
        audio.calibrationMethod = settings.calibrationMethod
        audio.fullScaleSPL1k = settings.fullScaleSPL1k
    }

    public func updateSettingsFromAudio(_ audio: iOSAudioEngine) {
        settings.headphoneProfile = audio.headphoneProfile
        settings.calibrationMethod = audio.calibrationMethod
        settings.fullScaleSPL1k = audio.fullScaleSPL1k
        saveSettingsToDisk()
    }

    public func showToast(_ text: String) {
        toastMessage = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                self.toastMessage = nil
            }
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? decoder.decode(PersistedAppSettings.self, from: data) {
            self.settings = decoded
        }
        if let data = try? Data(contentsOf: sessionsURL),
           let decoded = try? decoder.decode([AudiogramSession].self, from: data) {
            self.sessions = decoded.sorted { $0.timestamp > $1.timestamp }
        }
        if let data = try? Data(contentsOf: tinnitusURL),
           let decoded = try? decoder.decode([TinnitusMatchRecord].self, from: data) {
            self.tinnitusLogs = decoded.sorted { $0.timestamp > $1.timestamp }
        }
    }

    public func saveSettingsToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    private func saveSessionsToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(sessions) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }

    private func saveTinnitusToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(tinnitusLogs) {
            try? data.write(to: tinnitusURL, options: .atomic)
        }
    }

    public func saveCurrentSession(audio: iOSAudioEngine, note: String, source: SessionSource = .homeTest) {
        guard !currentResults.isEmpty else {
            showToast("当前尚无测听曲线数据，请先完成测听")
            return
        }
        if isDemoPreview && source == .homeTest {
            showToast("当前为演示曲线，请先完成您的真实耳机测听再保存")
            return
        }
        let volPct = Int((audio.systemVolume * 100.0).rounded())
        let session = AudiogramSession(
            source: source,
            headphoneProfile: audio.headphoneProfile,
            systemVolumePercent: volPct,
            note: note,
            results: currentResults
        )
        sessions.insert(session, at: 0)
        saveSessionsToDisk()

        if source == .hospitalImport {
            selectedBaselineSessionId = session.id
        } else if selectedBaselineSessionId == nil && sessions.count >= 2 {
            selectedBaselineSessionId = sessions.last?.id
        }
        successHaptic.notificationOccurred(.success)
        showToast("已保存至本地康复档案！")
    }

    public func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if selectedBaselineSessionId == id {
            selectedBaselineSessionId = nil
        }
        saveSessionsToDisk()
    }

    public func addTinnitusRecord(freqHz: Int, dbHL: Double, isNarrowBand: Bool, vas: Int) {
        let rec = TinnitusMatchRecord(freqHz: freqHz, dbHL: dbHL, isNarrowBandNoise: isNarrowBand, vasScore: vas)
        tinnitusLogs.insert(rec, at: 0)
        saveTinnitusToDisk()
        showToast("已记录耳鸣主频：\(freqHz) Hz")
    }

    public func exportBackupJSONString() -> String {
        struct BackupPayload: Codable {
            let exportedAt: Date
            let settings: PersistedAppSettings
            let sessions: [AudiogramSession]
            let tinnitusLogs: [TinnitusMatchRecord]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let payload = BackupPayload(
            exportedAt: Date(),
            settings: settings,
            sessions: sessions,
            tinnitusLogs: tinnitusLogs
        )
        guard let data = try? encoder.encode(payload),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: - Demo Sample Loaders

    public func loadDemoLowFrequencySSNHL() {
        currentResults = BilateralResults(
            left: [
                125: ThresholdPoint(freq: 125, db: 50),
                250: ThresholdPoint(freq: 250, db: 55),
                500: ThresholdPoint(freq: 500, db: 45),
                1000: ThresholdPoint(freq: 1000, db: 25),
                2000: ThresholdPoint(freq: 2000, db: 15),
                4000: ThresholdPoint(freq: 4000, db: 15),
                8000: ThresholdPoint(freq: 8000, db: 20)
            ],
            right: [
                125: ThresholdPoint(freq: 125, db: 15),
                250: ThresholdPoint(freq: 250, db: 15),
                500: ThresholdPoint(freq: 500, db: 10),
                1000: ThresholdPoint(freq: 1000, db: 10),
                2000: ThresholdPoint(freq: 2000, db: 15),
                4000: ThresholdPoint(freq: 4000, db: 15),
                8000: ThresholdPoint(freq: 8000, db: 20)
            ]
        )
        isDemoPreview = true
        showToast("预览：典型左耳低频下降型突聋 (125–500Hz 受损)")
    }

    public func loadDemoHighFrequencySSNHL() {
        currentResults = BilateralResults(
            left: [
                125: ThresholdPoint(freq: 125, db: 15),
                250: ThresholdPoint(freq: 250, db: 10),
                500: ThresholdPoint(freq: 500, db: 10),
                1000: ThresholdPoint(freq: 1000, db: 10),
                2000: ThresholdPoint(freq: 2000, db: 15),
                4000: ThresholdPoint(freq: 4000, db: 15),
                8000: ThresholdPoint(freq: 8000, db: 20)
            ],
            right: [
                125: ThresholdPoint(freq: 125, db: 15),
                250: ThresholdPoint(freq: 250, db: 15),
                500: ThresholdPoint(freq: 500, db: 15),
                1000: ThresholdPoint(freq: 1000, db: 20),
                2000: ThresholdPoint(freq: 2000, db: 45),
                4000: ThresholdPoint(freq: 4000, db: 65, masked: true),
                8000: ThresholdPoint(freq: 8000, db: 70, masked: true)
            ]
        )
        isDemoPreview = true
        showToast("预览：典型右耳高频下降型突聋 (2k–8kHz 受损)")
    }

    // MARK: - Automated Hughson-Westlake Low-to-High Runner (125Hz -> 8000Hz)

    public func startAutomatedAudiometry(audio: iOSAudioEngine) {
        stopAutomatedAudiometry(audio: audio)
        saveSettingsToDisk()

        if isDemoPreview {
            currentResults = BilateralResults()
            isDemoPreview = false
        }

        let ears = settings.earTestOrder.resolveEars(affected: settings.affectedSide)
        let freqs = settings.frequencySetMode.frequencies // Strictly 125 -> 250 -> 500 -> ... -> 8000 Hz!

        switch settings.earTestOrder {
        case .leftOnly:
            currentResults.left = [:]
        case .rightOnly:
            currentResults.right = [:]
        default:
            currentResults = BilateralResults()
        }

        var steps: [(ear: EarSide, freq: Int)] = []
        for e in ears {
            for f in freqs {
                steps.append((e, f))
            }
        }

        activeQueue = steps
        activeStepIndex = 0
        isAutoTesting = true
        isAutoPaused = false
        lightHaptic.prepare()

        beginCurrentQueueStep(audio: audio)
    }

    public func togglePauseAutomated(audio: iOSAudioEngine) {
        guard isAutoTesting else { return }
        if isAutoPaused {
            isAutoPaused = false
            liveStatusMessage = "继续测听，请闭目静心聆听..."
            scheduleNextTrial(audio: audio, customDelaySec: 0.75)
        } else {
            isAutoPaused = true
            cancelTimersAndAudio(audio: audio)
            windowPhase = .idle
            liveStatusMessage = "已暂停 — 随时点击继续"
        }
    }

    public func stopAutomatedAudiometry(audio: iOSAudioEngine) {
        isAutoTesting = false
        isAutoPaused = false
        windowPhase = .idle
        activeStateMachine = nil
        cancelTimersAndAudio(audio: audio)
    }

    public func restartCurrentFrequency(audio: iOSAudioEngine) {
        guard isAutoTesting else { return }
        cancelTimersAndAudio(audio: audio)
        beginCurrentQueueStep(audio: audio)
        showToast("已重新开始当前频率寻阈")
    }

    public func skipCurrentFrequencyAsNoResponse(audio: iOSAudioEngine) {
        guard isAutoTesting, let sm = activeStateMachine else { return }
        cancelTimersAndAudio(audio: audio)
        let nrPoint = ThresholdPoint(
            freq: sm.freq,
            db: sm.maxDb,
            noResponse: true,
            masked: sm.usedMasking,
            lowConfidence: false
        )
        commitAutomatedPoint(nrPoint, audio: audio)
    }

    /// Called when user taps the giant tactile response button
    public func registerHeardButtonTap(audio: iOSAudioEngine) {
        guard isAutoTesting, !isAutoPaused else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // Catch premature tap during silent pre-stimulus delay or <110ms human reaction limit
        if windowPhase == .silentPreDelay || (windowPhase == .listeningWindow && (now - stimulusStartUptime) < 0.11) {
            cancelTimersAndAudio(audio: audio)
            windowPhase = .interTrial
            liveStatusMessage = "刚才尚未发声，已重新排期给声..."
            showToast("提示：请确认听到微弱“嘀-嘀-嘀”脉冲音再点击")
            scheduleNextTrial(audio: audio, customDelaySec: Double.random(in: 1.1...1.9))
            return
        }

        if windowPhase == .listeningWindow {
            windowPhase = .interTrial
            windowTimeoutTask?.cancel()
            windowTimeoutTask = nil
            lightHaptic.impactOccurred()

            // Smoothly fade out remaining pulses after brief confirmation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                audio.stopAllAudio()
            }

            advanceStateMachine(heard: true, audio: audio)
        }
    }

    private func beginCurrentQueueStep(audio: iOSAudioEngine) {
        if activeStepIndex >= activeQueue.count {
            stopAutomatedAudiometry(audio: audio)
            successHaptic.notificationOccurred(.success)
            showToast("全频段测听完成！已生成左右耳听力曲线图")
            selectedTab = 2
            return
        }

        let item = activeQueue[activeStepIndex]
        let maxDb = audio.maxSafeDbHL(for: item.freq)

        // Check previous measured frequency on same ear for gentle starting level adaptation
        let prevFreqs = currentResults[item.ear].keys.sorted()
        let prevDb = prevFreqs.last.flatMap { currentResults[item.ear][$0]?.db }

        activeStateMachine = HughsonWestlakeStateMachine(
            ear: item.ear,
            freq: item.freq,
            maxDb: maxDb,
            previousAdjacentDb: prevDb
        )
        activeMaskingIndicator = false
        liveStatusMessage = "准备 \(item.ear.title) \(item.freq) Hz..."
        scheduleNextTrial(audio: audio, customDelaySec: 0.85)
    }

    private func scheduleNextTrial(audio: iOSAudioEngine, customDelaySec: Double? = nil) {
        guard isAutoTesting, !isAutoPaused, activeStateMachine != nil else { return }
        cancelTimersAndAudio(audio: audio)

        let delaySec = customDelaySec ?? Double.random(in: 0.95...2.10)
        windowPhase = .silentPreDelay
        liveStatusMessage = "请静心聆听，听到微弱脉冲音即轻触下方圆盘..."

        preDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            guard let self = self, !Task.isCancelled, self.isAutoTesting, !self.isAutoPaused else { return }
            guard var sm = self.activeStateMachine else { return }

            let oppPt = self.currentResults[sm.ear.opposite][sm.freq]
            let maskDb = sm.maskingLevelIfNeeded(
                enableMasking: self.settings.enableAutoMasking,
                oppositeEarThreshold: oppPt,
                interauralAttenuation: audio.headphoneProfile.interauralAttenuationDb
            )
            self.activeStateMachine = sm
            self.activeMaskingIndicator = (maskDb != nil)

            self.windowPhase = .listeningWindow
            self.stimulusStartUptime = ProcessInfo.processInfo.systemUptime

            let stimDur = audio.playStimulus(
                freq: sm.freq,
                dbHL: sm.currentDb,
                ear: sm.ear,
                waveform: self.settings.toneWaveform,
                maskingDbHL: maskDb
            )

            if maskDb != nil {
                self.liveStatusMessage = "正在给声（对侧好耳已加轻柔沙沙掩蔽，请只对嘀嘀声点击）"
            }

            let totalWindowSec = stimDur + 1.15
            self.windowTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(totalWindowSec * 1_000_000_000))
                guard let self = self, !Task.isCancelled,
                      self.isAutoTesting, !self.isAutoPaused,
                      self.windowPhase == .listeningWindow else { return }
                self.windowPhase = .interTrial
                self.advanceStateMachine(heard: false, audio: audio)
            }
        }
    }

    private func advanceStateMachine(heard: Bool, audio: iOSAudioEngine) {
        guard var sm = activeStateMachine else { return }
        if let finalized = sm.recordTrial(heard: heard) {
            activeStateMachine = sm
            commitAutomatedPoint(finalized, audio: audio)
        } else {
            activeStateMachine = sm
            scheduleNextTrial(audio: audio)
        }
    }

    private func commitAutomatedPoint(_ point: ThresholdPoint, audio: iOSAudioEngine) {
        guard activeStepIndex < activeQueue.count else { return }
        let ear = activeQueue[activeStepIndex].ear
        var earDict = currentResults[ear]
        earDict[point.freq] = point
        currentResults[ear] = earDict

        activeStepIndex += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self = self, self.isAutoTesting, !self.isAutoPaused else { return }
            self.beginCurrentQueueStep(audio: audio)
        }
    }

    private func cancelTimersAndAudio(audio: iOSAudioEngine) {
        preDelayTask?.cancel()
        preDelayTask = nil
        windowTimeoutTask?.cancel()
        windowTimeoutTask = nil
        audio.stopAllAudio()
    }

    // MARK: - Jump to Single-Point Manual Fine-Tuning

    public func jumpToManualRetest(ear: EarSide, freq: Int, forceMasking: Bool = false, audio: iOSAudioEngine) {
        stopAutomatedAudiometry(audio: audio)
        if [750, 1500, 3000, 6000].contains(freq) {
            settings.frequencySetMode = .extended11
        }
        useManualMode = true
        manualEar = ear
        manualFreq = freq
        manualDb = currentResults[ear][freq]?.db ?? min(30.0, audio.maxSafeDbHL(for: freq))
        if forceMasking {
            manualUseMasking = true
        }
        selectedTab = 1
        showToast("已定位至 \(ear.title) \(freq) Hz 手动微调")
    }
}
