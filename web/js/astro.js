// 太阳、月亮位置的低精度算法（移植自 SunCalc，误差约 1°，用来判断天黑和月光足够了）
import { RAD } from './util.js';

const obliquity = RAD * 23.4397;

const days = (ms) => ms / 86400000 - 0.5 + 2440588 - 2451545;
const rightAscension = (l, b) => Math.atan2(Math.sin(l) * Math.cos(obliquity) - Math.tan(b) * Math.sin(obliquity), Math.cos(l));
const declination = (l, b) => Math.asin(Math.sin(b) * Math.cos(obliquity) + Math.cos(b) * Math.sin(obliquity) * Math.sin(l));
const altitude = (h, phi, dec) => Math.asin(Math.sin(phi) * Math.sin(dec) + Math.cos(phi) * Math.cos(dec) * Math.cos(h));
const siderealTime = (d, lw) => RAD * (280.16 + 360.9856235 * d) - lw;

function sunCoords(d) {
  const m = RAD * (357.5291 + 0.98560028 * d);
  const c = RAD * (1.9148 * Math.sin(m) + 0.02 * Math.sin(2 * m) + 0.0003 * Math.sin(3 * m));
  const l = m + c + RAD * 102.9372 + Math.PI;
  return { dec: declination(l, 0), ra: rightAscension(l, 0) };
}

function moonCoords(d) {
  const l0 = RAD * (218.316 + 13.176396 * d);
  const m = RAD * (134.963 + 13.064993 * d);
  const f = RAD * (93.272 + 13.229350 * d);
  const l = l0 + RAD * 6.289 * Math.sin(m);
  const b = RAD * 5.128 * Math.sin(f);
  return { dec: declination(l, b), ra: rightAscension(l, b), dist: 385001 - 20905 * Math.cos(m) };
}

/** 太阳高度角（度） */
export function sunAltitude(ms, lat, lon) {
  const d = days(ms);
  const c = sunCoords(d);
  const h = siderealTime(d, RAD * -lon) - c.ra;
  return altitude(h, RAD * lat, c.dec) / RAD;
}

/** 月亮高度角（度） */
export function moonAltitude(ms, lat, lon) {
  const d = days(ms);
  const c = moonCoords(d);
  const h = siderealTime(d, RAD * -lon) - c.ra;
  return altitude(h, RAD * lat, c.dec) / RAD;
}

/** 太阳直射点 [纬度, 经度] */
export function subsolarPoint(ms) {
  const d = days(ms);
  const c = sunCoords(d);
  let lon = (c.ra - siderealTime(d, 0)) / RAD;
  lon = (((lon % 360) + 540) % 360) - 180;
  return [c.dec / RAD, lon];
}

/** 月面被照亮的比例 0...1 */
export function moonIllumination(ms) {
  const d = days(ms);
  const s = sunCoords(d);
  const m = moonCoords(d);
  const sunDistance = 149598000;
  const phi = Math.acos(Math.sin(s.dec) * Math.sin(m.dec) + Math.cos(s.dec) * Math.cos(m.dec) * Math.cos(s.ra - m.ra));
  const inc = Math.atan2(sunDistance * Math.sin(phi), m.dist - sunDistance * Math.cos(phi));
  return (1 + Math.cos(inc)) / 2;
}

/** 包含 ms、或在它之后最近的一段黑夜（太阳低于 threshold 度）。24 小时内都不会天黑时返回 null */
export function darkWindow(ms, lat, lon, threshold = -12) {
  const step = 5 * 60000;
  const isDark = (t) => sunAltitude(t, lat, lon) < threshold;

  let start;
  if (isDark(ms)) {
    start = ms;
    for (let i = 0; i < 24 * 12; i++) {
      if (!isDark(start - step)) break;
      start -= step;
    }
  } else {
    start = null;
    for (let t = ms; t <= ms + 24 * 3600000; t += step) {
      if (isDark(t)) { start = t; break; }
    }
    if (start == null) return null;
  }

  let end = start;
  for (let i = 0; i < 36 * 12; i++) {
    end += step;
    if (!isDark(end)) break;
  }
  return { start, end };
}
