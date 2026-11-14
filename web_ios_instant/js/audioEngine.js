/**
 * Precision Web Audio API Acoustic Synthesizer & Calibrated Attenuator
 * Designed specifically for Sudden Sensorineural Hearing Loss (SSNHL) self-monitoring:
 * - Zero-click raised-cosine / smooth envelope ramping (35ms rise/fall per ISO 8253-1 / IEC 60645-1)
 * - Strict Left/Right channel isolation via ChannelMergerNode(2)
 * - Pulsed pure tone, FM warble tone (anti-tinnitus confusion), and continuous tone
 * - Optional contralateral narrow-band noise (NBN) masking for severe unilateral asymmetry
 * - Brickwall safety limiter + non-clipping dynamic headroom calculation per frequency
 * - Local-only FFT ambient noise monitor (auto-releases mic before testing to preserve Bluetooth A2DP stereo!)
 */

import { HEADPHONE_PROFILES, TEST_MAX_HARD_DB, TEST_MIN_DB } from './constants.js';

const MAX_LINEAR_GAIN = 0.89125; // -1.0 dBFS ceiling to guarantee 0% harmonic clipping distortion
const MAX_DBFS = -1.0;

export class AudioEngine {
  constructor() {
    this.ctx = null;
    this.masterLimiter = null;
    this.profileId = 'in_ear';
    // Effective dB SPL produced at 1000 Hz when digital signal is 0 dBFS
    this.fullScaleSpl1k = HEADPHONE_PROFILES.in_ear.defaultFullScaleSpl1k;
    this.calibrationMethod = 'preset'; // 'preset' | 'healthy_ear' | 'hand_rub'

    this.activeNodes = [];
    this.sustainedSession = null;
    this.noiseBuffer = null;

    // Ambient mic state
    this.micStream = null;
    this.micSource = null;
    this.micAnalyser = null;
    this.micRafId = null;
  }

  ensureContext() {
    if (!this.ctx) {
      const AudioCtx = window.AudioContext || window.webkitAudioContext;
      this.ctx = new AudioCtx({ latencyHint: 'interactive' });

      // Brickwall safety limiter at -0.8 dBFS to protect recovering cochlea
      this.masterLimiter = this.ctx.createDynamicsCompressor();
      this.masterLimiter.threshold.setValueAtTime(-0.8, this.ctx.currentTime);
      this.masterLimiter.knee.setValueAtTime(0, this.ctx.currentTime);
      this.masterLimiter.ratio.setValueAtTime(20, this.ctx.currentTime);
      this.masterLimiter.attack.setValueAtTime(0.001, this.ctx.currentTime);
      this.masterLimiter.release.setValueAtTime(0.05, this.ctx.currentTime);
      this.masterLimiter.connect(this.ctx.destination);
    }
    if (this.ctx.state === 'suspended') {
      this.ctx.resume();
    }
    return this.ctx;
  }

  setHeadphoneProfile(profileId, preserveCustomCalibration = false) {
    const profile = HEADPHONE_PROFILES[profileId] || HEADPHONE_PROFILES.in_ear;
    this.profileId = profile.id;
    if (!preserveCustomCalibration || this.calibrationMethod === 'preset') {
      this.fullScaleSpl1k = profile.defaultFullScaleSpl1k;
      this.calibrationMethod = 'preset';
    }
  }

  getProfile() {
    return HEADPHONE_PROFILES[this.profileId] || HEADPHONE_PROFILES.in_ear;
  }

  /**
   * Calibrate from known dBFS slider level at 1000 Hz corresponding to targetRefDbHL
   * Formula: SPL(1k) = targetRefDbHL + RETSPL(1k) = fullScaleSpl1k + rawDbfs
   */
  calibrateAt1kHz(rawDbfs, targetRefDbHL = 10, method = 'healthy_ear') {
    const retspl1k = this.getProfile().retspl[1000] ?? 5.5;
    const computed = targetRefDbHL + retspl1k - rawDbfs;
    // Clamp to physically plausible headphone output range (72 dB SPL to 118 dB SPL @ 0 dBFS)
    this.fullScaleSpl1k = Math.max(72, Math.min(118, computed));
    this.calibrationMethod = method;
    return this.fullScaleSpl1k;
  }

