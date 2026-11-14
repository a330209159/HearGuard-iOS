/**
 * Main Application Controller for HearGuard SSNHL Clinical Pure-Tone Audiometry
 * Connects:
 * - Calibration Wizard (ISO 389 RETSPL + Contralateral Healthy Ear 1kHz + Masalski Hand-Rub)
 * - Low-to-High Pure-Tone Test Runner (125Hz -> 8000Hz, Auto Hughson-Westlake & Manual Fine-Tune)
 * - Bilateral Clinical Audiogram & SSNHL Guideline Analysis Report
 * - Longitudinal Recovery Tracker & Tinnitus Pitch/Loudness Matcher
 */

import {
  STANDARD_FREQUENCIES,
  EXTENDED_FREQUENCIES,
  FREQUENCY_LABELS,
  HEADPHONE_PROFILES,
  TEST_MIN_DB
} from './constants.js';
import { AudioEngine } from './audioEngine.js';
import { HughsonWestlakeRunner } from './audiometryProtocol.js';
import { AudiogramChart, renderRecoveryTrendChart } from './audiogramChart.js';
import { analyzeBilateral, compareWithBaseline } from './clinicalAnalyzer.js';
import {
  loadSettings,
  saveSettings,
  loadSessions,
  saveSession,
  deleteSession,
  loadTinnitusLogs,
  saveTinnitusLog,
  exportAllDataJson,
  importAllDataJson,
  DEMO_PROFILES
} from './storage.js';

class HearGuardApp {
  constructor() {
    this.audio = new AudioEngine();
    this.runner = null;
    this.activeTab = 'tab-prep';

    // Current working audiogram results { left: { [freq]: {db, noResponse, masked} }, right: {...} }
    this.currentResults = { left: {}, right: {} };
    this.isDemoPreview = false;

    // Settings
    this.affectedSide = 'left'; // 'left' | 'right' | 'unknown'
    this.micActive = false;

    // Manual Mode state
    this.manualState = {
      ear: 'left',
      freq: 125,
      db: 30
    };

    // Inspector state on Report Chart
    this.inspectedFreq = null;

    // Tinnitus Matcher state
    this.tinnitusPlaying = false;

    // Charts
    this.liveChart = null;
    this.mainChart = null;
    this.toastTimer = null;
  }

  init() {
    this._restoreSettings();
    this._initCharts();
    this._renderHeadphoneProfiles();
    this._bindNavigation();
    this._bindPrepTab();
    this._bindTestTab();
    this._bindReportTab();
    this._bindHistoryAndTinnitusTab();
    this._bindHospitalModal();
    this._bindGlobalShortcuts();

    // Load latest saved session into report if user already has history
    const sessions = loadSessions();
    if (sessions.length > 0) {
      this.currentResults = structuredClone(sessions[0].results || { left: {}, right: {} });
    }

    this._refreshCalibrationBadge();
    this._syncManualFrequencyOptions();
    this._renderFrequencyStepperRail();
    this._refreshAllViews();

    window.addEventListener('resize', () => {
      if (this.activeTab === 'tab-test') this.liveChart?.render();
      if (this.activeTab === 'tab-report') this.mainChart?.render();
      if (this.activeTab === 'tab-history') this._renderTrend();
    });
  }

  _restoreSettings() {
    const saved = loadSettings();
    if (saved) {
      if (saved.profileId && HEADPHONE_PROFILES[saved.profileId]) {
        this.audio.setHeadphoneProfile(saved.profileId, false);
      }
      if (Number.isFinite(saved.fullScaleSpl1k)) {
        this.audio.fullScaleSpl1k = saved.fullScaleSpl1k;
      }
      if (saved.calibrationMethod) {
        this.audio.calibrationMethod = saved.calibrationMethod;
      }
      if (saved.affectedSide) {
        this.affectedSide = saved.affectedSide;
      }
    }
  }

  _persistSettings() {
    saveSettings({
      profileId: this.audio.profileId,
      fullScaleSpl1k: this.audio.fullScaleSpl1k,
      calibrationMethod: this.audio.calibrationMethod,
      affectedSide: this.affectedSide
    });
    this._refreshCalibrationBadge();
  }

  _refreshCalibrationBadge() {
    const badge = document.getElementById('calibrationStatusBadge');
    const hpShort = this.audio.getProfile().name.split(' ')[0];
    const methodMap = {
      preset: '标准预设',
      healthy_ear: '健耳1kHz已校准',
      hand_rub: '搓手声已校准'
    };
    const mLabel = methodMap[this.audio.calibrationMethod] || '标准预设';
    badge.textContent = `${mLabel} · ${hpShort}`;
    badge.classList.toggle('status-calibrated', this.audio.calibrationMethod !== 'preset');
  }

