// 通用工具：几何、格式化、网络请求、本地存储

export const RAD = Math.PI / 180;

export const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

export function distanceKm(lat1, lon1, lat2, lon2) {
  const dLat = (lat2 - lat1) * RAD;
  const dLon = (lon2 - lon1) * RAD;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * RAD) * Math.cos(lat2 * RAD) * Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/** 从某点沿方位角走 distanceKm 后的坐标 */
export function destination(lat, lon, distanceKm, bearing) {
  const delta = distanceKm / 6371;
  const phi1 = lat * RAD, lambda1 = lon * RAD, theta = bearing * RAD;
  const phi2 = Math.asin(Math.sin(phi1) * Math.cos(delta) + Math.cos(phi1) * Math.sin(delta) * Math.cos(theta));
  const lambda2 = lambda1 + Math.atan2(Math.sin(theta) * Math.sin(delta) * Math.cos(phi1),
    Math.cos(delta) - Math.sin(phi1) * Math.sin(phi2));
  const lon2 = ((lambda2 / RAD + 540) % 360) - 180;
  return [phi2 / RAD, lon2];
}

export function bearingDegrees(lat1, lon1, lat2, lon2) {
  const dLon = (lon2 - lon1) * RAD;
  const y = Math.sin(dLon) * Math.cos(lat2 * RAD);
  const x = Math.cos(lat1 * RAD) * Math.sin(lat2 * RAD) - Math.sin(lat1 * RAD) * Math.cos(lat2 * RAD) * Math.cos(dLon);
  return (Math.atan2(y, x) / RAD + 360) % 360;
}

export function compass(bearing) {
  const names = ['北', '东北', '东', '东南', '南', '西南', '西', '西北'];
  return names[Math.floor((((bearing % 360) + 360 + 22.5) % 360) / 45) % 8];
}

/** 「北偏西 17°」这种精确方向 */
export function preciseDirection(bearing) {
  const b = ((bearing % 360) + 360) % 360;
  const fromNorth = b > 180 ? 360 - b : b;
  const base = fromNorth <= 90 ? '北' : '南';
  const offset = Math.round(fromNorth <= 90 ? fromNorth : 180 - fromNorth);
  if (offset <= 2) return `正${base}`;
  if (offset >= 88) return b < 180 ? '正东' : '正西';
  return `${base}偏${b < 180 ? '东' : '西'} ${offset}°`;
}

// MARK: 格式化（时间按地点的时区显示）

const formatters = new Map();
function formatter(tz, options) {
  const key = tz + JSON.stringify(options);
  let f = formatters.get(key);
  if (!f) {
    try {
      f = new Intl.DateTimeFormat('zh-CN', { ...options, timeZone: tz || undefined });
    } catch {
      f = new Intl.DateTimeFormat('zh-CN', options);
    }
    formatters.set(key, f);
  }
  return f;
}

export const fmt = {
  time: (ms, tz) => formatter(tz, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(ms),
  hour: (ms, tz) => formatter(tz, { hour: '2-digit', hourCycle: 'h23' }).format(ms).replace(/\D/g, '').padStart(2, '0'),
  day: (ms, tz) => formatter(tz, { month: 'numeric', day: 'numeric' }).format(ms),
  kp: (v) => v.toFixed(1),
};

export function escapeHTML(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

// MARK: 网络

export async function fetchJSON(url, { timeout = 30000 } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(url, { signal: controller.signal, cache: 'no-store' });
    if (!response.ok) throw new Error(`服务器返回 ${response.status}`);
    return await response.json();
  } catch (error) {
    if (error.name === 'AbortError') throw new Error('请求超时');
    if (error instanceof TypeError) throw new Error('网络连接失败');
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

// MARK: 本地存储（隐私模式下可能不可用，读写都包一层）

export const store = {
  get(key, fallback = null) {
    try {
      const raw = localStorage.getItem(key);
      return raw == null ? fallback : JSON.parse(raw);
    } catch {
      return fallback;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
    } catch {
      // 存不下就算了
    }
  },
};

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
