/**
 * Clinical Pure-Tone Audiometry Threshold Search Engine
 * Implements:
 * 1. Modified Hughson-Westlake Automated Protocol (ISO 8253-1: "Down 10 dB, Up 5 dB", 2-of-3 ascending convergence)
 * 2. Randomized inter-stimulus intervals (ISI) & false-alarm (early press) detection
 * 3. Contralateral Narrow-Band Masking calculation when interaural difference >= IA
 * 4. Interactive Manual Fine-Tune (Self-Paced Bracket) helper
 */

import { TEST_MIN_DB } from './constants.js';

export class HughsonWestlakeRunner {
  /**
   * @param {Object} config
   * @param {import('./audioEngine.js').AudioEngine} config.audioEngine
   * @param {Array<{ear: 'left'|'right', freq: number}>} config.steps - Ordered test queue (125Hz -> 8000Hz)
   * @param {'pulsed'|'warble'|'continuous'} config.toneType
   * @param {boolean} config.enableMasking
   * @param {Object} config.initialResults - Pre-existing { left: {}, right: {} } (e.g. for cross-hearing reference)
   * @param {Function} config.onStateChange - UI state callback
   * @param {Function} config.onPointComplete - Called whenever a (ear, freq) threshold is finalized
   * @param {Function} config.onAllComplete - Called when entire test queue completes
   * @param {Function} config.onFalseAlarm - Called when user clicks during silent pre-stimulus delay
   */
  constructor(config) {
    this.audio = config.audioEngine;
    this.steps = config.steps;
    this.toneType = config.toneType || 'pulsed';
    this.enableMasking = Boolean(config.enableMasking);
    this.results = {
      left: { ...(config.initialResults?.left || {}) },
      right: { ...(config.initialResults?.right || {}) }
    };

    this.onStateChange = config.onStateChange || (() => {});
    this.onPointComplete = config.onPointComplete || (() => {});
    this.onAllComplete = config.onAllComplete || (() => {});
    this.onFalseAlarm = config.onFalseAlarm || (() => {});

    this.stepIndex = 0;
    this.running = false;
    this.paused = false;

    // Per-frequency state
    this.freqState = null;

    // Timing handles
    this.preDelayTimer = null;
    this.windowCloseTimer = null;
    this.activePlayback = null;
    this.windowState = 'idle'; // 'pre_delay' | 'listening_window' | 'inter_trial'
    this.stimulusOnsetPerfMs = 0;
    this.falseAlarmCount = 0;
  }

  start() {
    if (this.steps.length === 0) {
      this.onAllComplete(this.results);
      return;
    }
    this.running = true;
    this.paused = false;
    this.stepIndex = 0;
    this._initFrequencyStep();
  }

  pause() {
    if (!this.running || this.paused) return;
    this.paused = true;
    this._clearTimersAndAudio();
    this.windowState = 'idle';
    this._emitState('已暂停 — 随时点击继续测听');
  }

  resume() {
    if (!this.running || !this.paused) return;
    this.paused = false;
    this._emitState('继续测听中，请静心聆听...');
    this._scheduleNextTrial(700);
  }

  stop() {
    this.running = false;
    this.paused = false;
    this._clearTimersAndAudio();
  }

  /**
   * User pressed "I Heard It" (Spacebar / Button)
   */
  registerUserResponse() {
    if (!this.running || this.paused || !this.freqState) return false;

    const nowMs = performance.now();

    // Check if user pressed BEFORE sound played (or <110ms human physiological reaction limit)
    if (
      this.windowState === 'pre_delay' ||
      (this.windowState === 'listening_window' && nowMs - this.stimulusOnsetPerfMs < 110)
    ) {
      this.falseAlarmCount++;
      this._clearTimersAndAudio();
      this.windowState = 'inter_trial';
      this.onFalseAlarm(this.falseAlarmCount);
      this._emitState('刚才还未播放测试音，已为您重新排期该次发声...');
      // Re-run exact same trial after a fresh random pause
      this._scheduleNextTrial(1100 + Math.random() * 900);
      return false;
    }

    if (this.windowState === 'listening_window') {
      // Valid detection!
      this.windowState = 'inter_trial';
      if (this.windowCloseTimer) {
        clearTimeout(this.windowCloseTimer);
        this.windowCloseTimer = null;
      }
      // Gently stop remaining pulses after 110ms so test feels crisp & responsive
      const playbackRef = this.activePlayback;
      this.activePlayback = null;
      if (playbackRef) {
        setTimeout(() => playbackRef.cancel(), 110);
      }

      this._processTrialOutcome(true);
      return true;
    }

    return false;
  }

