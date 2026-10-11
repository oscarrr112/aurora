// 轻量 SVG 折线图（不依赖图表库）
import { fmt } from './util.js';

export const COLORS = {
  aurora: '#59f28c',
  teal: '#3cc8c8',
  yellow: '#ffd60a',
  orange: '#ff9f0a',
  red: '#ff453a',
  purple: '#bf5af2',
  gray: '#8e8e93',
};

export function scoreColor(v) {
  if (v < 10) return COLORS.gray;
  if (v < 30) return COLORS.teal;
  if (v < 60) return COLORS.aurora;
  return COLORS.yellow;
}

export function kpColor(v) {
  if (v < 4) return COLORS.aurora;
  if (v < 5) return COLORS.yellow;
  if (v < 6) return COLORS.orange;
  if (v < 7) return COLORS.red;
  return COLORS.purple;
}

let gradientID = 0;

/** 单调三次插值（和 d3.curveMonotoneX 一样，不会冲过数据点） */
function monotonePath(points) {
  const n = points.length;
  if (n === 0) return '';
  if (n === 1) return `M${points[0][0]},${points[0][1]}`;
  const dx = [], slope = [];
  for (let i = 0; i < n - 1; i++) {
    dx.push(points[i + 1][0] - points[i][0]);
    slope.push(dx[i] === 0 ? 0 : (points[i + 1][1] - points[i][1]) / dx[i]);
  }
  const tangent = [slope[0]];
  for (let i = 1; i < n - 1; i++) {
    tangent.push(slope[i - 1] * slope[i] <= 0 ? 0 : (3 * (dx[i - 1] + dx[i])) /
      ((2 * dx[i] + dx[i - 1]) / slope[i - 1] + (dx[i] + 2 * dx[i - 1]) / slope[i]));
  }
  tangent.push(slope[n - 2]);
  let d = `M${points[0][0].toFixed(1)},${points[0][1].toFixed(1)}`;
  for (let i = 0; i < n - 1; i++) {
    const [x0, y0] = points[i], [x1, y1] = points[i + 1];
    const h = dx[i] / 3;
    d += `C${(x0 + h).toFixed(1)},${(y0 + h * tangent[i]).toFixed(1)} ${(x1 - h).toFixed(1)},${(y1 - h * tangent[i + 1]).toFixed(1)} ${x1.toFixed(1)},${y1.toFixed(1)}`;
  }
  return d;
}

/** 把曲线闭合到底线，用来画面积 */
const areaPath = (points, baseY) => points.length < 2 ? '' :
  `${monotonePath(points)}L${points.at(-1)[0].toFixed(1)},${baseY}L${points[0][0].toFixed(1)},${baseY}Z`;

/** 坐标轴映射 */
function scales(width, height, pad, xDomain, yDomain) {
  const [x0, x1] = xDomain, [y0, y1] = yDomain;
  const w = width - pad.left - pad.right, h = height - pad.top - pad.bottom;
  return {
    x: (v) => pad.left + ((v - x0) / (x1 - x0 || 1)) * w,
    y: (v) => pad.top + h - ((v - y0) / (y1 - y0 || 1)) * h,
    left: pad.left, right: width - pad.right, top: pad.top, bottom: height - pad.bottom,
  };
}

const svgOpen = (width, height) =>
  `<svg viewBox="0 0 ${width} ${height}" width="100%" height="${height}" xmlns="http://www.w3.org/2000/svg" class="chart">`;

/** 逐小时评分：云量面积、极光强度虚线、评分面积 + 线、最佳点标注 */
export function hourlyChart(hours, tz, width) {
  const height = 180;
  const pad = { top: 22, right: 30, bottom: 22, left: 8 };
  const xs = hours.map((h) => h.time);
  const s = scales(width, height, pad, [xs[0], xs.at(-1)], [0, 110]);
  const id = ++gradientID;
  let out = svgOpen(width, height);
  out += `<defs><linearGradient id="sg${id}" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="${COLORS.aurora}" stop-opacity="0.45"/><stop offset="1" stop-color="${COLORS.aurora}" stop-opacity="0.02"/>
  </linearGradient></defs>`;
  for (const v of [0, 50, 100]) {
    out += `<line x1="${s.left}" x2="${s.right}" y1="${s.y(v)}" y2="${s.y(v)}" class="grid"/>`;
    out += `<text x="${s.right + 4}" y="${s.y(v) + 4}" class="axis">${v}</text>`;
  }
  hours.forEach((h, i) => {
    if (i % 2 === 0) out += `<text x="${s.x(h.time)}" y="${height - 6}" class="axis" text-anchor="middle">${fmt.hour(h.time, tz)}</text>`;
  });
  const cloud = hours.filter((h) => h.cloud != null).map((h) => [s.x(h.time), s.y(h.cloud)]);
  out += `<path d="${areaPath(cloud, s.bottom)}" fill="rgba(142,142,147,0.22)"/>`;
  out += `<path d="${monotonePath(hours.map((h) => [s.x(h.time), s.y(h.auroraChance * 100)]))}" fill="none" stroke="${COLORS.purple}" stroke-width="1.5" stroke-dasharray="4 3" opacity="0.9"/>`;
  const score = hours.map((h) => [s.x(h.time), s.y(h.score)]);
  out += `<path d="${areaPath(score, s.bottom)}" fill="url(#sg${id})"/>`;
  out += `<path d="${monotonePath(score)}" fill="none" stroke="${COLORS.aurora}" stroke-width="2.5" stroke-linecap="round"/>`;
  const best = hours.reduce((b, h) => (!b || h.score > b.score ? h : b), null);
  if (best && best.score >= 1) {
    const x = s.x(best.time), y = s.y(best.score);
    const anchor = x < width * 0.2 ? 'start' : x > width * 0.8 ? 'end' : 'middle';
    out += `<circle cx="${x}" cy="${y}" r="4.5" fill="${scoreColor(best.score)}"/>`;
    out += `<text x="${x}" y="${y - 9}" text-anchor="${anchor}" class="label" fill="${scoreColor(best.score)}">${Math.floor(best.score)} 分 · ${fmt.time(best.time, tz)}</text>`;
  }
  return out + '</svg>';
}

