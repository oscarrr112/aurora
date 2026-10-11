// 在出行范围内找具体的观测点：OpenStreetMap 里有名字的地点（观景点、海滩、灯塔、自然保护区、营地、山顶…），
// 加上光污染图上几块暗的陆地。每个点都算一下脚下和极光方向地平线的光害，以及那个方向是不是海。
import { bearingDegrees, destination, distanceKm } from './util.js';
import { auroraBearing } from './geomag.js';
import { ZONES, zoneAt, darkCandidates } from './lightpollution.js';
import { fetchElevations, photonReverse } from './data.js';
import { KINDS } from './spots.js';

const OSM_KINDS = {
  'tourism:viewpoint': 'viewpoint', 'leisure:bird_hide': 'viewpoint',
  'natural:beach': 'beach', 'man_made:lighthouse': 'lighthouse',
  'natural:peak': 'peak', 'natural:cape': 'cape',
  'leisure:nature_reserve': 'nature',
  'tourism:camp_site': 'camp', 'tourism:caravan_site': 'camp',
  'tourism:picnic_site': 'picnic',
  'leisure:park': 'park', 'leisure:marina': 'marina', 'man_made:pier': 'marina',
};

/** 每次最多返回 50 个、按离中心远近，所以分组查，免得自然保护区把观景点挤掉；公园和码头只在身边找 */
const OSM_GROUPS = [
  { tags: ['tourism:viewpoint', 'natural:beach', 'man_made:lighthouse', 'natural:peak', 'natural:cape', 'leisure:bird_hide'] },
  { tags: ['leisure:nature_reserve', 'tourism:camp_site', 'tourism:caravan_site', 'tourism:picnic_site'] },
  { tags: ['leisure:park', 'leisure:marina', 'man_made:pier'], maxRadiusKm: 2 },
];

const SEA_DISTANCES = [1.5, 4.0];

/** 光害系数：脚下天空和极光方向地平线取较差的那个；看不到海的扣一点（可能被挡） */
export function siteFactor(ground, horizon) {
  if (!horizon) return ground.skyFactor;
  const worst = Math.max(ground.index, horizon.glow.index);
  return ZONES[worst].skyFactor * (horizon.seaView ? 1 : 0.96);
}

/** 朝极光方向 ±25° 采样，近处的灯光按原等级算，每远一倍降 2 级 */
export async function horizonGlow(lat, lon, bearing) {
  let worst = 0;
  for (const offset of [-25, -12, 0, 12, 25]) {
    for (const distance of [1, 2, 4, 8, 15, 25]) {
      const [la, lo] = destination(lat, lon, distance, bearing + offset);
      const zone = await zoneAt(la, lo);
      if (zone) worst = Math.max(worst, zone.index - 2 * Math.log2(distance));
    }
  }
  return ZONES[Math.min(Math.max(Math.round(worst), 0), 14)];
}

/** 某个地点朝极光方向的地平线；complete 为 false 表示海拔没查到 */
export async function horizonAt(lat, lon) {
  const bearing = auroraBearing(lat, lon);
  const glow = await horizonGlow(lat, lon, bearing);
  try {
    const elevations = await fetchElevations(SEA_DISTANCES.map((d) => destination(lat, lon, d, bearing)));
    return { view: { bearing, glow, seaView: elevations.every((e) => e <= 0) }, complete: true };
  } catch {
    return { view: { bearing, glow, seaView: false }, complete: false };
  }
}

/** 半径内在陆地上的采样点，暗的优先（海面在光污染图上也是黑的，用海拔排除） */
async function landPoints(lat, lon, radiusKm) {
  const grid = await darkCandidates(lat, lon, radiusKm, 100, Math.max(radiusKm / 8, 0.5));
  const elevations = await fetchElevations(grid.map((g) => [g.latitude, g.longitude]));
  return grid.filter((_, i) => elevations[i] > 0);
}

async function searchOSM(lat, lon, radiusKm) {
  const spots = [];
  let complete = true;
  for (const group of OSM_GROUPS) {
    try {
      const features = await photonReverse(lat, lon, { radiusKm: Math.min(radiusKm, group.maxRadiusKm ?? radiusKm), tags: group.tags });
      for (const f of features) {
        const kind = OSM_KINDS[`${f.key}:${f.value}`];
        if (f.name && kind) spots.push({ name: f.name, kind, lat: f.lat, lon: f.lon });
      }
    } catch {
      complete = false;
    }
  }
  return { spots, complete };
}

