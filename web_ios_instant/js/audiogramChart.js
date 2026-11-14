/**
 * High-DPI Clinical Bilateral Pure-Tone Audiogram Renderer & Report Image Exporter
 * Conforms to ISO 8253-1 / ASHA / 中华医学会纯音听力图绘制规范:
 * - X-Axis: Logarithmic Octave Scale (125 Hz -> 8000 Hz, low-to-high)
 * - Y-Axis: Hearing Level (-10 dB HL top -> 100 dB HL bottom)
 * - Right Ear: Red (#DC2626) Circle 'O' (unmasked) / Triangle '△' (masked)
 * - Left Ear: Blue (#2563EB) Cross '✕' (unmasked) / Square '□' (masked)
 * - Supports WHO severity bands, Speech Banana, Interaural Asymmetry shading, Baseline overlay, and PNG report export.
 */

import {
  STANDARD_FREQUENCIES,
  EXTENDED_FREQUENCIES,
  HEARING_SEVERITY_BANDS,
  SPEECH_BANANA_ENVELOPE,
  SPEECH_PHONEME_MARKERS,
  HEADPHONE_PROFILES
} from './constants.js';
import { analyzeBilateral } from './clinicalAnalyzer.js';

const MIN_FREQ = 125;
const MAX_FREQ = 8000;
const MIN_DB = -10;
const MAX_DB = 100;

const COLOR_RIGHT = '#dc2626'; // Clinical Red (Right = Red = Round)
const COLOR_LEFT = '#2563eb'; // Clinical Blue (Left = Blue = X)

export class AudiogramChart {
  constructor(canvas, options = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.results = { left: {}, right: {} };
    this.baselineResults = null;
    this.baselineLabel = '对比基线';

    this.options = {
      showSeverityBands: true,
      showSpeechBanana: false,
      showAsymmetryShade: true,
      showExtendedGrid: false,
      interactive: true,
      activeHighlight: null, // { ear, freq } during live testing
      onPointClick: null,
      ...options
    };

    this.hoverFreq = null;
    this.hitTargets = [];
    this.layout = null;

    if (this.options.interactive) {
      this._bindEvents();
    }
  }

  setData(results, baselineResults = this.baselineResults, baselineLabel = this.baselineLabel) {
    this.results = results || { left: {}, right: {} };
    this.baselineResults = baselineResults;
    this.baselineLabel = baselineLabel || '对比基线';
    this.render();
  }

  setOptions(partial) {
    Object.assign(this.options, partial);
    this.render();
  }

  _bindEvents() {
    const getPos = (evt) => {
      const rect = this.canvas.getBoundingClientRect();
      const clientX = evt.touches ? evt.touches[0].clientX : evt.clientX;
      const clientY = evt.touches ? evt.touches[0].clientY : evt.clientY;
      return { x: clientX - rect.left, y: clientY - rect.top };
    };

    this.canvas.addEventListener('mousemove', (e) => {
      if (!this.layout) return;
      const { x, y } = getPos(e);
      const nearest = this._findNearestFrequency(x, y);
      if (nearest !== this.hoverFreq) {
        this.hoverFreq = nearest;
        this.canvas.style.cursor = nearest ? 'pointer' : 'default';
        this.render();
      }
    });

    this.canvas.addEventListener('mouseleave', () => {
      if (this.hoverFreq !== null) {
        this.hoverFreq = null;
        this.render();
      }
    });

    this.canvas.addEventListener('click', (e) => {
      if (!this.layout || !this.options.onPointClick) return;
      const { x, y } = getPos(e);
      // Check exact symbol hit first
      let bestHit = null;
      let bestDist = 26;
      for (const t of this.hitTargets) {
        const d = Math.hypot(t.x - x, t.y - y);
        if (d < bestDist) {
          bestDist = d;
          bestHit = t;
        }
      }
      if (bestHit) {
        this.options.onPointClick({
          freq: bestHit.freq,
          ear: bestHit.ear,
          point: bestHit.point
        });
        return;
      }
      const freq = this._findNearestFrequency(x, y);
      if (freq) {
        this.options.onPointClick({
          freq,
          ear: null,
          point: null
        });
      }
    });
  }

  _findNearestFrequency(x, y) {
    const L = this.layout;
    if (!L) return null;
    if (x < L.left - 18 || x > L.right + 18 || y < L.top - 18 || y > L.bottom + 18) {
      return null;
    }
    const candidateFreqs = this._getActiveFrequencyGrid();
    let bestF = null;
    let bestDx = 28;
    for (const f of candidateFreqs) {
      const fx = this._freqToX(f, L);
      const dx = Math.abs(fx - x);
      if (dx < bestDx) {
        bestDx = dx;
        bestF = f;
      }
    }
    return bestF;
  }

