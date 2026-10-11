// 各个页面的 HTML（地图页在 map.js）
import { escapeHTML as e, fmt, preciseDirection, compass } from './util.js';
import { sunAltitude, moonIllumination, darkWindow } from './astro.js';
import { magneticLatitude, kpNeeded, auroraBearing } from './geomag.js';
import { nowcast, outlook, bestHour } from './forecaster.js';
import { cloudNear } from './data.js';
import { DESTINATIONS, TRAVEL_MODES, KINDS, durationText, directionText, forecastSpot } from './spots.js';
import { hourlyChart, kpChart, seriesChart, sparkline, scoreRing, scoreColor, kpColor, COLORS } from './charts.js';
import { state, activePlace, timeZone, placeSkyFactor, travelMode, CURRENT_ID } from './model.js';

/** 渲染时登记的观测点，点导航按钮时按 key 找回来 */
export const spotRegistry = new Map();

const chartWidth = () => Math.min(document.getElementById('view').clientWidth, 640) - 32;

const spinner = (text = '') => `<div class="loading"><span class="spin"></span>${text ? `<span>${e(text)}</span>` : ''}</div>`;
const card = (title, body, cls = '') => `<section class="card ${cls}">${title ? `<h3>${e(title)}</h3>` : ''}${body}</section>`;

export function zoneChip(zone) {
  const [r, g, b] = zone.rgb;
  const light = r * 0.299 + g * 0.587 + b * 0.114 > 140;
  return `<span class="chip" style="background:rgb(${r},${g},${b});color:${light ? '#000' : '#fff'};${zone.index <= 2 ? 'box-shadow:inset 0 0 0 0.5px rgba(255,255,255,.35)' : ''}">${zone.name}</span>`;
}

function errorBanner() {
  if (!state.errors.length) return '';
  return `<div class="errors">${state.errors.map((m) => `<div>${e(m)}</div>`).join('')}</div>`;
}

// MARK: 今晚

export function tonightView() {
  const place = activePlace();
  if (!place) {
    return errorBanner() + (state.loading ? spinner('定位中…') :
      `<div class="unavailable"><div class="big-icon">📍</div><h2>没有位置</h2><p>请允许定位，或在「设置」里选一个地点</p>
       <button class="button" data-action="tab:settings">去设置</button></div>`);
  }
  const tz = timeZone();
  const now = Date.now();
  const hours = outlook(place.latitude, place.longitude, state.kp, state.clouds, placeSkyFactor(), now);
  const mlat = magneticLatitude(place.latitude, place.longitude);
  const need = kpNeeded(mlat);
  const here = hours.reduce((m, h) => Math.max(m, h.score), 0);

  return errorBanner() + nowCard(place, now, tz) + tonightSummary(place, hours, mlat, need, now, tz) + breakdownCard(hours) + nearbyHint(here)
    + (hours.length ? hourlyCard(hours, need, tz) : '') + kpCard(need, tz)
    + (state.lastUpdated ? `<p class="footnote">更新于 ${fmt.time(state.lastUpdated)} · 时间均为${tz ? '当地' : '本地'}时间</p>` : '');
}

function nowCard(place, now, tz) {
  if (!state.ovation) return card('现在', spinner());
  const sun = sunAltitude(now, place.latitude, place.longitude);
  const cloud = cloudNear(state.clouds, now)?.effective;
  const cast = nowcast(state.ovation, place.latitude, place.longitude);
  let verdict;
  if (sun > -6) verdict = '天还亮着，等天黑再说';
  else if (cloud != null && cloud >= 85) verdict = `云太厚了（${Math.round(cloud)}%），基本没戏`;
  else if (cast.visible >= 50) verdict = '很有希望，赶紧出门！';
  else if (cast.visible >= 20) verdict = `有机会，去暗处往${place.latitude >= 0 ? '北' : '南'}看`;
  else if (cast.visible >= 8) verdict = '可能有微弱极光，相机比肉眼更容易拍到';
  else verdict = '暂时没有明显极光';

  return card('现在', `
    <div class="now-row">
      <div class="now-value" style="color:${scoreColor(cast.visible * 1.5)}">${cast.visible}<span>%</span></div>
      <div class="now-side"><div>视野内极光概率</div><small>头顶 ${cast.overhead}%</small></div>
    </div>
    <p class="verdict">${e(verdict)}</p>
    <div class="meta-row"><span>${sun > -6 ? '☀️' : '🌅'} ${Math.round(sun)}°</span>${cloud != null ? `<span>☁️ ${Math.round(cloud)}%</span>` : ''}
      <span class="spacer"></span><span>模型预测到 ${fmt.time(state.ovation.forecastTime, tz)}</span></div>`);
}