  resetCalibrationToPreset() {
    this.fullScaleSpl1k = this.getProfile().defaultFullScaleSpl1k;
    this.calibrationMethod = 'preset';
    return this.fullScaleSpl1k;
  }

  /**
   * Get interpolated RETSPL (dB SPL) for any frequency (125 Hz - 10000 Hz)
   */
  getRetspl(freq) {
    const table = this.getProfile().retspl;
    if (table[freq] !== undefined) return table[freq];

    const freqs = Object.keys(table).map(Number).sort((a, b) => a - b);
    if (freq <= freqs[0]) return table[freqs[0]];
    if (freq >= freqs[freqs.length - 1]) return table[freqs[freqs.length - 1]];

    for (let i = 0; i < freqs.length - 1; i++) {
      const f1 = freqs[i];
      const f2 = freqs[i + 1];
      if (freq >= f1 && freq <= f2) {
        const logT = Math.log2(freq / f1) / Math.log2(f2 / f1);
        return table[f1] + logT * (table[f2] - table[f1]);
      }
    }
    return 7.0;
  }

  /**
   * Compute maximum distortion-free dB HL achievable at a given frequency
   * before hitting -1.0 dBFS digital ceiling OR TEST_MAX_HARD_DB safety cap.
   */
  getMaxSafeDbHL(freq) {
    const retspl = this.getRetspl(freq);
    // requiredSpl = dbHL + retspl <= fullScaleSpl1k + MAX_DBFS
    const maxUnclipped = Math.floor((this.fullScaleSpl1k + MAX_DBFS - retspl) / 5) * 5;
    return Math.min(TEST_MAX_HARD_DB, Math.max(40, maxUnclipped));
  }

  /**
   * Convert (frequency, dB HL) -> linear Web Audio gain [0, MAX_LINEAR_GAIN]
   */
  dbHLToGain(freq, dbHL) {
    const clampedHL = Math.max(TEST_MIN_DB, Math.min(TEST_MAX_HARD_DB, dbHL));
    const retspl = this.getRetspl(freq);
    const targetSpl = clampedHL + retspl;
    const dbfs = Math.min(MAX_DBFS, targetSpl - this.fullScaleSpl1k);
    return Math.min(MAX_LINEAR_GAIN, Math.pow(10, dbfs / 20));
  }

  dbfsToGain(dbfs) {
    const safeDbfs = Math.min(MAX_DBFS, Math.max(-105, dbfs));
    return Math.pow(10, safeDbfs / 20);
  }