  _getActiveFrequencyGrid() {
    const hasInterOctave = [750, 1500, 3000, 6000].some(
      (f) =>
        this.results?.left?.[f] !== undefined ||
        this.results?.right?.[f] !== undefined ||
        this.baselineResults?.left?.[f] !== undefined ||
        this.baselineResults?.right?.[f] !== undefined
    );
    return this.options.showExtendedGrid || hasInterOctave
      ? EXTENDED_FREQUENCIES
      : STANDARD_FREQUENCIES;
  }

  _freqToX(freq, L) {
    const totalOctaves = Math.log2(MAX_FREQ / MIN_FREQ); // log2(8000/125) = 6 octaves
    const oct = Math.log2(freq / MIN_FREQ);
    return L.left + (oct / totalOctaves) * L.width;
  }

  _dbToY(db, L) {
    const clamped = Math.max(MIN_DB, Math.min(MAX_DB, db));
    return L.top + ((clamped - MIN_DB) / (MAX_DB - MIN_DB)) * L.height;
  }

  render() {
    const rect = this.canvas.getBoundingClientRect();
    const cssWidth = Math.max(320, rect.width || 720);
    const cssHeight = Math.max(340, rect.height || 460);
    const dpr = Math.min(3, window.devicePixelRatio || 1);

    if (this.canvas.width !== Math.round(cssWidth * dpr) || this.canvas.height !== Math.round(cssHeight * dpr)) {
      this.canvas.width = Math.round(cssWidth * dpr);
      this.canvas.height = Math.round(cssHeight * dpr);
    }

    const ctx = this.ctx;
    ctx.save();
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, cssWidth, cssHeight);

    const padLeft = cssWidth < 480 ? 48 : 64;
    const padRight = cssWidth < 480 ? 26 : 86;
    const padTop = 52;
    const padBottom = 44;

    const L = {
      left: padLeft,
      right: cssWidth - padRight,
      top: padTop,
      bottom: cssHeight - padBottom,
      width: cssWidth - padLeft - padRight,
      height: cssHeight - padTop - padBottom,
      cssWidth,
      cssHeight
    };
    this.layout = L;
    this.hitTargets = [];

