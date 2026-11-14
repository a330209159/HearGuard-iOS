/**
 * Local Storage Manager for SSNHL Audiometry Sessions, Calibration & Tinnitus Logs
 * 100% offline local storage — zero cloud upload to protect personal medical privacy.
 */

const KEY_SETTINGS = 'ssnhl_audiometry_settings_v1';
const KEY_SESSIONS = 'ssnhl_audiometry_sessions_v1';
const KEY_TINNITUS = 'ssnhl_tinnitus_logs_v1';

export function loadSettings() {
  try {
    const raw = localStorage.getItem(KEY_SETTINGS);
    if (!raw) return null;
    return JSON.parse(raw);
  } catch (_) {
    return null;
  }
}

export function saveSettings(settings) {
  try {
    localStorage.setItem(KEY_SETTINGS, JSON.stringify(settings));
  } catch (_) {}
}

export function loadSessions() {
  try {
    const raw = localStorage.getItem(KEY_SESSIONS);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.sort((a, b) => b.timestamp - a.timestamp) : [];
  } catch (_) {
    return [];
  }
}

export function saveSession(session) {
  const list = loadSessions();
  const entry = {
    id: session.id || `sess_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`,
    timestamp: session.timestamp || Date.now(),
    source: session.source || 'home_test', // 'home_test' | 'hospital_import'
    profileId: session.profileId || 'in_ear',
    toneType: session.toneType || 'pulsed',
    note: session.note || '',
    symptoms: session.symptoms || {},
    results: session.results || { left: {}, right: {} }
  };
  const existingIdx = list.findIndex((s) => s.id === entry.id);
  if (existingIdx >= 0) {
    list[existingIdx] = entry;
  } else {
    list.unshift(entry);
  }
  try {
    localStorage.setItem(KEY_SESSIONS, JSON.stringify(list));
  } catch (_) {}
  return entry;
}

export function deleteSession(id) {
  const list = loadSessions().filter((s) => s.id !== id);
  try {
    localStorage.setItem(KEY_SESSIONS, JSON.stringify(list));
  } catch (_) {}
  return list;
}

export function loadTinnitusLogs() {
  try {
    const raw = localStorage.getItem(KEY_TINNITUS);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.sort((a, b) => b.timestamp - a.timestamp) : [];
  } catch (_) {
    return [];
  }
}

export function saveTinnitusLog(log) {
  const list = loadTinnitusLogs();
  const item = {
    id: `tin_${Date.now()}`,
    timestamp: Date.now(),
    ...log
  };
  list.unshift(item);
  try {
    localStorage.setItem(KEY_TINNITUS, JSON.stringify(list));
  } catch (_) {}
  return item;
}

export function exportAllDataJson() {
  return JSON.stringify(
    {
      exportedAt: new Date().toISOString(),
      app: 'SSNHL-Clinical-Audiometry-Tracker',
      version: 1,
      settings: loadSettings(),
      sessions: loadSessions(),
      tinnitusLogs: loadTinnitusLogs()
    },
    null,
    2
  );
}

export function importAllDataJson(jsonString) {
  const data = JSON.parse(jsonString);
  if (!data || !Array.isArray(data.sessions)) {
    throw new Error('备份文件格式无效');
  }
  localStorage.setItem(KEY_SESSIONS, JSON.stringify(data.sessions));
  if (data.settings) {
    localStorage.setItem(KEY_SETTINGS, JSON.stringify(data.settings));
  }
  if (Array.isArray(data.tinnitusLogs)) {
    localStorage.setItem(KEY_TINNITUS, JSON.stringify(data.tinnitusLogs));
  }
  return data.sessions.length;
}

/**
 * Sample clinical profiles for quick demonstration (not saved into user history)
 */
export const DEMO_PROFILES = {
  low_freq_ssnhl: {
    label: '示例：左耳低频下降型突聋 (125–500Hz 受损)',
    results: {
      right: {
        125: { db: 15 },
        250: { db: 15 },
        500: { db: 10 },
        1000: { db: 10 },
        2000: { db: 15 },
        4000: { db: 15 },
        8000: { db: 20 }
      },
      left: {
        125: { db: 50 },
        250: { db: 55 },
        500: { db: 45 },
        1000: { db: 25 },
        2000: { db: 15 },
        4000: { db: 15 },
        8000: { db: 20 }
      }
    }
  },
  high_freq_ssnhl: {
    label: '示例：右耳高频下降型突聋 (2k–8kHz 受损)',
    results: {
      left: {
        125: { db: 15 },
        250: { db: 10 },
        500: { db: 10 },
        1000: { db: 10 },
        2000: { db: 15 },
        4000: { db: 15 },
        8000: { db: 20 }
      },
      right: {
        125: { db: 15 },
        250: { db: 15 },
        500: { db: 15 },
        1000: { db: 20 },
        2000: { db: 45 },
        4000: { db: 65, masked: true },
        8000: { db: 70, masked: true }
      }
    }
  }
};
