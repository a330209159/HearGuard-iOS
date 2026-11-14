import Foundation

/// Deterministic Modified Hughson-Westlake State Machine per Frequency (ISO 8253-1)
/// Rule:
/// - Initial search starts at a gentle comfortable level (default 30 dB HL, adapted mildly to adjacent octave <=45 dB).
/// - If not heard initially, steps UP by +10 dB until first heard (or hits distortion-free maxDb twice -> No Response).
/// - Once heard, enters bracketing ("Down 10 dB, Up 5 dB").
/// - Threshold converges when an ascending presentation at a given level achieves >=2 hits and >=50% response rate.
public struct HughsonWestlakeStateMachine {
    public enum Phase {
        case initialSearch
        case bracketing
    }

    public enum Direction {
        case descending
        case ascending
    }

    public struct AscendStat {
        public var attempts: Int = 0
        public var hits: Int = 0
    }

    public let ear: EarSide
    public let freq: Int
    public let maxDb: Double
    public private(set) var currentDb: Double
    public private(set) var phase: Phase = .initialSearch
    public private(set) var direction: Direction = .descending
    public private(set) var ascendingStats: [Int: AscendStat] = [:]
    public private(set) var floorHits: Int = 0
    public private(set) var ceilingMisses: Int = 0
    public private(set) var trialCount: Int = 0
    public private(set) var usedMasking: Bool = false

    public init(ear: EarSide, freq: Int, maxDb: Double, previousAdjacentDb: Double? = nil) {
        self.ear = ear
        self.freq = freq
        self.maxDb = maxDb

        var startDb = 30.0
        if let prev = previousAdjacentDb {
            let adapted = ((prev + 5.0) / 5.0).rounded() * 5.0
            startDb = min(45.0, max(25.0, adapted))
        }
        self.currentDb = min(maxDb, startDb)
    }

    /// Compute optional Contralateral Narrow-Band Noise Masking dB HL when opposite ear threshold is known
    public mutating func maskingLevelIfNeeded(
        enableMasking: Bool,
        oppositeEarThreshold: ThresholdPoint?,
        interauralAttenuation: Double
    ) -> Double? {
        guard enableMasking,
              let opp = oppositeEarThreshold,
              !opp.noResponse else {
            return nil
        }
        if currentDb - opp.db >= interauralAttenuation - 5.0 {
            usedMasking = true
            let over = max(0.0, currentDb - interauralAttenuation - opp.db)
            let rawMask = opp.db + 15.0 + over
            let rounded = (rawMask / 5.0).rounded() * 5.0
            return min(65.0, max(20.0, rounded))
        }
        return nil
    }

    /// Record outcome of presenting `currentDb` and return finalized `ThresholdPoint` if converged, or `nil` to continue.
    public mutating func recordTrial(heard: Bool) -> ThresholdPoint? {
        let testedDb = currentDb
        let testedInt = Int(testedDb.rounded())
        trialCount += 1

        if phase == .initialSearch {
            if heard {
                phase = .bracketing
                if testedDb <= AcousticMath.minTestDbHL {
                    floorHits = 1
                    currentDb = AcousticMath.minTestDbHL
                    direction = .ascending
                } else {
                    currentDb = max(AcousticMath.minTestDbHL, testedDb - 10.0)
                    direction = .descending
                }
            } else {
                if testedDb >= maxDb {
                    ceilingMisses += 1
                    if ceilingMisses >= 2 {
                        return ThresholdPoint(
                            freq: freq,
                            db: maxDb,
                            noResponse: true,
                            masked: usedMasking,
                            lowConfidence: false
                        )
                    }
                } else {
                    currentDb = min(maxDb, testedDb + 10.0)
                }
            }
            return nil
        }

        // Phase == .bracketing
        if direction == .ascending || testedDb <= AcousticMath.minTestDbHL {
            var stat = ascendingStats[testedInt] ?? AscendStat()
            stat.attempts += 1
            if heard { stat.hits += 1 }
            ascendingStats[testedInt] = stat
        }

        if heard {
            ceilingMisses = 0
            if testedDb <= AcousticMath.minTestDbHL {
                floorHits += 1
                let minInt = Int(AcousticMath.minTestDbHL.rounded())
                if floorHits >= 2 || (ascendingStats[minInt]?.hits ?? 0) >= 2 {
                    return ThresholdPoint(
                        freq: freq,
                        db: AcousticMath.minTestDbHL,
                        noResponse: false,
                        masked: usedMasking,
                        lowConfidence: false
                    )
                }
                currentDb = AcousticMath.minTestDbHL
                direction = .ascending
                return nil
            }

            if direction == .ascending, let stat = ascendingStats[testedInt] {
                if stat.hits >= 2 && Double(stat.hits) / Double(stat.attempts) >= 0.5 {
                    return ThresholdPoint(
                        freq: freq,
                        db: testedDb,
                        noResponse: false,
                        masked: usedMasking,
                        lowConfidence: false
                    )
                }
            }

            // Heard -> Step DOWN 10 dB
            currentDb = max(AcousticMath.minTestDbHL, testedDb - 10.0)
            direction = .descending
        } else {
            // Not heard -> Step UP 5 dB
            if testedDb >= maxDb {
                ceilingMisses += 1
                if ceilingMisses >= 2 {
                    let maxInt = Int(maxDb.rounded())
                    let ceilHits = ascendingStats[maxInt]?.hits ?? 0
                    return ThresholdPoint(
                        freq: freq,
                        db: maxDb,
                        noResponse: ceilHits == 0,
                        masked: usedMasking,
                        lowConfidence: false
                    )
                }
                currentDb = maxDb
                direction = .ascending
            } else {
                currentDb = min(maxDb, testedDb + 5.0)
                direction = .ascending
            }
        }

        // Anti-fatigue cap at 16 presentations per frequency
        if trialCount >= 16 {
            let fallbackDb = estimateBestFallback()
            return ThresholdPoint(
                freq: freq,
                db: fallbackDb,
                noResponse: false,
                masked: usedMasking,
                lowConfidence: true
            )
        }

        return nil
    }

    private func estimateBestFallback() -> Double {
        let sorted = ascendingStats
            .filter { $0.value.hits >= 1 }
            .sorted { $0.key < $1.key }

        if let fifty = sorted.first(where: { Double($0.value.hits) / Double($0.value.attempts) >= 0.5 }) {
            return Double(fifty.key)
        }
        if let first = sorted.first {
            return Double(first.key)
        }
        return currentDb
    }
}
