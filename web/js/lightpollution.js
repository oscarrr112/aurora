// 光污染：David Lorenz《Light Pollution Atlas 2025》的瓦片（z=6，1024 像素，北纬 70° 约 0.2 km 一个像素）
import { distanceKm } from './util.js';

const zoneTable = [
  ['0', 22.0, [0, 0, 0]], ['1a', 21.96, [34, 34, 34]], ['1b', 21.91, [66, 66, 66]],
  ['2a', 21.85, [20, 47, 114]], ['2b', 21.75, [33, 84, 216]],
  ['3a', 21.60, [15, 87, 20]], ['3b', 21.38, [31, 161, 42]],
  ['4a', 21.08, [110, 100, 30]], ['4b', 20.70, [184, 166, 37]],
  ['5a', 20.25, [191, 100, 30]], ['5b', 19.76, [253, 150, 80]],
  ['6a', 19.22, [251, 90, 73]], ['6b', 18.66, [251, 153, 138]],
  ['7a', 18.09, [160, 160, 160]], ['7b', 17.60, [242, 242, 242]],
];

/** 光害对看极光的影响：弱极光会被淹没，强极光影响小，这里取一个折中系数 */
const skyFactors = [1, 1, 1, 0.99, 0.98, 0.96, 0.93, 0.88, 0.82, 0.74, 0.65, 0.55, 0.46, 0.38, 0.30];

function summary(index) {
  if (index <= 2) return '几乎没有光害';
  if (index <= 4) return '很暗';
  if (index <= 6) return '乡村，暗';
  if (index <= 8) return '郊区，地平线有光';
  if (index <= 10) return '城郊，光害明显';
  if (index <= 12) return '城市';
  return '市中心';
}

/** 光污染等级（天顶天空亮度，sqm 越大越黑，22.0 为无人造光） */
export const ZONES = zoneTable.map(([name, sqm, rgb], index) => ({
  index, name, sqm, rgb, skyFactor: skyFactors[index], summary: summary(index),
}));

const YEAR = 2025;
const ZOOM = 6;
const SIZE = 1024;
const UNKNOWN = 255;

const tiles = new Map();
const inFlight = new Map();

/** 颜色 → 区号。浏览器解码时颜色可能有一点偏差，精确匹配不上就找最接近的 */
const colorCache = new Map(ZONES.map((z) => [(z.rgb[0] << 16) | (z.rgb[1] << 8) | z.rgb[2], z.index]));
function zoneForColor(r, g, b) {
  const key = (r << 16) | (g << 8) | b;
  let index = colorCache.get(key);
  if (index !== undefined) return index;
  let best = UNKNOWN, bestDistance = 40 * 40;
  for (const z of ZONES) {
    const d = (z.rgb[0] - r) ** 2 + (z.rgb[1] - g) ** 2 + (z.rgb[2] - b) ** 2;
    if (d < bestDistance) { bestDistance = d; best = z.index; }
  }
  colorCache.set(key, best);
  return best;
}

function locate(lat, lon) {
  const n = 1 << ZOOM;
  const la = Math.min(Math.max(lat, -85), 85);
  const x = ((lon + 180) / 360) * n;
  const y = ((1 - Math.asinh(Math.tan((la * Math.PI) / 180)) / Math.PI) / 2) * n;
  const tx = Math.min(Math.max(Math.floor(x), 0), n - 1);
  const ty = Math.min(Math.max(Math.floor(y), 0), n - 1);
  const px = Math.min(Math.max(Math.floor((x - tx) * SIZE), 0), SIZE - 1);
  const py = Math.min(Math.max(Math.floor((y - ty) * SIZE), 0), SIZE - 1);
  return { key: `${tx}_${ty}`, px, py };
}

const tileURL = (key) => `https://djlorenz.github.io/astronomy/image_tiles/tiles${YEAR}/tile_${ZOOM}_${key}.png`;

/** 下载瓦片，用 Cache API 存在本地（数据是年度的） */
async function download(url) {
  let cache = null;
  try {
    cache = await caches.open(`lightpollution${YEAR}`);
    const hit = await cache.match(url);
    if (hit) return hit.blob();
  } catch {
    cache = null;
  }
  const response = await fetch(url);
  // 没有瓦片的地方（大洋、极区）就是没有灯光
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`光污染瓦片 ${response.status}`);
  if (cache) cache.put(url, response.clone()).catch(() => {});
  return response.blob();
}

/** 不同浏览器对 createImageBitmap 的参数支持不一样，逐个退回 */
async function toImage(blob) {
  try {
    return await createImageBitmap(blob, { colorSpaceConversion: 'none', premultiplyAlpha: 'none' });
  } catch {
    try {
      return await createImageBitmap(blob);
    } catch {
      const url = URL.createObjectURL(blob);
      try {
        const img = new Image();
        img.src = url;
        await img.decode();
        return img;
      } finally {
        URL.revokeObjectURL(url);
      }
    }
  }
}