  showToast(msg, durationMs = 3400) {
    const el = document.getElementById('toastBanner');
    el.textContent = msg;
    el.classList.remove('hidden');
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => {
      el.classList.add('hidden');
    }, durationMs);
  }

  _initCharts() {
    const liveCanvas = document.getElementById('liveAudiogramCanvas');
    const mainCanvas = document.getElementById('mainAudiogramCanvas');

    this.liveChart = new AudiogramChart(liveCanvas, {
      interactive: false,
      showSeverityBands: true,
      showAsymmetryShade: true
    });

    this.mainChart = new AudiogramChart(mainCanvas, {
      interactive: true,
      showSeverityBands: true,
      showSpeechBanana: false,
      showAsymmetryShade: true,
      onPointClick: ({ freq }) => {
        this._openPointInspector(freq);
      }
    });
  }

  switchTab(tabId) {
    // Stop ambient mic or tinnitus tone when switching tabs cleanly
    if (tabId !== 'tab-prep' && this.micActive) {
      this._stopMicUI();
    }
    if (tabId !== 'tab-history' && this.tinnitusPlaying) {
      this._stopTinnitusUI();
    }

    this.activeTab = tabId;
    document.querySelectorAll('.nav-tab').forEach((btn) => {
      const isActive = btn.dataset.tab === tabId;
      btn.classList.toggle('active', isActive);
      btn.setAttribute('aria-selected', String(isActive));
    });
    document.querySelectorAll('.tab-panel').forEach((panel) => {
      panel.classList.toggle('active', panel.id === tabId);
    });

    requestAnimationFrame(() => {
      if (tabId === 'tab-test') {
        this.liveChart.setData(this.currentResults, null);
      } else if (tabId === 'tab-report') {
        this._refreshReportView();
      } else if (tabId === 'tab-history') {
        this._refreshHistoryTab();
      }
    });
  }

  _bindNavigation() {
    document.querySelectorAll('.nav-tab').forEach((btn) => {
      btn.addEventListener('click', () => this.switchTab(btn.dataset.tab));
    });

    document.getElementById('btnEmergencyMute').addEventListener('click', () => {
      this._emergencyMuteAll();
    });
  }

  _emergencyMuteAll() {
    this.audio.stopAll();
    if (this.runner && this.runner.running && !this.runner.paused) {
      this.runner.pause();
      document.getElementById('btnPauseResume').textContent = '继续测听';
    }
    if (this.tinnitusPlaying) {
      this._stopTinnitusUI();
    }
    this.showToast('已紧急静音并暂停所有音频输出');
  }

  /* ========================================================================
   * TAB 1: PREPARATION & CALIBRATION
   * ======================================================================== */
  _renderHeadphoneProfiles() {
    const grid = document.getElementById('headphoneProfileGrid');
    grid.innerHTML = '';
    Object.values(HEADPHONE_PROFILES).forEach((prof) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = `profile-item ${prof.id === this.audio.profileId ? 'selected' : ''}`;
      btn.innerHTML = `
        <div class="profile-item-title">${prof.name}</div>
        <div class="profile-item-sub">${prof.subtitle}</div>
      `;
      btn.addEventListener('click', () => {
        this.audio.setHeadphoneProfile(prof.id, true);
        this._persistSettings();
        this._renderHeadphoneProfiles();
        this._updateManualReadout();
        this.showToast(`已切换声学补偿模型：${prof.name}`);
      });
      grid.appendChild(btn);
    });
  }

  _bindPrepTab() {
    const selSide = document.getElementById('selectAffectedSide');
    selSide.value = this.affectedSide;
    const syncRefEar = () => {
      const refSel = document.getElementById('calibRefEar');
      if (this.affectedSide === 'left') refSel.value = 'right';
      else if (this.affectedSide === 'right') refSel.value = 'left';
    };
    syncRefEar();

    selSide.addEventListener('change', () => {
      this.affectedSide = selSide.value;
      syncRefEar();
      this._persistSettings();
    });

    document.getElementById('btnCheckLeft').addEventListener('click', () => {
      this.audio.playChannelVerification('left');
      this.showToast('正在播放【左耳 L】校验双音 — 请确认仅左侧耳塞发声');
    });

    document.getElementById('btnCheckRight').addEventListener('click', () => {
      this.audio.playChannelVerification('right');
      this.showToast('正在播放【右耳 R】校验双音 — 请确认仅右侧耳塞发声');
    });

    // Ambient Mic Noise Monitor
    document.getElementById('btnToggleMic').addEventListener('click', async () => {
      if (this.micActive) {
        this._stopMicUI();
        return;
      }
      try {
        const wrap = document.getElementById('ambientMeterWrap');
        const fill = document.getElementById('ambientMeterFill');
        const txt = document.getElementById('ambientDbText');
        const lowBadge = document.getElementById('ambientLowFreqBadge');
        const btn = document.getElementById('btnToggleMic');

        await this.audio.startAmbientMonitor(({ estDbSpl, lowFreqWarning, status }) => {
          const pct = Math.min(100, Math.max(8, ((estDbSpl - 20) / 60) * 100));
          fill.style.width = `${pct}%`;
          fill.style.backgroundColor =
            status === 'quiet' ? '#10b981' : status === 'moderate' ? '#f59e0b' : '#ef4444';
          txt.textContent = `估算环境声级：约 ${estDbSpl} dBA (${
            status === 'quiet' ? '安静适宜测听' : status === 'moderate' ? '尚可，略偏吵' : '环境偏吵，建议换安静房间'
          })`;

          if (lowFreqWarning) {
            lowBadge.className = 'badge badge-warn';
            lowBadge.textContent = '检测到 125–250Hz 低频嗡声（建议关闭空调/风扇）';
          } else {
            lowBadge.className = 'badge badge-ok';
            lowBadge.textContent = '125–250Hz 低频底噪干净';
          }
        });

        this.micActive = true;
        wrap.classList.remove('hidden');
        btn.textContent = '关闭噪音检测';
      } catch (err) {
        this.showToast(`无法启动麦克风检测：${err.message || '请授予麦克风权限或直接跳过此步'}`);
      }
    });

    // Calibration Mode Tabs
    document.querySelectorAll('.calib-mode-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('.calib-mode-btn').forEach((b) => b.classList.remove('active'));
        btn.classList.add('active');
        const mode = btn.dataset.calib;
        document.getElementById('calibPanelPreset').classList.toggle('hidden', mode !== 'preset');
        document.getElementById('calibPanelHealthy').classList.toggle('hidden', mode !== 'healthy_ear');
        document.getElementById('calibPanelHandRub').classList.toggle('hidden', mode !== 'hand_rub');
      });
    });

    document.getElementById('btnApplyPresetCalib').addEventListener('click', () => {
      this.audio.resetCalibrationToPreset();
      this._persistSettings();
      this.showToast('已恢复为 50% 系统音量标准 RETSPL 校准参数');
    });

    // Healthy Ear 1000 Hz Calibration
    const rawSlider = document.getElementById('calibRawSlider');
    const rawLabel = document.getElementById('calibRawDbfsVal');
    const updateRawLabel = () => {
      rawLabel.textContent = `${rawSlider.value} dBFS`;
    };
    rawSlider.addEventListener('input', updateRawLabel);

    const playCalibPulse = () => {
      const ear = document.getElementById('calibRefEar').value;
      const rawDbfs = Number(rawSlider.value);
      this.audio.playStimulus({
        freq: 1000,
        ear,
        toneType: 'pulsed',
        rawDbfs
      });
    };

    document.getElementById('btnPlayCalibTone').addEventListener('click', playCalibPulse);
    document.getElementById('btnCalibStepDown').addEventListener('click', () => {
      rawSlider.value = String(Math.max(-96, Number(rawSlider.value) - 2));
      updateRawLabel();
      playCalibPulse();
    });
    document.getElementById('btnCalibStepUp').addEventListener('click', () => {
      rawSlider.value = String(Math.min(-35, Number(rawSlider.value) + 2));
      updateRawLabel();
      playCalibPulse();
    });

    document.getElementById('btnSaveHealthyCalib').addEventListener('click', () => {
      const rawDbfs = Number(rawSlider.value);
      const refDb = Number(document.getElementById('calibHospital1k').value) || 10;
      const fs = this.audio.calibrateAt1kHz(rawDbfs, refDb, 'healthy_ear');
      this._persistSettings();
      this._updateManualReadout();
      this.showToast(`健侧耳生物校准已锁定！(等效满刻度 ${fs.toFixed(1)} dB SPL @ 1kHz)`);
    });

    // Hand-Rub Calibration (55 dB SPL equivalent -> ~49.5 dB HL at 1kHz)
    const rubSlider = document.getElementById('handRubSlider');
    const rubLabel = document.getElementById('handRubDbfsVal');
    rubSlider.addEventListener('input', () => {
      rubLabel.textContent = `${rubSlider.value} dBFS`;
    });
    document.getElementById('btnPlayHandRubTone').addEventListener('click', () => {
      const ear = this.affectedSide === 'left' ? 'right' : 'left';
      this.audio.playStimulus({
        freq: 1000,
        ear,
        toneType: 'continuous',
        rawDbfs: Number(rubSlider.value)
      });
    });
    document.getElementById('btnSaveHandRubCalib').addEventListener('click', () => {
      const rawDbfs = Number(rubSlider.value);
      // Hand rubbing at 5cm ~ 55 dB SPL -> ~49.5 dB HL at 1000 Hz
      const fs = this.audio.calibrateAt1kHz(rawDbfs, 49.5, 'hand_rub');
      this._persistSettings();
      this._updateManualReadout();
      this.showToast(`搓手声生物校准已锁定！(等效满刻度 ${fs.toFixed(1)} dB SPL @ 1kHz)`);
    });

    document.getElementById('btnGoToTest').addEventListener('click', () => {
      this._stopMicUI();
      this.switchTab('tab-test');
    });
  }

  _stopMicUI() {
    this.audio.stopAmbientMonitor();
    this.micActive = false;
    document.getElementById('ambientMeterWrap').classList.add('hidden');
    document.getElementById('btnToggleMic').textContent = '开启噪音检测';
  }

  /* ========================================================================
   * TAB 2: PURE-TONE AUDIOMETRY (125 Hz -> 8000 Hz LOW-TO-HIGH)
   * ======================================================================== */
  _getSelectedFrequencies() {
    const mode = document.getElementById('selectFreqSet').value;
    return mode === 'extended' ? EXTENDED_FREQUENCIES : STANDARD_FREQUENCIES;
  }

  _buildOrderedSteps() {
    const freqs = this._getSelectedFrequencies(); // Strictly ascending: 125 -> 250 -> 500 -> ... -> 8000
    const order = document.getElementById('selectEarOrder').value;

    let earSequence = ['right', 'left'];
    if (order === 'healthy_first') {
      earSequence = this.affectedSide === 'right' ? ['left', 'right'] : ['right', 'left'];
    } else if (order === 'left_first') {
      earSequence = ['left', 'right'];
    } else if (order === 'right_first') {
      earSequence = ['right', 'left'];
    } else if (order === 'left_only') {
      earSequence = ['left'];
    } else if (order === 'right_only') {
      earSequence = ['right'];
    }

    const steps = [];
    for (const ear of earSequence) {
      for (const freq of freqs) {
        steps.push({ ear, freq });
      }
    }
    return steps;
  }

  _renderFrequencyStepperRail(activeEar = null, activeFreq = null) {
    const rail = document.getElementById('frequencyStepperRail');
    const freqs = this._getSelectedFrequencies();
    rail.innerHTML = '';

    freqs.forEach((f) => {
      const lPt = this.currentResults?.left?.[f];
      const rPt = this.currentResults?.right?.[f];
      const isCurrent = activeFreq === f;
      const pill = document.createElement('div');
      pill.className = `freq-pill ${isCurrent ? 'current' : ''}`;
      const hzLabel = f >= 1000 ? `${f / 1000}kHz` : `${f}Hz`;

      const lTxt = lPt ? `✕${lPt.noResponse ? '>' : ''}${lPt.db}` : '✕--';
      const rTxt = rPt ? `O${rPt.noResponse ? '>' : ''}${rPt.db}` : 'O--';

      pill.innerHTML = `
        <div class="freq-pill-hz">${hzLabel}</div>
        <div class="freq-pill-ears">
          <span class="${lPt ? 'pill-l' : 'pill-pending'}">${lTxt}</span>
          <span class="${rPt ? 'pill-r' : 'pill-pending'}">${rTxt}</span>
        </div>
      `;
      pill.title = '点击切换到手动微调该频点';
      pill.addEventListener('click', () => {
        if (this.runner && this.runner.running) return;
        document.getElementById('selectMethodMode').value = 'manual';
        this._toggleTestMethodArena();
        this.manualState.freq = f;
        if (activeEar) this.manualState.ear = activeEar;
        this._updateManualReadout();
      });
      rail.appendChild(pill);
    });
  }

  _toggleTestMethodArena() {
    const isManual = document.getElementById('selectMethodMode').value === 'manual';
    if (isManual && this.runner?.running) {
      this.runner.stop();
      this._resetAutoArenaToIdle();
    }
    document.getElementById('autoModeArena').classList.toggle('hidden', isManual);
    document.getElementById('manualModeArena').classList.toggle('hidden', !isManual);
    if (isManual) {
      this._syncManualFrequencyOptions();
      this._updateManualReadout();
    }
  }

  _bindTestTab() {
    document.getElementById('selectFreqSet').addEventListener('change', () => {
      const isExt = document.getElementById('selectFreqSet').value === 'extended';
      this.liveChart.setOptions({ showExtendedGrid: isExt });
      this.mainChart.setOptions({ showExtendedGrid: isExt });
      this._syncManualFrequencyOptions();
      this._renderFrequencyStepperRail();
    });

    document.getElementById('selectMethodMode').addEventListener('change', () => {
      this._toggleTestMethodArena();
    });

    document.getElementById('btnJumpFullReport').addEventListener('click', () => {
      this.switchTab('tab-report');
    });

    // Automated Mode Controls
    document.getElementById('btnStartAutoTest').addEventListener('click', () => {
      this._startAutomatedTest();
    });

    const heardBtn = document.getElementById('btnHeardResponse');
    const triggerHeard = (e) => {
      e.preventDefault();
      if (!this.runner || !this.runner.running) return;
      const accepted = this.runner.registerUserResponse();
      if (accepted) {
        heardBtn.classList.add('pressed');
        setTimeout(() => heardBtn.classList.remove('pressed'), 180);
      }
    };
    heardBtn.addEventListener('pointerdown', triggerHeard);

    document.getElementById('btnPauseResume').addEventListener('click', () => {
      if (!this.runner) return;
      const btn = document.getElementById('btnPauseResume');
      if (this.runner.paused) {
        this.runner.resume();
        btn.textContent = '暂停';
      } else {
        this.runner.pause();
        btn.textContent = '继续测听';
      }
    });

    document.getElementById('btnRestartFreq').addEventListener('click', () => {
      if (!this.runner) return;
      this.runner.restartCurrentFrequency();
      this.showToast('已重置当前频率，重新寻找听阈');
    });

    document.getElementById('btnSkipNoResponse').addEventListener('click', () => {
      if (!this.runner) return;
      this.runner.skipCurrentAsNoResponse();
    });

    document.getElementById('btnFinishEarly').addEventListener('click', () => {
      if (this.runner) this.runner.stop();
      this._resetAutoArenaToIdle();
      this.switchTab('tab-report');
    });

    // Manual Self-Paced Fine-Tune Controls
    document.getElementById('btnManualEarLeft').addEventListener('click', () => {
      this.manualState.ear = 'left';
      const existing = this.currentResults?.left?.[this.manualState.freq]?.db;
      if (Number.isFinite(existing)) this.manualState.db = existing;
      this._updateManualReadout();
    });

    document.getElementById('btnManualEarRight').addEventListener('click', () => {
      this.manualState.ear = 'right';
      const existing = this.currentResults?.right?.[this.manualState.freq]?.db;
      if (Number.isFinite(existing)) this.manualState.db = existing;
      this._updateManualReadout();
    });

    document.getElementById('selectManualFreq').addEventListener('change', (e) => {
      this.manualState.freq = Number(e.target.value);
      const existing = this.currentResults?.[this.manualState.ear]?.[this.manualState.freq]?.db;
      if (Number.isFinite(existing)) {
        this.manualState.db = existing;
      } else {
        this.manualState.db = Math.min(30, this.audio.getMaxSafeDbHL(this.manualState.freq));
      }
      this._updateManualReadout();
    });

    document.getElementById('btnManualPrevFreq').addEventListener('click', () => {
      this._stepManualFrequency(-1);
    });
    document.getElementById('btnManualNextFreq').addEventListener('click', () => {
      this._stepManualFrequency(1);
    });

    document.querySelectorAll('.manual-step-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        const delta = Number(btn.dataset.step);
        const maxDb = this.audio.getMaxSafeDbHL(this.manualState.freq);
        this.manualState.db = Math.max(TEST_MIN_DB, Math.min(maxDb, this.manualState.db + delta));
        this._updateManualReadout();
        this._playManualTone(this.manualState.ear);
      });
    });

    document.getElementById('btnManualPlay').addEventListener('click', () => {
      this._playManualTone(this.manualState.ear);
    });

    document.getElementById('btnManualCompareOpp').addEventListener('click', () => {
      const opp = this.manualState.ear === 'left' ? 'right' : 'left';
      this._playManualTone(opp, false);
      this.showToast(`正在对侧【${opp === 'left' ? '左耳' : '右耳'}】播放同频率 ${this.manualState.db} dB HL 供响度对比`);
    });

    document.getElementById('btnManualSavePoint').addEventListener('click', () => {
      this._commitManualPoint(false);
    });

    document.getElementById('btnManualMarkNR').addEventListener('click', () => {
      this.manualState.db = this.audio.getMaxSafeDbHL(this.manualState.freq);
      this._commitManualPoint(true);
    });
  }

  _startAutomatedTest(overrideSteps = null) {
    if (this.isDemoPreview) {
      this.currentResults = { left: {}, right: {} };
      this.isDemoPreview = false;
    }

    const steps = overrideSteps || this._buildOrderedSteps();
    // If doing full test (not single point retest), clear only ears being tested completely if user starts fresh
    if (!overrideSteps) {
      const order = document.getElementById('selectEarOrder').value;
      if (order === 'left_only') {
        this.currentResults.left = {};
      } else if (order === 'right_only') {
        this.currentResults.right = {};
      } else {
        this.currentResults = { left: {}, right: {} };
      }
    }

    const toneType = document.getElementById('selectToneType').value;
    const enableMasking = document.getElementById('chkEnableMasking').checked;

    document.getElementById('autoStartPanel').classList.add('hidden');
    document.getElementById('autoRunningPanel').classList.remove('hidden');
    document.getElementById('btnPauseResume').textContent = '暂停';

    this.runner = new HughsonWestlakeRunner({
      audioEngine: this.audio,
      steps,
      toneType,
      enableMasking,
      initialResults: this.currentResults,
      onStateChange: (st) => {
        this._updateAutoArenaUI(st);
      },
      onPointComplete: (pt, updatedResults, idx, total) => {
        this.currentResults = structuredClone(updatedResults);
        this.liveChart.setData(this.currentResults, null);
        this._renderFrequencyStepperRail(pt.ear, pt.freq);
        document.getElementById('freqProgressCounter').textContent = `已完成 ${idx + 1} / ${total}`;
      },
      onFalseAlarm: () => {
        this.showToast('提示：刚才还在静默等待期，请听到微弱“嘀-嘀-嘀”脉冲声后再按键哦');
      },
      onAllComplete: (finalResults) => {
        this.currentResults = structuredClone(finalResults);
        this._resetAutoArenaToIdle();
        this._refreshAllViews();
        this.showToast('纯音测听已完成！已为您生成左右耳标准听力曲线图');
        this.switchTab('tab-report');
      }
    });

    this.liveChart.setData(this.currentResults, null);
    this.runner.start();
  }

  _updateAutoArenaUI(st) {
    const earBadge = document.getElementById('currentEarBadge');
    const freqDisp = document.getElementById('currentFreqDisplay');
    const noteEl = document.getElementById('currentFreqClinicalNote');
    const statusEl = document.getElementById('autoLiveStatusText');
    const trialBadge = document.getElementById('trialCountBadge');
    const maskBadge = document.getElementById('maskingActiveBadge');

    if (st.ear === 'left') {
      earBadge.className = 'ear-indicator ear-left';
      earBadge.textContent = '正在测左耳 (✕ Left)';
    } else if (st.ear === 'right') {
      earBadge.className = 'ear-indicator ear-right';
      earBadge.textContent = '正在测右耳 (O Right)';
    }

    if (st.freq) {
      const info = FREQUENCY_LABELS[st.freq] || { band: '', note: '' };
      freqDisp.innerHTML = `${st.freq} Hz <small>${info.band}</small>`;
      noteEl.textContent = `${info.note} · 进度 ${st.stepIndex + 1}/${st.totalSteps}`;
      this.liveChart.setOptions({ activeHighlight: { ear: st.ear, freq: st.freq } });
      this._renderFrequencyStepperRail(st.ear, st.freq);
    }

    statusEl.textContent = st.statusText;
    trialBadge.textContent = `当前频点第 ${st.trialCount + 1} 次寻阈给声`;
    maskBadge.classList.toggle('hidden', !st.usedMasking);
    document.getElementById('freqProgressCounter').textContent = `测绘中 ${st.stepIndex + 1} / ${st.totalSteps}`;
  }

  _resetAutoArenaToIdle() {
    document.getElementById('autoStartPanel').classList.remove('hidden');
    document.getElementById('autoRunningPanel').classList.add('hidden');
    document.getElementById('currentEarBadge').className = 'ear-indicator ear-neutral';
    document.getElementById('currentEarBadge').textContent = '待机中';
    this.liveChart?.setOptions({ activeHighlight: null });
    this._renderFrequencyStepperRail();
  }

  _syncManualFrequencyOptions() {
    const freqs = this._getSelectedFrequencies();
    const sel = document.getElementById('selectManualFreq');
    sel.innerHTML = '';
    freqs.forEach((f) => {
      const opt = document.createElement('option');
      opt.value = String(f);
      opt.textContent = `${f} Hz (${FREQUENCY_LABELS[f]?.band || ''})`;
      sel.appendChild(opt);
    });
    if (!freqs.includes(this.manualState.freq)) {
      this.manualState.freq = freqs[0];
    }
    sel.value = String(this.manualState.freq);
  }

  _updateManualReadout() {
    const { ear, freq } = this.manualState;
    const maxDb = this.audio.getMaxSafeDbHL(freq);
    this.manualState.db = Math.max(TEST_MIN_DB, Math.min(maxDb, this.manualState.db));

    document.getElementById('btnManualEarLeft').classList.toggle('active', ear === 'left');
    document.getElementById('btnManualEarRight').classList.toggle('active', ear === 'right');
    document.getElementById('selectManualFreq').value = String(freq);
    document.getElementById('manualFreqTitle').innerHTML = `${freq} Hz <small>${FREQUENCY_LABELS[freq]?.band || ''}</small>`;
    document.getElementById('manualDbValue').innerHTML = `${this.manualState.db} <small>dB HL</small>`;
    document.getElementById('manualCeilingHint').textContent = `当前频点零削波安全上限: ${maxDb} dB HL`;
    this._renderFrequencyStepperRail(ear, freq);
  }

  _stepManualFrequency(dir) {
    const freqs = this._getSelectedFrequencies();
    const idx = freqs.indexOf(this.manualState.freq);
    const nextIdx = Math.max(0, Math.min(freqs.length - 1, idx + dir));
    this.manualState.freq = freqs[nextIdx];
    const existing = this.currentResults?.[this.manualState.ear]?.[this.manualState.freq]?.db;
    if (Number.isFinite(existing)) {
      this.manualState.db = existing;
    } else {
      this.manualState.db = Math.min(30, this.audio.getMaxSafeDbHL(this.manualState.freq));
    }
    this._updateManualReadout();
  }

  _playManualTone(targetEar, allowMask = true) {
    const toneType = document.getElementById('selectToneType').value;
    const useMask = allowMask && document.getElementById('chkManualMask').checked;
    let maskDb = null;
    if (useMask) {
      const oppEar = targetEar === 'left' ? 'right' : 'left';
      const oppBase = this.currentResults?.[oppEar]?.[this.manualState.freq]?.db ?? 15;
      maskDb = Math.min(65, Math.max(25, oppBase + 20));
    }
    this.audio.playStimulus({
      freq: this.manualState.freq,
      dbHL: this.manualState.db,
      ear: targetEar,
      toneType,
      maskingDbHL: maskDb
    });
  }

  _commitManualPoint(noResponse = false) {
    if (this.isDemoPreview) {
      this.currentResults = { left: {}, right: {} };
      this.isDemoPreview = false;
    }
    const { ear, freq, db } = this.manualState;
    const masked = document.getElementById('chkManualMask').checked;
    this.currentResults[ear][freq] = {
      db,
      noResponse,
      masked,
      timestamp: Date.now()
    };

    this.liveChart.setData(this.currentResults, null);
    this._renderFrequencyStepperRail(ear, freq);

    // Advance low -> high automatically! If reached 8000 Hz, offer switching to other ear or report!
    const freqs = this._getSelectedFrequencies();
    const idx = freqs.indexOf(freq);
    if (idx < freqs.length - 1) {
      this.manualState.freq = freqs[idx + 1];
      const nextExisting = this.currentResults?.[ear]?.[this.manualState.freq]?.db;
      this.manualState.db = Number.isFinite(nextExisting)
        ? nextExisting
        : Math.min(35, Math.max(20, db));
      this._updateManualReadout();
      this.showToast(`已记录 ${ear === 'left' ? '左耳' : '右耳'} ${freq}Hz = ${noResponse ? '>' : ''}${db} dB，升至 ${this.manualState.freq}Hz`);
    } else {
      const otherEar = ear === 'left' ? 'right' : 'left';
      const otherCount = Object.keys(this.currentResults[otherEar] || {}).length;
      if (otherCount === 0) {
        this.manualState.ear = otherEar;
        this.manualState.freq = freqs[0];
        this.manualState.db = 30;
        this._updateManualReadout();
        this.showToast(`${ear === 'left' ? '左耳' : '右耳'}全频段记录完毕！已自动切换至${otherEar === 'left' ? '左耳' : '右耳'} 125Hz 起点`);
      } else {
        this._refreshAllViews();
        this.showToast('双耳全频段记录完成！为您展示完整双耳听力曲线图');
        this.switchTab('tab-report');
      }
    }
  }

  /* ========================================================================
   * TAB 3: BILATERAL AUDIOGRAM & CLINICAL REPORT
   * ======================================================================== */
  _bindReportTab() {
    document.getElementById('chkShowBands').addEventListener('change', (e) => {
      this.mainChart.setOptions({ showSeverityBands: e.target.checked });
    });
    document.getElementById('chkShowBanana').addEventListener('change', (e) => {
      this.mainChart.setOptions({ showSpeechBanana: e.target.checked });
    });
    document.getElementById('chkShowAsymmetry').addEventListener('change', (e) => {
      this.mainChart.setOptions({ showAsymmetryShade: e.target.checked });
    });

    document.getElementById('selectBaselineOverlay').addEventListener('change', () => {
      this._refreshReportView();
    });

    document.getElementById('btnDemoLowFreq').addEventListener('click', () => {
      this.currentResults = structuredClone(DEMO_PROFILES.low_freq_ssnhl.results);
      this.isDemoPreview = true;
      this._refreshAllViews();
      this.showToast('已加载预览：典型左耳低频下降型突发性耳聋听力图');
    });

    document.getElementById('btnDemoHighFreq').addEventListener('click', () => {
      this.currentResults = structuredClone(DEMO_PROFILES.high_freq_ssnhl.results);
      this.isDemoPreview = true;
      this._refreshAllViews();
      this.showToast('已加载预览：典型右耳高频下降型突发性耳聋听力图');
    });

    document.getElementById('btnClearCurrentData').addEventListener('click', () => {
      this.currentResults = { left: {}, right: {} };
      this.isDemoPreview = false;
      this._refreshAllViews();
    });

    // Inspector Bar actions
    document.getElementById('btnCloseInspector').addEventListener('click', () => {
      document.getElementById('pointInspectorBar').classList.add('hidden');
    });

    document.getElementById('btnInspectPlayLeft').addEventListener('click', () => {
      if (!this.inspectedFreq) return;
      const db = this.currentResults?.left?.[this.inspectedFreq]?.db ?? 25;
      this.audio.playStimulus({ freq: this.inspectedFreq, dbHL: db, ear: 'left', toneType: 'pulsed' });
    });

    document.getElementById('btnInspectPlayRight').addEventListener('click', () => {
      if (!this.inspectedFreq) return;
      const db = this.currentResults?.right?.[this.inspectedFreq]?.db ?? 25;
      this.audio.playStimulus({ freq: this.inspectedFreq, dbHL: db, ear: 'right', toneType: 'pulsed' });
    });

    document.getElementById('btnInspectRetestLeft').addEventListener('click', () => {
      this._jumpToManualSinglePoint('left', this.inspectedFreq);
    });
    document.getElementById('btnInspectRetestRight').addEventListener('click', () => {
      this._jumpToManualSinglePoint('right', this.inspectedFreq);
    });

    // Quick Tags & Save Session
    document.querySelectorAll('.tag-chip').forEach((chip) => {
      chip.addEventListener('click', () => {
        const inp = document.getElementById('inputSessionNote');
        const tag = chip.dataset.tag;
        if (!inp.value.includes(tag)) {
          inp.value = inp.value ? `${inp.value} · ${tag}` : tag;
        }
      });
    });

    document.getElementById('btnSaveSession').addEventListener('click', () => {
      const hasPoints =
        Object.keys(this.currentResults.left || {}).length > 0 ||
        Object.keys(this.currentResults.right || {}).length > 0;
      if (!hasPoints) {
        this.showToast('当前尚无测听数据，请先完成测试后再保存');
        return;
      }
      if (this.isDemoPreview) {
        this.showToast('当前为示例预览数据，请先进行您的真实听力测试后再保存档案');
        return;
      }
      const note = document.getElementById('inputSessionNote').value.trim();
      saveSession({
        source: 'home_test',
        profileId: this.audio.profileId,
        toneType: document.getElementById('selectToneType').value,
        note,
        results: structuredClone(this.currentResults)
      });
      document.getElementById('inputSessionNote').value = '';
      this._refreshBaselineDropdown();
      this._refreshReportView();
      this.showToast('已保存至本地康复随访档案！可在「耳鸣匹配与康复档案」查看恢复趋势');
    });

    // Export High-DPI Medical PNG Report
    document.getElementById('btnExportPng').addEventListener('click', () => {
      const note = document.getElementById('inputSessionNote').value.trim();
      const url = this.mainChart.exportReportPng({
        profileId: this.audio.profileId,
        note
      });
      const a = document.createElement('a');
      const d = new Date();
      const stamp = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}_${String(d.getHours()).padStart(2, '0')}${String(d.getMinutes()).padStart(2, '0')}`;
      a.href = url;
      a.download = `左右耳听力曲线报告_${stamp}.png`;
      a.click();
      this.showToast('已生成并下载高清左右耳纯音听力曲线图报告 (PNG)');
    });
  }

  _openPointInspector(freq) {
    this.inspectedFreq = freq;
    const bar = document.getElementById('pointInspectorBar');
    const l = this.currentResults?.left?.[freq];
    const r = this.currentResults?.right?.[freq];
    document.getElementById('inspectorTitle').textContent = `频点操作：${freq} Hz (${FREQUENCY_LABELS[freq]?.band || ''})`;
    document.getElementById('inspectorValues').textContent = `左耳(✕): ${
      l ? `${l.noResponse ? '>' : ''}${l.db} dB HL` : '未测'
    }  |  右耳(O): ${r ? `${r.noResponse ? '>' : ''}${r.db} dB HL` : '未测'}`;
    bar.classList.remove('hidden');
  }

  _jumpToManualSinglePoint(ear, freq, forceMask = false) {
    if (!freq) return;
    if ([750, 1500, 3000, 6000].includes(freq)) {
      document.getElementById('selectFreqSet').value = 'extended';
      this._syncManualFrequencyOptions();
    }
    document.getElementById('selectMethodMode').value = 'manual';
    this._toggleTestMethodArena();
    this.manualState.ear = ear;
    this.manualState.freq = freq;
    this.manualState.db = this.currentResults?.[ear]?.[freq]?.db ?? 30;
    if (forceMask) {
      document.getElementById('chkManualMask').checked = true;
    }
    this._updateManualReadout();
    this.switchTab('tab-test');
    this.showToast(`已定位到【${ear === 'left' ? '左耳' : '右耳'} ${freq} Hz】，可精细微调并确认`);
  }

  _refreshBaselineDropdown() {
    const sel = document.getElementById('selectBaselineOverlay');
    const prevVal = sel.value;
    const sessions = loadSessions();
    sel.innerHTML = '<option value="">不叠加对比曲线</option>';
    sessions.forEach((s) => {
      const dt = new Date(s.timestamp).toLocaleString('zh-CN', {
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit'
      });
      const tag = s.source === 'hospital_import' ? '[医院报告]' : '[居家自测]';
      const opt = document.createElement('option');
      opt.value = s.id;
      opt.textContent = `${tag} ${dt} ${s.note ? `· ${s.note.slice(0, 12)}` : ''}`;
      sel.appendChild(opt);
    });
    if (prevVal && sessions.some((s) => s.id === prevVal)) {
      sel.value = prevVal;
    } else if (sessions.length >= 2) {
      // Automatically select earliest/hospital baseline if multiple sessions exist!
      const hospitalSess = sessions.find((s) => s.source === 'hospital_import');
      sel.value = hospitalSess ? hospitalSess.id : sessions[sessions.length - 1].id;
    }
  }

  _refreshReportView() {
    const sessions = loadSessions();
    const hasCurrent =
      Object.keys(this.currentResults.left || {}).length > 0 ||
      Object.keys(this.currentResults.right || {}).length > 0;

    document.getElementById('emptyReportDemoBar').classList.toggle('hidden', hasCurrent && !this.isDemoPreview);

    const baseId = document.getElementById('selectBaselineOverlay').value;
    const baseSession = sessions.find((s) => s.id === baseId) || null;
    const baseLabel = baseSession
      ? `${baseSession.source === 'hospital_import' ? '医院基线' : '历史基线'} (${new Date(baseSession.timestamp).toLocaleDateString('zh-CN')})`
      : '对比基线';

    this.mainChart.setData(this.currentResults, baseSession?.results || null, baseLabel);
    this._renderThresholdTable();

    const bi = analyzeBilateral(this.currentResults, this.audio.profileId);
    this._populateEarSummaryCard('right', bi.right);
    this._populateEarSummaryCard('left', bi.left);
    this._renderClinicalAlerts(bi);
    this._renderBaselineComparisonBanner(baseSession);
  }

  _populateEarSummaryCard(ear, sum) {
    const badge = document.getElementById(`${ear}SeverityBadge`);
    badge.className = `grade-badge ${sum.severity.badgeClass}`;
    badge.textContent = sum.hasData ? sum.severity.label : '未测';

    document.getElementById(`${ear}PtaVal`).textContent = sum.pta4 !== null ? `${sum.pta4} dB` : '--';
    document.getElementById(`${ear}LowVal`).textContent = sum.lowAvg !== null ? `${sum.lowAvg} dB` : '--';
    document.getElementById(`${ear}HighVal`).textContent = sum.highAvg !== null ? `${sum.highAvg} dB` : '--';
    document.getElementById(`${ear}CurveType`).textContent = sum.curveType;
    document.getElementById(`${ear}CurveDetail`).textContent = sum.curveDetail;

    const warnEl = document.getElementById(`${ear}FocalWarn`);
    if (sum.focalWarning) {
      warnEl.textContent = sum.focalWarning;
      warnEl.classList.remove('hidden');
    } else {
      warnEl.classList.add('hidden');
    }
  }

  _renderClinicalAlerts(bi) {
    const container = document.getElementById('clinicalAlertsContainer');
    container.innerHTML = '';

    // 1. Consecutive >=20 dB interaural asymmetry alert (CMA/AAO-HNS SSNHL hallmark)
    if (bi.consecutive20dB.length > 0) {
      const side = bi.consecutive20dB[0].ear === 'left' ? '左耳' : '右耳';
      const pairsStr = bi.consecutive20dB.map((p) => `${p.pair[0]}–${p.pair[1]}Hz`).join('、');
      const div = document.createElement('div');
      div.className = 'clinical-alert-item clinical-alert-warn';
      div.innerHTML = `
        <div>
          <strong>检测到相邻频率双耳不对称 ≥20 dB（${side}：${pairsStr}）</strong><br/>
          符合《突发性聋诊断和治疗指南》相邻至少两个频率下降 ≥20 dB HL 的曲线特征。若为新近发生或较前加重，请务必及时在耳鼻咽喉科规范诊疗。
        </div>
      `;
      container.appendChild(div);
    }

    // 2. Shadow Curve / Cross-hearing warning
    if (bi.shadowRisks.length > 0) {
      const r0 = bi.shadowRisks[0];
      const sideTxt = r0.ear === 'left' ? '左耳' : '右耳';
      const freqsTxt = bi.shadowRisks.map((s) => `${s.freq}Hz`).join('、');
      const div = document.createElement('div');
      div.className = 'clinical-alert-item clinical-alert-mask';
      div.innerHTML = `
        <div>
          <strong>交叉听力（影子曲线）复核提示：</strong>${sideTxt}在 <strong>${freqsTxt}</strong> 与对侧好耳差距已达 ${r0.diff} dB（≥耳间衰减 ${r0.ia} dB）且未启用掩蔽，可能存在声音经颅骨传至好耳被“代听”的可能。
        </div>
        <button type="button" class="btn btn-outline btn-sm">加窄带掩蔽复核 ${r0.freq}Hz</button>
      `;
      div.querySelector('button').addEventListener('click', () => {
        this._jumpToManualSinglePoint(r0.ear, r0.freq, true);
      });
      container.appendChild(div);
    }
  }

  _renderBaselineComparisonBanner(baseSession) {
    const box = document.getElementById('baselineComparisonBox');
    if (!baseSession) {
      box.classList.add('hidden');
      return;
    }
    const reports = compareWithBaseline(this.currentResults, baseSession.results);
    if (!reports || reports.length === 0) {
      box.classList.add('hidden');
      return;
    }

    box.classList.remove('hidden');
    box.innerHTML = reports
      .map(
        (r) => `
        <div style="margin-bottom: 6px;">
          <strong>纵向疗效参考评估（对比 ${new Date(baseSession.timestamp).toLocaleDateString('zh-CN')} ${baseSession.source === 'hospital_import' ? '医院报告' : '基线'}）：【${r.grade}】</strong><br/>
          <span>${r.summary}（基线受损均值 ${r.baseMean} dB → 当前 ${r.currMean} dB）</span>
        </div>
      `
      )
      .join('');
  }

  _renderThresholdTable() {
    const table = document.getElementById('thresholdDataTable');
    const hasInter = [750, 1500, 3000, 6000].some(
      (f) => this.currentResults?.left?.[f] || this.currentResults?.right?.[f]
    );
    const freqs =
      document.getElementById('selectFreqSet').value === 'extended' || hasInter
        ? EXTENDED_FREQUENCIES
        : STANDARD_FREQUENCIES;

    const formatCell = (pt) => {
      if (!pt) return '<span class="text-muted">--</span>';
      const prefix = pt.noResponse ? '&gt;' : '';
      const maskTag = pt.masked ? ' <small title="已加对侧掩蔽">[掩]</small>' : '';
      return `<strong>${prefix}${pt.db}</strong>${maskTag}`;
    };

    table.innerHTML = `
      <thead>
        <tr>
          <th>频率 (低频 → 高频)</th>
          ${freqs.map((f) => `<th>${f} Hz</th>`).join('')}
        </tr>
      </thead>
      <tbody>
        <tr>
          <td class="text-right-ear">右耳气导 O (dB HL)</td>
          ${freqs.map((f) => `<td class="text-right-ear">${formatCell(this.currentResults?.right?.[f])}</td>`).join('')}
        </tr>
        <tr>
          <td class="text-left-ear">左耳气导 ✕ (dB HL)</td>
          ${freqs.map((f) => `<td class="text-left-ear">${formatCell(this.currentResults?.left?.[f])}</td>`).join('')}
        </tr>
        <tr>
          <td>双耳差值 |L - R|</td>
          ${freqs
            .map((f) => {
              const l = this.currentResults?.left?.[f];
              const r = this.currentResults?.right?.[f];
              if (!l || !r) return '<td class="text-muted">--</td>';
              const d = Math.abs(l.db - r.db);
              return `<td style="${d >= 20 ? 'color:#b45309;font-weight:700;' : ''}">${d} dB</td>`;
            })
            .join('')}
        </tr>
      </tbody>
    `;
  }

  /* ========================================================================
   * HOSPITAL AUDIOGRAM MODAL
   * ======================================================================== */
  _bindHospitalModal() {
    const modal = document.getElementById('hospitalModal');
    const close = () => modal.classList.add('hidden');

    document.getElementById('btnOpenHospitalModal').addEventListener('click', () => {
      modal.classList.remove('hidden');
    });
    document.getElementById('btnCloseHospitalModal').addEventListener('click', close);
    document.getElementById('btnCancelHospitalModal').addEventListener('click', close);

    document.getElementById('btnSaveHospitalReport').addEventListener('click', () => {
      const hospResults = { left: {}, right: {} };
      let count = 0;
      document.querySelectorAll('[data-hosp-ear]').forEach((inp) => {
        const val = inp.value.trim();
        if (val !== '') {
          const num = Number(val);
          if (Number.isFinite(num) && num >= -10 && num <= 120) {
            const ear = inp.dataset.hospEar;
            const freq = Number(inp.dataset.hospFreq);
            hospResults[ear][freq] = { db: num, noResponse: false, masked: false };
            count++;
          }
        }
      });

      if (count === 0) {
        this.showToast('请至少填入一个频点的医院测听数值');
        return;
      }

      const note = document.getElementById('inputHospitalNote').value.trim() || '医院纯音测听基准';
      const saved = saveSession({
        source: 'hospital_import',
        profileId: this.audio.profileId,
        note,
        results: hospResults
      });

      const hasCurrent =
        Object.keys(this.currentResults.left || {}).length > 0 ||
        Object.keys(this.currentResults.right || {}).length > 0;
      if (!hasCurrent || this.isDemoPreview) {
        this.currentResults = structuredClone(hospResults);
        this.isDemoPreview = false;
      }

      close();
      this._refreshBaselineDropdown();
      document.getElementById('selectBaselineOverlay').value = saved.id;
      this._refreshReportView();
      this.showToast('医院测听报告已保存，并设为叠加对比基线！');
    });
  }

  /* ========================================================================
   * TAB 4: RECOVERY ARCHIVE & TINNITUS MATCHER
   * ======================================================================== */
  _bindHistoryAndTinnitusTab() {
    document.getElementById('selectTrendEar').addEventListener('change', () => {
      this._renderTrend();
    });

    document.getElementById('btnExportJson').addEventListener('click', () => {
      const json = exportAllDataJson();
      const blob = new Blob([json], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `突发性耳聋听力随访备份_${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      URL.revokeObjectURL(url);
      this.showToast('已导出全部测听档案 JSON 备份');
    });

    document.getElementById('inputImportJson').addEventListener('change', (e) => {
      const file = e.target.files?.[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = () => {
        try {
          const n = importAllDataJson(String(reader.result));
          this._restoreSettings();
          this._refreshAllViews();
          this.showToast(`成功导入 ${n} 条历史测听档案！`);
        } catch (err) {
          this.showToast(`导入失败：${err.message}`);
        }
      };
      reader.readAsText(file);
    });

    // Logarithmic Tinnitus Frequency Slider: 0..1000 -> 125 Hz .. 10000 Hz
    const tinSlider = document.getElementById('tinFreqSlider');
    const tinDbSlider = document.getElementById('tinDbSlider');
    const sliderToHz = (v) => Math.round(125 * Math.pow(10000 / 125, Number(v) / 1000));
    const hzToSlider = (hz) =>
      Math.round((Math.log(Math.max(125, Math.min(10000, hz)) / 125) / Math.log(10000 / 125)) * 1000);

    const syncTinnitusParams = () => {
      const freq = sliderToHz(tinSlider.value);
      const dbHL = Number(tinDbSlider.value);
      const mode = document.getElementById('tinWaveform').value;
      const ear = document.getElementById('tinEar').value;
      document.getElementById('tinFreqReadout').textContent = `${freq} Hz`;
      document.getElementById('tinDbReadout').textContent = `${dbHL} dB HL`;
      if (this.tinnitusPlaying) {
        this.audio.updateSustainedTone({ freq, dbHL, ear, mode });
      }
    };

    tinSlider.addEventListener('input', syncTinnitusParams);
    tinDbSlider.addEventListener('input', syncTinnitusParams);
    document.getElementById('tinWaveform').addEventListener('change', syncTinnitusParams);
    document.getElementById('tinEar').addEventListener('change', syncTinnitusParams);

    document.getElementById('btnTinTogglePlay').addEventListener('click', () => {
      if (this.tinnitusPlaying) {
        this._stopTinnitusUI();
      } else {
        const freq = sliderToHz(tinSlider.value);
        const dbHL = Number(tinDbSlider.value);
        const mode = document.getElementById('tinWaveform').value;
        const ear = document.getElementById('tinEar').value;
        this.audio.startSustainedTone({ freq, dbHL, ear, mode });
        this.tinnitusPlaying = true;
        document.getElementById('btnTinTogglePlay').textContent = '■ 停止匹配音';
      }
    });

    document.getElementById('btnTinHalfOctave').addEventListener('click', () => {
      const cur = sliderToHz(tinSlider.value);
      tinSlider.value = String(hzToSlider(Math.max(125, Math.round(cur / 2))));
      syncTinnitusParams();
    });

    document.getElementById('btnTinDoubleOctave').addEventListener('click', () => {
      const cur = sliderToHz(tinSlider.value);
      tinSlider.value = String(hzToSlider(Math.min(10000, cur * 2)));
      syncTinnitusParams();
    });

    document.getElementById('btnSaveTinnitusLog').addEventListener('click', () => {
      const freq = sliderToHz(tinSlider.value);
      const dbHL = Number(tinDbSlider.value);
      const mode = document.getElementById('tinWaveform').value;
      const vas = Number(document.getElementById('tinVasSelect').value);
      saveTinnitusLog({ freq, dbHL, mode, vas });
      this._renderTinnitusLogs();
      this.showToast(`已记录耳鸣特征：约 ${freq} Hz (${mode === 'sine' ? '纯音样' : '窄带噪声样'})`);
    });
  }

  _stopTinnitusUI() {
    this.audio.stopSustainedTone();
    this.tinnitusPlaying = false;
    document.getElementById('btnTinTogglePlay').textContent = '▶ 播放耳鸣匹配音';
  }

  _renderTrend() {
    const sessions = loadSessions();
    const earChoice = document.getElementById('selectTrendEar').value;
    renderRecoveryTrendChart(document.getElementById('recoveryTrendCanvas'), sessions, earChoice);
  }

  _refreshHistoryTab() {
    this._renderTrend();
    this._renderTinnitusLogs();

    const listEl = document.getElementById('sessionHistoryList');
    const sessions = loadSessions();
    if (sessions.length === 0) {
      listEl.innerHTML = '<p class="text-muted">暂无已保存的测听记录。完成测试后在「左右耳听力曲线图」底部点击保存即可建立随访档案。</p>';
      return;
    }

    listEl.innerHTML = '';
    sessions.forEach((s) => {
      const bi = analyzeBilateral(s.results, s.profileId);
      const dt = new Date(s.timestamp).toLocaleString('zh-CN');
      const rPta = bi.right.pta4 !== null ? `${bi.right.pta4}dB` : '--';
      const lPta = bi.left.pta4 !== null ? `${bi.left.pta4}dB` : '--';
      const rLow = bi.right.lowAvg !== null ? `${bi.right.lowAvg}dB` : '--';
      const lLow = bi.left.lowAvg !== null ? `${bi.left.lowAvg}dB` : '--';

      const item = document.createElement('div');
      item.className = 'history-item';
      item.innerHTML = `
        <div class="history-item-top">
          <span class="history-date">${dt}</span>
          <span class="badge ${s.source === 'hospital_import' ? 'badge-mask' : 'badge-neutral'}">
            ${s.source === 'hospital_import' ? '医院报告' : '居家测听'}
          </span>
        </div>
        <div class="history-metrics">
          <span class="text-right-ear">右耳(O) PTA: ${rPta} / 低频: ${rLow}</span> &nbsp;|&nbsp;
          <span class="text-left-ear">左耳(✕) PTA: ${lPta} / 低频: ${lLow}</span>
        </div>
        ${s.note ? `<div class="history-note">备注：${s.note}</div>` : ''}
        <div class="history-btns">
          <button type="button" class="btn btn-outline btn-sm btn-load-sess">载入到主听力图</button>
          <button type="button" class="btn btn-secondary btn-sm btn-base-sess">设为对比基线</button>
          <button type="button" class="btn btn-danger-outline btn-sm btn-del-sess">删除</button>
        </div>
      `;

      item.querySelector('.btn-load-sess').addEventListener('click', () => {
        this.currentResults = structuredClone(s.results);
        this.isDemoPreview = false;
        this._refreshAllViews();
        this.switchTab('tab-report');
      });

      item.querySelector('.btn-base-sess').addEventListener('click', () => {
        this._refreshBaselineDropdown();
        document.getElementById('selectBaselineOverlay').value = s.id;
        this._refreshReportView();
        this.switchTab('tab-report');
        this.showToast('已将该记录设为虚线对比基线');
      });

      item.querySelector('.btn-del-sess').addEventListener('click', () => {
        deleteSession(s.id);
        this._refreshAllViews();
      });

      listEl.appendChild(item);
    });
  }

  _renderTinnitusLogs() {
    const box = document.getElementById('tinnitusLogList');
    const logs = loadTinnitusLogs().slice(0, 6);
    if (logs.length === 0) {
      box.innerHTML = '';
      return;
    }
    box.innerHTML = logs
      .map((l) => {
        const dt = new Date(l.timestamp).toLocaleDateString('zh-CN', { month: '2-digit', day: '2-digit' });
        return `
          <div class="tin-log-entry">
            <span>${dt} · 主频约 <strong>${l.freq} Hz</strong> (${l.mode === 'sine' ? '纯音' : '窄带'})</span>
            <span>响度 ${l.dbHL} dB · VAS ${l.vas}/10</span>
          </div>
        `;
      })
      .join('');
  }

  _bindGlobalShortcuts() {
    window.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        this._emergencyMuteAll();
        return;
      }
      // Spacebar responds in Automated Test Mode when not typing in an input field
      const tag = document.activeElement?.tagName;
      if (e.code === 'Space' && tag !== 'INPUT' && tag !== 'TEXTAREA' && tag !== 'SELECT') {
        if (this.activeTab === 'tab-test' && this.runner && this.runner.running && !this.runner.paused) {
          e.preventDefault();
          const btn = document.getElementById('btnHeardResponse');
          const ok = this.runner.registerUserResponse();
          if (ok) {
            btn.classList.add('pressed');
            setTimeout(() => btn.classList.remove('pressed'), 180);
          }
        }
      }
    });
  }

  _refreshAllViews() {
    this._renderFrequencyStepperRail();
    this.liveChart?.setData(this.currentResults, null);
    this._refreshBaselineDropdown();
    this._refreshReportView();
    if (this.activeTab === 'tab-history') {
      this._refreshHistoryTab();
    }
  }
}

document.addEventListener('DOMContentLoaded', () => {
  const app = new HearGuardApp();
  app.init();
});
