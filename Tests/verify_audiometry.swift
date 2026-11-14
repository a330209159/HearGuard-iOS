import Foundation

@main
struct VerifyAudiometrySuite {
    static func assertTrue(_ cond: Bool, _ msg: String) {
        if !cond {
            fputs("❌ ASSERTION FAILED: \(msg)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        print("=== Running HearGuard iOS Clinical & DSP Unit Verification ===")

        // 1. Verify strictly ascending frequency order 125 Hz -> 8000 Hz
        let std = FrequencySetMode.standardFrequencies
        let ext = FrequencySetMode.extendedFrequencies
        assertTrue(std == [125, 250, 500, 1000, 2000, 4000, 8000], "Standard 7 frequencies must be 125->8000Hz")
        for i in 1..<ext.count {
            assertTrue(ext[i] > ext[i - 1], "Extended frequencies must be strictly ascending")
        }
        print("✅ 1. Low-to-High Frequency Sequence (125Hz -> 8000Hz) verified")

        // 2. Verify ISO 389 RETSPL compensation & 1kHz biological calibration exactness
        let amp125 = AcousticMath.linearAmplitude(freq: 125, dbHL: 20, fullScaleSPL1k: 96.0, profile: .inEar)
        let amp1k = AcousticMath.linearAmplitude(freq: 1000, dbHL: 20, fullScaleSPL1k: 96.0, profile: .inEar)
        assertTrue(amp125 > amp1k * 8.0, "125Hz must have higher SPL drive than 1000Hz per ISO RETSPL")

        let calFS = AcousticMath.calibrateFullScaleSPL1k(rawDbfs: -76.0, targetRefDbHL: 10.0, profile: .inEar)
        let roundTripAmp = AcousticMath.linearAmplitude(freq: 1000, dbHL: 10.0, fullScaleSPL1k: calFS, profile: .inEar)
        let expectedAmp = AcousticMath.dbfsToLinearAmplitude(-76.0)
        assertTrue(abs(roundTripAmp - expectedAmp) < 1e-6, "1000Hz calibration round-trip must be exact")

        // Verify raised-cosine envelope starts & ends cleanly at 0 and peaks at 1.0
        let gStart = AcousticMath.raisedCosineGain(sampleIndex: 0, totalSamples: 4800, rampSamples: 1680)
        let gMid = AcousticMath.raisedCosineGain(sampleIndex: 2400, totalSamples: 4800, rampSamples: 1680)
        let gEnd = AcousticMath.raisedCosineGain(sampleIndex: 4799, totalSamples: 4800, rampSamples: 1680)
        assertTrue(gStart == 0.0 && gMid == 1.0 && gEnd == 0.0, "Raised-cosine envelope bounds check")
        print("✅ 2. ISO 389 RETSPL, 1kHz Biological Calibration & Raised-Cosine Envelope verified")

        // 3. Verify Modified Hughson-Westlake ("Down 10 dB, Up 5 dB") convergence
        // Simulate a patient whose true threshold at 250 Hz is 45 dB HL
        let trueThreshold = 45.0
        var hw = HughsonWestlakeStateMachine(ear: .left, freq: 250, maxDb: 75.0)
        var converged: ThresholdPoint? = nil
        for _ in 0..<20 {
            let heard = hw.currentDb >= trueThreshold
            if let pt = hw.recordTrial(heard: heard) {
                converged = pt
                break
            }
        }
        assertTrue(converged != nil, "Hughson-Westlake must converge within 20 steps")
        assertTrue(converged!.db == 45.0 && !converged!.noResponse, "Hughson-Westlake must converge to exact 45 dB HL")
        print("✅ 3. Modified Hughson-Westlake ('Down 10, Up 5') converged at \(converged!.db) dB HL in \(hw.trialCount) trials")

        // 4. Verify Narrow-Band Biquad Filter stability on 48kHz white noise
        var rng = RealtimeNoiseGenerator()
        var bp1 = BiquadBandpassFilter()
        var bp2 = BiquadBandpassFilter()
        bp1.configure(centerFreq: 1000.0, q: 3.2, sampleRate: 48000.0)
        bp2.configure(centerFreq: 1000.0, q: 3.2, sampleRate: 48000.0)
        var energy: Float = 0
        for _ in 0..<4800 {
            let w = rng.nextUniformSym()
            let y = bp2.process(bp1.process(w))
            assertTrue(y.isFinite && abs(y) < 5.0, "Biquad NBN filter must be bounded and finite")
            energy += y * y
        }
        assertTrue(energy > 0.01, "Narrow-band masking filter must pass in-band energy")
        print("✅ 4. 48kHz Cascaded Narrow-Band Noise Masking Filter stability verified")

        // 5. Verify SSNHL Clinical Analyzer (Low-Freq SSNHL + Efficacy comparison)
        let baseline = BilateralResults(
            left: [
                125: ThresholdPoint(freq: 125, db: 55),
                250: ThresholdPoint(freq: 250, db: 60),
                500: ThresholdPoint(freq: 500, db: 50),
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
        let biReport = ClinicalAnalyzer.analyzeBilateral(results: baseline, profile: .inEar)
        assertTrue(biReport.left.curveType.contains("低频下降型"), "Must detect Low-Frequency Descending SSNHL")
        assertTrue(biReport.right.curveType.contains("正常"), "Must detect normal contralateral ear")
        assertTrue(biReport.suspectedAffectedEar == .left, "Must identify Left ear as affected")

        var recovered = baseline
        recovered.left[125]?.db = 20
        recovered.left[250]?.db = 20
        recovered.left[500]?.db = 15
        let eff = ClinicalAnalyzer.compareWithBaseline(current: recovered, baseline: baseline)
        assertTrue(!eff.isEmpty && eff[0].efficacyGrade.contains("痊愈"), "Must detect recovery to normal range")
        print("✅ 5. CMA 2015 SSNHL Typing & Longitudinal Recovery Analyzer verified")
        print("=== ALL UNIT VERIFICATIONS PASSED ===")
    }
}
