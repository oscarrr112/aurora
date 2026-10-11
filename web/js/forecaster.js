// 综合评分：极光强度 × 天黑 × 晴朗 × 月光 × 光害
import { distanceKm } from './util.js';
import { sunAltitude, moonAltitude, moonIllumination } from './astro.js';
import { magneticLatitude, kpNeeded } from './geomag.js';
import { kpAt, cloudNear } from './data.js';

/**
 * OVATION 临近预报：头顶概率，以及视野内概率。
 * 极光底部离地约 100 km，300 km 内都算「抬头可见」，约 1000 km 外沉到地平线下。
 */
export function nowcast(grid, lat, lon) {
  const lat0 = Math.round(lat), lon0 = Math.round(lon);
  const overhead = grid.value(lat0, lon0);
  let best = 0;
  for (let dLat = -10; dLat <= 10; dLat++) {
    const la = lat0 + dLat;
    if (la < -90 || la > 90) continue;
    const cosLat = Math.max(Math.cos((la * Math.PI) / 180), 0.05);
    const span = Math.min(Math.ceil(10 / cosLat), 180);
    for (let dLon = -span; dLon <= span; dLon++) {
      const v = grid.value(la, lon0 + dLon);
      if (v <= best) continue;
      const d = distanceKm(lat, lon, la, lon0 + dLon);
      const weight = d <= 300 ? 1 : Math.max(0, 1 - (d - 300) / 700);
      best = Math.max(best, v * weight);
    }
  }
  return { overhead, visible: Math.round(best) };
}

/** Kp 刚好达到本地地平线门槛时算 50%，每高 1 级 +25% */
export const auroraChance = (kp, kpHorizon) => Math.min(Math.max(0.5 + (kp - kpHorizon) * 0.25, 0), 1);

/** 太阳高度 −6°（民用晨昏）以上算 0，−15° 以下算完全黑 */
export const darkness = (sunAlt) => Math.min(Math.max((-6 - sunAlt) / 9, 0), 1);

/** 光害系数随极光强度放宽：Kp 刚到本地门槛时按原值扣，超过 3 级以上扣分减半（亮的极光不怕城里的灯） */
export function lightFactor(skyFactor, kp, kpHorizon) {
  if (kp == null) return skyFactor;
  const strength = Math.min(Math.max((kp - kpHorizon) / 3, 0), 1);
  return 1 - (1 - skyFactor) * (1 - 0.5 * strength);
}

/** 满月高挂时最多扣 40% */
export const moonFactor = (alt, illumination) => (alt <= 0 ? 1 : 1 - 0.4 * illumination * Math.min(alt / 30, 1));

/** 从现在开始的第一段黑夜（最多 24 小时），逐小时给出评分 */
export function outlook(lat, lon, kp, clouds, skyFactor = 1, now = Date.now()) {
  const kpHorizon = kpNeeded(magneticLatitude(lat, lon)).horizon;
  const startHour = Math.floor(now / 3600000) * 3600000;
  const result = [];
  for (let i = 0; i < 40; i++) {
    const time = startHour + i * 3600000;
    const mid = time + 1800000;
    const sunAlt = sunAltitude(mid, lat, lon);
    const dark = darkness(sunAlt);
    if (dark <= 0) {
      if (result.length === 0) continue;
      break;
    }
    if (result.length >= 24) break;

    const kpValue = kpAt(mid, kp)?.kp ?? null;
    const moonAlt = moonAltitude(mid, lat, lon);
    const illumination = moonIllumination(mid);
    // 有效云量（几个模型平均、高云打折），cloudDetail 留着给评分拆解看分层和各模型
    const cloudDetail = cloudNear(clouds, mid);
    const cloud = cloudDetail?.effective ?? null;
    const aurora = kpValue == null ? 0 : auroraChance(kpValue, kpHorizon);
    const moon = moonFactor(moonAlt, illumination);
    const light = lightFactor(skyFactor, kpValue, kpHorizon);
    const score = 100 * aurora * dark * (1 - (cloud ?? 0) / 100) * moon * light;
    result.push({ time, kp: kpValue, kpHorizon, auroraChance: aurora, sunAltitude: sunAlt, darkness: dark, cloud, cloudDetail,
      moonAltitude: moonAlt, moonIllumination: illumination, moon, skyFactor, light, score });
  }
  return result;
}

export const bestHour = (hours) => hours.reduce((best, h) => (!best || h.score > best.score ? h : best), null);