/**
 * 返回 { spots, complete }。complete 为 false 表示有请求失败（被限流、没网），结果不要缓存。
 * 距离和方位是相对 center 的；调用方换了中心可以重新算。
 */
export async function findViewingSpots(center, mode) {
  const radius = mode.radiusKm;
  const bearing = auroraBearing(center.latitude, center.longitude);

  let land = [], landComplete = true;
  try {
    land = await landPoints(center.latitude, center.longitude, radius);
  } catch {
    landComplete = false;
  }
  const rankDark = (s) => s.zone.index + (2 * s.distanceKm) / radius;
  const darkLand = [...land].sort((a, b) => rankDark(a) - rankDark(b)).slice(0, 6);

  const osm = await searchOSM(center.latitude, center.longitude, radius);
  const raw = [];
  for (const poi of osm.spots) {
    if (!raw.some((r) => distanceKm(r.lat, r.lon, poi.lat, poi.lon) < 0.15)) raw.push(poi);
  }
  // 附近 400 m 内没有有名字的地点，就用暗处本身
  for (const s of darkLand) {
    if (!raw.some((r) => distanceKm(r.lat, r.lon, s.latitude, s.longitude) < 0.4)) {
      raw.push({ name: '', kind: 'dark', lat: s.latitude, lon: s.longitude });
    }
  }

  // 粗筛：脚下越暗越好，远一个半径相当于亮 2 级
  let scored = [];
  for (const item of raw) {
    const distance = distanceKm(center.latitude, center.longitude, item.lat, item.lon);
    if (distance > radius * 1.1) continue;
    const zone = await zoneAt(item.lat, item.lon);
    if (!zone) continue;
    const rank = zone.index + (2 * distance) / radius + KINDS[item.kind].preference * 0.3;
    scored.push({ item, zone, distance, rank });
  }
  scored.sort((a, b) => a.rank - b.rank);
  scored = scored.slice(0, 30);

  // 一次请求查海拔：极光方向 1.5 km、4 km 处是不是海
  const coordinates = scored.flatMap((s) => SEA_DISTANCES.map((d) => destination(s.item.lat, s.item.lon, d, bearing)));
  let elevations = null;
  try {
    elevations = await fetchElevations(coordinates);
  } catch {
    elevations = null;
  }

  const spots = [];
  for (const [i, s] of scored.entries()) {
    const checks = elevations ? elevations.slice(i * SEA_DISTANCES.length, (i + 1) * SEA_DISTANCES.length) : [];
    const seaView = checks.length > 0 && checks.every((e) => e <= 0);
    const glow = await horizonGlow(s.item.lat, s.item.lon, bearing);
    spots.push({
      name: s.item.name,
      kind: s.item.kind,
      latitude: s.item.lat,
      longitude: s.item.lon,
      distanceKm: s.distance,
      bearing: bearingDegrees(center.latitude, center.longitude, s.item.lat, s.item.lon),
      ground: s.zone,
      horizon: { bearing, glow, seaView },
    });
  }
  return { spots, complete: landComplete && osm.complete && (elevations != null || coordinates.length === 0) };
}

/** 暗处没有名字：查附近的地点、路名或村名。落在机场里返回 null（又暗又空旷，但进不去） */
export async function nameForDarkSpot(lat, lon) {
  // 机场占地大，跑道离机场的中心点一两公里也很常见
  const airports = await photonReverse(lat, lon, { radiusKm: 3, limit: 3, tags: ['aeroway:aerodrome'] });
  if (airports.some((a) => distanceKm(lat, lon, a.lat, a.lon) < 2)) return null;
  const features = await photonReverse(lat, lon, { radiusKm: 1, limit: 5 });
  if (features.some((f) => f.key === 'aeroway' || /airport|机场|flygplats|lufthavn|lentoasema/i.test(f.name ?? ''))) return null;
  const named = features.find((f) => f.name && ['natural', 'leisure', 'landuse', 'place', 'tourism', 'highway'].includes(f.key));
  const label = named?.name ?? features[0]?.street ?? features[0]?.district ?? features[0]?.city;
  return label ? `${label} 附近` : '空旷暗处';
}
