import Foundation
import AVFoundation
import CoreAudioTypes
import Combine
import Darwin

/// Non-isolated real-time 48kHz stereo synthesizer running safely on CoreAudio IO thread
final class RealtimeAudiometrySynth {
    enum Mode {
        case silent
        case finiteStimulus
        case chime
        case sustainedTinnitus
    }

    private var lock = os_unfair_lock_s()

    private var sampleRate: Double = 48000.0
    private var mode: Mode = .silent

    // Finite stimulus state
    private var targetEarChannel: Int = 0 // 0 = Left, 1 = Right
    private var carrierFreq: Double = 1000.0
    private var waveform: ToneWaveform = .pulsed
    private var peakAmp: Float = 0.0
    private var sampleCursor: Int = 0
    private var totalStimSamples: Int = 0

    // Chime notes
    private var chimeFreq1: Double = 523.25
    private var chimeFreq2: Double = 659.25

    // Contralateral narrow-band masking state
    private var maskingEnabled: Bool = false
    private var maskingPeakAmp: Float = 0.0
    private var bp1 = BiquadBandpassFilter()
    private var bp2 = BiquadBandpassFilter()
    private var rng = RealtimeNoiseGenerator()

    // Phase accumulators
    private var carrierPhase: Double = 0.0
    private var lfoPhase: Double = 0.0

    // Smooth emergency / early-cancel fade-out multiplier
    private var fadeOutActive: Bool = false
    private var fadeOutGain: Float = 1.0

    // Sustained tinnitus matcher state
    private var sustTargetFreq: Double = 4000.0
    private var sustCurrentFreq: Double = 4000.0
    private var sustTargetAmpL: Float = 0.0
    private var sustTargetAmpR: Float = 0.0
    private var sustCurrentAmpL: Float = 0.0
    private var sustCurrentAmpR: Float = 0.0
    private var sustNarrowBand: Bool = false

    init(sampleRate: Double = 48000.0) {
        self.sampleRate = sampleRate
        bp1.configure(centerFreq: 1000.0, q: 3.2, sampleRate: sampleRate)
        bp2.configure(centerFreq: 1000.0, q: 3.2, sampleRate: sampleRate)
    }

    func setSampleRate(_ sr: Double) {
        os_unfair_lock_lock(&lock)
        sampleRate = max(8000.0, sr)
        os_unfair_lock_unlock(&lock)
    }

    /// Trigger a calibrated audiometric stimulus (returns total duration in seconds)
    func triggerStimulus(
        ear: EarSide,
        freq: Double,
        peakAmplitude: Float,
        waveform: ToneWaveform,
        maskingAmplitude: Float?
    ) -> Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        self.mode = .finiteStimulus
        self.targetEarChannel = (ear == .left) ? 0 : 1
        self.carrierFreq = freq
        self.waveform = waveform
        self.peakAmp = min(AcousticMath.maxLinearAmplitude, max(0, peakAmplitude))
        self.sampleCursor = 0
        self.carrierPhase = 0.0
        self.lfoPhase = 0.0
        self.fadeOutActive = false
        self.fadeOutGain = 1.0

        let durationSec: Double
        switch waveform {
        case .pulsed, .warble:
            // 3 pulses: 0.25s ON, 0.17s OFF -> 3 * 0.25 + 2 * 0.17 = 1.09s
            durationSec = 1.09
        case .continuous:
            durationSec = 1.15
        }
        self.totalStimSamples = Int(durationSec * sampleRate)

        if let mAmp = maskingAmplitude, mAmp > 0 {
            self.maskingEnabled = true
            self.maskingPeakAmp = min(AcousticMath.maxLinearAmplitude * 0.72, mAmp * 3.4)
            self.bp1.reset()
            self.bp2.reset()
            self.bp1.configure(centerFreq: freq, q: 3.2, sampleRate: sampleRate)
            self.bp2.configure(centerFreq: freq, q: 3.2, sampleRate: sampleRate)
        } else {
            self.maskingEnabled = false
            self.maskingPeakAmp = 0.0
        }