function needText(need) {
  if (need.horizon > 9) return '需要超强磁暴（Kp 9+），极少见';
  if (need.overhead <= 0.5) return 'Kp 1 左右就可能在头顶出现';
  const horizon = need.horizon <= 0 ? 'Kp 0 就可能看到' : `地平线 Kp ≥ ${fmt.kp(need.horizon)}`;
  const overhead = need.overhead > 9 ? '头顶几乎不可能' : `头顶 Kp ≥ ${fmt.kp(need.overhead)}`;
  return `${horizon} · ${overhead}`;
}

function tonightSummary(place, hours, mlat, need, now, tz) {
  const window = darkWindow(now, place.latitude, place.longitude);
  const best = bestHour(hours);
  const maxKp = hours.reduce((m, h) => (h.kp != null && (m == null || h.kp > m) ? h.kp : m), null);
  const bearing = auroraBearing(place.latitude, place.longitude);
  const rows = [];
  const row = (icon, title, value) => rows.push(`<div class="row"><span class="row-title">${icon} ${title}</span><span>${value}</span></div>`);

  row('🌙', '天黑', window ? (window.end - window.start > 30 * 3600000 ? '极夜，全天都黑' : `${fmt.time(window.start, tz)} – ${fmt.time(window.end, tz)}`)
    : '<span style="color:var(--orange)">今晚不会完全天黑</span>');
  if (best && best.score >= 1) row('⭐️', '最佳时段', `<span style="color:${scoreColor(best.score)}">${fmt.time(best.time, tz)} 起 · 评分 ${Math.floor(best.score)}</span>`);
  if (maxKp != null) row('⚡️', '最高 Kp', `<span style="color:${kpColor(maxKp)}">${fmt.kp(maxKp)}</span>`);
  row('🌗', '月亮', `亮度 ${Math.round(moonIllumination(now) * 100)}%`);
  row('📍', '本地门槛', needText(need));
  row('🧭', '看哪边', need.overhead > 1 ? `${preciseDirection(bearing)}的低空，强的时候会升高` : `${preciseDirection(bearing)}，强的时候满天都是`);
  if (state.placeSky) {
    const sky = state.placeSky, h = state.placeHorizon;
    row('💡', '光污染', `<span>${zoneChip(sky)} ${sky.summary} · SQM ${sky.sqm.toFixed(1)}</span>
      ${h ? `<small class="sub">${compass(h.bearing)}方地平线 ${zoneChip(h.glow)}${h.seaView ? ' · 朝海，视野开阔' : ''}</small>` : ''}`);
  }
  return card('今晚', `<div class="rows">${rows.join('')}</div>
    <p class="note">磁纬约 ${Math.abs(mlat).toFixed(1)}°。门槛是粗略估算，实际以「现在」的概率为准。</p>`);
}

// MARK: 评分拆解

