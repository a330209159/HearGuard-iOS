/**
 * Clinical Audiogram Analyzer & SSNHL Guideline Evaluator
 * Implements:
 * - PTA-4 (500, 1k, 2k, 4k Hz), Low-Freq Avg (125, 250, 500 Hz), High-Freq Avg (2k, 4k, 8k Hz)
 * - 中华医学会《突发性聋诊断和治疗指南 (2015)》曲线分型参考 (低频下降型 / 高频下降型 / 平坦下降型 / 全聋型)
 * - 相邻两频率 ≥20 dB 突聋特征检测与耳间不对称度计算
 * - 交叉听力 (Shadow Curve) 风险识别
 * - 纵向康复疗效对比计算 (痊愈 / 显效 ≥30dB / 有效 15-30dB / 下降预警)
 */

import { HEARING_SEVERITY_BANDS, HEADPHONE_PROFILES, STANDARD_FREQUENCIES } from './constants.js';

function mean(nums) {
  if (!nums || nums.length === 0) return null;
  return nums.reduce((a, b) => a + b, 0) / nums.length;
}

function round1(val) {
  return val === null || val === undefined || Number.isNaN(val)
    ? null
    : Math.round(val * 10) / 10;
}

export function getSeverityForDb(db) {
  if (db === null || db === undefined || Number.isNaN(db)) {
    return { label: '未测', shortLabel: '未测', badgeClass: 'grade-unknown', borderColor: '#94a3b8' };
  }
  for (const band of HEARING_SEVERITY_BANDS) {
    if (db <= band.max) return band;
  }
  return HEARING_SEVERITY_BANDS[HEARING_SEVERITY_BANDS.length - 1];
}