async function decode(blob) {
  const image = await toImage(blob);
  const canvas = document.createElement('canvas');
  canvas.width = SIZE;
  canvas.height = SIZE;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  context.drawImage(image, 0, 0, SIZE, SIZE);
  image.close?.();
  const rgba = context.getImageData(0, 0, SIZE, SIZE).data;
  const zones = new Uint8Array(SIZE * SIZE);
  for (let i = 0, p = 0; i < zones.length; i++, p += 4) {
    // 透明像素按 0 区（没有灯光）算
    zones[i] = rgba[p + 3] === 0 ? 0 : zoneForColor(rgba[p], rgba[p + 1], rgba[p + 2]);
  }
  return zones;
}

async function loadTile(key) {
  if (tiles.has(key)) return tiles.get(key);
  if (inFlight.has(key)) return inFlight.get(key);
  const task = (async () => {
    try {
      const blob = await download(tileURL(key));
      return blob ? await decode(blob) : new Uint8Array(SIZE * SIZE);
    } catch {
      return null;
    }
  })();
  inFlight.set(key, task);
  const result = await task;
  inFlight.delete(key);
  if (result) {
    tiles.set(key, result);
    // 每张 1 MB，最多留 30 张在内存里
    if (tiles.size > 30) tiles.delete(tiles.keys().next().value);
  }
  return result;
}

export async function zoneAt(lat, lon) {
  const { key, px, py } = locate(lat, lon);
  const tile = tiles.get(key) ?? (await loadTile(key));
  if (!tile) return null;
  const value = tile[py * SIZE + px];
  return value === UNKNOWN ? null : ZONES[value];
}

/**
 * 半径内最暗的若干个点（按光害从低到高、距离从近到远），彼此至少相隔 minSpacingKm。
 * 海面在图上也是全黑，调用方需要再用海拔排除海面。
 */
export async function darkCandidates(lat, lon, radiusKm, count, minSpacingKm = 1) {
  const step = Math.max(radiusKm / 12, 0.4);
  const steps = Math.ceil(radiusKm / step);
  const cosLat = Math.max(Math.cos((lat * Math.PI) / 180), 0.05);
  const samples = [];
  for (let iy = -steps; iy <= steps; iy++) {
    for (let ix = -steps; ix <= steps; ix++) {
      const dx = ix * step, dy = iy * step;
      const distance = Math.hypot(dx, dy);
      if (distance > radiusKm) continue;
      const la = lat + dy / 111.2;
      const lo = lon + dx / (111.2 * cosLat);
      const zone = await zoneAt(la, lo);
      if (!zone) continue;
      const bearing = ((Math.atan2(dx, dy) * 180) / Math.PI + 360) % 360;
      samples.push({ latitude: la, longitude: lo, zone, distanceKm: distance, bearing });
    }
  }
  samples.sort((a, b) => a.zone.index - b.zone.index || a.distanceKm - b.distanceKm);
  const picked = [];
  for (const s of samples) {
    if (picked.every((p) => distanceKm(p.latitude, p.longitude, s.latitude, s.longitude) >= minSpacingKm)) picked.push(s);
    if (picked.length >= count) break;
  }
  return picked;
}

export const ATLAS_ZOOM = ZOOM;
export const ATLAS_TILE_SIZE = SIZE;

/**
 * 地图集瓦片 (tx, ty) 里从像素 (sx, sy) 开始、每隔 step 像素取一个、count × count 个点的区号（没数据按 0 区）。
 * 越出这张瓦片的部分从相邻瓦片取，地图上的瓦片之间才接得上。一张都没取到返回 null
 */
export async function zoneBlock(tx, ty, sx, sy, count, step = 1) {
  const world = (1 << ZOOM) * SIZE;
  const out = new Uint8Array(count * count);
  const loaded = new Map();
  let any = false;
  for (let j = 0; j < count; j++) {
    const gy = ty * SIZE + sy + Math.floor(j * step);
    if (gy < 0 || gy >= world) continue;
    const tileY = Math.floor(gy / SIZE), py = gy - tileY * SIZE;
    for (let i = 0; i < count; i++) {
      const gx = (((tx * SIZE + sx + Math.floor(i * step)) % world) + world) % world;
      const tileX = Math.floor(gx / SIZE), px = gx - tileX * SIZE;
      const key = `${tileX}_${tileY}`;
      let tile = loaded.get(key);
      if (tile === undefined) {
        tile = tiles.get(key) ?? (await loadTile(key));
        loaded.set(key, tile);
      }
      if (!tile) continue;
      any = true;
      const value = tile[py * SIZE + px];
      out[j * count + i] = value === UNKNOWN ? 0 : value;
    }
  }
  return any ? out : null;
}