    this._drawPlotCore(ctx, L);
    ctx.restore();
  }

  _drawPlotCore(ctx, L) {
    // 1. Background surface
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, L.cssWidth, L.cssHeight);

    // 2. Severity Color Bands
    if (this.options.showSeverityBands) {
      for (const band of HEARING_SEVERITY_BANDS) {
        const bMin = Math.max(MIN_DB, band.min);
        const bMax = Math.min(MAX_DB, band.max);
        if (bMax <= bMin) continue;
        const y1 = this._dbToY(bMin, L);
        const y2 = this._dbToY(bMax, L);
        ctx.fillStyle = band.color;
        ctx.fillRect(L.left, y1, L.width, y2 - y1);

        // Right-side clinical severity tag if wide enough
        if (L.cssWidth >= 480) {
          ctx.fillStyle = band.borderColor;
          ctx.font = '600 11px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
          ctx.textAlign = 'left';
          ctx.textBaseline = 'middle';
          ctx.fillText(band.shortLabel, L.right + 8, (y1 + y2) / 2);
        }
      }
    }

    // 3. Speech Banana Overlay
    if (this.options.showSpeechBanana) {
      this._drawSpeechBanana(ctx, L);
    }

    // 4. Grid Lines (dB Horizontal + Frequency Vertical)
    for (let db = MIN_DB; db <= MAX_DB; db += 5) {
      const y = this._dbToY(db, L);
      const isMajor = db % 10 === 0;
      ctx.beginPath();
      ctx.moveTo(L.left, y);
      ctx.lineTo(L.right, y);
      if (db === 0) {
        ctx.strokeStyle = '#334155';
        ctx.lineWidth = 1.6;
        ctx.setLineDash([]);
      } else if (db === 25) {
        // Clinical normal cutoff line (25 dB HL)
        ctx.strokeStyle = '#059669';
        ctx.lineWidth = 1.3;
        ctx.setLineDash([5, 4]);
      } else if (isMajor) {
        ctx.strokeStyle = '#cbd5e1';
        ctx.lineWidth = 1.0;
        ctx.setLineDash([]);
      } else {
        ctx.strokeStyle = '#f1f5f9';
        ctx.lineWidth = 0.8;
        ctx.setLineDash([]);
      }
      ctx.stroke();
      ctx.setLineDash([]);

      if (isMajor) {
        ctx.fillStyle = db === 0 ? '#0f172a' : '#475569';
        ctx.font = `${db === 0 ? '700' : '500'} 11.5px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif`;
        ctx.textAlign = 'right';
        ctx.textBaseline = 'middle';
        ctx.fillText(`${db}`, L.left - 10, y);
      }
    }

    // Frequency vertical grid (125 -> 8000 Hz)
    const gridFreqs = this._getActiveFrequencyGrid();
    for (const freq of gridFreqs) {
      const x = this._freqToX(freq, L);
      const isStandard = STANDARD_FREQUENCIES.includes(freq);
      const isHovered = this.hoverFreq === freq;
      const isLiveActive = this.options.activeHighlight?.freq === freq;

      ctx.beginPath();
      ctx.moveTo(x, L.top);
      ctx.lineTo(x, L.bottom);
      if (isLiveActive) {
        ctx.strokeStyle = 'rgba(14, 165, 233, 0.65)';
        ctx.lineWidth = 2.2;
        ctx.setLineDash([]);
      } else if (isHovered) {
        ctx.strokeStyle = '#64748b';
        ctx.lineWidth = 1.5;
        ctx.setLineDash([]);
      } else if (isStandard) {
        ctx.strokeStyle = '#cbd5e1';
        ctx.lineWidth = 1.0;
        ctx.setLineDash([]);
      } else {
        ctx.strokeStyle = '#e2e8f0';
        ctx.lineWidth = 0.9;
        ctx.setLineDash([4, 4]);
      }
      ctx.stroke();
      ctx.setLineDash([]);

      // Top & Bottom frequency labels (Clinical audiograms place Hz along top header!)
      const label = freq >= 1000 ? `${freq / 1000}k` : `${freq}`;
      ctx.fillStyle = isStandard ? '#0f172a' : '#64748b';
      ctx.font = `${isStandard ? '700' : '500'} ${isStandard ? '12px' : '10.5px'} -apple-system, BlinkMacSystemFont, sans-serif`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'bottom';
      ctx.fillText(label, x, L.top - 9);

      ctx.fillStyle = isStandard ? '#475569' : '#94a3b8';
      ctx.textBaseline = 'top';
      ctx.fillText(freq >= 1000 && L.cssWidth >= 540 ? `${freq}` : label, x, L.bottom + 9);
    }

    // Plot border
    ctx.strokeStyle = '#64748b';
    ctx.lineWidth = 1.4;
    ctx.strokeRect(L.left, L.top, L.width, L.height);

    // Axis titles
    ctx.fillStyle = '#334155';
    ctx.font = '600 12px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.fillText('频率 (Hz) · 低频 → 高频', L.left, 10);

    // Legend top-right
    this._drawTopLegend(ctx, L);

    // Y-axis rotated label
    ctx.save();
    ctx.translate(15, L.top + L.height / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.fillStyle = '#475569';
    ctx.font = '600 11.5px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('听力级 Hearing Level (dB HL)', 0, 0);
    ctx.restore();

    // 5. Interaural Asymmetry Shading (highlights gap between Left & Right ears)
    if (this.options.showAsymmetryShade) {
      this._drawAsymmetryShading(ctx, L);
    }

    // 6. Baseline Overlay Curve (if comparing with past/hospital session)
    if (this.baselineResults) {
      this._drawEarCurve(ctx, L, this.baselineResults.right, 'right', true);
      this._drawEarCurve(ctx, L, this.baselineResults.left, 'left', true);
    }

    // 7. Primary Right & Left Ear Curves & Clinical Symbols
    this._drawEarCurve(ctx, L, this.results?.right, 'right', false);
    this._drawEarCurve(ctx, L, this.results?.left, 'left', false);

    // 8. Empty State Prompt if no points yet
    const hasAny =
      Object.keys(this.results?.left || {}).length > 0 ||
      Object.keys(this.results?.right || {}).length > 0;
    if (!hasAny && !this.baselineResults) {
      ctx.fillStyle = 'rgba(255, 255, 255, 0.86)';
      const boxW = Math.min(340, L.width - 24);
      const boxH = 74;
      const bx = L.left + (L.width - boxW) / 2;
      const by = L.top + (L.height - boxH) / 2;
      ctx.fillRect(bx, by, boxW, boxH);
      ctx.strokeStyle = '#cbd5e1';
      ctx.lineWidth = 1;
      ctx.strokeRect(bx, by, boxW, boxH);

      ctx.fillStyle = '#334155';
      ctx.font = '600 13px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText('等待测听数据 (125 Hz → 8000 Hz)', bx + boxW / 2, by + 26);
      ctx.fillStyle = '#64748b';
      ctx.font = '400 12px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
      ctx.fillText('完成左/右耳测试后将实时绘制标准纯音听力曲线', bx + boxW / 2, by + 50);
    }

    // 9. Interactive Hover Tooltip
    if (this.hoverFreq && hasAny) {
      this._drawHoverTooltip(ctx, L, this.hoverFreq);
    }
  }

  _drawTopLegend(ctx, L) {
    const rightX = L.right;
    const y = 17;
    ctx.font = '600 12px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.textBaseline = 'middle';

    // Left Ear X (Blue)
    const leftLabel = '左耳 (✕ 蓝)';
    const rightLabel = '右耳 (O 红)';
    ctx.textAlign = 'right';
    ctx.fillStyle = COLOR_LEFT;
    ctx.fillText(leftLabel, rightX, y);

    const wLeft = ctx.measureText(leftLabel).width;
    ctx.fillStyle = COLOR_RIGHT;
    ctx.fillText(rightLabel, rightX - wLeft - 16, y);

    if (this.baselineResults && L.cssWidth >= 560) {
      const wRight = ctx.measureText(rightLabel).width;
      ctx.fillStyle = '#64748b';
      ctx.font = '500 11.5px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
      ctx.fillText(`--- ${this.baselineLabel}`, rightX - wLeft - wRight - 30, y);
    }
  }

  _drawSpeechBanana(ctx, L) {
    ctx.save();
    ctx.beginPath();
    SPEECH_BANANA_ENVELOPE.forEach((pt, idx) => {
      const x = this._freqToX(pt.freq, L);
      const y = this._dbToY(pt.topDb, L);
      if (idx === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    for (let i = SPEECH_BANANA_ENVELOPE.length - 1; i >= 0; i--) {
      const pt = SPEECH_BANANA_ENVELOPE[i];
      const x = this._freqToX(pt.freq, L);
      const y = this._dbToY(pt.bottomDb, L);
      ctx.lineTo(x, y);
    }
    ctx.closePath();
    ctx.fillStyle = 'rgba(250, 204, 21, 0.20)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(202, 138, 4, 0.55)';
    ctx.lineWidth = 1.3;
    ctx.setLineDash([4, 3]);
    ctx.stroke();
    ctx.setLineDash([]);

    ctx.fillStyle = '#854d0e';
    ctx.font = '600 11px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    for (const m of SPEECH_PHONEME_MARKERS) {
      const mx = this._freqToX(m.freq, L);
      const my = this._dbToY(m.db, L);
      ctx.fillText(m.text, mx, my);
    }
    ctx.restore();
  }

  _drawAsymmetryShading(ctx, L) {
    const leftMap = this.results?.left || {};
    const rightMap = this.results?.right || {};
    const shared = Object.keys(leftMap)
      .map(Number)
      .filter((f) => Number.isFinite(leftMap[f]?.db) && Number.isFinite(rightMap[f]?.db))
      .sort((a, b) => a - b);

    if (shared.length < 2) return;

    const maxDiff = Math.max(...shared.map((f) => Math.abs(leftMap[f].db - rightMap[f].db)));
    if (maxDiff < 15) return;

    ctx.save();
    ctx.beginPath();
    shared.forEach((f, i) => {
      const x = this._freqToX(f, L);
      const y = this._dbToY(leftMap[f].db, L);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    for (let i = shared.length - 1; i >= 0; i--) {
      const f = shared[i];
      const x = this._freqToX(f, L);
      const y = this._dbToY(rightMap[f].db, L);
      ctx.lineTo(x, y);
    }
    ctx.closePath();
    ctx.fillStyle = 'rgba(139, 92, 246, 0.10)';
    ctx.fill();
    ctx.restore();
  }

  _drawEarCurve(ctx, L, earData = {}, ear = 'right', isBaseline = false) {
    if (!earData) return;
    const points = Object.entries(earData)
      .map(([f, v]) => ({
        freq: Number(f),
        db: typeof v === 'number' ? v : v?.db,
        noResponse: Boolean(v?.noResponse),
        masked: Boolean(v?.masked),
        lowConfidence: Boolean(v?.lowConfidence)
      }))
      .filter((p) => Number.isFinite(p.db) && p.freq >= MIN_FREQ && p.freq <= MAX_FREQ)
      .sort((a, b) => a.freq - b.freq);

    if (points.length === 0) return;

    const color = ear === 'right' ? COLOR_RIGHT : COLOR_LEFT;
    ctx.save();
    ctx.strokeStyle = color;
    ctx.fillStyle = color;
    ctx.globalAlpha = isBaseline ? 0.36 : 1.0;

    // Connect adjacent responsive points with clinical line (ISO 8253-1: do not connect through NR points with solid line)
    ctx.lineWidth = isBaseline ? 1.8 : 2.5;
    if (isBaseline) {
      ctx.setLineDash([6, 4]);
    } else if (ear === 'left') {
      ctx.setLineDash([]); // Crisp solid blue line; symbols clearly distinguish O vs X
    }

    ctx.beginPath();
    let penDown = false;
    for (const pt of points) {
      const x = this._freqToX(pt.freq, L);
      const y = this._dbToY(pt.db, L);
      if (pt.noResponse && !isBaseline) {
        penDown = false;
        continue;
      }
      if (!penDown) {
        ctx.moveTo(x, y);
        penDown = true;
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.stroke();
    ctx.setLineDash([]);

    // Draw standard clinical symbols at each frequency
    for (const pt of points) {
      const x = this._freqToX(pt.freq, L);
      const y = this._dbToY(pt.db, L);
      const size = isBaseline ? 5.2 : 7.2;

      if (!isBaseline) {
        // Subtle white halo behind symbol for crisp legibility over grid lines
        ctx.save();
        ctx.beginPath();
        ctx.arc(x, y, size + 2.5, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(255,255,255,0.82)';
        ctx.fill();
        ctx.restore();
      }

      ctx.lineWidth = isBaseline ? 1.8 : 2.4;
      ctx.strokeStyle = color;

      if (ear === 'right') {
        if (pt.masked) {
          // Masked Right Air Conduction: Open Triangle '△'
          ctx.beginPath();
          ctx.moveTo(x, y - size - 1);
          ctx.lineTo(x - size - 0.5, y + size * 0.85);
          ctx.lineTo(x + size + 0.5, y + size * 0.85);
          ctx.closePath();
          ctx.stroke();
        } else {
          // Unmasked Right Air Conduction: Open Circle 'O'
          ctx.beginPath();
          ctx.arc(x, y, size, 0, Math.PI * 2);
          ctx.stroke();
        }
      } else {
        if (pt.masked) {
          // Masked Left Air Conduction: Open Square '□'
          ctx.strokeRect(x - size + 0.5, y - size + 0.5, (size - 0.5) * 2, (size - 0.5) * 2);
        } else {
          // Unmasked Left Air Conduction: Cross '✕'
          const s = size * 0.88;
          ctx.beginPath();
          ctx.moveTo(x - s, y - s);
          ctx.lineTo(x + s, y + s);
          ctx.moveTo(x + s, y - s);
          ctx.lineTo(x - s, y + s);
          ctx.stroke();
        }
      }

      // Clinical No-Response downward diagonal arrow
      if (pt.noResponse) {
        const dir = ear === 'right' ? 1 : -1;
        const ax1 = x + dir * (size * 0.7);
        const ay1 = y + size * 0.7;
        const ax2 = x + dir * (size * 1.9);
        const ay2 = y + size * 1.9;
        ctx.beginPath();
        ctx.moveTo(ax1, ay1);
        ctx.lineTo(ax2, ay2);
        ctx.lineTo(ax2 - dir * 4.5, ay2 - 1);
        ctx.moveTo(ax2, ay2);
        ctx.lineTo(ax2 - dir * 1, ay2 - 4.5);
        ctx.stroke();
      }

      if (!isBaseline) {
        this.hitTargets.push({ x, y, freq: pt.freq, ear, point: pt });
      }
    }

    ctx.restore();
  }

  _drawHoverTooltip(ctx, L, freq) {
    const lPt = this.results?.left?.[freq];
    const rPt = this.results?.right?.[freq];
    if (!lPt && !rPt) return;

    const fx = this._freqToX(freq, L);
    const lines = [`频率: ${freq} Hz`];
    if (rPt) {
      lines.push(`右耳 (O): ${rPt.noResponse ? '>' : ''}${rPt.db} dB HL${rPt.masked ? ' [掩蔽]' : ''}`);
    }
    if (lPt) {
      lines.push(`左耳 (✕): ${lPt.noResponse ? '>' : ''}${lPt.db} dB HL${lPt.masked ? ' [掩蔽]' : ''}`);
    }
    if (lPt && rPt) {
      const diff = Math.abs(lPt.db - rPt.db);
      lines.push(`双耳差值: ${diff} dB`);
    }
    if (this.options.onPointClick) {
      lines.push('点击可试听或微调此频点');
    }

    ctx.save();
    ctx.font = '500 11.5px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    const boxW = Math.max(...lines.map((s) => ctx.measureText(s).width)) + 22;
    const lineH = 18;
    const boxH = lines.length * lineH + 14;

    let bx = fx + 14;
    if (bx + boxW > L.right) bx = fx - boxW - 14;
    bx = Math.max(L.left + 4, bx);
    const by = L.top + 12;

    ctx.fillStyle = 'rgba(15, 23, 42, 0.92)';
    ctx.beginPath();
    if (ctx.roundRect) {
      ctx.roundRect(bx, by, boxW, boxH, 8);
    } else {
      ctx.rect(bx, by, boxW, boxH);
    }
    ctx.fill();

    lines.forEach((line, idx) => {
      if (idx === 0) ctx.fillStyle = '#f8fafc';
      else if (line.startsWith('右耳')) ctx.fillStyle = '#fca5a5';
      else if (line.startsWith('左耳')) ctx.fillStyle = '#93c5fd';
      else if (line.startsWith('点击')) ctx.fillStyle = '#38bdf8';
      else ctx.fillStyle = '#cbd5e1';

      ctx.font = `${idx === 0 ? '700' : '500'} 11.5px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif`;
      ctx.textAlign = 'left';
      ctx.textBaseline = 'top';
      ctx.fillText(line, bx + 11, by + 8 + idx * lineH);
    });
    ctx.restore();
  }

  /**
   * Generate a comprehensive High-DPI (1600x1160) Medical Audiogram Report PNG DataURL
   */
  exportReportPng(meta = {}) {
    const offCanvas = document.createElement('canvas');
    const W = 1400;
    const H = 1040;
    offCanvas.width = W;
    offCanvas.height = H;
    const ctx = offCanvas.getContext('2d');

    // Card Background
    ctx.fillStyle = '#f8fafc';
    ctx.fillRect(0, 0, W, H);

    // Header Banner
    ctx.fillStyle = '#0f172a';
    ctx.fillRect(0, 0, W, 92);
    ctx.fillStyle = '#ffffff';
    ctx.font = '700 26px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText('纯音测听曲线与突发性耳聋居家随访报告', 40, 36);

    const dateStr = meta.dateStr || new Date().toLocaleString('zh-CN');
    const hpName = HEADPHONE_PROFILES[meta.profileId]?.name || '标准校准耳机';
    ctx.fillStyle = '#94a3b8';
    ctx.font = '500 14px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.fillText(`测听时间：${dateStr}   |   耳机配置：${hpName}   |   低频→高频标准序列 (125Hz–8000Hz)`, 40, 68);

    // Audiogram Sub-Panel
    const chartBox = { x: 40, y: 114, w: 860, h: 610 };
    ctx.save();
    ctx.translate(chartBox.x, chartBox.y);
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, chartBox.w, chartBox.h);
    const subLayout = {
      left: 68,
      right: chartBox.w - 86,
      top: 54,
      bottom: chartBox.h - 46,
      width: chartBox.w - 154,
      height: chartBox.h - 100,
      cssWidth: chartBox.w,
      cssHeight: chartBox.h
    };
    const prevHover = this.hoverFreq;
    this.hoverFreq = null;
    this._drawPlotCore(ctx, subLayout);
    this.hoverFreq = prevHover;
    ctx.strokeStyle = '#e2e8f0';
    ctx.lineWidth = 1.5;
    ctx.strokeRect(0, 0, chartBox.w, chartBox.h);
    ctx.restore();

    // Right-Side Clinical Summary Panel
    const analysis = analyzeBilateral(this.results, meta.profileId);
    const panelX = 924;
    const panelW = W - panelX - 40;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(panelX, 114, panelW, 610);
    ctx.strokeStyle = '#e2e8f0';
    ctx.strokeRect(panelX, 114, panelW, 610);

    const drawEarCard = (earTitle, color, sum, startY) => {
      ctx.fillStyle = color;
      ctx.font = '700 19px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
      ctx.textAlign = 'left';
      ctx.fillText(earTitle, panelX + 24, startY);

      ctx.fillStyle = '#334155';
      ctx.font = '600 15px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
      const ptaTxt = sum.pta4 !== null ? `${sum.pta4} dB HL (${sum.severity.shortLabel})` : '未测';
      const lowTxt = sum.lowAvg !== null ? `${sum.lowAvg} dB` : '--';
      const highTxt = sum.highAvg !== null ? `${sum.highAvg} dB` : '--';
      ctx.fillText(`四频平均 PTA: ${ptaTxt}`, panelX + 24, startY + 30);
      ctx.fillStyle = '#475569';
      ctx.font = '500 14px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
      ctx.fillText(`低频均值 (125-500Hz): ${lowTxt}  |  高频均值 (2k-8kHz): ${highTxt}`, panelX + 24, startY + 56);
      ctx.fillStyle = '#0f172a';
      ctx.font = '600 14.5px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
      ctx.fillText(`曲线特征: ${sum.curveType}`, panelX + 24, startY + 84);

      // Wrap detail text
      ctx.fillStyle = '#64748b';
      ctx.font = '400 13px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
      this._wrapCanvasText(ctx, sum.curveDetail, panelX + 24, startY + 110, panelW - 48, 20);
    };

    drawEarCard('右耳评估 (Right Ear · O)', COLOR_RIGHT, analysis.right, 152);

    ctx.beginPath();
    ctx.moveTo(panelX + 24, 405);
    ctx.lineTo(panelX + panelW - 24, 405);
    ctx.strokeStyle = '#e2e8f0';
    ctx.stroke();

    drawEarCard('左耳评估 (Left Ear · ✕)', COLOR_LEFT, analysis.left, 438);

    // Bottom Threshold Table (125 Hz -> 8000 Hz)
    const tableY = 748;
    const tableW = W - 80;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(40, tableY, tableW, 185);
    ctx.strokeStyle = '#e2e8f0';
    ctx.strokeRect(40, tableY, tableW, 185);

    const freqs = this._getActiveFrequencyGrid();
    const labelColW = 160;
    const colW = (tableW - labelColW) / freqs.length;

    const rows = [
      { label: '频率 (Hz)', bg: '#f1f5f9', color: '#0f172a', bold: true },
      { label: '右耳 O (dB HL)', bg: '#ffffff', color: COLOR_RIGHT, bold: true },
      { label: '左耳 ✕ (dB HL)', bg: '#f8fafc', color: COLOR_LEFT, bold: true },
      { label: '双耳差值 |L-R|', bg: '#ffffff', color: '#475569', bold: false }
    ];

    rows.forEach((r, rIdx) => {
      const ry = tableY + rIdx * 45;
      ctx.fillStyle = r.bg;
      ctx.fillRect(41, ry + 1, tableW - 2, 44);
      ctx.fillStyle = r.color;
      ctx.font = `${r.bold ? '700' : '600'} 14px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif`;
      ctx.textAlign = 'left';
      ctx.textBaseline = 'middle';
      ctx.fillText(r.label, 58, ry + 23);

      freqs.forEach((f, cIdx) => {
        const cx = 40 + labelColW + cIdx * colW + colW / 2;
        let valTxt = '--';
        if (rIdx === 0) {
          valTxt = `${f}`;
        } else if (rIdx === 1) {
          const p = this.results?.right?.[f];
          if (p) valTxt = `${p.noResponse ? '>' : ''}${p.db}${p.masked ? '△' : ''}`;
        } else if (rIdx === 2) {
          const p = this.results?.left?.[f];
          if (p) valTxt = `${p.noResponse ? '>' : ''}${p.db}${p.masked ? '□' : ''}`;
        } else {
          const pl = this.results?.left?.[f];
          const pr = this.results?.right?.[f];
          if (pl && pr) valTxt = `${Math.abs(pl.db - pr.db)} dB`;
        }
        ctx.textAlign = 'center';
        ctx.fillText(valTxt, cx, ry + 23);
      });
    });

    // Note & Medical Disclaimer Footer
    ctx.fillStyle = '#475569';
    ctx.font = '500 13px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.textAlign = 'left';
    const noteLine = meta.note ? `症状与治疗备注：${meta.note}` : '症状与治疗备注：（未填写）';
    ctx.fillText(noteLine, 40, 962);

    ctx.fillStyle = '#94a3b8';
    ctx.font = '400 12.5px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.fillText(
      '医学声明：本图表由居家校准纯音测听系统生成，仅用于突发性耳聋康复趋势自我监测与复诊沟通参考，不可替代医院标准隔声室纯音测听与声导抗诊断。',
      40,
      995
    );

    return offCanvas.toDataURL('image/png');
  }

  _wrapCanvasText(ctx, text, x, y, maxWidth, lineHeight) {
    const chars = Array.from(text || '');
    let line = '';
    let currY = y;
    for (let i = 0; i < chars.length; i++) {
      const testLine = line + chars[i];
      if (ctx.measureText(testLine).width > maxWidth && line.length > 0) {
        ctx.fillText(line, x, currY);
        line = chars[i];
        currY += lineHeight;
      } else {
        line = testLine;
      }
    }
    if (line) ctx.fillText(line, x, currY);
  }
}

/**
 * Render Longitudinal Recovery Trend Chart across saved sessions
 */
export function renderRecoveryTrendChart(canvas, sessions = [], targetEar = 'affected') {
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const rect = canvas.getBoundingClientRect();
  const cssW = Math.max(300, rect.width || 680);
  const cssH = Math.max(220, rect.height || 260);
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  canvas.width = Math.round(cssW * dpr);
  canvas.height = Math.round(cssH * dpr);

  ctx.save();
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, cssW, cssH);
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, cssW, cssH);

  const chronological = [...sessions].sort((a, b) => a.timestamp - b.timestamp);
  if (chronological.length < 2) {
    ctx.fillStyle = '#64748b';
    ctx.font = '500 13px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText('保存 ≥2 次测听记录后，将在此绘制低频/高频/PTA 纵向恢复曲线（越往上代表听力越好）', cssW / 2, cssH / 2);
    ctx.restore();
    return;
  }

  // Pick ear to plot
  let ear = targetEar;
  if (ear === 'affected') {
    const firstBi = analyzeBilateral(chronological[0].results);
    ear = firstBi.affectedEar || 'left';
  }

  const L = { left: 54, right: cssW - 28, top: 38, bottom: cssH - 36 };
  L.width = L.right - L.left;
  L.height = L.bottom - L.top;

  // Inverted Y (-10 dB top to 90 dB bottom, higher on chart = better hearing!)
  const dbToY = (db) => L.top + ((Math.max(-10, Math.min(90, db)) - -10) / 100) * L.height;

  for (let db = 0; db <= 80; db += 20) {
    const y = dbToY(db);
    ctx.beginPath();
    ctx.moveTo(L.left, y);
    ctx.lineTo(L.right, y);
    ctx.strokeStyle = db === 20 ? 'rgba(16, 185, 129, 0.45)' : '#e2e8f0';
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.fillStyle = '#64748b';
    ctx.font = '500 11px -apple-system, sans-serif';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    ctx.fillText(`${db} dB`, L.left - 8, y);
  }

  const seriesDefs = [
    { key: 'lowAvg', label: '低频均值 (125-500Hz)', color: '#0ea5e9' },
    { key: 'pta4', label: '标准四频 PTA', color: ear === 'right' ? '#dc2626' : '#2563eb' },
    { key: 'highAvg', label: '高频均值 (2k-8kHz)', color: '#f59e0b' }
  ];

  // Header legend
  ctx.textAlign = 'left';
  ctx.textBaseline = 'middle';
  ctx.font = '600 12px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
  ctx.fillStyle = '#0f172a';
  ctx.fillText(`${ear === 'left' ? '左耳' : '右耳'}恢复趋势 (曲线向上抬升 = 听阈好转)`, L.left, 16);

  let lx = L.right;
  for (let i = seriesDefs.length - 1; i >= 0; i--) {
    const s = seriesDefs[i];
    ctx.font = '600 11px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif';
    ctx.textAlign = 'right';
    ctx.fillStyle = s.color;
    ctx.fillText(`● ${s.label}`, lx, 16);
    lx -= ctx.measureText(`● ${s.label}`).width + 14;
  }

  chronological.forEach((sess, idx) => {
    const x = L.left + (idx / (chronological.length - 1)) * L.width;
    const d = new Date(sess.timestamp);
    const lbl = `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
    ctx.fillStyle = '#64748b';
    ctx.font = '500 10.5px -apple-system, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    if (chronological.length <= 7 || idx === 0 || idx === chronological.length - 1 || idx % 2 === 0) {
      ctx.fillText(lbl, x, L.bottom + 8);
    }
  });

  for (const s of seriesDefs) {
    ctx.beginPath();
    ctx.strokeStyle = s.color;
    ctx.lineWidth = 2.2;
    let started = false;
    const pts = [];
    chronological.forEach((sess, idx) => {
      const sum = analyzeBilateral(sess.results)[ear];
      const val = sum?.[s.key];
      if (val !== null && val !== undefined) {
        const x = L.left + (idx / (chronological.length - 1)) * L.width;
        const y = dbToY(val);
        pts.push({ x, y, val });
        if (!started) {
          ctx.moveTo(x, y);
          started = true;
        } else {
          ctx.lineTo(x, y);
        }
      }
    });
    ctx.stroke();

    for (const p of pts) {
      ctx.beginPath();
      ctx.arc(p.x, p.y, 4, 0, Math.PI * 2);
      ctx.fillStyle = s.color;
      ctx.fill();
    }
  }

  ctx.restore();
}
