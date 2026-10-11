// 观测点：热门目的地、开车范围的几圈候选点、评分和排序
import { compass, destination, distanceKm } from './util.js';
import { outlook, nowcast, bestHour } from './forecaster.js';

/** 热门极光目的地（也作为设置里的预设地点） */
export const DESTINATIONS = [
  { id: 'tromso', name: '特罗姆瑟', latitude: 69.65, longitude: 18.96 },
  { id: 'lofoten', name: '罗弗敦群岛', latitude: 68.23, longitude: 14.56 },
  { id: 'abisko', name: '阿比斯库', latitude: 68.35, longitude: 18.83 },
  { id: 'kiruna', name: '基律纳', latitude: 67.86, longitude: 20.23 },
  { id: 'rovaniemi', name: '罗瓦涅米', latitude: 66.50, longitude: 25.73 },
  { id: 'saariselka', name: '萨里塞尔卡', latitude: 68.42, longitude: 27.41 },
  { id: 'murmansk', name: '摩尔曼斯克', latitude: 68.97, longitude: 33.08 },
  { id: 'reykjavik', name: '雷克雅未克', latitude: 64.15, longitude: -21.94 },
  { id: 'akureyri', name: '阿克雷里', latitude: 65.68, longitude: -18.09 },
  { id: 'fairbanks', name: '费尔班克斯', latitude: 64.84, longitude: -147.72 },
  { id: 'whitehorse', name: '白马镇', latitude: 60.72, longitude: -135.06 },
  { id: 'yellowknife', name: '黄刀镇', latitude: 62.45, longitude: -114.37 },
  { id: 'churchill', name: '丘吉尔', latitude: 58.77, longitude: -94.17 },
  { id: 'mohe', name: '漠河', latitude: 52.97, longitude: 122.54 },
  { id: 'tekapo', name: '特卡波', latitude: -44.00, longitude: 170.48 },
  { id: 'queenstown', name: '皇后镇', latitude: -45.03, longitude: 168.66 },
  { id: 'hobart', name: '霍巴特', latitude: -42.88, longitude: 147.33 },
];

/** 怎么去观测点：决定搜索半径和路上时间 */
export const TRAVEL_MODES = {
  walk: { id: 'walk', label: '步行', radiusKm: 4, speed: 4.5 },
  bike: { id: 'bike', label: '骑车', radiusKm: 12, speed: 14 },
  car: { id: 'car', label: '开车', radiusKm: 50, speed: 55 },
};

/** 直线距离乘 1.3 估算实际路程 */
export function durationText(mode, km) {
  const minutes = Math.ceil((km * 1.3) / mode.speed * 60 / 5) * 5;
  if (minutes < 60) return `${mode.label}约 ${Math.max(minutes, 5)} 分钟`;
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return m === 0 ? `${mode.label}约 ${h} 小时` : `${mode.label}约 ${h} 小时 ${m} 分`;
}

/** 观测点的类型：名称、图标、同等条件下的偏好（公园、地标多在城里，排后一点） */
export const KINDS = {
  beach: { label: '海滩', icon: '🏖️', preference: 0 },
  viewpoint: { label: '观景点', icon: '🔭', preference: 0 },
  lighthouse: { label: '灯塔', icon: '🗼', preference: 0 },
  nature: { label: '自然区', icon: '🌿', preference: 0 },
  peak: { label: '山顶', icon: '⛰️', preference: 0 },
  cape: { label: '海角', icon: '🌊', preference: 0 },
  camp: { label: '营地', icon: '⛺', preference: 1 },
  marina: { label: '码头', icon: '⛵', preference: 1 },
  picnic: { label: '野餐点', icon: '🧺', preference: 1 },
  dark: { label: '暗处', icon: '🌙', preference: 1 },
  park: { label: '公园', icon: '🌳', preference: 2 },
};

/** 当前地点周围的候选点：原地 + 8 个方向 × 3 个距离（开车才用得上） */
export function nearbyCandidates(center) {
  const result = [{ place: center, distance: 0, bearing: 0 }];
  for (const distance of [50, 100, 150]) {
    for (let bearing = 0; bearing < 360; bearing += 45) {
      const [lat, lon] = destination(center.latitude, center.longitude, distance, bearing);
      result.push({
        place: { id: `nearby-${bearing}-${distance}`, name: `${compass(bearing)} ${distance} km`, latitude: lat, longitude: lon },
        distance, bearing,
      });
    }
  }
  return result;
}

/** 一个候选观测点今晚的情况 */
export function forecastSpot(place, { clouds, kp, ovation, sky = null, skyFactor = null, distanceKm = null, bearing = null }) {
  const factor = skyFactor ?? sky?.skyFactor ?? 1;
  const hours = outlook(place.latitude, place.longitude, kp, clouds, factor);
  const best = bestHour(hours);
  return {
    id: place.id,
    place: { ...place },
    distanceKm,
    bearing,
    timeZone: clouds?.timeZone,
    hours,
    best,
    bestScore: best?.score ?? 0,
    nowVisible: ovation ? nowcast(ovation, place.latitude, place.longitude).visible : null,
    clouds,
    sky,
    siteFactor: factor,
    originalSky: null,
    shiftKm: null,
    kind: null,
    horizon: null,
  };
}

/** 「北 80 km」这种相对说法 */
export function directionText(spot) {
  if (spot.distanceKm == null || spot.bearing == null) return null;
  if (spot.distanceKm < 5) return '原地';
  return `${compass(spot.bearing)} ${Math.round(spot.distanceKm)} km`;
}

/** 把观测点挪到附近更暗的地方（云量沿用原来的，几 km 内差别不大） */
export function relocate(spot, dark, ctx) {
  const place = { ...spot.place, latitude: dark.latitude, longitude: dark.longitude };
  const moved = forecastSpot(place, { ...ctx, clouds: spot.clouds, sky: dark.zone, distanceKm: spot.distanceKm, bearing: spot.bearing });
  moved.originalSky = spot.sky;
  moved.shiftKm = dark.distanceKm;
  return moved;
}

/** 按 5 分一档排序，同一档里近的在前 */
export function rankNearby(spots) {
  return [...spots].sort((a, b) => {
    const tierA = Math.floor(a.bestScore / 5), tierB = Math.floor(b.bestScore / 5);
    if (tierA !== tierB) return tierB - tierA;
    return (a.distanceKm ?? 0) - (b.distanceKm ?? 0);
  });
}

/**
 * 观测点排序：今晚评分（评分都是 0 时看光害系数），走到半径边上打 85 折，
 * 没名字的暗处和城里的公园再打一点折扣（差不多时优先有名字的公共地方）；挑出彼此不太挨着的几个
 */
export function pickViewing(spots, count, radiusKm) {
  const value = (s) => (s.bestScore + s.siteFactor * 10) * (1 - 0.15 * Math.min((s.distanceKm ?? 0) / radiusKm, 1))
    * (1 - 0.03 * (KINDS[s.kind]?.preference ?? 0));
  const sorted = [...spots].sort((a, b) => value(b) - value(a));
  const picked = [];
  for (const spot of sorted) {
    if (picked.length >= count) break;
    const farEnough = picked.every((p) =>
      distanceKm(p.place.latitude, p.place.longitude, spot.place.latitude, spot.place.longitude) >= radiusKm / 6);
    if (farEnough) picked.push(spot);
  }
  return picked;
}
