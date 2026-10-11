// 全局状态和刷新逻辑（对应 iOS 版的 AppModel）
import { bearingDegrees, distanceKm, store } from './util.js';
import { fetchOvation, fetchKp, fetchSolarWind, fetchClouds, fetchElevations } from './data.js';
import { zoneAt, darkCandidates } from './lightpollution.js';
import { DESTINATIONS, TRAVEL_MODES, nearbyCandidates, forecastSpot, relocate, rankNearby, pickViewing } from './spots.js';
import { findViewingSpots, horizonAt, nameForDarkSpot, siteFactor } from './viewing.js';

export const CURRENT_ID = 'current';

const listeners = new Set();
let scheduled = false;

export const state = {
  tab: store.get('tab', 'tonight'),
  customPlaces: store.get('customPlaces', []),
  selectedPlaceID: store.get('selectedPlace', CURRENT_ID),
  currentLocation: store.get('lastLocation', null),
  /** 网址里带 ?at=纬度,经度 时固定用这个位置（调试用） */
  fixedLocation: null,
  travelMode: store.get('travelMode', 'walk'),

  ovation: null,
  kp: [],
  wind: [],
  clouds: null,
  loading: false,
  errors: [],
  lastUpdated: null,

  placeSky: null,
  placeHorizon: null,

  viewingSpots: [],
  loadingViewing: false,
  nearby: [],
  destinations: [],
  loadingSpots: false,
};

const at = new URLSearchParams(location.search).get('at')?.split(',').map(Number);
if (at?.length === 2 && at.every(Number.isFinite)) {
  state.fixedLocation = { latitude: at[0], longitude: at[1] };
  state.currentLocation = state.fixedLocation;
  state.selectedPlaceID = CURRENT_ID;
}

export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** 状态变了就在下一帧通知界面重画（同一帧里多次修改只画一次） */
export function changed() {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    for (const fn of listeners) fn();
  });
}

export const allPlaces = () => [...DESTINATIONS, ...state.customPlaces];

export function activePlace() {
  if (state.selectedPlaceID === CURRENT_ID) {
    const c = state.currentLocation;
    return c ? { id: CURRENT_ID, name: '当前位置', latitude: c.latitude, longitude: c.longitude } : null;
  }
  return allPlaces().find((p) => p.id === state.selectedPlaceID) ?? null;
}

/** 时间按所选地点的当地时区显示 */
export function timeZone() {
  const place = activePlace();
  const c = state.clouds;
  if (c && place && Math.abs(c.latitude - place.latitude) < 0.01 && Math.abs(c.longitude - place.longitude) < 0.01) return c.timeZone;
  return undefined;
}

export function placeSkyFactor() {
  return state.placeSky ? siteFactor(state.placeSky, state.placeHorizon) : 1;
}

export const travelMode = () => TRAVEL_MODES[state.travelMode] ?? TRAVEL_MODES.walk;

// MARK: 地点

export function setTab(tab) {
  state.tab = tab;
  store.set('tab', tab);
  changed();
}

export function select(id) {
  if (id === state.selectedPlaceID) return;
  state.selectedPlaceID = id;
  state.clouds = null;
  state.nearby = [];
  state.viewingSpots = [];
  state.placeSky = null;
  state.placeHorizon = null;
  store.set('selectedPlace', id);
  changed();
  refresh();
}

export function addPlace(name, latitude, longitude) {
  const place = { id: `p${Date.now().toString(36)}`, name, latitude, longitude };
  state.customPlaces = [...state.customPlaces, place];
  store.set('customPlaces', state.customPlaces);
  select(place.id);
}

export function removePlace(id) {
  state.customPlaces = state.customPlaces.filter((p) => p.id !== id);
  store.set('customPlaces', state.customPlaces);
  if (state.selectedPlaceID === id) select(CURRENT_ID);
  changed();
}

export function setTravelMode(mode) {
  if (mode === state.travelMode) return;
  state.travelMode = mode;
  store.set('travelMode', mode);
  state.viewingSpots = [];
  changed();
  const place = activePlace();
  refreshViewingSpots(place).then(() => {
    if (mode === 'car' && state.nearby.length === 0) refreshSpots(place);
  });
}

// MARK: 定位

function locate() {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) return reject(new Error('这个浏览器不支持定位'));
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ latitude: p.coords.latitude, longitude: p.coords.longitude }),
      (e) => reject(new Error(e.code === 1 ? '没有定位权限，请在浏览器设置里允许，或在「设置」里选一个固定地点'
        : e.code === 3 ? '定位超时' : '定位失败')),
      { enableHighAccuracy: false, timeout: 15000, maximumAge: 5 * 60000 },
    );
  });
}

// MARK: 刷新

export async function refreshIfStale() {
  if (state.lastUpdated && Date.now() - state.lastUpdated < 5 * 60000) return;
  await refresh();
}

