import Foundation

/// Ear side following international clinical audiometry conventions
public enum EarSide: String, Codable, CaseIterable, Identifiable {
    case left = "left"
    case right = "right"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .left: return "左耳"
        case .right: return "右耳"
        }
    }

    public var fullLabel: String {
        switch self {
        case .left: return "左耳 (L · ✕)"
        case .right: return "右耳 (R · O)"
        }
    }

    public var unmaskedSymbol: String {
        switch self {
        case .left: return "✕"
        case .right: return "O"
        }
    }

    public var maskedSymbol: String {
        switch self {
        case .left: return "□"
        case .right: return "△"
        }
    }

    public var opposite: EarSide {
        self == .left ? .right : .left
    }
}

/// Affected ear configuration for unilateral/bilateral SSNHL
public enum AffectedSidePreference: String, Codable, CaseIterable, Identifiable {
    case left = "left"
    case right = "right"
    case unknown = "unknown"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .left: return "左耳突聋/耳闷（右耳较好）"
        case .right: return "右耳突聋/耳闷（左耳较好）"
        case .unknown: return "双耳受累 或 暂不确定"
        }
    }

    /// Recommended clinical ear order: test healthier ear first to establish intra-subject baseline & masking reference
    public var recommendedOrder: [EarSide] {
        switch self {
        case .left: return [.right, .left]
        case .right: return [.left, .right]
        case .unknown: return [.right, .left]
        }
    }
}

/// Ear testing sequence option
public enum EarTestOrder: String, Codable, CaseIterable, Identifiable {
    case healthyFirst = "healthy_first"
    case leftFirst = "left_first"
    case rightFirst = "right_first"
    case leftOnly = "left_only"
    case rightOnly = "right_only"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .healthyFirst: return "智能推荐（先健侧 → 后患侧）"
        case .leftFirst: return "双耳：先左耳(✕) → 后右耳(O)"
        case .rightFirst: return "双耳：先右耳(O) → 后左耳(✕)"
        case .leftOnly: return "单耳快速复查：仅左耳(✕)"
        case .rightOnly: return "单耳快速复查：仅右耳(O)"
        }
    }

    public func resolveEars(affected: AffectedSidePreference) -> [EarSide] {
        switch self {
        case .healthyFirst: return affected.recommendedOrder
        case .leftFirst: return [.left, .right]
        case .rightFirst: return [.right, .left]
        case .leftOnly: return [.left]
        case .rightOnly: return [.right]
        }
    }
}

/// Strictly ordered Low-to-High Frequency Sets (125 Hz -> 8000 Hz)
public enum FrequencySetMode: String, Codable, CaseIterable, Identifiable {
    case standard7 = "standard"
    case extended11 = "extended"

    public var id: String { rawValue }

    public static let standardFrequencies: [Int] = [125, 250, 500, 1000, 2000, 4000, 8000]
    public static let extendedFrequencies: [Int] = [125, 250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000, 8000]

    public var frequencies: [Int] {
        switch self {
        case .standard7: return Self.standardFrequencies
        case .extended11: return Self.extendedFrequencies
        }
    }

    public var label: String {
        switch self {
        case .standard7: return "标准 7 频点 (125→8000Hz)"
        case .extended11: return "精细 11 频点 (含半倍频程)"
        }
    }
}

public struct FrequencyMetadata {
    public let hz: Int
    public let shortLabel: String
    public let bandName: String
    public let clinicalNote: String

