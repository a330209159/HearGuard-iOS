/**
 * Clinical & Acoustic Constants for SSNHL Pure-Tone Audiometry
 * Grounded in:
 * - ISO 8253-1:2010 (Acoustics — Audiometric test methods — Part 1: Pure-tone air and bone conduction)
 * - ISO 389-1 / ISO 389-2 / ISO 389-8 (RETSPL Reference Equivalent Threshold Sound Pressure Levels)
 * - Ho et al. (2017) & Masalski et al. (2016/2018) consumer earphone mobile audiometry calibration
 * - 中华医学会耳鼻咽喉头颈外科学分会《突发性聋诊断和治疗指南 (2015)》
 * - WHO World Report on Hearing (2021) Hearing Loss Grades
 */

// Strictly ordered from Low Frequency (125 Hz) to High Frequency (8000 Hz)
export const STANDARD_FREQUENCIES = [125, 250, 500, 1000, 2000, 4000, 8000];

export const EXTENDED_FREQUENCIES = [
  125, 250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000, 8000
];

export const FREQUENCY_LABELS = {
  125: { hz: '125', band: '极低频', note: '耳蜗顶回 · 闷胀感高发区 (轰鸣/雷声频段)' },
  250: { hz: '250', band: '低频', note: '耳蜗顶回 · 低频突聋核心频点 (男声基频/元音)' },
  500: { hz: '500', band: '中低频', note: '言语能量主频区 · 元音饱满度' },
  750: { hz: '750', band: '中低半倍频', note: '低中频过渡精细监测点' },
  1000: { hz: '1k', band: '中频基准', note: '国际听力学声学校准核心参考频点' },
  1500: { hz: '1.5k', band: '中高频', note: '言语清晰度重要过渡频点' },
  2000: { hz: '2k', band: '高频起点', note: '汉语声母/辅音辨识关键频点' },
  3000: { hz: '3k', band: '高频', note: '摩擦音与嘈杂环境言语理解关键区' },
  4000: { hz: '4k', band: '高频核心', note: '耳蜗底回 · 高频突聋与蝉鸣样耳鸣高发区' },
  6000: { hz: '6k', band: '超高频过渡', note: '耳蜗底回精细监测点' },
  8000: { hz: '8k', band: '极高频', note: '耳蜗底回末端 · 早期微循环受损敏感区' }
};

/**
 * Headphone Transducer Profiles & RETSPL Compensation Curves (in dB SPL for 0 dB HL)
 * Also specifies Minimum Interaural Attenuation (IA, dB) per ISO 8253-1 for cross-hearing detection.
 */
export const HEADPHONE_PROFILES = {
  in_ear: {
    id: 'in_ear',
    name: '入耳式硅胶塞耳机 (推荐)',
    subtitle: 'AirPods Pro / 索尼 WF / 有线入耳式耳塞 (密封耳道，低频 125Hz 气密性最佳)',
    interauralAttenuation: 55, // Sealed insert/canal reduces bone cross-hearing (55-60 dB)
    defaultFullScaleSpl1k: 96.0, // Typical dB SPL @ 0 dBFS when OS volume is at 50%
    // Effective consumer-sealed RETSPL mapping (ISO 389-2 + consumer IEM coupler transfer)
    retspl: {
      125: 26.0,
      250: 15.5,
      500: 9.5,
      750: 6.5,
      1000: 5.0,
      1500: 4.5,
      2000: 3.5,
      3000: 3.5,
      4000: 7.5,
      6000: 13.0,
      8000: 15.5
    }
  },
  over_ear: {
    id: 'over_ear',
    name: '头戴式包耳耳机 (ISO 389-8)',
    subtitle: 'AirPods Max / Sony WH / Bose / 专业监听包耳式耳机 (隔音较好，声场稳定)',
    interauralAttenuation: 45,
    defaultFullScaleSpl1k: 95.0,
    // ISO 389-8 (Sennheiser HDA 200 / IEC 60318-1 ear simulator standard)
    retspl: {
      125: 30.5,
      250: 18.0,
      500: 11.0,
      750: 7.5,
      1000: 5.5,
      1500: 5.5,
      2000: 4.5,
      3000: 6.0,
      4000: 9.5,
      6000: 17.0,
      8000: 17.5
    }
  },
  semi_in_ear: {
    id: 'semi_in_ear',
    name: '半入耳式平头耳塞',
    subtitle: 'Apple EarPods / 标准版 AirPods 2·3·4 (注意：非密封设计在 125Hz 易漏音)',
    interauralAttenuation: 40,
    defaultFullScaleSpl1k: 94.0,
    // Derived from Ho et al. (2017) Apple EarPods RETSPL + unsealed concha 125 Hz roll-off offset
    retspl: {
      125: 34.0,
      250: 18.5,
      500: 11.5,
      750: 7.5,
      1000: 5.5,
      1500: 3.5,
      2000: 2.0,
      3000: 4.5,
      4000: 8.5,
      6000: 15.0,
      8000: 18.0
    }
  },
  supra_aural: {
    id: 'supra_aural',
    name: '压耳式标准耳机 (ISO 389-1)',
    subtitle: 'TDH-39 / DD45 医院测听室传统压耳式换能器参考曲线',
    interauralAttenuation: 40,
    defaultFullScaleSpl1k: 96.0,
    // ISO 389-1 TDH-39 / IEC 60318-3 6-cc coupler standard
    retspl: {
      125: 45.0,
      250: 25.5,
      500: 11.5,
      750: 8.5,
      1000: 7.0,
      1500: 6.5,
      2000: 9.0,
      3000: 10.0,
      4000: 9.5,
      6000: 15.5,
      8000: 13.0
    }
  }
};