/** 一小时的评分拆成五个相乘的因素，每个 0–100% */
function factors(h) {
  const list = [];

  list.push({ key: 'aurora', icon: '⚡️', label: '极光强度', value: h.auroraChance,
    text: h.kp == null ? '还没有这个时段的 Kp 预报'
      : h.auroraChance <= 0 ? `预计 Kp ${fmt.kp(h.kp)}，这里要 Kp ${fmt.kp(h.kpHorizon)} 才能在低空看到`
        : `预计 Kp ${fmt.kp(h.kp)}，这里要 ${fmt.kp(h.kpHorizon)}` });

  list.push({ key: 'dark', icon: '🌙', label: '天黑', value: h.darkness,
    text: h.darkness >= 1 ? '全黑' : `太阳在地平线下 ${Math.round(-h.sunAltitude)}°，还没全黑` });

  const c = h.cloudDetail;
  let cloudText = '没有云量数据，按晴天算';
  if (c) {
    cloudText = `低云 ${Math.round(c.low)}% · 中云 ${Math.round(c.mid)}% · 高云 ${Math.round(c.high)}%（高云薄，打折算）`;
  }
  list.push({ key: 'clear', icon: '☁️', label: '晴朗', value: 1 - (h.cloud ?? 0) / 100, text: cloudText,
    models: c?.models?.length > 1 ? c.models : null });

  list.push({ key: 'moon', icon: '🌗', label: '月光', value: h.moon,
    text: h.moonAltitude <= 0 ? '月亮在地平线下' : `月亮 ${Math.round(h.moonIllumination * 100)}% 亮，高 ${Math.round(h.moonAltitude)}°` });

  const sky = state.placeSky, horizon = state.placeHorizon;
  let lightText = h.light >= 0.995 ? '几乎没有光害' : '光害';
  if (sky) {
    lightText = `头顶 ${zoneChip(sky)}${horizon ? ` · ${compass(horizon.bearing)}方地平线 ${zoneChip(horizon.glow)}` : ''} ${e(sky.summary)}`;
  }
  if (h.light > h.skyFactor + 0.005) lightText += '，极光强时影响小一些';
  list.push({ key: 'light', icon: '💡', label: '光害', value: h.light, text: lightText, html: true });
  return list;
}

function breakdownCard(hours) {
  const best = bestHour(hours);
  if (!best || best.kp == null) return '';
  const rows = factors(best).map((f) => {
    const color = f.value >= 0.8 ? 'var(--aurora)' : f.value >= 0.5 ? 'var(--yellow)' : 'var(--orange)';
    const models = f.models ? `<div class="factor-models">${f.models.map((m) =>
      `<span>${e(m.label)} <b>${Math.round(m.effective)}%</b></span>`).join('')}</div>` : '';
    return `<div class="factor">
      <div class="factor-head"><span>${f.icon} ${f.label}</span><b style="color:${color}">${Math.round(f.value * 100)}%</b></div>
      <div class="factor-bar"><span style="width:${Math.max(f.value * 100, 1.5)}%;background:${color}"></span></div>
      <div class="factor-text">${f.html ? f.text : e(f.text)}</div>${models}</div>`;
  }).join('');
  return card('评分构成', `<div class="factors">${rows}</div>`, 'breakdown');
}

function nearbyHint(here) {
  const mode = travelMode();
  const spot = state.viewingSpots.find((s) => (s.distanceKm ?? 0) >= 0.3);
  let title, subtitle;
  if (spot && spot.bestScore >= Math.max(here + 10, 15)) {
    title = `${spot.place.name} 今晚更好`;
    subtitle = `${durationText(mode, spot.distanceKm ?? 0)} · 评分 ${Math.floor(spot.bestScore)}，这里只有 ${Math.floor(here)}`;
  } else {
    const best = state.nearby[0];
    if (mode.id !== 'car' || !best || (best.distanceKm ?? 0) <= 0 || best.bestScore < Math.max(here + 15, 20)) return '';
    title = `${directionText(best) ?? ''} 的 ${best.place.name} 今晚更好`;
    subtitle = `评分 ${Math.floor(best.bestScore)}，这里只有 ${Math.floor(here)}`;
  }
  return `<button class="hint" data-action="tab:spots"><span>${modeIcon(mode.id)}</span>
    <span class="hint-text"><b>${e(title)}</b><small>${e(subtitle)}</small></span><span class="chev">›</span></button>`;
}

const modeIcon = (id) => ({ walk: '🚶', bike: '🚲', car: '🚗' })[id];