  /**
   * Allow user to explicitly mark "Cannot hear even at comfortable max / Skip point" or re-start current freq
   */
  restartCurrentFrequency() {
    if (!this.running) return;
    this._clearTimersAndAudio();
    this._initFrequencyStep();
  }

  skipCurrentAsNoResponse() {
    if (!this.running || !this.freqState) return;
    this._clearTimersAndAudio();
    const { ear, freq, maxDb, usedMasking } = this.freqState;
    this._finalizePoint({
      ear,
      freq,
      db: maxDb,
      noResponse: true,
      masked: usedMasking,
      lowConfidence: false,
      history: [...this.freqState.history]
    });
  }

  _initFrequencyStep() {
    if (this.stepIndex >= this.steps.length) {
      this.running = false;
      this._clearTimersAndAudio();
      this.onAllComplete(this.results);
      return;
    }

    const { ear, freq } = this.steps[this.stepIndex];
    const maxDb = this.audio.getMaxSafeDbHL(freq);

    // Smart gentle starting level: 30 dB HL default (or mildly adapted to adjacent octave, capped <=45 dB for safety)
    let startDb = 30;
    const earMap = this.results[ear] || {};
    const measuredFreqs = Object.keys(earMap).map(Number);
    if (measuredFreqs.length > 0) {
      const prev = earMap[measuredFreqs[measuredFreqs.length - 1]];
      if (prev && Number.isFinite(prev.db)) {
        startDb = Math.min(45, Math.max(25, Math.round((prev.db + 5) / 5) * 5));
      }
    }
    startDb = Math.min(maxDb, startDb);

    this.freqState = {
      ear,
      freq,
      maxDb,
      currentDb: startDb,
      phase: 'initial_search', // 'initial_search' | 'bracketing'
      direction: 'descending', // 'descending' | 'ascending'
      ascendingStats: {}, // { [db]: { attempts, hits } }
      floorHits: 0,
      ceilingMisses: 0,
      trialCount: 0,
      usedMasking: false,
      history: [] // [{ db, heard, masked }]
    };

    this._emitState(`正在准备 ${ear === 'left' ? '左耳' : '右耳'} ${freq} Hz 测听...`);
    this._scheduleNextTrial(850);
  }

  _computeContralateralMasking(ear, freq, presentationDb) {
    if (!this.enableMasking) return null;
    const oppEar = ear === 'left' ? 'right' : 'left';
    const oppEntry = this.results[oppEar]?.[freq];
    if (!oppEntry || oppEntry.noResponse || !Number.isFinite(oppEntry.db)) {
      return null;
    }
    const ia = this.audio.getProfile().interauralAttenuation || 45;
    const oppDb = oppEntry.db;
    if (presentationDb - oppDb >= ia - 5) {
      // Plateau effective masking level: oppThreshold + 15 dB + over-attenuation delta, capped safely at 65 dB HL
      const maskDb = Math.min(65, Math.max(20, oppDb + 15 + Math.max(0, presentationDb - ia - oppDb)));
      return Math.round(maskDb / 5) * 5;
    }
    return null;
  }