/**
 * Hearing Loss Severity Grades (Clinical / WHO Reference)
 * Note: Chinese ENT clinics commonly use <=25 dB HL as clinical normal adult range
 * (WHO 2021 updated normal threshold to <20 dB, while Chinese 2015 SSNHL guideline uses <=25 dB normal).
 * We show clear clinical bands compatible with Chinese ENT audiograms!
 */
export const HEARING_SEVERITY_BANDS = [
  { min: -10, max: 25, label: '正常听力 (≤25 dB)', shortLabel: '正常', color: 'rgba(16, 185, 129, 0.09)', borderColor: '#10b981', badgeClass: 'grade-normal' },
  { min: 25, max: 40, label: '轻度听损 (26–40 dB)', shortLabel: '轻度', color: 'rgba(234, 179, 8, 0.09)', borderColor: '#eab308', badgeClass: 'grade-mild' },
  { min: 40, max: 55, label: '中度听损 (41–55 dB)', shortLabel: '中度', color: 'rgba(249, 115, 22, 0.10)', borderColor: '#f97316', badgeClass: 'grade-moderate' },
  { min: 55, max: 70, label: '中重度听损 (56–70 dB)', shortLabel: '中重度', color: 'rgba(239, 68, 68, 0.10)', borderColor: '#ef4444', badgeClass: 'grade-mod-severe' },
  { min: 70, max: 90, label: '重度听损 (71–90 dB)', shortLabel: '重度', color: 'rgba(185, 28, 28, 0.12)', borderColor: '#b91c1c', badgeClass: 'grade-severe' },
  { min: 90, max: 110, label: '极重度/全聋 (>90 dB)', shortLabel: '极重度', color: 'rgba(127, 29, 29, 0.15)', borderColor: '#7f1d1d', badgeClass: 'grade-profound' }
];

/**
 * Approximate Speech Banana Polygon (in { freq, topDb, bottomDb }) for Chinese/International conversational speech
 */
export const SPEECH_BANANA_ENVELOPE = [
  { freq: 180, topDb: 28, bottomDb: 52 },
  { freq: 250, topDb: 22, bottomDb: 55 },
  { freq: 500, topDb: 20, bottomDb: 58 },
  { freq: 1000, topDb: 18, bottomDb: 55 },
  { freq: 2000, topDb: 16, bottomDb: 48 },
  { freq: 4000, topDb: 14, bottomDb: 42 },
  { freq: 6000, topDb: 18, bottomDb: 36 }
];

export const SPEECH_PHONEME_MARKERS = [
  { freq: 250, db: 38, text: 'm / n / ng (鼻音)' },
  { freq: 500, db: 42, text: 'a / o / e / u (元音)' },
  { freq: 1000, db: 36, text: 'i / ü / l / r' },
  { freq: 2000, db: 32, text: 'g / k / zh / ch' },
  { freq: 4000, db: 24, text: 'f / s / sh / x (清擦音)' }
];

export const ENVIRONMENTAL_SOUND_MARKERS = [
  { freq: 125, db: 30, text: '远处雷鸣/低频嗡声' },
  { freq: 250, db: 20, text: '滴水声' },
  { freq: 1000, db: 65, text: '正常交谈' },
  { freq: 4000, db: 15, text: '树叶沙沙/鸟鸣' },
  { freq: 8000, db: 20, text: '细微虫鸣' }
];

export const TEST_MIN_DB = -10;
export const TEST_MAX_HARD_DB = 85; // Safe home self-test ceiling to prevent acoustic trauma / recruitment pain
export const STEP_DB = 5;