        return durationSec
    }

    func triggerChannelChime(ear: EarSide, amplitude: Float) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        self.mode = .chime
        self.targetEarChannel = (ear == .left) ? 0 : 1
        self.chimeFreq1 = (ear == .left) ? 523.25 : 659.25
        self.chimeFreq2 = (ear == .left) ? 659.25 : 783.99
        self.peakAmp = min(0.35, max(0.001, amplitude))
        self.sampleCursor = 0
        self.totalStimSamples = Int(0.52 * sampleRate)
        self.carrierPhase = 0.0
        self.fadeOutActive = false
        self.fadeOutGain = 1.0
        self.maskingEnabled = false
    }

    func updateSustained(
        freq: Double,
        ampLeft: Float,
        ampRight: Float,
        isNarrowBand: Bool
    ) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let clampedL = min(AcousticMath.maxLinearAmplitude * 0.65, max(0, ampLeft * (isNarrowBand ? 3.4 : 1.0)))
        let clampedR = min(AcousticMath.maxLinearAmplitude * 0.65, max(0, ampRight * (isNarrowBand ? 3.4 : 1.0)))

        if self.mode != .sustainedTinnitus || self.sustNarrowBand != isNarrowBand {
            self.sustCurrentFreq = freq
            self.bp1.reset()
            self.bp2.reset()
        }
        self.mode = .sustainedTinnitus
        self.sustTargetFreq = freq
        self.sustTargetAmpL = clampedL
        self.sustTargetAmpR = clampedR
        self.sustNarrowBand = isNarrowBand
        self.fadeOutActive = false
        self.fadeOutGain = 1.0
        if isNarrowBand {
            self.bp1.configure(centerFreq: freq, q: 4.0, sampleRate: sampleRate)
            self.bp2.configure(centerFreq: freq, q: 4.0, sampleRate: sampleRate)
        }
    }

    /// Smooth 25ms ramp-down to silence (prevents click artifacts on stop/cancel)
    func fadeOutToStop() {
        os_unfair_lock_lock(&lock)
        if mode != .silent {
            fadeOutActive = true
        }
        sustTargetAmpL = 0
        sustTargetAmpR = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Create AVAudioSourceNode render callback outside @MainActor
    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        return AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = Int(frameCount)

            guard ablPointer.count >= 2,
                  let leftPtr = ablPointer[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightPtr = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buf in ablPointer {
                    if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) }
                }
                return noErr
            }

            os_unfair_lock_lock(&self.lock)
            defer { os_unfair_lock_unlock(&self.lock) }

            if self.mode == .silent {
                memset(leftPtr, 0, count * MemoryLayout<Float>.size)
                memset(rightPtr, 0, count * MemoryLayout<Float>.size)
                return noErr
            }

            let sr = self.sampleRate
            let twoPi = 2.0 * Double.pi
            let rampSamples = Int(0.035 * sr) // 35ms raised-cosine per ISO 8253-1
            let pulseOnSamples = Int(0.25 * sr)
            let pulsePeriodSamples = Int(0.42 * sr) // 0.25s ON + 0.17s OFF
            let fadeStep = Float(1.0 / max(1.0, 0.025 * sr))

            for i in 0..<count {
                var outL: Float = 0.0
                var outR: Float = 0.0

                if self.fadeOutActive {
                    self.fadeOutGain -= fadeStep
                    if self.fadeOutGain <= 0.0 {
                        self.fadeOutGain = 0.0
                        self.fadeOutActive = false
                        self.mode = .silent
                        leftPtr[i] = 0.0
                        rightPtr[i] = 0.0
                        continue
                    }
                }

                switch self.mode {
                case .silent:
                    break

                case .finiteStimulus:
                    if self.sampleCursor >= self.totalStimSamples {
                        self.mode = .silent
                        break
                    }

                    // Envelope for tone
                    var env: Float = 0.0
                    switch self.waveform {
                    case .pulsed, .warble:
                        let pulseIdx = self.sampleCursor / pulsePeriodSamples
                        let posInPeriod = self.sampleCursor % pulsePeriodSamples
                        if pulseIdx < 3 && posInPeriod < pulseOnSamples {
                            env = AcousticMath.raisedCosineGain(
                                sampleIndex: posInPeriod,
                                totalSamples: pulseOnSamples,
                                rampSamples: rampSamples
                            )
                        }
                    case .continuous:
                        env = AcousticMath.raisedCosineGain(
                            sampleIndex: self.sampleCursor,
                            totalSamples: self.totalStimSamples,
                            rampSamples: rampSamples
                        )
                    }

                    // Instantaneous frequency (pure sine or ±5% @ 5Hz warble FM)
                    var instFreq = self.carrierFreq
                    if self.waveform == .warble {
                        let mod = sin(self.lfoPhase)
                        instFreq = self.carrierFreq * (1.0 + 0.05 * mod)
                        self.lfoPhase += twoPi * 5.0 / sr
                        if self.lfoPhase >= twoPi { self.lfoPhase -= twoPi }
                    }

                    let sampleVal = Float(sin(self.carrierPhase)) * self.peakAmp * env * self.fadeOutGain
                    self.carrierPhase += twoPi * instFreq / sr
                    if self.carrierPhase >= twoPi { self.carrierPhase -= twoPi }

                    if self.targetEarChannel == 0 {
                        outL = sampleVal
                    } else {
                        outR = sampleVal
                    }

                    // Contralateral narrow-band noise in opposite ear channel
                    if self.maskingEnabled {
                        let maskEnv = AcousticMath.raisedCosineGain(
                            sampleIndex: self.sampleCursor,
                            totalSamples: self.totalStimSamples,
                            rampSamples: Int(0.045 * sr)
                        )
                        let white = self.rng.nextUniformSym()
                        let nbn = self.bp2.process(self.bp1.process(white))
                        let maskSample = max(-0.85, min(0.85, nbn * self.maskingPeakAmp * maskEnv * self.fadeOutGain))
                        if self.targetEarChannel == 0 {
                            outR = maskSample
                        } else {
                            outL = maskSample
                        }
                    }

                    self.sampleCursor += 1

                case .chime:
                    if self.sampleCursor >= self.totalStimSamples {
                        self.mode = .silent
                        break
                    }
                    let half = self.totalStimSamples / 2
                    let noteFreq = self.sampleCursor < half ? self.chimeFreq1 : self.chimeFreq2
                    let posInNote = self.sampleCursor < half ? self.sampleCursor : (self.sampleCursor - half)
                    let noteLen = half
                    let env = AcousticMath.raisedCosineGain(
                        sampleIndex: posInNote,
                        totalSamples: noteLen,
                        rampSamples: Int(0.025 * sr)
                    )
                    let val = Float(sin(self.carrierPhase)) * self.peakAmp * env * self.fadeOutGain
                    self.carrierPhase += twoPi * noteFreq / sr
                    if self.carrierPhase >= twoPi { self.carrierPhase -= twoPi }

                    if self.targetEarChannel == 0 { outL = val } else { outR = val }
                    self.sampleCursor += 1

                case .sustainedTinnitus:
                    let smooth: Float = 0.0015
                    self.sustCurrentAmpL += (self.sustTargetAmpL - self.sustCurrentAmpL) * smooth
                    self.sustCurrentAmpR += (self.sustTargetAmpR - self.sustCurrentAmpR) * smooth
                    self.sustCurrentFreq += (self.sustTargetFreq - self.sustCurrentFreq) * 0.002

                    let genSample: Float
                    if self.sustNarrowBand {
                        let w = self.rng.nextUniformSym()
                        genSample = self.bp2.process(self.bp1.process(w))
                    } else {
                        genSample = Float(sin(self.carrierPhase))
                        self.carrierPhase += twoPi * self.sustCurrentFreq / sr
                        if self.carrierPhase >= twoPi { self.carrierPhase -= twoPi }
                    }

                    outL = max(-0.85, min(0.85, genSample * self.sustCurrentAmpL * self.fadeOutGain))
                    outR = max(-0.85, min(0.85, genSample * self.sustCurrentAmpR * self.fadeOutGain))
                }

                leftPtr[i] = outL
                rightPtr[i] = outR
            }

            return noErr
        }
    }
}