function hourlyCard(hours, need, tz) {
  const best = bestHour(hours);
  let overlay = '';
  const maxKp = hours.reduce((m, h) => (h.kp != null && (m == null || h.kp > m) ? h.kp : m), null);
  // Kp 还没加载出来时不显示原因
  if ((best?.score ?? 0) < 1 && maxKp != null) {
    let reason = '今晚这里评分很低';
    if (hours.every((h) => h.auroraChance === 0)) reason = `今晚这里评分为 0<br>这里需要 Kp ≥ ${fmt.kp(need.horizon)}，今晚预报最高只有 ${fmt.kp(maxKp)}`;
    else if (hours.every((h) => (h.cloud ?? 0) >= 98)) reason = '今晚这里评分为 0<br>整晚都是阴天，可以看看「去哪看」';
    overlay = `<div class="chart-overlay">${reason}</div>`;
  }
  const table = hours.map((h) => `<tr><td>${fmt.time(h.time, tz)}</td>
    <td style="color:${h.kp != null ? kpColor(h.kp) : 'inherit'}">${h.kp != null ? fmt.kp(h.kp) : '–'}</td>
    <td>${h.cloud != null ? Math.round(h.cloud) + '%' : '–'}</td>
    <td class="dim">${h.moonAltitude > 0 ? Math.round(h.moonAltitude) + '°' : '落'}</td>
    <td style="color:${scoreColor(h.score)}"><b>${Math.floor(h.score)}</b></td></tr>`).join('');
  return card('逐小时评分', `
    <div class="chart-wrap">${hourlyChart(hours, tz, chartWidth())}${overlay}</div>
    <div class="legend"><span><i class="line" style="background:${COLORS.aurora}"></i>综合评分</span>
      <span><i class="line dashed" style="color:${COLORS.purple}"></i>极光强度</span><span><i class="box"></i>云量</span></div>
    <details><summary>逐小时明细</summary>
      <table class="hours"><thead><tr><th>时间</th><th>Kp</th><th>云量</th><th>月亮</th><th>评分</th></tr></thead><tbody>${table}</tbody></table>
    </details>`);
}

function kpCard(need, tz) {
  const now = Date.now();
  const shown = state.kp.filter((p) => p.end > now - 24 * 3600000);
  if (!shown.length) return card('Kp 指数（3 天）', spinner());
  return card('Kp 指数（3 天）', kpChart(shown, need, tz, chartWidth(), now) +
    '<p class="note">Kp 是全球地磁活跃度，0–9 级。5 级以上为磁暴（G1–G5），极光会往低纬扩展。</p>');
}

// MARK: 去哪看

export function spotsView() {
  spotRegistry.clear();
  const place = activePlace();
  let out = '';
  if (place) {
    out += viewingSection(place);
    if (state.travelMode === 'car') out += nearbySection(place);
  }
  out += destinationSection();
  out += `<p class="footnote">评分综合了极光强度、天黑、云量、月光和光污染。光污染数据来自 David Lorenz 的 Light Pollution Atlas 2025（年度卫星数据推算的天顶亮度），色块就是地图集里的分区；地平线一栏是朝极光方向看过去、按远近折算的灯光。地点来自 OpenStreetMap，「暗处」是光污染图上找到的空地，去之前看一眼是不是私人土地、晚上安不安全。</p>`;
  return out;
}