    public static func info(for hz: Int) -> FrequencyMetadata {
        switch hz {
        case 125:
            return .init(hz: 125, shortLabel: "125", bandName: "极低频", clinicalNote: "耳蜗顶回末端 · 低频突聋耳闷胀感/嗡鸣高发区")
        case 250:
            return .init(hz: 250, shortLabel: "250", bandName: "低频", clinicalNote: "耳蜗顶回 · 膜迷路积水型突聋核心受损频点")
        case 500:
            return .init(hz: 500, shortLabel: "500", bandName: "中低频", clinicalNote: "汉语元音能量主频区 · 决定声音饱满度")
        case 750:
            return .init(hz: 750, shortLabel: "750", bandName: "低中过渡", clinicalNote: "低频与中频斜率精细过渡监测点")
        case 1000:
            return .init(hz: 1000, shortLabel: "1k", bandName: "中频基准", clinicalNote: "国际听力学声学校准核心参考频率")
        case 1500:
            return .init(hz: 1500, shortLabel: "1.5k", bandName: "中高频", clinicalNote: "言语清晰度重要过渡半倍频程")
        case 2000:
            return .init(hz: 2000, shortLabel: "2k", bandName: "高频起点", clinicalNote: "声母/辅音可懂度核心频点")
        case 3000:
            return .init(hz: 3000, shortLabel: "3k", bandName: "高频", clinicalNote: "嘈杂环境下言语分辨关键区")
        case 4000:
            return .init(hz: 4000, shortLabel: "4k", bandName: "高频核心", clinicalNote: "耳蜗底回 · 高频突聋与蝉鸣样耳鸣高发区")
        case 6000:
            return .init(hz: 6000, shortLabel: "6k", bandName: "超高频过渡", clinicalNote: "耳蜗底回精细监测半倍频程")
        case 8000:
            return .init(hz: 8000, shortLabel: "8k", bandName: "极高频", clinicalNote: "耳蜗底回基底部 · 内耳微循环早期敏感区")
        default:
            let lbl = hz >= 1000 ? String(format: "%g", Double(hz) / 1000.0) + "k" : "\(hz)"
            return .init(hz: hz, shortLabel: lbl, bandName: "自定义频点", clinicalNote: "纯音气导测听频点")
        }
    }
}

/// Stimulus waveform engineered for SSNHL & Tinnitus separation (ISO 8253-1)
public enum ToneWaveform: String, Codable, CaseIterable, Identifiable {
    case pulsed = "pulsed"
    case warble = "warble"
    case continuous = "continuous"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pulsed: return "脉冲纯音 (嘀-嘀-嘀 · 抗耳鸣首选)"
        case .warble: return "调频啭音 (±5%调制 · 重度耳鸣推荐)"
        case .continuous: return "连续平滑纯音 (1.15秒正弦波)"
        }
    }
}

/// Headphone Transducer Profile & ISO 389 / Empirical RETSPL Curve
public enum HeadphoneProfile: String, Codable, CaseIterable, Identifiable {
    case inEar = "in_ear"
    case overEar = "over_ear"
    case semiInEar = "semi_in_ear"
    case supraAural = "supra_aural"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .inEar: return "入耳式硅胶塞耳机 (推荐)"
        case .overEar: return "头戴式包耳耳机 (ISO 389-8)"
        case .semiInEar: return "半入耳式耳塞 (EarPods/AirPods)"
        case .supraAural: return "压耳式测听耳机 (ISO 389-1)"
        }
    }

    public var subtitle: String {
        switch self {
        case .inEar: return "AirPods Pro / 索尼 WF / 有线入耳塞（耳道密封，125Hz 低频气密性最佳）"
        case .overEar: return "AirPods Max / Bose / Sony WH 包耳式头戴耳机（隔音稳定）"
        case .semiInEar: return "标准版 AirPods 2·3·4 / Apple EarPods（非密封，已含低频漏音补偿）"
        case .supraAural: return "TDH-39 / DD45 标准压耳式换能器耦合模型"
        }
    }

    /// Minimum Interaural Attenuation (IA, dB) per ISO 8253-1 for cross-hearing detection
    public var interauralAttenuationDb: Double {
        switch self {
        case .inEar: return 55.0
        case .overEar: return 45.0
        case .semiInEar: return 40.0
        case .supraAural: return 40.0
        }
    }

    /// Typical dB SPL @ 1000 Hz (0 dBFS) when iPhone volume is set to 50%
    public var defaultFullScaleSPL1k: Double {
        switch self {
        case .inEar: return 96.0
        case .overEar: return 95.0
        case .semiInEar: return 94.0
        case .supraAural: return 96.0
        }
    }

    /// Reference Equivalent Threshold Sound Pressure Level (RETSPL in dB SPL for 0 dB HL)
    public var retsplTable: [Int: Double] {
        switch self {
        case .inEar:
            return [
                125: 26.0, 250: 15.5, 500: 9.5, 750: 6.5,
                1000: 5.0, 1500: 4.5, 2000: 3.5, 3000: 3.5,
                4000: 7.5, 6000: 13.0, 8000: 15.5
            ]
        case .overEar:
            // ISO 389-8 (Sennheiser HDA 200 / IEC 60318-1 circumaural standard)
            return [
                125: 30.5, 250: 18.0, 500: 11.0, 750: 7.5,
                1000: 5.5, 1500: 5.5, 2000: 4.5, 3000: 6.0,
                4000: 9.5, 6000: 17.0, 8000: 17.5
            ]
        case .semiInEar:
            // Derived from Ho et al. (2017) Apple EarPods empirical RETSPL + 125Hz unsealed concha compensation
            return [
                125: 34.0, 250: 18.5, 500: 11.5, 750: 7.5,
                1000: 5.5, 1500: 3.5, 2000: 2.0, 3000: 4.5,
                4000: 8.5, 6000: 15.0, 8000: 18.0
            ]
        case .supraAural:
            // ISO 389-1 (TDH-39 / IEC 60318-3 6-cc coupler standard)
            return [
                125: 45.0, 250: 25.5, 500: 11.5, 750: 8.5,
                1000: 7.0, 1500: 6.5, 2000: 9.0, 3000: 10.0,
                4000: 9.5, 6000: 15.5, 8000: 13.0
            ]
        }
    }

    /// Infer best headphone profile from iOS AVAudioSession port name
    public static func infer(fromPortName portName: String) -> HeadphoneProfile? {
        let lower = portName.lowercased()
        if lower.contains("airpods pro") || lower.contains("wf-") || lower.contains("buds pro") {
            return .inEar
        }
        if lower.contains("airpods max") || lower.contains("wh-") || lower.contains("bose") {
            return .overEar
        }
        if lower.contains("earpods") || lower.contains("airpods") {
            return .semiInEar
        }
        return nil
    }
}