  _scheduleNextTrial(customDelayMs = null) {
    if (!this.running || this.paused || !this.freqState) return;
    this._clearTimersAndAudio();

    // Randomized silent pre-stimulus delay (950ms - 2150ms) to prevent rhythmic guessing
    const preDelay = customDelayMs !== null ? customDelayMs : Math.round(950 + Math.random() * 1200);
    this.windowState = 'pre_delay';
    this._emitState('请静心聆听，听到微弱脉冲音即按下响应键...');

    this.preDelayTimer = setTimeout(() => {
      if (!this.running || this.paused || !this.freqState) return;
      const st = this.freqState;
      const maskDb = this._computeContralateralMasking(st.ear, st.freq, st.currentDb);
      if (maskDb !== null) {
        st.usedMasking = true;
      }

      this.windowState = 'listening_window';
      this.stimulusOnsetPerfMs = performance.now();

      this.activePlayback = this.audio.playStimulus({
        freq: st.freq,
        dbHL: st.currentDb,
        ear: st.ear,
        toneType: this.toneType,
        maskingDbHL: maskDb
      });

      this._emitState(
        maskDb !== null
          ? '正在测听（健侧已自动开启轻柔窄带掩蔽，请只对嘀嘀声按键）...'
          : '请静心聆听，听到微弱脉冲音即按下响应键...'
      );

      // Post-stimulus response window: stimulus duration + 1150ms reaction grace time
      const totalWindowMs = this.activePlayback.durationMs + 1150;
      this.windowCloseTimer = setTimeout(() => {
        if (!this.running || this.paused || this.windowState !== 'listening_window') return;
        this.windowState = 'inter_trial';
        this.activePlayback = null;
        this._processTrialOutcome(false);
      }, totalWindowMs);
    }, preDelay);
  }

  _processTrialOutcome(heard) {
    const st = this.freqState;
    if (!st) return;

    const testedDb = st.currentDb;
    st.trialCount++;
    st.history.push({ db: testedDb, heard, direction: st.direction });

    if (st.phase === 'initial_search') {
      if (heard) {
        // First response achieved! Switch to Modified Hughson-Westlake bracketing ("Down 10, Up 5")
        st.phase = 'bracketing';
        if (testedDb <= TEST_MIN_DB) {
          st.floorHits = 1;
          st.currentDb = TEST_MIN_DB;
          st.direction = 'ascending';
        } else {
          st.currentDb = Math.max(TEST_MIN_DB, testedDb - 10);
          st.direction = 'descending';
        }
      } else {
        // Not heard during initial search -> step up safely by +10 dB (or +5 dB near ceiling)
        if (testedDb >= st.maxDb) {
          st.ceilingMisses++;
          if (st.ceilingMisses >= 2) {
            this._finalizePoint({
              ear: st.ear,
              freq: st.freq,
              db: st.maxDb,
              noResponse: true,
              masked: st.usedMasking,
              lowConfidence: false,
              history: [...st.history]
            });
            return;
          }
        } else {
          st.currentDb = Math.min(st.maxDb, testedDb + 10);
        }
      }
      this._scheduleNextTrial();
      return;
    }

    // Phase === 'bracketing'
    if (st.direction === 'ascending' || testedDb === TEST_MIN_DB) {
      if (!st.ascendingStats[testedDb]) {
        st.ascendingStats[testedDb] = { attempts: 0, hits: 0 };
      }
      st.ascendingStats[testedDb].attempts++;
      if (heard) {
        st.ascendingStats[testedDb].hits++;
      }
    }

    if (heard) {
      st.ceilingMisses = 0;

      // Check floor convergence (-10 dB HL)
      if (testedDb <= TEST_MIN_DB) {
        st.floorHits++;
        if (st.floorHits >= 2 || (st.ascendingStats[TEST_MIN_DB]?.hits || 0) >= 2) {
          this._finalizePoint({
            ear: st.ear,
            freq: st.freq,
            db: TEST_MIN_DB,
            noResponse: false,
            masked: st.usedMasking,
            lowConfidence: false,
            history: [...st.history]
          });
          return;
        }
        st.currentDb = TEST_MIN_DB;
        st.direction = 'ascending';
        this._scheduleNextTrial();
        return;
      }

      // Check Modified Hughson-Westlake Ascending Convergence: >=2 hits and >=50% response rate at this level
      const stat = st.ascendingStats[testedDb];
      if (st.direction === 'ascending' && stat && stat.hits >= 2 && stat.hits / stat.attempts >= 0.5) {
        this._finalizePoint({
          ear: st.ear,
          freq: st.freq,
          db: testedDb,
          noResponse: false,
          masked: st.usedMasking,
          lowConfidence: false,
          history: [...st.history]
        });
        return;
      }

      // Standard rule: Heard -> Descend by 10 dB
      st.currentDb = Math.max(TEST_MIN_DB, testedDb - 10);
      st.direction = 'descending';
    } else {
      // Not Heard -> Ascend by 5 dB
      if (testedDb >= st.maxDb) {
        st.ceilingMisses++;
        if (st.ceilingMisses >= 2) {
          const ceilHits = st.ascendingStats[st.maxDb]?.hits || 0;
          this._finalizePoint({
            ear: st.ear,
            freq: st.freq,
            db: st.maxDb,
            noResponse: ceilHits === 0,
            masked: st.usedMasking,
            lowConfidence: false,
            history: [...st.history]
          });
          return;
        }
        st.currentDb = st.maxDb;
        st.direction = 'ascending';
      } else {
        st.currentDb = Math.min(st.maxDb, testedDb + 5);
        st.direction = 'ascending';
      }
    }

    // Fallback convergence if trials reach 16 (prevents fatigue in tinnitus patients)
    if (st.trialCount >= 16) {
      const bestDb = this._estimateBestThreshold(st);
      this._finalizePoint({
        ear: st.ear,
        freq: st.freq,
        db: bestDb,
        noResponse: false,
        masked: st.usedMasking,
        lowConfidence: true,
        history: [...st.history]
      });
      return;
    }

    this._scheduleNextTrial();
  }

