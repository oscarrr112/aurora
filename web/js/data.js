// 数据源：NOAA SWPC（极光、Kp、太阳风）、Open-Meteo（云量、海拔）、Photon（OpenStreetMap 地点），全部免费、不要 key
import { fetchJSON, store } from './util.js';

const NOAA = 'https://services.swpc.noaa.gov';

/** NOAA 的时间字符串都是 UTC，有的带 Z，有的不带，有的带小数秒 */
function parseUTC(s) {
  if (!s) return null;
  let t = s.replace(' ', 'T');
  if (t.endsWith('Z')) t = t.slice(0, -1);
  const dot = t.indexOf('.');
  if (dot >= 0) t = t.slice(0, dot);
  const ms = Date.parse(t + 'Z');
  return Number.isNaN(ms) ? null : ms;
}

// MARK: OVATION 极光概率（约 30–90 分钟的临近预报），全球 1°×1° 网格上「头顶出现极光」的概率

export class OvationGrid {
  constructor(observationTime, forecastTime, values) {
    this.observationTime = observationTime;
    this.forecastTime = forecastTime;
    /** 索引 = (lat + 90) * 360 + lon，lon 取 0...359，lat 取 -90...90 */
    this.values = values;
    let max = 0;
    for (const v of values) if (v > max) max = v;
    this.maxValue = max;
  }

  value(lat, lon) {
    if (lat < -90 || lat > 90) return 0;
    const l = ((lon % 360) + 360) % 360;
    return this.values[(lat + 90) * 360 + l];
  }
}

export async function fetchOvation() {
  const raw = await fetchJSON(`${NOAA}/json/ovation_aurora_latest.json`);
  const values = new Uint8Array(181 * 360);
  for (const point of raw.coordinates ?? []) {
    if (point.length < 3) continue;
    const lon = Math.trunc(point[0]), lat = Math.trunc(point[1]);
    if (lon < 0 || lon >= 360 || lat < -90 || lat > 90) continue;
    values[(lat + 90) * 360 + lon] = Math.min(Math.max(point[2], 0), 100);
  }
  return new OvationGrid(parseUTC(raw['Observation Time']) ?? Date.now(), parseUTC(raw['Forecast Time']) ?? Date.now(), values);
}

// MARK: Kp 指数（过去 7 天实测 + 未来 3 天预报），每个点是 3 小时区间的起点

export async function fetchKp() {
  const data = await fetchJSON(`${NOAA}/products/noaa-planetary-k-index-forecast.json`);
  let rows;
  if (Array.isArray(data) && data.length && !Array.isArray(data[0])) {
    rows = data.map((r) => ({ time_tag: r.time_tag, kp: Number(r.kp), observed: r.observed, scale: r.noaa_scale }));
  } else {
    // 旧格式：二维数组，第一行是表头
    rows = data.slice(1).map((r) => ({ time_tag: r[0], kp: Number(r[1]), observed: r[2], scale: r[3] }));
  }
  return rows
    .map((r) => ({ time: parseUTC(r.time_tag), kp: r.kp, kind: r.observed, scale: r.scale }))
    .filter((p) => p.time != null && Number.isFinite(p.kp))
    .map((p) => ({ ...p, end: p.time + 3 * 3600000 }))
    .sort((a, b) => a.time - b.time);
}

export const kpAt = (ms, points) => points.findLast((p) => p.time <= ms && ms < p.end) ?? null;

// MARK: 实时太阳风（L1 点卫星，过去 24 小时，每分钟一条）

export async function fetchSolarWind() {
  const [mag, plasma] = await Promise.all([
    fetchJSON(`${NOAA}/json/rtsw/rtsw_mag_1m.json`),
    fetchJSON(`${NOAA}/json/rtsw/rtsw_wind_1m.json`),
  ]);
  // 同一分钟会有多颗卫星的数据，只取当前在用（active）的那一颗
  const active = (rows) => (rows.some((r) => r.active === true) ? rows.filter((r) => r.active === true) : rows);
  const byMinute = new Map();
  const sample = (t) => {
    const key = Math.floor(t / 60000);
    if (!byMinute.has(key)) byMinute.set(key, { time: key * 60000, bz: null, bt: null, speed: null, density: null });
    return byMinute.get(key);
  };
  for (const r of active(mag)) {
    const t = parseUTC(r.time_tag);
    if (t == null) continue;
    const s = sample(t);
    if (r.bz_gsm != null) s.bz = r.bz_gsm;
    if (r.bt != null) s.bt = r.bt;
  }
  for (const r of active(plasma)) {
    const t = parseUTC(r.time_tag);
    if (t == null) continue;
    const s = sample(t);
    if (r.proton_speed != null) s.speed = r.proton_speed;
    if (r.proton_density != null) s.density = r.proton_density;
  }
  return [...byMinute.values()].sort((a, b) => a.time - b.time);
}

// MARK: Open-Meteo 云量预报，一次请求查多个坐标，结果顺序和输入一致

/**
 * 一起查的几个天气模型：当地最优（北欧是 MET Nordic）、欧洲中心、德国、美国。
 * 云量预报在模型之间常常差很多，只信一个容易整晚误判，取平均更稳
 */
export const CLOUD_MODELS = [
  { id: 'best_match', label: '当地模型' },
  { id: 'ecmwf_ifs025', label: 'ECMWF' },
  { id: 'icon_seamless', label: 'ICON' },
  { id: 'gfs_seamless', label: 'GFS' },
];