public enum CalibrationMethod: String, Codable {
    case preset = "preset"
    case healthyEar1k = "healthy_ear"
    case handRub = "hand_rub"

    public var label: String {
        switch self {
        case .preset: return "50%音量标准校准"
        case .healthyEar1k: return "健侧耳1kHz生物校准"
        case .handRub: return "搓手声生物校准"
        }
    }
}

/// Single measured pure-tone threshold point
public struct ThresholdPoint: Codable, Equatable {
    public var freq: Int
    public var db: Double
    public var noResponse: Bool
    public var masked: Bool
    public var lowConfidence: Bool

    public init(freq: Int, db: Double, noResponse: Bool = false, masked: Bool = false, lowConfidence: Bool = false) {
        self.freq = freq
        self.db = db
        self.noResponse = noResponse
        self.masked = masked
        self.lowConfidence = lowConfidence
    }

    public var formattedShort: String {
        let prefix = noResponse ? ">" : ""
        let dbInt = Int(db.rounded())
        return "\(prefix)\(dbInt)"
    }
}

/// Bilateral threshold map
public struct BilateralResults: Codable, Equatable {
    public var left: [Int: ThresholdPoint]
    public var right: [Int: ThresholdPoint]

    public init(left: [Int: ThresholdPoint] = [:], right: [Int: ThresholdPoint] = [:]) {
        self.left = left
        self.right = right
    }

    public subscript(ear: EarSide) -> [Int: ThresholdPoint] {
        get { ear == .left ? left : right }
        set {
            if ear == .left { left = newValue }
            else { right = newValue }
        }
    }

    public var isEmpty: Bool {
        left.isEmpty && right.isEmpty
    }
}

public enum SessionSource: String, Codable {
    case homeTest = "home_test"
    case hospitalImport = "hospital_import"

    public var badgeText: String {
        switch self {
        case .homeTest: return "居家耳机测听"
        case .hospitalImport: return "医院隔声室报告"
        }
    }
}

/// Saved Audiogram Session for longitudinal recovery tracking
public struct AudiogramSession: Codable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var source: SessionSource
    public var headphoneProfile: HeadphoneProfile
    public var systemVolumePercent: Int
    public var note: String
    public var results: BilateralResults

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: SessionSource = .homeTest,
        headphoneProfile: HeadphoneProfile = .inEar,
        systemVolumePercent: Int = 50,
        note: String = "",
        results: BilateralResults
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.headphoneProfile = headphoneProfile
        self.systemVolumePercent = systemVolumePercent
        self.note = note
        self.results = results
    }
}

/// Tinnitus Pitch & Loudness Match Log
public struct TinnitusMatchRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var freqHz: Int
    public var dbHL: Double
    public var isNarrowBandNoise: Bool
    public var vasScore: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        freqHz: Int,
        dbHL: Double,
        isNarrowBandNoise: Bool,
        vasScore: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.freqHz = freqHz
        self.dbHL = dbHL
        self.isNarrowBandNoise = isNarrowBandNoise
        self.vasScore = vasScore
    }
}