function viewingSection(center) {
  const mode = travelMode();
  const bearing = auroraBearing(center.latitude, center.longitude);
  const segments = Object.values(TRAVEL_MODES).map((m) =>
    `<button class="${m.id === mode.id ? 'on' : ''}" data-action="mode:${m.id}">${m.label} ${m.radiusKm} km</button>`).join('');
  let out = `<div class="section-head"><h2>附近去哪看</h2>
    <div class="segmented">${segments}</div>
    <p class="caption">极光出现在${preciseDirection(bearing)}方向的低空。按脚下和${compass(bearing)}方地平线的光害、云量、路程排序，朝海的地方最开阔。</p></div>
    <div class="spots-map-slot"></div>`;

  const rows = [];
  if (state.placeSky) {
    const origin = forecastSpot(center, { clouds: state.clouds, kp: state.kp, ovation: state.ovation, sky: state.placeSky,
      skyFactor: placeSkyFactor(), distanceKm: 0, bearing: 0 });
    origin.horizon = state.placeHorizon;
    rows.push(spotRow(origin, '原地', mode));
  }
  if (!state.viewingSpots.length) {
    rows.push(card('', state.loadingViewing || state.loading ? spinner(`正在找${mode.label}能到的地方…`)
      : `<p class="dim">${mode.radiusKm} km 内没找到合适的地方，换个出行方式试试</p>`));
  } else {
    state.viewingSpots.forEach((spot, i) => rows.push(spotRow(spot, KINDS[spot.kind]?.label, mode, i + 1)));
  }
  return out + `<div class="list">${rows.join('')}</div>`;
}

function nearbySection(center) {
  const better = state.nearby.filter((s) => (s.distanceKm ?? 0) > 0).slice(0, 5);
  let out = `<div class="section-head"><h2>开远一点哪里晴</h2>
    <p class="caption">在「${e(center.name)}」周围 150 km 内比较了 25 个点的天气（已排除海面）</p></div>`;
  if (!state.nearby.length) {
    out += card('', state.loadingSpots || state.loading ? spinner('正在比较附近的天气…') : '<p class="dim">暂时没有数据，下拉刷新试试</p>');
  } else {
    out += `<div class="list">${better.map((s) => spotRow(s, directionText(s), TRAVEL_MODES.car)).join('')}</div>`;
  }
  return out;
}

function destinationSection() {
  let out = `<div class="section-head"><h2>热门目的地今晚</h2>
    <p class="caption">点一下切换到这个地点 · 时间为各地当地时间 · 光污染按开车出城 15 km 内最暗的地方算</p></div>`;
  if (!state.destinations.length) return out + card('', spinner());
  return out + `<div class="list">${state.destinations.map((s) =>
    `<div class="tappable" data-action="select-go:${e(s.id)}">${spotRow(s, null, null)}</div>`).join('')}</div>`;
}

/** rank：地图上的序号 */
function spotRow(spot, badge, mode, rank = null) {
  const canNavigate = mode && (spot.distanceKm ?? 0) > 0;
  let key = '';
  if (canNavigate || (!mode && spot.shiftKm != null)) {
    key = `k${spotRegistry.size}`;
    spotRegistry.set(key, { spot, mode: mode ?? TRAVEL_MODES.car });
  }
  const kind = spot.kind ? KINDS[spot.kind] : null;
  const lines = [];
  if (mode && kind && spot.distanceKm != null) {
    const d = spot.distanceKm;
    lines.push(`<div class="line">${durationText(mode, d)} · ${compass(spot.bearing)} ${d < 10 ? d.toFixed(1) : Math.round(d)} km</div>`);
  }
  if (spot.sky) lines.push(`<div class="line sky">${skyLine(spot, mode)}</div>`);
  lines.push(`<div class="line">${e(detail(spot))}</div>`);

  return `<div class="spot">
    ${scoreRing(spot.bestScore)}
    <div class="spot-main">
      <div class="spot-title">${rank ? `<span class="rank" style="background:${scoreColor(spot.bestScore)}">${rank}</span>` : ''}${kind ? `<span class="kind">${kind.icon}</span>` : ''}<span class="name">${e(spot.place.name || '…')}</span>${badge ? `<span class="badge">${e(badge)}</span>` : ''}</div>
      ${lines.join('')}
    </div>
    ${!spot.kind && spot.hours.length ? `<div class="spark-wrap">${sparkline(spot.hours)}</div>` : ''}
    ${key ? `<button class="nav-button" data-action="nav:${key}" aria-label="导航">➜</button>` : ''}
  </div>`;
}