/** 刷新进行中又要求刷新（比如换了地点），就等这次结束后再来一次 */
let running = null;
let queued = false;
export function refresh() {
  if (running) {
    queued = true;
    return running;
  }
  running = doRefresh().finally(() => {
    running = null;
    if (queued) {
      queued = false;
      refresh();
    }
  });
  return running;
}

async function doRefresh() {
  state.loading = true;
  changed();
  const problems = [];

  if (state.selectedPlaceID === CURRENT_ID && !state.fixedLocation) {
    try {
      state.currentLocation = await locate();
      store.set('lastLocation', state.currentLocation);
    } catch (error) {
      problems.push(error.message);
    }
  }
  const place = activePlace();

  const [ovation, kp, wind, clouds] = await Promise.allSettled([
    fetchOvation(), fetchKp(), fetchSolarWind(),
    place ? fetchClouds([[place.latitude, place.longitude]]).then((r) => r[0]) : Promise.resolve(null),
  ]);
  if (ovation.status === 'fulfilled') state.ovation = ovation.value; else problems.push(`极光概率：${ovation.reason.message}`);
  if (kp.status === 'fulfilled') state.kp = kp.value; else problems.push(`Kp 预报：${kp.reason.message}`);
  if (wind.status === 'fulfilled') state.wind = wind.value; else problems.push(`太阳风：${wind.reason.message}`);
  if (clouds.status === 'fulfilled') state.clouds = clouds.value; else problems.push(`云量：${clouds.reason.message}`);

  state.errors = problems;
  state.lastUpdated = Date.now();
  state.loading = false;
  changed();

  if (place) {
    state.placeSky = await zoneAt(place.latitude, place.longitude);
    state.placeHorizon = await cachedHorizon(place);
    changed();
  }
  await refreshViewingSpots(place);
  await refreshSpots(place);
}

const horizonCache = new Map();
async function cachedHorizon(place) {
  const key = `${place.latitude.toFixed(3)},${place.longitude.toFixed(3)}`;
  if (horizonCache.has(key)) return horizonCache.get(key);
  const result = await horizonAt(place.latitude, place.longitude);
  if (result.complete) horizonCache.set(key, result.view);
  return result.view;
}

// MARK: 具体观测点

/**
 * 光害、地平线、海景都是静态的，按 500 m 网格取整后的中心算一次存在本地（7 天），
 * 每次刷新只重新拉天气、重新算到当前位置的距离。
 */
async function viewingCandidates(center, mode) {
  const snapped = {
    latitude: Math.round(center.latitude / 0.005) * 0.005,
    longitude: Math.round(center.longitude / 0.005) * 0.005,
  };
  const key = `viewing:${snapped.latitude.toFixed(3)},${snapped.longitude.toFixed(3)},${mode.id}`;
  const cached = store.get(key);
  if (cached && Date.now() - cached.date < 7 * 86400000) return cached.spots;
  const result = await findViewingSpots(snapped, mode);
  if (result.complete) store.set(key, { date: Date.now(), spots: result.spots });
  return result.spots;
}

let viewingRun = 0;
async function refreshViewingSpots(center) {
  if (!center) {
    state.viewingSpots = [];
    return;
  }
  const run = ++viewingRun;
  const mode = travelMode();
  state.loadingViewing = true;
  changed();
  try {
    const found = (await viewingCandidates(center, mode))
      .map((c) => ({
        ...c,
        distanceKm: distanceKm(center.latitude, center.longitude, c.latitude, c.longitude),
        bearing: bearingDegrees(center.latitude, center.longitude, c.latitude, c.longitude),
      }))
      .filter((c) => c.distanceKm <= mode.radiusKm * 1.1);

    // 步行范围内天气都一样，直接用当前地点的；远一点的一次请求查完
    let cloudList = found.map(() => state.clouds);
    if (mode.id !== 'walk' && found.length) {
      try {
        cloudList = await fetchClouds(found.map((c) => [c.latitude, c.longitude]));
      } catch {
        // 用当前地点的天气凑合
      }
    }
    if (run !== viewingRun) return;

    const ctx = { kp: state.kp, ovation: state.ovation };
    const spots = found.map((c, i) => {
      const place = { id: `spot-${c.latitude.toFixed(4)},${c.longitude.toFixed(4)}`, name: c.name, latitude: c.latitude, longitude: c.longitude };
      const spot = forecastSpot(place, { ...ctx, clouds: cloudList[i], sky: c.ground, skyFactor: siteFactor(c.ground, c.horizon),
        distanceKm: c.distanceKm, bearing: c.bearing });
      spot.kind = c.kind;
      spot.horizon = c.horizon;
      return spot;
    });
    // 多挑两个，查地名时可能会去掉机场
    state.viewingSpots = pickViewing(spots, 8, mode.radiusKm);
    changed();
    await nameViewingSpots(run);
    if (run === viewingRun) state.viewingSpots = state.viewingSpots.slice(0, 6);
  } finally {
    if (run === viewingRun) {
      state.loadingViewing = false;
      changed();
    }
  }
}