/// Main-Actor iOS Audio Session, Headphone Route & Volume Monitor, and Calibrated Synthesizer Controller
@MainActor
public final class iOSAudioEngine: ObservableObject {
    @Published public var headphoneProfile: HeadphoneProfile = .inEar
    @Published public var calibrationMethod: CalibrationMethod = .preset
    @Published public var fullScaleSPL1k: Double = HeadphoneProfile.inEar.defaultFullScaleSPL1k

    // Live Hardware Status on iPhone
    @Published public var isHeadphonesConnected: Bool = false
    @Published public var connectedPortName: String = "检测中..."
    @Published public var systemVolume: Float = 0.5
    @Published public var autoMatchedHeadphoneHint: String? = nil

    // Optional Ambient Room Noise Meter
    @Published public var isMonitoringAmbientNoise: Bool = false
    @Published public var estimatedAmbientDbA: Int = 30

    private let engine = AVAudioEngine()
    private let synth = RealtimeAudiometrySynth(sampleRate: 48000.0)
    private var sourceNode: AVAudioSourceNode?
    private var volumeObservation: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?

    private var ambientRecorder: AVAudioRecorder?
    private var ambientTimer: Timer?

    public init() {
        setupAudioSessionAndGraph()
        observeRouteAndVolume()
        refreshAudioRouteInfo()
    }