function skyLine(spot, mode) {
  const sky = spot.sky;
  if (spot.horizon) {
    const h = spot.horizon;
    return `头顶 ${zoneChip(sky)} ${compass(h.bearing)}方 ${zoneChip(h.glow)}${h.seaView ? ' <span class="sea">≋ 朝海</span>' : ''}`;
  }
  if (spot.originalSky && spot.shiftKm != null) {
    return mode ? `${zoneChip(sky)} 挪 ${spot.shiftKm.toFixed(1)} km 避开灯光`
      : `城区 ${zoneChip(spot.originalSky)} → 城外 ${Math.round(spot.shiftKm)} km ${zoneChip(sky)}`;
  }
  return `${zoneChip(sky)} ${sky.summary}`;
}

function detail(spot) {
  const best = spot.best;
  if (!best || best.score < 1) {
    if (!spot.hours.length) return '今晚不会天黑';
    if (spot.hours.reduce((m, h) => Math.max(m, h.auroraChance), 0) < 0.2) return 'Kp 不够，这里纬度偏低';
    return '云太多';
  }
  const parts = [`${fmt.time(best.time, spot.timeZone)} 最好`];
  if (best.cloud != null) parts.push(`云 ${Math.round(best.cloud)}%`);
  if (spot.nowVisible != null && spot.nowVisible >= 5) parts.push(`现在 ${spot.nowVisible}%`);
  return parts.join(' · ');
}

// MARK: 太阳风

export const windState = { hours: 3 };

export function windView() {
  if (!state.wind.length) return errorBanner() + (state.loading ? spinner() : '<p class="dim center">暂无数据</p>');
  const w = state.wind;
  const last = (k) => w.findLast((s) => s[k] != null);
  const bz = last('bz'), bt = last('bt')?.bt, speed = last('speed')?.speed, density = last('density')?.density;
  // 最近 30 分钟 Bz 的平均值比单个点更能说明问题
  const recent = w.filter((s) => s.time > Date.now() - 30 * 60000 && s.bz != null).map((s) => s.bz);
  const avgBz = recent.length ? recent.reduce((a, b) => a + b, 0) / recent.length : null;

  const bzColor = (v) => v == null ? 'inherit' : v <= -10 ? COLORS.red : v <= -5 ? COLORS.orange : v < 0 ? COLORS.aurora : 'var(--dim)';
  const speedColor = (v) => v == null ? 'inherit' : v >= 700 ? COLORS.red : v >= 500 ? COLORS.orange : 'inherit';
  const densityColor = (v) => v == null ? 'inherit' : v >= 20 ? COLORS.orange : v >= 10 ? COLORS.yellow : 'inherit';
  const metric = (title, value, unit, digits, color, note = '') => `<div class="metric"><div class="dim">${title}</div>
    <div><b style="color:${color}">${value == null ? '–' : value.toFixed(digits)}</b> <small class="dim">${unit}</small></div>
    <small class="dim">${note || '&nbsp;'}</small></div>`;

  const cutoff = Date.now() - windState.hours * 3600000;
  const samples = w.filter((s) => s.time > cutoff);
  const width = chartWidth();
  const segments = [3, 6, 24].map((h) => `<button class="${h === windState.hours ? 'on' : ''}" data-action="wind:${h}">${h} 小时</button>`).join('');

  return errorBanner() + `
    <div class="metrics">
      ${metric('Bz', bz?.bz, 'nT', 1, bzColor(bz?.bz), avgBz != null ? `30 分钟均值 ${avgBz.toFixed(1)}` : '')}
      ${metric('速度', speed, 'km/s', 0, speedColor(speed))}
      ${metric('密度', density, 'p/cm³', 1, densityColor(density))}
      ${metric('Bt', bt, 'nT', 1, 'inherit')}
    </div>
    ${speed > 0 ? `<p class="caption center">L1 点离地球约 150 万 km，按当前速度约 ${Math.round(1500000 / speed / 60)} 分钟后到达</p>` : ''}
    ${bz ? `<p class="footnote center">数据时间 ${fmt.time(bz.time)}</p>` : ''}
    <div class="segmented">${segments}</div>
    ${card('Bz（向南为负，越负越好）', seriesChart(samples, 'bz', { color: COLORS.aurora, height: 150, zeroLine: true, width }))}
    ${card('速度 km/s', seriesChart(samples, 'speed', { color: COLORS.orange, height: 130, includeZero: false, width }))}
    ${card('密度 p/cm³', seriesChart(samples, 'density', { color: COLORS.yellow, height: 110, width }))}
    ${card('怎么看', `<ul class="guide">
      <li><b>Bz 持续为负</b>最关键：低于 −5 持续 20 分钟以上，极光通常会变强。</li>
      <li><b>速度</b>越快能量越大，500 以上不错，700 以上是强烈事件。</li>
      <li><b>密度</b>高会让极光更亮、往低纬扩展。</li>
      <li>这些是太阳风到地球前 30–60 分钟的「预警」，比 Kp 反应快。</li></ul>`)}`;
}

