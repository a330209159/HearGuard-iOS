import Foundation

public enum HearingLossGrade: String {
    case unknown = "未测"
    case normal = "正常 (≤25 dB)"
    case mild = "轻度听损 (26–40 dB)"
    case moderate = "中度听损 (41–55 dB)"
    case moderatelySevere = "中重度听损 (56–70 dB)"
    case severe = "重度听损 (71–90 dB)"
    case profound = "极重度/全聋 (>90 dB)"

    public var shortName: String {
        switch self {
        case .unknown: return "未测"
        case .normal: return "正常"
        case .mild: return "轻度"
        case .moderate: return "中度"
        case .moderatelySevere: return "中重度"
        case .severe: return "重度"
        case .profound: return "极重度"
        }
    }

    public static func from(db: Double?) -> HearingLossGrade {
        guard let val = db else { return .unknown }
        if val <= 25.0 { return .normal }
        if val <= 40.0 { return .mild }
        if val <= 55.0 { return .moderate }
        if val <= 70.0 { return .moderatelySevere }
        if val <= 90.0 { return .severe }
        return .profound
    }
}

public struct SingleEarAnalysis {
    public let hasData: Bool
    public let pta4: Double?        // 500, 1000, 2000, 4000 Hz
    public let lowAvg: Double?      // 125, 250, 500 Hz
    public let highAvg: Double?     // 2000, 4000, 8000 Hz
    public let fullAvg: Double?     // 250 - 8000 Hz
    public let grade: HearingLossGrade
    public let curveType: String
    public let curveDetail: String
    public let focalWarning: String?
}

public struct ShadowRiskItem: Identifiable {
    public var id: String { "\(ear.rawValue)_\(freq)" }
    public let ear: EarSide
    public let freq: Int
    public let diffDb: Double
    public let iaDb: Double
}

public struct BilateralClinicalReport {
    public let left: SingleEarAnalysis
    public let right: SingleEarAnalysis
    public let suspectedAffectedEar: EarSide?
    public let consecutive20dBPairs: [(ear: EarSide, f1: Int, f2: Int)]
    public let shadowRisks: [ShadowRiskItem]
}

public struct BaselineComparisonItem: Identifiable {
    public var id: String { ear.rawValue }
    public let ear: EarSide
    public let impairedFreqs: [Int]
    public let baselineMeanDb: Double
    public let currentMeanDb: Double
    public let improvementDb: Double // Positive = hearing recovered (dB lowered)
    public let efficacyGrade: String
    public let summary: String
}

public enum ClinicalAnalyzer {
    private static func average(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        let sum = vals.reduce(0.0, +)
        return ((sum / Double(vals.count)) * 10.0).rounded() / 10.0
    }