    private func setupAudioSessionAndGraph() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Pure .playback guarantees high-resolution 48kHz stereo A2DP on AirPods/Bluetooth headphones
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredSampleRate(48000.0)
            try session.setActive(true)
        } catch {
            print("AVAudioSession setup error: \(error)")
        }

        let hwRate = session.sampleRate > 0 ? session.sampleRate : 48000.0
        synth.setSampleRate(hwRate)

        guard let stereoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwRate,
            channels: 2,
            interleaved: false
        ) else { return }

        let node = synth.makeSourceNode(format: stereoFormat)
        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: stereoFormat)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
        } catch {
            print("AVAudioEngine start error: \(error)")
        }
    }

    private func ensureEngineRunning() {
        if isMonitoringAmbientNoise {
            stopAmbientNoiseCheck()
        }
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default, options: [])
        }
        try? session.setActive(true)
        if !engine.isRunning {
            try? engine.start()
        }
    }

    private func observeRouteAndVolume() {
        let session = AVAudioSession.sharedInstance()
        self.systemVolume = session.outputVolume

        volumeObservation = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] sess, _ in
            let vol = sess.outputVolume
            Task { @MainActor [weak self] in
                self?.systemVolume = vol
            }
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAudioRouteInfo()
            }
        }
    }

    public func refreshAudioRouteInfo() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let port = outputs.first else {
            isHeadphonesConnected = false
            connectedPortName = "未检测到输出设备"
            return
        }

        connectedPortName = port.portName
        let headphoneTypes: Set<AVAudioSession.Port> = [
            .headphones,
            .bluetoothA2DP,
            .bluetoothLE,
            .bluetoothHFP,
            .usbAudio
        ]
        isHeadphonesConnected = headphoneTypes.contains(port.portType)

        if isHeadphonesConnected, let suggested = HeadphoneProfile.infer(fromPortName: port.portName) {
            if calibrationMethod == .preset && headphoneProfile != suggested {
                selectHeadphoneProfile(suggested, preserveCustomCalibration: false)
                autoMatchedHeadphoneHint = "已根据「\(port.portName)」自动匹配：\(suggested.name)"
            }
        }
    }

    public func selectHeadphoneProfile(_ profile: HeadphoneProfile, preserveCustomCalibration: Bool = true) {
        headphoneProfile = profile
        if !preserveCustomCalibration || calibrationMethod == .preset {
            fullScaleSPL1k = profile.defaultFullScaleSPL1k
            calibrationMethod = .preset
        }
    }

    public func applyBiologicalCalibration(rawDbfs: Double, targetRefDbHL: Double, method: CalibrationMethod) {
        fullScaleSPL1k = AcousticMath.calibrateFullScaleSPL1k(
            rawDbfs: rawDbfs,
            targetRefDbHL: targetRefDbHL,
            profile: headphoneProfile
        )
        calibrationMethod = method
    }

    public func resetCalibrationToPreset() {
        fullScaleSPL1k = headphoneProfile.defaultFullScaleSPL1k
        calibrationMethod = .preset
    }

    public func maxSafeDbHL(for freq: Int) -> Double {
        AcousticMath.maxSafeDbHL(
            forFreq: freq,
            fullScaleSPL1k: fullScaleSPL1k,
            profile: headphoneProfile
        )
    }

    /// Play calibrated audiometric stimulus in isolated Left or Right ear channel
    @discardableResult
    public func playStimulus(
        freq: Int,
        dbHL: Double,
        ear: EarSide,
        waveform: ToneWaveform = .pulsed,
        maskingDbHL: Double? = nil,
        rawDbfsOverride: Double? = nil
    ) -> Double {
        ensureEngineRunning()
        let peakAmp: Float
        if let raw = rawDbfsOverride {
            peakAmp = AcousticMath.dbfsToLinearAmplitude(raw)
        } else {
            peakAmp = AcousticMath.linearAmplitude(
                freq: Double(freq),
                dbHL: dbHL,
                fullScaleSPL1k: fullScaleSPL1k,
                profile: headphoneProfile
            )
        }

        var maskAmp: Float? = nil
        if let mDb = maskingDbHL {
            maskAmp = AcousticMath.linearAmplitude(
                freq: Double(freq),
                dbHL: mDb,
                fullScaleSPL1k: fullScaleSPL1k,
                profile: headphoneProfile
            )
        }

        return synth.triggerStimulus(
            ear: ear,
            freq: Double(freq),
            peakAmplitude: peakAmp,
            waveform: waveform,
            maskingAmplitude: maskAmp
        )
    }

    public func playChannelVerification(ear: EarSide) {
        ensureEngineRunning()
        let amp = AcousticMath.linearAmplitude(
            freq: 1000.0,
            dbHL: 45.0,
            fullScaleSPL1k: fullScaleSPL1k,
            profile: headphoneProfile
        )
        synth.triggerChannelChime(ear: ear, amplitude: amp)
    }

    public func startOrUpdateTinnitusTone(
        freqHz: Int,
        dbHL: Double,
        earChoice: String, // "left" | "right" | "both"
        isNarrowBand: Bool
    ) {
        ensureEngineRunning()
        let amp = AcousticMath.linearAmplitude(
            freq: Double(freqHz),
            dbHL: dbHL,
            fullScaleSPL1k: fullScaleSPL1k,
            profile: headphoneProfile
        )
        let ampL: Float = (earChoice == "left" || earChoice == "both") ? amp : 0.0
        let ampR: Float = (earChoice == "right" || earChoice == "both") ? amp : 0.0
        synth.updateSustained(
            freq: Double(freqHz),
            ampLeft: ampL,
            ampRight: ampR,
            isNarrowBand: isNarrowBand
        )
    }

    public func stopAllAudio() {
        synth.fadeOutToStop()
    }

    // MARK: - Optional Temporary Ambient Room Noise Check

    public func startAmbientNoiseCheck(onDenied: @escaping (String) -> Void) {
        stopAllAudio()
        if engine.isRunning { engine.pause() }

        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard granted else {
                    onDenied("未授予麦克风权限，可直接跳过此步在安静卧室测试")
                    self.ensureEngineRunning()
                    return
                }
                do {
                    try session.setCategory(.record, mode: .measurement, options: [])
                    try session.setActive(true)
                    let nullURL = URL(fileURLWithPath: "/dev/null")
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatAppleLossless),
                        AVSampleRateKey: 44100.0,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue
                    ]
                    let recorder = try AVAudioRecorder(url: nullURL, settings: settings)
                    recorder.isMeteringEnabled = true
                    recorder.record()
                    self.ambientRecorder = recorder
                    self.isMonitoringAmbientNoise = true

                    self.ambientTimer?.invalidate()
                    self.ambientTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self = self, let rec = self.ambientRecorder else { return }
                            rec.updateMeters()
                            let avgPower = rec.averagePower(forChannel: 0) // -160 .. 0 dBFS
                            // Calibrated approximate iPhone MEMS mic dBA mapping
                            let est = Int(max(22.0, min(88.0, Double(avgPower) + 96.0)))
                            self.estimatedAmbientDbA = est
                        }
                    }
                } catch {
                    onDenied("环境底噪启动失败：\(error.localizedDescription)")
                    self.stopAmbientNoiseCheck()
                }
            }
        }
    }

    public func stopAmbientNoiseCheck() {
        ambientTimer?.invalidate()
        ambientTimer = nil
        ambientRecorder?.stop()
        ambientRecorder = nil
        isMonitoringAmbientNoise = false

        // Immediately restore pure .playback stereo session for A2DP headphones!
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        if !engine.isRunning {
            try? engine.start()
        }
        refreshAudioRouteInfo()
    }
}