export function analyzeSingleEar(earData = {}, contralateralData = {}) {
  const entries = Object.entries(earData)
    .map(([f, v]) => ({
      freq: Number(f),
      db: typeof v === 'number' ? v : v?.db,
      noResponse: Boolean(v?.noResponse),
      masked: Boolean(v?.masked)
    }))
    .filter((e) => Number.isFinite(e.db))
    .sort((a, b) => a.freq - b.freq);

  if (entries.length === 0) {
    return {
      hasData: false,
      count: 0,
      pta4: null,
      lowAvg: null,
      highAvg: null,
      fullAvg: null,
      severity: getSeverityForDb(null),
      curveType: '暂无测听数据',
      curveDetail: '完成该侧耳朵纯音测试后将自动生成分型与频段评估。',
      focalWarning: null
    };
  }

  const getVal = (freqs) =>
    entries
      .filter((e) => freqs.includes(e.freq))
      .map((e) => (e.noResponse ? e.db + 5 : e.db));

  const pta4 = round1(mean(getVal([500, 1000, 2000, 4000])));
  const lowAvg = round1(mean(getVal([125, 250, 500])));
  const lowWith1k = round1(mean(getVal([125, 250, 500, 1000])));
  const highAvg = round1(mean(getVal([2000, 4000, 8000])));
  const fullAvg = round1(mean(getVal([250, 500, 1000, 2000, 4000, 8000])));

  const primaryDb = pta4 ?? fullAvg ?? round1(mean(entries.map((e) => e.db)));
  const severity = getSeverityForDb(primaryDb);

  // Check adjacent >= 20 dB loss relative to normal (0-15 dB) or relative to contralateral healthy ear
  let adjacentAbnormalPairs = [];
  for (let i = 0; i < entries.length - 1; i++) {
    const a = entries[i];
    const b = entries[i + 1];
    const oppA = contralateralData?.[a.freq]?.db;
    const oppB = contralateralData?.[b.freq]?.db;
    const lossA = Number.isFinite(oppA) ? Math.max(a.db - 20, a.db - oppA) : a.db;
    const lossB = Number.isFinite(oppB) ? Math.max(b.db - 20, b.db - oppB) : b.db;
    if ((a.db > 25 && b.db > 25) || (lossA >= 20 && lossB >= 20)) {
      adjacentAbnormalPairs.push([a.freq, b.freq]);
    }
  }

  // Curve pattern classification per CMA 2015 SSNHL Guideline
  let curveType = '平坦正常型';
  let curveDetail = '所测各频段听阈均处于正常参考范围（≤25 dB HL），未见明显感音神经性下降特征。';
  let focalWarning = null;

  const maxDb = Math.max(...entries.map((e) => e.db));
  const noRespCount = entries.filter((e) => e.noResponse).length;

  const d250 = earData[250]?.db ?? earData[125]?.db;
  const d500 = earData[500]?.db;
  const d4k = earData[4000]?.db;
  const d8k = earData[8000]?.db;

  const hasLowLoss =
    (lowAvg !== null && lowAvg > 25) ||
    ((d250 ?? 0) >= 25 && (d500 ?? 0) >= 25) ||
    ((earData[125]?.db ?? 0) >= 30 && (d250 ?? 0) >= 25);

  const hasHighLoss =
    (highAvg !== null && highAvg > 25) ||
    ((d4k ?? 0) >= 25 && (d8k ?? 0) >= 25);

  if (maxDb <= 25 && adjacentAbnormalPairs.length === 0) {
    curveType = '各频段基本正常';
    curveDetail = '125 Hz 至 8000 Hz 测听阈值均 ≤25 dB HL。若仍有耳闷、耳鸣或双耳听感不一，请结合对侧耳差值及医院声导抗/耳内镜综合判断。';
  } else if ((fullAvg !== null && fullAvg >= 81) || (noRespCount >= 4 && (fullAvg ?? 85) >= 75)) {
    curveType = '全聋/极重度下降型';
    curveDetail = '全频段重度至极重度听力下降（250–8000 Hz 均值 ≥81 dB HL 或多频点超出安全最大声强）。属耳科急症重点关注类型，请务必在耳鼻喉科专科规范治疗并开启对侧掩蔽复核。';
  } else if (hasLowLoss && (!hasHighLoss || (lowAvg !== null && highAvg !== null && lowAvg - highAvg >= 15))) {
    curveType = '低频下降型（上升型曲线）';
    curveDetail = '主要累及 125–1000 Hz 低频区（常见于耳蜗顶回膜迷路积水型突聋），常伴耳闷胀感、低调轰鸣声或自身回音感。指南统计该分型规范治疗后恢复预后通常最佳。';
    if (pta4 !== null && pta4 <= 25) {
      focalWarning = `注意：虽然标准四频 PTA (${pta4} dB) 看似正常，但低频均值达 ${lowAvg} dB HL，存在典型低频听力受损！`;
    }
  } else if (hasHighLoss && (!hasLowLoss || (highAvg !== null && lowAvg !== null && highAvg - lowAvg >= 15))) {
    curveType = '高频下降型（下降型曲线）';
    curveDetail = '主要累及 2000–8000 Hz 高频区（耳蜗底回受累），常伴随清辅音辨识下降或高调蝉鸣/电流样耳鸣。建议严格避免噪声暴露并坚持临床疗程追踪。';
    if (pta4 !== null && pta4 <= 25) {
      focalWarning = `注意：虽然标准四频 PTA (${pta4} dB) 处于正常边界，但高频均值达 ${highAvg} dB HL，存在高频听力下降！`;
    }
  } else if (hasLowLoss && hasHighLoss) {
    curveType = '平坦下降型（全频受累型）';
    curveDetail = '低频、中频至高频普遍下降（250–8000 Hz 均值 ≤80 dB HL），常见于耳蜗血管纹或内耳微循环供血受累，建议定期复测全频曲线观察低频或中频率先抬升趋势。';
  } else {
    curveType = '局部频点轻度偏移型';
    curveDetail = `部分频点阈值高于 25 dB HL（最高 ${maxDb} dB HL），可点击听力图上的单个频点进行精细复测验证。`;
  }

  return {
    hasData: true,
    count: entries.length,
    pta4,
    lowAvg,
    lowWith1k,
    highAvg,
    fullAvg,
    maxDb,
    severity,
    curveType,
    curveDetail,
    focalWarning,
    adjacentAbnormalPairs
  };
}

/**
 * Full Bilateral Analysis including Interaural Asymmetry & Cross-Hearing Detection
 */