/** 有效云量：低云不透光按原值，中云按 9 成，高云（薄卷云，亮的极光能透过来）按 4 成，各层随机重叠 */
export function effectiveCloud(low, mid, high) {
  return 100 * (1 - (1 - low / 100) * (1 - (0.9 * mid) / 100) * (1 - (0.4 * high) / 100));
}

const mean = (values) => values.reduce((a, b) => a + b, 0) / values.length;

export async function fetchClouds(coordinates) {
  if (!coordinates.length) return [];
  const params = new URLSearchParams({
    latitude: coordinates.map((c) => c[0].toFixed(3)).join(','),
    longitude: coordinates.map((c) => c[1].toFixed(3)).join(','),
    hourly: 'cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high',
    models: CLOUD_MODELS.map((m) => m.id).join(','),
    timezone: 'auto',
    timeformat: 'unixtime',
    past_days: '1',
    forecast_days: '3',
  });
  const data = await fetchJSON(`https://api.open-meteo.com/v1/forecast?${params}`);
  // 单个坐标返回对象，多个坐标返回数组
  const raws = Array.isArray(data) ? data : [data];
  return raws.map((raw, i) => {
    const h = raw.hourly;
    const hours = [];
    h.time.forEach((t, j) => {
      const models = [];
      for (const { id, label } of CLOUD_MODELS) {
        const total = h[`cloud_cover_${id}`]?.[j];
        if (total == null) continue;
        const low = h[`cloud_cover_low_${id}`]?.[j], mid = h[`cloud_cover_mid_${id}`]?.[j], high = h[`cloud_cover_high_${id}`]?.[j];
        // 有的模型不分层，就只能用总云量
        const layered = low != null && mid != null && high != null;
        models.push({ id, label, total, low: low ?? 0, mid: mid ?? 0, high: high ?? 0,
          effective: layered ? effectiveCloud(low, mid, high) : total });
      }
      if (!models.length) return;
      hours.push({
        time: t * 1000,
        total: mean(models.map((m) => m.total)),
        low: mean(models.map((m) => m.low)),
        mid: mean(models.map((m) => m.mid)),
        high: mean(models.map((m) => m.high)),
        effective: mean(models.map((m) => m.effective)),
        models,
      });
    });
    return { timeZone: raw.timezone, latitude: coordinates[i][0], longitude: coordinates[i][1], elevation: raw.elevation, hours };
  });
}

/** 离 ms 最近、且相差不超过 2 小时的那一小时 */
export function cloudNear(forecast, ms) {
  if (!forecast) return null;
  let best = null;
  for (const h of forecast.hours) {
    if (!best || Math.abs(h.time - ms) < Math.abs(best.time - ms)) best = h;
  }
  return best && Math.abs(best.time - ms) <= 2 * 3600000 ? best : null;
}

// MARK: 海拔（米，海面为 0）。海拔不会变，查过的点存在本地

const elevationKey = (c) => `${c[0].toFixed(4)},${c[1].toFixed(4)}`;
let elevationCache = null;

function loadElevationCache() {
  if (!elevationCache) elevationCache = new Map(Object.entries(store.get('elevations', {})));
  return elevationCache;
}

function saveElevationCache() {
  // 最多留 6000 个点，删最早的
  const entries = [...elevationCache.entries()];
  const kept = entries.slice(Math.max(0, entries.length - 6000));
  elevationCache = new Map(kept);
  store.set('elevations', Object.fromEntries(kept));
}

export async function fetchElevations(coordinates) {
  const cache = loadElevationCache();
  const missing = [...new Set(coordinates.map(elevationKey).filter((k) => !cache.has(k)))];
  // 一次最多 100 个点
  for (let i = 0; i < missing.length; i += 100) {
    const chunk = missing.slice(i, i + 100);
    const params = new URLSearchParams({
      latitude: chunk.map((k) => k.split(',')[0]).join(','),
      longitude: chunk.map((k) => k.split(',')[1]).join(','),
    });
    const data = await fetchJSON(`https://api.open-meteo.com/v1/elevation?${params}`);
    chunk.forEach((k, j) => cache.set(k, data.elevation[j]));
  }
  if (missing.length) saveElevationCache();
  return coordinates.map((c) => cache.get(elevationKey(c)));
}

// MARK: Photon（OpenStreetMap 搜索服务）。按离中心远近返回，每次最多 50 个；地点基本不变，缓存 30 天

export async function photonReverse(lat, lon, { radiusKm, limit = 50, tags = [] } = {}) {
  const params = new URLSearchParams({ lat: lat.toFixed(5), lon: lon.toFixed(5), limit: String(limit) });
  if (radiusKm) params.set('radius', String(Math.round(radiusKm)));
  for (const tag of tags) params.append('osm_tag', tag);
  const key = `photon:${params}`;
  const cached = store.get(key);
  if (cached && Date.now() - cached.date < 30 * 86400000) return cached.features;

  const data = await fetchJSON(`https://photon.komoot.io/reverse?${params}`);
  const features = (data.features ?? []).map((f) => ({
    lat: f.geometry.coordinates[1],
    lon: f.geometry.coordinates[0],
    name: f.properties.name ?? null,
    key: f.properties.osm_key,
    value: f.properties.osm_value,
    street: f.properties.street ?? null,
    district: f.properties.district ?? null,
    city: f.properties.city ?? null,
  }));
  store.set(key, { date: Date.now(), features });
  return features;
}