// MARK: 设置

const coordinateText = (p) => `${Math.abs(p.latitude).toFixed(2)}°${p.latitude >= 0 ? 'N' : 'S'}, ${Math.abs(p.longitude).toFixed(2)}°${p.longitude >= 0 ? 'E' : 'W'}`;

export function settingsView() {
  const row = (id, name, detail, icon, removable = false) => `<div class="place-row" data-action="select:${e(id)}">
    <span class="place-icon">${icon}</span><span class="place-text"><span>${e(name)}</span><small>${e(detail)}</small></span>
    ${state.selectedPlaceID === id ? '<span class="check">✓</span>' : ''}
    ${removable ? `<button class="remove" data-action="remove:${e(id)}" aria-label="删除">✕</button>` : ''}</div>`;
  const fixed = state.fixedLocation ? `（网址指定 ${coordinateText(state.fixedLocation)}）` : '使用定位';
  return `
    <div class="group"><h4>地点</h4>
      ${row(CURRENT_ID, '当前位置', fixed, '📍')}
      ${DESTINATIONS.map((p) => row(p.id, p.name, coordinateText(p), '📌')).join('')}
    </div>
    <div class="group"><h4>我的地点</h4>
      ${state.customPlaces.map((p) => row(p.id, p.name, coordinateText(p), '⭐️', true)).join('')}
      <button class="place-row add" data-action="add-place">＋ 添加地点…</button>
    </div>
    <div class="group"><h4>装到手机桌面</h4>
      <p class="group-text">iPhone：用 Safari 打开，点分享按钮 →「添加到主屏幕」。<br>安卓：用浏览器打开，菜单里选「添加到桌面」或「安装应用」。<br>网页版没有后台提醒，打开时每 10 分钟自动刷新。</p>
    </div>
    <div class="group"><h4>数据来源</h4>
      <div class="kv"><span>极光概率、Kp、太阳风</span><span>NOAA SWPC</span></div>
      <div class="kv"><span>云量、海拔</span><span>Open-Meteo</span></div>
      <div class="kv"><span>光污染</span><span>Lorenz Atlas 2025</span></div>
      <div class="kv"><span>观测点</span><span>OpenStreetMap（Photon）</span></div>
      <div class="kv"><span>地图底图</span><span>Esri · OpenStreetMap</span></div>
      <div class="kv"><span>日月位置</span><span>本地计算</span></div>
    </div>
    <div class="group"><button class="place-row danger" data-action="clear-cache">清除缓存（地点、海拔、光污染瓦片）</button></div>`;
}

export function addPlaceSheet() {
  return `<form class="sheet-body" data-form="add-place">
    <h3>添加地点</h3>
    <input name="name" placeholder="名称" autocomplete="off">
    <input name="lat" placeholder="纬度（北正南负，如 69.65）" inputmode="decimal" autocomplete="off">
    <input name="lon" placeholder="经度（东正西负，如 18.96）" inputmode="decimal" autocomplete="off">
    <p class="caption">也可以在「地图」页长按一个点，直接添加。</p>
    <div class="sheet-actions"><button type="button" class="button secondary" data-action="close-sheet">取消</button>
      <button type="submit" class="button">保存</button></div>
  </form>`;
}