export function analyzeBilateral(results = { left: {}, right: {} }, profileId = 'in_ear') {
  const leftSummary = analyzeSingleEar(results.left || {}, results.right || {});
  const rightSummary = analyzeSingleEar(results.right || {}, results.left || {});

  const ia = HEADPHONE_PROFILES[profileId]?.interauralAttenuation || 45;
  const allFreqs = Array.from(
    new Set([
      ...Object.keys(results.left || {}).map(Number),
      ...Object.keys(results.right || {}).map(Number)
    ])
  ).sort((a, b) => a - b);

  const asymmetries = [];
  const shadowRisks = [];

  for (const f of allFreqs) {
    const l = results.left?.[f];
    const r = results.right?.[f];
    if (l && r && Number.isFinite(l.db) && Number.isFinite(r.db)) {
      const diff = l.db - r.db; // positive => Left ear is worse; negative => Right ear is worse
      const absDiff = Math.abs(diff);
      if (absDiff >= 15) {
        asymmetries.push({
          freq: f,
          worseEar: diff > 0 ? 'left' : 'right',
          diff: absDiff,
          leftDb: l.db,
          rightDb: r.db
        });
      }

      // Cross-hearing check if worse ear was NOT masked and gap >= IA
      const worseObj = diff > 0 ? l : r;
      const worseSide = diff > 0 ? 'left' : 'right';
      if (absDiff >= ia && !worseObj.masked && !worseObj.noResponse) {
        shadowRisks.push({
          freq: f,
          ear: worseSide,
          diff: absDiff,
          ia
        });
      }
    }
  }

  // Check CMA/AAO-HNS diagnostic red flag: >=20 dB interaural asymmetry at >=2 consecutive frequencies
  let consecutive20dB = [];
  for (let i = 0; i < allFreqs.length - 1; i++) {
    const f1 = allFreqs[i];
    const f2 = allFreqs[i + 1];
    const l1 = results.left?.[f1]?.db;
    const r1 = results.right?.[f1]?.db;
    const l2 = results.left?.[f2]?.db;
    const r2 = results.right?.[f2]?.db;
    if ([l1, r1, l2, r2].every(Number.isFinite)) {
      if (l1 - r1 >= 20 && l2 - r2 >= 20) {
        consecutive20dB.push({ ear: 'left', pair: [f1, f2] });
      } else if (r1 - l1 >= 20 && r2 - l2 >= 20) {
        consecutive20dB.push({ ear: 'right', pair: [f1, f2] });
      }
    }
  }

  // Determine suspected primary affected ear
  let affectedEar = null;
  if (leftSummary.hasData && rightSummary.hasData) {
    const lScore = leftSummary.fullAvg ?? leftSummary.pta4 ?? 0;
    const rScore = rightSummary.fullAvg ?? rightSummary.pta4 ?? 0;
    if (lScore - rScore >= 12) affectedEar = 'left';
    else if (rScore - lScore >= 12) affectedEar = 'right';
    else if ((leftSummary.lowAvg ?? 0) - (rightSummary.lowAvg ?? 0) >= 15) affectedEar = 'left';
    else if ((rightSummary.lowAvg ?? 0) - (leftSummary.lowAvg ?? 0) >= 15) affectedEar = 'right';
    else if ((leftSummary.highAvg ?? 0) - (rightSummary.highAvg ?? 0) >= 15) affectedEar = 'left';
    else if ((rightSummary.highAvg ?? 0) - (leftSummary.highAvg ?? 0) >= 15) affectedEar = 'right';
  } else if (leftSummary.hasData && (leftSummary.maxDb ?? 0) > 25) {
    affectedEar = 'left';
  } else if (rightSummary.hasData && (rightSummary.maxDb ?? 0) > 25) {
    affectedEar = 'right';
  }

  return {
    left: leftSummary,
    right: rightSummary,
    affectedEar,
    asymmetries,
    consecutive20dB,
    shadowRisks
  };
}

/**
 * Compare Current Session against a Baseline Session per CMA 2015 SSNHL Efficacy Standard
 * (痊愈 / 显效 >=30dB / 有效 15-30dB / 观察中 <15dB / 波动预警)
 */