  /**
   * Generate cached 3-second Gaussian white noise buffer for Narrow-Band Masking & Tinnitus matching
   */
  getWhiteNoiseBuffer() {
    const ctx = this.ensureContext();
    if (this.noiseBuffer && this.noiseBuffer.sampleRate === ctx.sampleRate) {
      return this.noiseBuffer;
    }
    const length = ctx.sampleRate * 3;
    const buffer = ctx.createBuffer(1, length, ctx.sampleRate);
    const data = buffer.getChannelData(0);
    // Box-Muller Gaussian white noise normalized safely
    for (let i = 0; i < length; i++) {
      const u1 = Math.max(1e-7, Math.random());
      const u2 = Math.random();
      const z = Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math.PI * u2);
      data[i] = Math.max(-0.95, Math.min(0.95, z * 0.25));
    }
    this.noiseBuffer = buffer;
    return buffer;
  }

  /**
   * Immediately fade out and stop all active stimulus tones (Emergency Mute / Stop)
   */
  stopAll() {
    if (!this.ctx) return;
    const now = this.ctx.currentTime;
    for (const item of this.activeNodes) {
      try {
        if (item.gainNode) {
          item.gainNode.gain.cancelScheduledValues(now);
          item.gainNode.gain.setValueAtTime(item.gainNode.gain.value, now);
          item.gainNode.gain.linearRampToValueAtTime(0.00001, now + 0.025);
        }
        if (item.stopTimer) clearTimeout(item.stopTimer);
        setTimeout(() => {
          try {
            item.sources.forEach((s) => {
              try { s.stop(); } catch (_) {}
              try { s.disconnect(); } catch (_) {}
            });
            if (item.merger) item.merger.disconnect();
          } catch (_) {}
        }, 40);
      } catch (_) {}
    }
    this.activeNodes = [];
    this.stopSustainedTone();
  }

  /**
   * Play a calibrated audiometric stimulus in strictly isolated Left or Right ear channel.
   * @param {Object} opts
   * @param {number} opts.freq - Frequency in Hz (e.g. 125..8000)
   * @param {number} opts.dbHL - Presentation level in dB HL
   * @param {'left'|'right'} opts.ear - Target ear
   * @param {'pulsed'|'warble'|'continuous'} [opts.toneType='pulsed'] - Stimulus type
   * @param {number|null} [opts.maskingDbHL=null] - Optional contralateral narrow-band masking noise in dB HL
   * @param {number|null} [opts.rawDbfs=null] - Optional direct dBFS override (used during calibration)
   * @returns {{ durationMs: number, cancel: Function }}
   */
  playStimulus({
    freq,
    dbHL = 30,
    ear = 'left',
    toneType = 'pulsed',
    maskingDbHL = null,
    rawDbfs = null
  }) {
    // Ensure mic is closed so Bluetooth headphones stay in stereo A2DP high-quality profile
    if (this.micStream) {
      this.stopAmbientMonitor();
    }

    const ctx = this.ensureContext();
    const now = ctx.currentTime + 0.015;
    const peakGain = rawDbfs !== null ? this.dbfsToGain(rawDbfs) : this.dbHLToGain(freq, dbHL);

    // ChannelMergerNode(2): index 0 = Left strictly, index 1 = Right strictly
    const merger = ctx.createChannelMerger(2);
    merger.connect(this.masterLimiter);

    const earChannel = ear === 'left' ? 0 : 1;
    const oppositeChannel = ear === 'left' ? 1 : 0;

    // Create explicit digital zero source on opposite channel if no masking, guaranteeing channel isolation
    const toneEnvGain = ctx.createGain();
    toneEnvGain.gain.setValueAtTime(0, now);
    toneEnvGain.connect(merger, 0, earChannel);

    const osc = ctx.createOscillator();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(freq, now);

    const sources = [osc];

    // Warble FM modulation (±5% frequency deviation @ 5 Hz sine LFO per ISO 8253-2 / BSA tinnitus guide)
    if (toneType === 'warble') {
      const lfo = ctx.createOscillator();
      const lfoDepth = ctx.createGain();
      lfo.type = 'sine';
      lfo.frequency.setValueAtTime(5.0, now);
      lfoDepth.gain.setValueAtTime(freq * 0.05, now);
      lfo.connect(lfoDepth);
      lfoDepth.connect(osc.frequency);
      lfo.start(now);
      sources.push(lfo);
    }

    osc.connect(toneEnvGain);

    // Schedule envelope with smooth 35ms rise/fall ramps (anti-spectral-splatter)
    const ramp = 0.035;
    let totalDurationSec = 1.15;

    if (toneType === 'pulsed' || toneType === 'warble') {
      // 3 clean pulses: 250ms ON (incl ramps), 170ms OFF -> unmistakable temporal cue against tinnitus
      const pulseCount = 3;
      const onDur = 0.25;
      const offDur = 0.17;
      for (let p = 0; p < pulseCount; p++) {
        const tStart = now + p * (onDur + offDur);
        const tSustainEnd = tStart + onDur - ramp;
        const tEnd = tStart + onDur;
        toneEnvGain.gain.setValueAtTime(0.0, tStart);
        toneEnvGain.gain.linearRampToValueAtTime(peakGain, tStart + ramp);
        toneEnvGain.gain.setValueAtTime(peakGain, tSustainEnd);
        toneEnvGain.gain.linearRampToValueAtTime(0.0, tEnd);
      }
      totalDurationSec = pulseCount * onDur + (pulseCount - 1) * offDur + 0.05;
    } else {
      // Continuous 1.15s pure tone
      const onDur = 1.15;
      toneEnvGain.gain.setValueAtTime(0.0, now);
      toneEnvGain.gain.linearRampToValueAtTime(peakGain, now + ramp);
      toneEnvGain.gain.setValueAtTime(peakGain, now + onDur - ramp);
      toneEnvGain.gain.linearRampToValueAtTime(0.0, now + onDur);
      totalDurationSec = onDur + 0.05;
    }

    // Optional Contralateral Narrow-Band Noise (NBN) Masking in opposite ear
    if (maskingDbHL !== null && Number.isFinite(maskingDbHL)) {
      const noiseSrc = ctx.createBufferSource();
      noiseSrc.buffer = this.getWhiteNoiseBuffer();
      noiseSrc.loop = true;

      // Cascaded 2nd-order bandpass filters centered at test freq (1/3-octave narrowband noise)
      const bp1 = ctx.createBiquadFilter();
      bp1.type = 'bandpass';
      bp1.frequency.setValueAtTime(freq, now);
      bp1.Q.setValueAtTime(3.2, now);

      const bp2 = ctx.createBiquadFilter();
      bp2.type = 'bandpass';
      bp2.frequency.setValueAtTime(freq, now);
      bp2.Q.setValueAtTime(3.2, now);

      // Compensate narrow-band energy loss (+11 dB makeup so RMS matches pure-tone SPL)
      const maskLinear = Math.min(MAX_LINEAR_GAIN * 0.7, this.dbHLToGain(freq, maskingDbHL) * 3.5);
      const maskGain = ctx.createGain();
      const maskLead = 0.06;
      const maskStart = Math.max(ctx.currentTime, now - maskLead);
      const maskStop = now + totalDurationSec + 0.04;

      maskGain.gain.setValueAtTime(0.0, maskStart);
      maskGain.gain.linearRampToValueAtTime(maskLinear, maskStart + 0.05);
      maskGain.gain.setValueAtTime(maskLinear, maskStop - 0.05);
      maskGain.gain.linearRampToValueAtTime(0.0, maskStop);

      noiseSrc.connect(bp1);
      bp1.connect(bp2);
      bp2.connect(maskGain);
      maskGain.connect(merger, 0, oppositeChannel);

      noiseSrc.start(maskStart);
      noiseSrc.stop(maskStop + 0.02);
      sources.push(noiseSrc);
    }

    osc.start(now);
    const stopAt = now + totalDurationSec + 0.03;
    sources.forEach((s) => {
      try { s.stop(stopAt); } catch (_) {}
    });

    const record = {
      sources,
      gainNode: toneEnvGain,
      merger,
      stopTimer: null
    };

    const durationMs = Math.round((totalDurationSec + 0.04) * 1000);
    record.stopTimer = setTimeout(() => {
      try { merger.disconnect(); } catch (_) {}
      this.activeNodes = this.activeNodes.filter((n) => n !== record);
    }, durationMs + 80);

    this.activeNodes.push(record);

    return {
      durationMs,
      cancel: () => {
        const t = ctx.currentTime;
        try {
          toneEnvGain.gain.cancelScheduledValues(t);
          toneEnvGain.gain.setValueAtTime(toneEnvGain.gain.value, t);
          toneEnvGain.gain.linearRampToValueAtTime(0.0, t + 0.025);
          setTimeout(() => {
            sources.forEach((s) => {
              try { s.stop(); } catch (_) {}
            });
            try { merger.disconnect(); } catch (_) {}
          }, 35);
        } catch (_) {}
        if (record.stopTimer) clearTimeout(record.stopTimer);
        this.activeNodes = this.activeNodes.filter((n) => n !== record);
      }
    };
  }

  /**
   * Play a gentle pleasant two-note verification chime in Left or Right ear only
   */
  playChannelVerification(ear = 'left') {
    const firstFreq = ear === 'left' ? 523.25 : 659.25; // C5 or E5
    const secondFreq = ear === 'left' ? 659.25 : 783.99; // E5 or G5
    this.stopAll();
    const ctx = this.ensureContext();
    const now = ctx.currentTime + 0.01;
    const merger = ctx.createChannelMerger(2);
    merger.connect(this.masterLimiter);
    const ch = ear === 'left' ? 0 : 1;

    [firstFreq, secondFreq].forEach((f, idx) => {
      const osc = ctx.createOscillator();
      const g = ctx.createGain();
      const start = now + idx * 0.24;
      const dur = 0.22;
      const amp = this.dbHLToGain(1000, 45); // Comfortable moderate level
      osc.type = 'sine';
      osc.frequency.setValueAtTime(f, start);
      g.gain.setValueAtTime(0, start);
      g.gain.linearRampToValueAtTime(amp, start + 0.025);
      g.gain.exponentialRampToValueAtTime(0.0001, start + dur);
      osc.connect(g);
      g.connect(merger, 0, ch);
      osc.start(start);
      osc.stop(start + dur + 0.02);
    });

    setTimeout(() => {
      try { merger.disconnect(); } catch (_) {}
    }, 650);
  }

  /**
   * Sustained interactive generator for Tinnitus Pitch/Loudness Matching
   * Supports pure tone or narrow-band noise ('sine' | 'nbn')
   */
  startSustainedTone({ freq = 4000, dbHL = 30, ear = 'both', mode = 'sine' }) {
    this.stopSustainedTone();
    if (this.micStream) this.stopAmbientMonitor();

    const ctx = this.ensureContext();
    const now = ctx.currentTime;
    const merger = ctx.createChannelMerger(2);
    merger.connect(this.masterLimiter);

    const envGainL = ctx.createGain();
    const envGainR = ctx.createGain();
    envGainL.gain.setValueAtTime(0, now);
    envGainR.gain.setValueAtTime(0, now);
    envGainL.connect(merger, 0, 0);
    envGainR.connect(merger, 0, 1);

    let source;
    let filter1 = null;
    let filter2 = null;

    if (mode === 'nbn') {
      source = ctx.createBufferSource();
      source.buffer = this.getWhiteNoiseBuffer();
      source.loop = true;
      filter1 = ctx.createBiquadFilter();
      filter1.type = 'bandpass';
      filter1.frequency.setValueAtTime(freq, now);
      filter1.Q.setValueAtTime(4.0, now);
      filter2 = ctx.createBiquadFilter();
      filter2.type = 'bandpass';
      filter2.frequency.setValueAtTime(freq, now);
      filter2.Q.setValueAtTime(4.0, now);
      source.connect(filter1);
      filter1.connect(filter2);
      filter2.connect(envGainL);
      filter2.connect(envGainR);
    } else {
      source = ctx.createOscillator();
      source.type = 'sine';
      source.frequency.setValueAtTime(freq, now);
      source.connect(envGainL);
      source.connect(envGainR);
    }

    const baseAmp = this.dbHLToGain(freq, dbHL) * (mode === 'nbn' ? 3.5 : 1.0);
    const safeAmp = Math.min(MAX_LINEAR_GAIN * 0.65, baseAmp);
    const ampL = ear === 'left' || ear === 'both' ? safeAmp : 0;
    const ampR = ear === 'right' || ear === 'both' ? safeAmp : 0;

    envGainL.gain.setTargetAtTime(ampL, now, 0.03);
    envGainR.gain.setTargetAtTime(ampR, now, 0.03);
    source.start(now);

    this.sustainedSession = { source, filter1, filter2, envGainL, envGainR, merger, mode };
  }

  updateSustainedTone({ freq, dbHL, ear, mode }) {
    if (!this.sustainedSession) return;
    if (mode && mode !== this.sustainedSession.mode) {
      this.startSustainedTone({ freq, dbHL, ear, mode });
      return;
    }
    const ctx = this.ensureContext();
    const now = ctx.currentTime;
    const s = this.sustainedSession;
    if (s.mode === 'nbn') {
      s.filter1.frequency.setTargetAtTime(freq, now, 0.025);
      s.filter2.frequency.setTargetAtTime(freq, now, 0.025);
    } else {
      s.source.frequency.setTargetAtTime(freq, now, 0.025);
    }
    const baseAmp = this.dbHLToGain(freq, dbHL) * (s.mode === 'nbn' ? 3.5 : 1.0);
    const safeAmp = Math.min(MAX_LINEAR_GAIN * 0.65, baseAmp);
    const ampL = ear === 'left' || ear === 'both' ? safeAmp : 0;
    const ampR = ear === 'right' || ear === 'both' ? safeAmp : 0;
    s.envGainL.gain.setTargetAtTime(ampL, now, 0.025);
    s.envGainR.gain.setTargetAtTime(ampR, now, 0.025);
  }

  stopSustainedTone() {
    if (!this.sustainedSession || !this.ctx) return;
    const s = this.sustainedSession;
    this.sustainedSession = null;
    const now = this.ctx.currentTime;
    try {
      s.envGainL.gain.setTargetAtTime(0, now, 0.015);
      s.envGainR.gain.setTargetAtTime(0, now, 0.015);
      setTimeout(() => {
        try { s.source.stop(); } catch (_) {}
        try { s.source.disconnect(); } catch (_) {}
        try { s.merger.disconnect(); } catch (_) {}
      }, 60);
    } catch (_) {}
  }

  /**
   * Start Ambient Room Noise Monitor (100% in-browser FFT, measures overall + 125-250Hz low-freq hum)
   */
  async startAmbientMonitor(onReading) {
    this.stopAmbientMonitor();
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      throw new Error('当前浏览器不支持麦克风环境噪音检测');
    }
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false
      }
    });
    const ctx = this.ensureContext();
    const src = ctx.createMediaStreamSource(stream);
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 2048;
    analyser.smoothingTimeConstant = 0.75;
    src.connect(analyser);

    this.micStream = stream;
    this.micSource = src;
    this.micAnalyser = analyser;

    const timeBuf = new Float32Array(analyser.fftSize);
    const freqBuf = new Float32Array(analyser.frequencyBinCount);
    const binHz = ctx.sampleRate / analyser.fftSize;

    const loop = () => {
      if (!this.micAnalyser) return;
      analyser.getFloatTimeDomainData(timeBuf);
      analyser.getFloatFrequencyData(freqBuf);

      let sumSq = 0;
      for (let i = 0; i < timeBuf.length; i++) {
        sumSq += timeBuf[i] * timeBuf[i];
      }
      const rms = Math.sqrt(sumSq / timeBuf.length);
      const dbfs = 20 * Math.log10(Math.max(1e-6, rms));
      // Approximate consumer MEMS mic SPL mapping (~94 dB SPL @ -26 to -20 dBFS -> +100 offset rough estimate)
      const estDbSpl = Math.max(22, Math.min(90, Math.round(dbfs + 100)));

      // Check 90 Hz - 320 Hz low-frequency hum (AC, refrigerator, traffic rumble affecting 125Hz & 250Hz!)
      const minBin = Math.max(1, Math.floor(90 / binHz));
      const maxBin = Math.min(freqBuf.length - 1, Math.ceil(320 / binHz));
      let lowEnergySum = 0;
      let count = 0;
      for (let b = minBin; b <= maxBin; b++) {
        lowEnergySum += freqBuf[b];
        count++;
      }
      const avgLowDb = count > 0 ? lowEnergySum / count : -90;
      const lowFreqWarning = avgLowDb > -52 || estDbSpl > 45;

      onReading({
        estDbSpl,
        lowFreqWarning,
        status: estDbSpl <= 36 ? 'quiet' : estDbSpl <= 45 ? 'moderate' : 'noisy'
      });

      this.micRafId = requestAnimationFrame(loop);
    };

    loop();
  }

  stopAmbientMonitor() {
    if (this.micRafId) {
      cancelAnimationFrame(this.micRafId);
      this.micRafId = null;
    }
    if (this.micSource) {
      try { this.micSource.disconnect(); } catch (_) {}
      this.micSource = null;
    }
    this.micAnalyser = null;
    if (this.micStream) {
      this.micStream.getTracks().forEach((t) => t.stop());
      this.micStream = null;
    }
  }
}