    public static func analyzeEar(
        earData: [Int: ThresholdPoint],
        contralateralData: [Int: ThresholdPoint] = [:]
    ) -> SingleEarAnalysis {
        let sorted = earData.values.sorted { $0.freq < $1.freq }
        guard !sorted.isEmpty else {
            return SingleEarAnalysis(
                hasData: false,
                pta4: nil,
                lowAvg: nil,
                highAvg: nil,
                fullAvg: nil,
                grade: .unknown,
                curveType: "暂无测听数据",
                curveDetail: "佩戴耳机完成该侧耳朵 125Hz–8000Hz 纯音测听后自动生成临床分型。",
                focalWarning: nil
            )
        }

        func pick(_ targetFreqs: Set<Int>) -> [Double] {
            sorted
                .filter { targetFreqs.contains($0.freq) }
                .map { $0.noResponse ? $0.db + 5.0 : $0.db }
        }

        let pta4 = average(pick([500, 1000, 2000, 4000]))
        let lowAvg = average(pick([125, 250, 500]))
        let highAvg = average(pick([2000, 4000, 8000]))
        let fullAvg = average(pick([250, 500, 1000, 2000, 4000, 8000]))
        let primary = pta4 ?? fullAvg ?? average(sorted.map { $0.db })
        let grade = HearingLossGrade.from(db: primary)

        var adjacentAbnormal = 0
        if sorted.count >= 2 {
            for i in 0..<(sorted.count - 1) {
                let a = sorted[i]
                let b = sorted[i + 1]
                let oppA = contralateralData[a.freq]?.db
                let oppB = contralateralData[b.freq]?.db
                let dA = oppA != nil ? max(a.db - 20.0, a.db - oppA!) : a.db
                let dB = oppB != nil ? max(b.db - 20.0, b.db - oppB!) : b.db
                if (a.db > 25.0 && b.db > 25.0) || (dA >= 20.0 && dB >= 20.0) {
                    adjacentAbnormal += 1
                }
            }
        }

        let maxDb = sorted.map { $0.db }.max() ?? 0.0
        let nrCount = sorted.filter { $0.noResponse }.count
        let d125 = earData[125]?.db ?? 0.0
        let d250 = earData[250]?.db ?? d125
        let d500 = earData[500]?.db ?? 0.0
        let d4k = earData[4000]?.db ?? 0.0
        let d8k = earData[8000]?.db ?? 0.0

        let hasLowLoss = (lowAvg ?? 0.0) > 25.0 || (d250 >= 25.0 && d500 >= 25.0) || (d125 >= 30.0 && d250 >= 25.0)
        let hasHighLoss = (highAvg ?? 0.0) > 25.0 || (d4k >= 25.0 && d8k >= 25.0)

        var curveType = "各频段基本正常"
        var curveDetail = "125 Hz 至 8000 Hz 测得听阈均 ≤25 dB HL。若仍有耳闷或双耳听感差异，请对比对侧耳差值并结合医院声导抗检查。"
        var focalWarning: String? = nil

        if maxDb <= 25.0 && adjacentAbnormal == 0 {
            // Keep normal
        } else if (fullAvg ?? 0.0) >= 81.0 || (nrCount >= 4 && (fullAvg ?? 82.0) >= 75.0) {
            curveType = "全聋 / 极重度下降型"
            curveDetail = "全频段显著下降（250–8000Hz 均值 ≥81 dB HL 或多频点超安全上限）。请务必遵耳鼻喉科医嘱规范治疗，并开启对侧窄带掩蔽复核。"
        } else if hasLowLoss && (!hasHighLoss || ((lowAvg ?? 0) - (highAvg ?? 0) >= 15.0)) {
            curveType = "低频下降型（上升型曲线）"
            curveDetail = "主要累及 125–1000 Hz 低频区（耳蜗顶回膜迷路积水常见特征），常伴耳闷塞感、低调轰鸣或自声增强。指南指出该分型规范治疗预后最佳。"
            if let p = pta4, p <= 25.0, let l = lowAvg {
                focalWarning = "提示：标准四频 PTA (\(p) dB) 虽在正常范围，但 125–500Hz 低频均值达 \(l) dB HL，存在典型低频受损！"
            }
        } else if hasHighLoss && (!hasLowLoss || ((highAvg ?? 0) - (lowAvg ?? 0) >= 15.0)) {
            curveType = "高频下降型（下降型曲线）"
            curveDetail = "主要累及 2000–8000 Hz 高频区（耳蜗底回受累），常伴清辅音辨识下降或高调蝉鸣样耳鸣。请注意避噪护耳并坚持疗程。"
            if let p = pta4, p <= 25.0, let h = highAvg {
                focalWarning = "提示：标准四频 PTA (\(p) dB) 虽处正常边界，但 2k–8kHz 高频均值达 \(h) dB HL，存在高频下降！"
            }
        } else if hasLowLoss && hasHighLoss {
            curveType = "平坦下降型（全频受累型）"
            curveDetail = "低频、中频至高频普遍受累（均值 ≤80 dB HL），多与耳蜗血管纹或内耳供血障碍相关，建议定期复测观察低中频抬升趋势。"
        } else {
            curveType = "局部频点轻度偏移型"
            curveDetail = "个别频点高于 25 dB HL（最高 \(Int(maxDb)) dB HL），可点击听力图对应频点单点复测验证。"
        }

        return SingleEarAnalysis(
            hasData: true,
            pta4: pta4,
            lowAvg: lowAvg,
            highAvg: highAvg,
            fullAvg: fullAvg,
            grade: grade,
            curveType: curveType,
            curveDetail: curveDetail,
            focalWarning: focalWarning
        )
    }