/** Kp 曲线：磁暴色带、预报区、本地门槛、现在 */
export function kpChart(points, need, tz, width, now = Date.now()) {
  const height = 190;
  const pad = { top: 16, right: 8, bottom: 22, left: 34 };
  const x0 = points[0].time, x1 = points.at(-1).end;
  const s = scales(width, height, pad, [x0, x1], [0, 9]);
  const id = ++gradientID;
  const stops = [[0, COLORS.aurora], [3.6, COLORS.aurora], [4.5, COLORS.yellow], [5.5, COLORS.orange], [6.5, COLORS.red], [7.6, COLORS.purple]];
  const gradient = (opacity) => stops.map(([v, c]) => `<stop offset="${(v / 9).toFixed(3)}" stop-color="${c}" stop-opacity="${opacity}"/>`).join('');
  let out = svgOpen(width, height);
  // 渐变按 Kp 数值上色：y 轴从下（0）到上（9）
  out += `<defs>
    <linearGradient id="kl${id}" gradientUnits="userSpaceOnUse" x1="0" y1="${s.y(0)}" x2="0" y2="${s.y(9)}">${gradient(1)}</linearGradient>
    <linearGradient id="ka${id}" gradientUnits="userSpaceOnUse" x1="0" y1="${s.y(0)}" x2="0" y2="${s.y(9)}">${gradient(0.25)}</linearGradient>
  </defs>`;
  out += `<rect x="${s.left}" y="${s.y(7)}" width="${s.right - s.left}" height="${s.y(5) - s.y(7)}" fill="rgba(255,159,10,0.07)"/>`;
  out += `<rect x="${s.left}" y="${s.y(9)}" width="${s.right - s.left}" height="${s.y(7) - s.y(9)}" fill="rgba(255,69,58,0.08)"/>`;
  if (now < x1) {
    const nx = Math.max(s.x(now), s.left);
    out += `<rect x="${nx}" y="${s.top}" width="${s.right - nx}" height="${s.bottom - s.top}" fill="rgba(255,255,255,0.035)"/>`;
    out += `<text x="${nx + 4}" y="${s.top + 11}" class="axis">预报</text>`;
  }
  for (const v of [0, 3, 5, 7, 9]) {
    out += `<line x1="${s.left}" x2="${s.right}" y1="${s.y(v)}" y2="${s.y(v)}" class="grid"/>`;
    out += `<text x="${s.left - 4}" y="${s.y(v) + 4}" class="axis" text-anchor="end">${v === 5 ? '5 G1' : v === 7 ? '7 G3' : v}</text>`;
  }
  // 每天 0 点一条竖线
  const dayMs = 86400000;
  for (let t = Math.ceil(x0 / 3600000) * 3600000; t <= x1; t += 3600000) {
    if (fmt.hour(t, tz) !== '00') continue;
    out += `<line x1="${s.x(t)}" x2="${s.x(t)}" y1="${s.top}" y2="${s.bottom}" class="grid"/>`;
    if (s.x(t) + 30 < s.right) out += `<text x="${s.x(t) + 3}" y="${height - 6}" class="axis">${fmt.day(t, tz)}</text>`;
    t += dayMs - 2 * 3600000;
  }
  const line = points.map((p) => [s.x(p.time + 5400000), s.y(p.kp)]);
  out += `<path d="${areaPath(line, s.bottom)}" fill="url(#ka${id})"/>`;
  out += `<path d="${monotonePath(line)}" fill="none" stroke="url(#kl${id})" stroke-width="2.5" stroke-linecap="round"/>`;
  if (need.horizon >= 0 && need.horizon <= 9) {
    const y = s.y(need.horizon);
    out += `<line x1="${s.left}" x2="${s.right}" y1="${y}" y2="${y}" stroke="rgba(255,255,255,0.7)" stroke-dasharray="4 3"/>`;
    out += `<text x="${s.right - 2}" y="${y - 4}" class="axis" text-anchor="end">本地门槛 ${fmt.kp(need.horizon)}</text>`;
  }
  if (now >= x0 && now <= x1) {
    out += `<line x1="${s.x(now)}" x2="${s.x(now)}" y1="${s.top}" y2="${s.bottom}" stroke="rgba(255,255,255,0.4)"/>`;
  }
  const current = points.findLast((p) => p.time <= now && now < p.end);
  if (current) {
    const x = s.x(current.time + 5400000), y = s.y(current.kp);
    out += `<circle cx="${x}" cy="${y}" r="4" fill="${kpColor(current.kp)}"/>`;
    out += `<text x="${x}" y="${y - 8}" text-anchor="middle" class="label" fill="${kpColor(current.kp)}">${fmt.kp(current.kp)}</text>`;
  }
  return out + '</svg>';
}