  _estimateBestThreshold(st) {
    const candidates = Object.entries(st.ascendingStats)
      .map(([dbStr, s]) => ({ db: Number(dbStr), ...s }))
      .filter((c) => c.hits >= 1)
      .sort((a, b) => a.db - b.db);

    const fiftyPct = candidates.find((c) => c.hits / c.attempts >= 0.5);
    if (fiftyPct) return fiftyPct.db;
    if (candidates.length > 0) return candidates[0].db;

    const heardTrials = st.history.filter((h) => h.heard).map((h) => h.db);
    if (heardTrials.length > 0) return Math.min(...heardTrials);
    return st.maxDb;
  }

  _finalizePoint(pointResult) {
    const { ear, freq } = pointResult;
    if (!this.results[ear]) this.results[ear] = {};
    this.results[ear][freq] = {
      db: pointResult.db,
      noResponse: Boolean(pointResult.noResponse),
      masked: Boolean(pointResult.masked),
      lowConfidence: Boolean(pointResult.lowConfidence),
      timestamp: Date.now()
    };

    this.onPointComplete(pointResult, this.results, this.stepIndex, this.steps.length);
    this.stepIndex++;
    // Brief calm breather between frequencies (650ms)
    setTimeout(() => {
      if (this.running && !this.paused) {
        this._initFrequencyStep();
      }
    }, 550);
  }

  _emitState(statusText) {
    const st = this.freqState;
    this.onStateChange({
      running: this.running,
      paused: this.paused,
      stepIndex: this.stepIndex,
      totalSteps: this.steps.length,
      ear: st?.ear || null,
      freq: st?.freq || null,
      trialCount: st?.trialCount || 0,
      history: st?.history || [],
      usedMasking: st?.usedMasking || false,
      statusText,
      results: this.results
    });
  }

  _clearTimersAndAudio() {
    if (this.preDelayTimer) {
      clearTimeout(this.preDelayTimer);
      this.preDelayTimer = null;
    }
    if (this.windowCloseTimer) {
      clearTimeout(this.windowCloseTimer);
      this.windowCloseTimer = null;
    }
    if (this.activePlayback) {
      this.activePlayback.cancel();
      this.activePlayback = null;
    }
  }
}
