import Foundation

/// Precision Acoustic & DSP Mathematics for Pure-Tone Audiometry (ISO 389 & ISO 8253-1)
public enum AcousticMath {
    public static let minTestDbHL: Double = -10.0
    public static let maxHardSafetyDbHL: Double = 85.0
    /// -1.0 dBFS digital peak ceiling (0.89125) to guarantee 0% harmonic clipping distortion
    public static let maxDigitalDbfs: Double = -1.0
    public static let maxLinearAmplitude: Float = 0.8912509

    /// Logarithmic octave interpolation of RETSPL (dB SPL at 0 dB HL)
    public static func retspl(forFreq freq: Double, profile: HeadphoneProfile) -> Double {
        let table = profile.retsplTable
        let intFreq = Int(freq.rounded())
        if let exact = table[intFreq], abs(Double(intFreq) - freq) < 0.5 {
            return exact
        }
        let sortedKeys = table.keys.sorted()
        guard let first = sortedKeys.first, let last = sortedKeys.last else { return 7.0 }
        if freq <= Double(first) { return table[first] ?? 26.0 }
        if freq >= Double(last) { return table[last] ?? 15.5 }

        for i in 0..<(sortedKeys.count - 1) {
            let f1 = Double(sortedKeys[i])
            let f2 = Double(sortedKeys[i + 1])
            if freq >= f1 && freq <= f2 {
                let v1 = table[sortedKeys[i]] ?? 7.0
                let v2 = table[sortedKeys[i + 1]] ?? 7.0
                let t = log2(freq / f1) / log2(f2 / f1)
                return v1 + t * (v2 - v1)
            }
        }
        return 7.0
    }

    /// Compute distortion-free maximum achievable dB HL (in 5 dB steps) before hitting -1 dBFS clipping
    public static func maxSafeDbHL(
        forFreq freq: Int,
        fullScaleSPL1k: Double,
        profile: HeadphoneProfile
    ) -> Double {
        let r = retspl(forFreq: Double(freq), profile: profile)
        let rawMax = floor((fullScaleSPL1k + maxDigitalDbfs - r) / 5.0) * 5.0
        return min(maxHardSafetyDbHL, max(40.0, rawMax))
    }

    /// Convert (Frequency Hz, Hearing Level dB HL) -> Linear Float32 Amplitude [0, 0.89125]
    public static func linearAmplitude(
        freq: Double,
        dbHL: Double,
        fullScaleSPL1k: Double,
        profile: HeadphoneProfile
    ) -> Float {
        let clampedHL = max(minTestDbHL, min(maxHardSafetyDbHL, dbHL))
        let r = retspl(forFreq: freq, profile: profile)
        let targetSPL = clampedHL + r
        let dbfs = min(maxDigitalDbfs, targetSPL - fullScaleSPL1k)
        let amp = pow(10.0, dbfs / 20.0)
        return min(maxLinearAmplitude, Float(amp))
    }

    /// Convert raw digital dBFS [-105, -1] -> Linear Float32 Amplitude
    public static func dbfsToLinearAmplitude(_ dbfs: Double) -> Float {
        let clamped = max(-105.0, min(maxDigitalDbfs, dbfs))
        return min(maxLinearAmplitude, Float(pow(10.0, clamped / 20.0)))
    }

    /// Solve calibrated Full-Scale SPL @ 1000 Hz from biological threshold calibration
    /// Formula: targetRefDbHL + RETSPL(1000) = fullScaleSPL1k + rawDbfs
    public static func calibrateFullScaleSPL1k(
        rawDbfs: Double,
        targetRefDbHL: Double,
        profile: HeadphoneProfile
    ) -> Double {
        let retspl1k = retspl(forFreq: 1000.0, profile: profile)
        let computed = targetRefDbHL + retspl1k - rawDbfs
        return max(72.0, min(118.0, computed))
    }

    /// Raised-cosine (Hann half-window) envelope for click-free tone onset & offset (ISO 8253-1: 35ms ramp)
    @inline(__always)
    public static func raisedCosineGain(
        sampleIndex: Int,
        totalSamples: Int,
        rampSamples: Int
    ) -> Float {
        if sampleIndex < 0 || sampleIndex >= totalSamples { return 0.0 }
        let safeRamp = max(1, min(rampSamples, totalSamples / 2))
        if sampleIndex < safeRamp {
            let phase = Double.pi * Double(sampleIndex) / Double(safeRamp)
            return Float(0.5 * (1.0 - cos(phase)))
        } else if sampleIndex >= totalSamples - safeRamp {
            let rem = totalSamples - 1 - sampleIndex
            let phase = Double.pi * Double(rem) / Double(safeRamp)
            return Float(0.5 * (1.0 - cos(phase)))
        }
        return 1.0
    }
}

/// Real-time allocation-free 2nd-order RBJ Bandpass Filter for Contralateral Narrow-Band Noise Masking
public struct BiquadBandpassFilter {
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0

    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    public init() {}

    public mutating func configure(centerFreq: Double, q: Double = 3.2, sampleRate: Double) {
        let f0 = max(60.0, min(sampleRate * 0.44, centerFreq))
        let w0 = 2.0 * Double.pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * max(0.5, q))

        let a0 = 1.0 + alpha
        self.b0 = Float(alpha / a0)
        self.b1 = 0.0
        self.b2 = Float(-alpha / a0)
        self.a1 = Float((-2.0 * cosW0) / a0)
        self.a2 = Float((1.0 - alpha) / a0)
    }

    public mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    @inline(__always)
    public mutating func process(_ x0: Float) -> Float {
        let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x0
        y2 = y1
        y1 = y0
        return y0
    }
}

/// Fast deterministic Xorshift64* PRNG for real-time audio-thread white noise generation (zero locks/syscalls)
public struct RealtimeNoiseGenerator {
    private var state: UInt64 = 0x853C49E6748FEA9B

    public init(seed: UInt64 = 0x853C49E6748FEA9B) {
        self.state = seed == 0 ? 0x853C49E6748FEA9B : seed
    }

    @inline(__always)
    public mutating func nextUniformSym() -> Float {
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        let mult = x &* 0x2545F4914F6CDD1D
        let norm = Float(mult >> 40) / Float(1 << 24) // [0, 1)
        return norm * 2.0 - 1.0
    }
}