async function nameViewingSpots(run) {
  const removed = new Set();
  for (const spot of state.viewingSpots.filter((s) => !s.place.name)) {
    let name;
    try {
      name = await nameForDarkSpot(spot.place.latitude, spot.place.longitude);
    } catch {
      name = '空旷暗处';
    }
    if (run !== viewingRun) return;
    if (name == null) removed.add(spot.id);
    else spot.place.name = name;
    changed();
  }
  state.viewingSpots = state.viewingSpots.filter((s) => !removed.has(s.id));
}

// MARK: 开车范围的几圈候选点 + 热门目的地

/** 每个点半径内最暗、且在陆地上的位置。光污染是年度数据，算一次就缓存起来 */
const darkSpotCache = new Map();
async function darkestLand(requests) {
  const results = new Array(requests.length).fill(null);
  const pending = [];
  for (const [i, r] of requests.entries()) {
    const key = `${r.latitude.toFixed(3)},${r.longitude.toFixed(3)},${r.radiusKm}`;
    if (darkSpotCache.has(key)) {
      results[i] = darkSpotCache.get(key);
      continue;
    }
    pending.push({ i, key, candidates: await darkCandidates(r.latitude, r.longitude, r.radiusKm, 8) });
  }
  const coordinates = pending.flatMap((p) => p.candidates.map((c) => [c.latitude, c.longitude]));
  if (!coordinates.length) return results;
  let elevations;
  try {
    elevations = await fetchElevations(coordinates);
  } catch {
    return results;
  }
  let offset = 0;
  for (const p of pending) {
    const slice = elevations.slice(offset, offset + p.candidates.length);
    offset += p.candidates.length;
    const land = p.candidates.find((_, j) => slice[j] > 0) ?? null;
    results[p.i] = land;
    darkSpotCache.set(p.key, land);
  }
  return results;
}

/** 光害在 2b 以上的点，如果半径内有更暗的陆地，就挪过去 */
async function relocateToDarkness(spots, limit, radiusKm, include) {
  const indices = spots.slice(0, limit).map((_, i) => i).filter((i) => include(spots[i]) && (spots[i].sky?.index ?? 0) > 4);
  const darks = await darkestLand(indices.map((i) => ({ latitude: spots[i].place.latitude, longitude: spots[i].place.longitude, radiusKm })));
  const result = [...spots];
  const ctx = { kp: state.kp, ovation: state.ovation };
  indices.forEach((i, j) => {
    const dark = darks[j];
    if (dark && spots[i].sky && dark.zone.index < spots[i].sky.index) result[i] = relocate(spots[i], dark, ctx);
  });
  return result;
}

async function refreshSpots(center) {
  state.loadingSpots = true;
  changed();
  const ctx = { kp: state.kp, ovation: state.ovation };
  // 远处的几圈候选点只有开车才用得上
  const candidates = state.travelMode === 'car' && center ? nearbyCandidates(center) : [];
  const places = allPlaces();
  const [nearbyResult, destinationResult] = await Promise.allSettled([
    fetchClouds(candidates.map((c) => [c.place.latitude, c.place.longitude])),
    fetchClouds(places.map((p) => [p.latitude, p.longitude])),
  ]);

  if (!candidates.length) {
    state.nearby = [];
  } else if (nearbyResult.status === 'fulfilled') {
    let spots = [];
    for (const [i, candidate] of candidates.entries()) {
      const cloud = nearbyResult.value[i];
      // 海拔为 0 基本是海面，原地除外
      if (candidate.distance > 0 && cloud.elevation != null && cloud.elevation <= 0) continue;
      const place = { ...candidate.place };
      if (candidate.distance === 0) place.name = center.name;
      const sky = await zoneAt(place.latitude, place.longitude);
      spots.push(forecastSpot(place, { ...ctx, clouds: cloud, sky, distanceKm: candidate.distance, bearing: candidate.bearing }));
    }
    // 排名靠前、但落在村镇里的点，挪到 5 km 内最暗的陆地上（原地不动，留作对比）
    spots = rankNearby(spots);
    spots = await relocateToDarkness(spots, 10, 5, (s) => (s.distanceKm ?? 0) > 0);
    state.nearby = rankNearby(spots);
    changed();
  }

  if (destinationResult.status === 'fulfilled') {
    let spots = [];
    for (const [i, place] of places.entries()) {
      const sky = await zoneAt(place.latitude, place.longitude);
      spots.push(forecastSpot(place, { ...ctx, clouds: destinationResult.value[i], sky }));
    }
    // 目的地都是城镇，按开车出城 15 km 内最暗的地方算
    spots = await relocateToDarkness(spots, spots.length, 15, () => true);
    state.destinations = spots.sort((a, b) => b.bestScore - a.bestScore);
  }
  state.loadingSpots = false;
  changed();
}