export function compareWithBaseline(currentResults, baselineResults) {
  if (!baselineResults || !currentResults) return null;

  const baseBi = analyzeBilateral(baselineResults);
  const targetEars = baseBi.affectedEar ? [baseBi.affectedEar] : ['left', 'right'];

  const earReports = [];

  for (const ear of targetEars) {
    const baseEar = baselineResults[ear] || {};
    const currEar = currentResults[ear] || {};
    const oppBaseEar = baselineResults[ear === 'left' ? 'right' : 'left'] || {};

    const sharedFreqs = Object.keys(baseEar)
      .map(Number)
      .filter((f) => Number.isFinite(baseEar[f]?.db) && Number.isFinite(currEar[f]?.db))
      .sort((a, b) => a - b);

    if (sharedFreqs.length === 0) continue;

    // Identify originally impaired frequencies on baseline (>25 dB HL or >=15 dB worse than healthy ear)
    let impairedFreqs = sharedFreqs.filter((f) => {
      const bDb = baseEar[f].db;
      const oppDb = oppBaseEar[f]?.db;
      return bDb > 25 || (Number.isFinite(oppDb) && bDb - oppDb >= 15);
    });

    if (impairedFreqs.length === 0) {
      impairedFreqs = sharedFreqs;
    }

    const baseMean = mean(impairedFreqs.map((f) => baseEar[f].db));
    const currMean = mean(impairedFreqs.map((f) => currEar[f].db));
    const improvementDb = round1(baseMean - currMean); // Positive = hearing got better (dB HL lowered!)

    const allNormalNow = impairedFreqs.every((f) => {
      const cDb = currEar[f].db;
      const oppDb = currentResults[ear === 'left' ? 'right' : 'left']?.[f]?.db;
      return cDb <= 25 || (Number.isFinite(oppDb) && cDb - oppDb <= 10);
    });

    let grade = '观察稳定期';
    let badgeClass = 'efficacy-stable';
    let summary = '';

    if (allNormalNow && baseMean > 25) {
      grade = '达到临床痊愈参考线';
      badgeClass = 'efficacy-cured';
      summary = `${ear === 'left' ? '左耳' : '右耳'}原先受损频段（${impairedFreqs.join('/')} Hz）已恢复至 ≤25 dB HL 或接近健侧耳水平（平均提升 ${improvementDb > 0 ? '+' : ''}${improvementDb} dB）。`;
    } else if (improvementDb >= 30) {
      grade = '显效（提升 ≥30 dB）';
      badgeClass = 'efficacy-marked';
      summary = `${ear === 'left' ? '左耳' : '右耳'}受损频率平均听阈较基线好转 ${improvementDb} dB，达到指南“显效”参考幅度！`;
    } else if (improvementDb >= 15) {
      grade = '有效（提升 15–30 dB）';
      badgeClass = 'efficacy-effective';
      summary = `${ear === 'left' ? '左耳' : '右耳'}受损频率平均听阈较基线好转 ${improvementDb} dB，达到指南“有效”改善区间，听力曲线正在抬升。`;
    } else if (improvementDb <= -15) {
      grade = '阈值下移预警（波动 ≥15 dB）';
      badgeClass = 'efficacy-worse';
      summary = `${ear === 'left' ? '左耳' : '右耳'}测得阈值较对比基线下降 ${Math.abs(improvementDb)} dB。请先排查耳机贴合度与系统音量是否一致；若确感耳闷加重或听力下降，请尽快复诊耳鼻喉科！`;
    } else {
      grade = '小幅波动 / 恢复观察中';
      badgeClass = 'efficacy-stable';
      summary = `${ear === 'left' ? '左耳' : '右耳'}受损频段较对比基线平均变化 ${improvementDb > 0 ? '+' : ''}${improvementDb} dB（<15 dB 常见于居家复测误差或平台期，请遵医嘱坚持疗程）。`;
    }

    earReports.push({
      ear,
      impairedFreqs,
      baseMean: round1(baseMean),
      currMean: round1(currMean),
      improvementDb,
      grade,
      badgeClass,
      summary
    });
  }

  return earReports.length > 0 ? earReports : null;
}

export function normalizeStandardFreqArray(earData) {
  return STANDARD_FREQUENCIES.map((f) => earData?.[f]?.db ?? null);
}