/** 太阳风的简单折线 */
export function seriesChart(samples, key, { color, height = 130, zeroLine = false, includeZero = true, tz, width }) {
  const data = samples.filter((s) => s[key] != null);
  if (data.length < 2) return '<div class="empty">暂无数据</div>';
  const pad = { top: 10, right: 8, bottom: 20, left: 36 };
  const values = data.map((d) => d[key]);
  let lo = Math.min(...values), hi = Math.max(...values);
  if (includeZero) { lo = Math.min(lo, 0); hi = Math.max(hi, 0); }
  const span = hi - lo || 1;
  lo -= span * 0.08; hi += span * 0.08;
  const s = scales(width, height, pad, [data[0].time, data.at(-1).time], [lo, hi]);
  let out = svgOpen(width, height);
  const ticks = niceTicks(lo, hi, 4);
  for (const v of ticks) {
    out += `<line x1="${s.left}" x2="${s.right}" y1="${s.y(v)}" y2="${s.y(v)}" class="grid"/>`;
    out += `<text x="${s.left - 4}" y="${s.y(v) + 4}" class="axis" text-anchor="end">${v}</text>`;
  }
  if (zeroLine) out += `<line x1="${s.left}" x2="${s.right}" y1="${s.y(0)}" y2="${s.y(0)}" stroke="rgba(255,255,255,0.4)"/>`;
  const spanMs = data.at(-1).time - data[0].time;
  const stepH = spanMs > 12 * 3600000 ? 6 : spanMs > 4 * 3600000 ? 2 : 1;
  for (let t = Math.ceil(data[0].time / 3600000) * 3600000; t <= data.at(-1).time; t += 3600000) {
    if (Number(fmt.hour(t, tz)) % stepH !== 0) continue;
    out += `<text x="${s.x(t)}" y="${height - 5}" class="axis" text-anchor="middle">${fmt.time(t, tz)}</text>`;
  }
  // 每分钟一个点太密，按宽度抽稀
  const every = Math.max(1, Math.floor(data.length / (width / 2)));
  const line = data.filter((_, i) => i % every === 0 || i === data.length - 1).map((d) => [s.x(d.time), s.y(d[key])]);
  out += `<path d="${monotonePath(line)}" fill="none" stroke="${color}" stroke-width="1.6"/>`;
  return out + '</svg>';
}

function niceTicks(lo, hi, count) {
  const raw = (hi - lo) / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 5, 10].map((m) => m * mag).find((v) => v >= raw) ?? raw;
  const ticks = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi; v += step) ticks.push(Math.round(v * 1000) / 1000);
  return ticks;
}

/** 小卡片上的评分迷你曲线 */
export function sparkline(hours, width = 64, height = 28) {
  if (!hours.length) return '';
  const s = scales(width, height, { top: 2, right: 1, bottom: 2, left: 1 }, [hours[0].time, hours.at(-1).time || hours[0].time + 1], [0, 100]);
  const id = ++gradientID;
  const line = hours.map((h) => [s.x(h.time), s.y(h.score)]);
  return `<svg viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" class="spark">
    <defs><linearGradient id="sp${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${COLORS.aurora}" stop-opacity="0.4"/><stop offset="1" stop-color="${COLORS.aurora}" stop-opacity="0"/></linearGradient></defs>
    <path d="${areaPath(line, s.bottom)}" fill="url(#sp${id})"/>
    <path d="${monotonePath(line)}" fill="none" stroke="${COLORS.aurora}" stroke-width="1.5"/>
  </svg>`;
}

/** 分数圆环 */
export function scoreRing(score, size = 46) {
  const r = size / 2 - 3, c = 2 * Math.PI * r;
  const color = scoreColor(score);
  const fraction = Math.min(score / 100, 1);
  return `<svg viewBox="0 0 ${size} ${size}" width="${size}" height="${size}" class="ring">
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${color}" stroke-opacity="0.25" stroke-width="4"/>
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${color}" stroke-width="4" stroke-linecap="round"
      stroke-dasharray="${(c * fraction).toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 ${size / 2} ${size / 2})"/>
    <text x="50%" y="50%" dy="0.36em" text-anchor="middle" fill="${color}" class="ring-text">${Math.floor(score)}</text>
  </svg>`;
}