    public static func analyzeBilateral(
        results: BilateralResults,
        profile: HeadphoneProfile = .inEar
    ) -> BilateralClinicalReport {
        let leftSum = analyzeEar(earData: results.left, contralateralData: results.right)
        let rightSum = analyzeEar(earData: results.right, contralateralData: results.left)

        let ia = profile.interauralAttenuationDb
        let allFreqs = Array(Set(results.left.keys).union(results.right.keys)).sorted()

        var shadowRisks: [ShadowRiskItem] = []
        for f in allFreqs {
            if let l = results.left[f], let r = results.right[f] {
                let diff = l.db - r.db
                let absDiff = abs(diff)
                let worsePt = diff > 0 ? l : r
                let worseEar: EarSide = diff > 0 ? .left : .right
                if absDiff >= ia && !worsePt.masked && !worsePt.noResponse {
                    shadowRisks.append(ShadowRiskItem(ear: worseEar, freq: f, diffDb: absDiff, iaDb: ia))
                }
            }
        }

        var consecutive: [(ear: EarSide, f1: Int, f2: Int)] = []
        if allFreqs.count >= 2 {
            for i in 0..<(allFreqs.count - 1) {
                let f1 = allFreqs[i]
                let f2 = allFreqs[i + 1]
                if let l1 = results.left[f1]?.db, let r1 = results.right[f1]?.db,
                   let l2 = results.left[f2]?.db, let r2 = results.right[f2]?.db {
                    if l1 - r1 >= 20.0 && l2 - r2 >= 20.0 {
                        consecutive.append((.left, f1, f2))
                    } else if r1 - l1 >= 20.0 && r2 - l2 >= 20.0 {
                        consecutive.append((.right, f1, f2))
                    }
                }
            }
        }

        var affected: EarSide? = nil
        if leftSum.hasData && rightSum.hasData {
            let lScore = leftSum.fullAvg ?? leftSum.pta4 ?? 0
            let rScore = rightSum.fullAvg ?? rightSum.pta4 ?? 0
            if lScore - rScore >= 12.0 { affected = .left }
            else if rScore - lScore >= 12.0 { affected = .right }
            else if (leftSum.lowAvg ?? 0) - (rightSum.lowAvg ?? 0) >= 15.0 { affected = .left }
            else if (rightSum.lowAvg ?? 0) - (leftSum.lowAvg ?? 0) >= 15.0 { affected = .right }
            else if (leftSum.highAvg ?? 0) - (rightSum.highAvg ?? 0) >= 15.0 { affected = .left }
            else if (rightSum.highAvg ?? 0) - (leftSum.highAvg ?? 0) >= 15.0 { affected = .right }
        } else if leftSum.hasData && (leftSum.pta4 ?? leftSum.lowAvg ?? 0) > 25.0 {
            affected = .left
        } else if rightSum.hasData && (rightSum.pta4 ?? rightSum.lowAvg ?? 0) > 25.0 {
            affected = .right
        }

        return BilateralClinicalReport(
            left: leftSum,
            right: rightSum,
            suspectedAffectedEar: affected,
            consecutive20dBPairs: consecutive,
            shadowRisks: shadowRisks
        )
    }

    /// Compare Current Results vs Baseline Session per CMA 2015 SSNHL Efficacy Grading
    public static func compareWithBaseline(
        current: BilateralResults,
        baseline: BilateralResults
    ) -> [BaselineComparisonItem] {
        let baseReport = analyzeBilateral(results: baseline)
        let candidateEars: [EarSide] = baseReport.suspectedAffectedEar != nil
            ? [baseReport.suspectedAffectedEar!]
            : [.left, .right]

        var items: [BaselineComparisonItem] = []
        for ear in candidateEars {
            let baseMap = baseline[ear]
            let currMap = current[ear]
            let oppBaseMap = baseline[ear.opposite]

            let shared = baseMap.keys.filter { currMap[$0] != nil }.sorted()
            guard !shared.isEmpty else { continue }

            var impaired = shared.filter { f in
                let bDb = baseMap[f]!.db
                if let opp = oppBaseMap[f]?.db {
                    return bDb > 25.0 || (bDb - opp >= 15.0)
                }
                return bDb > 25.0
            }
            if impaired.isEmpty { impaired = shared }

            guard let bMean = average(impaired.map { baseMap[$0]!.db }),
                  let cMean = average(impaired.map { currMap[$0]!.db }) else { continue }

            let imp = ((bMean - cMean) * 10.0).rounded() / 10.0
            let allNormalNow = impaired.allSatisfy { f in
                let cDb = currMap[f]!.db
                if let oppNow = current[ear.opposite][f]?.db {
                    return cDb <= 25.0 || (cDb - oppNow <= 10.0)
                }
                return cDb <= 25.0
            }

            let grade: String
            let summary: String
            let freqStr = impaired.map(String.init).joined(separator: "/")

            if allNormalNow && bMean > 25.0 {
                grade = "达到临床痊愈参考线"
                summary = "\(ear.title)原受损频段(\(freqStr)Hz)已恢复至 ≤25 dB HL 或接近健侧水平（较基线好转 +\(imp) dB）。"
            } else if imp >= 30.0 {
                grade = "显效（平均提升 ≥30 dB）"
                summary = "\(ear.title)受损频段平均听阈较基线提升 +\(imp) dB，达到指南“显效”标准！"
            } else if imp >= 15.0 {
                grade = "有效（平均提升 15–30 dB）"
                summary = "\(ear.title)受损频段平均听阈较基线提升 +\(imp) dB，听力曲线正在稳步上抬。"
            } else if imp <= -15.0 {
                grade = "阈值下移预警（下降 ≥15 dB）"
                summary = "\(ear.title)较对比基线下移 \(abs(imp)) dB。请确认耳机佩戴与 50% 音量是否一致；若确感耳闷或听力下降请及时复诊！"
            } else {
                let sign = imp > 0 ? "+" : ""
                grade = "稳定观察期"
                summary = "\(ear.title)受损频段较基线平均变化 \(sign)\(imp) dB（\(bMean) → \(cMean) dB HL）。"
            }

            items.append(BaselineComparisonItem(
                ear: ear,
                impairedFreqs: impaired,
                baselineMeanDb: bMean,
                currentMeanDb: cMean,
                improvementDb: imp,
                efficacyGrade: grade,
                summary: summary
            ))
        }
        return items
    }
}
