// 地图页：NOAA 极光概率图层（含昼夜）、热门目的地评分和当前地点
/* global L */
import { escapeHTML as e, fmt } from './util.js';
import { subsolarPoint } from './astro.js';
import { scoreColor } from './charts.js';
import { state, activePlace } from './model.js';

const MAX_LAT = 84;

/** 概率 → 颜色和不透明度。低概率几乎透明，避免整片极区糊成一块 */
const STOPS = [
  [2, [0.10, 0.80, 0.45], 0.0],
  [5, [0.15, 0.95, 0.50], 0.28],
  [12, [0.25, 1.00, 0.55], 0.50],
  [25, [0.40, 1.00, 0.50], 0.65],
  [45, [0.90, 0.95, 0.30], 0.75],
  [65, [1.00, 0.55, 0.20], 0.82],
  [85, [1.00, 0.25, 0.55], 0.88],
];

export const legendGradient = `linear-gradient(to right, ${STOPS.slice(1).map(([, c]) =>
  `rgb(${c.map((v) => Math.round(v * 255)).join(',')})`).join(', ')})`;

function color(v) {
  if (v <= STOPS[0][0]) return null;
  for (let i = 1; i < STOPS.length; i++) {
    const [va, ca, aa] = STOPS[i - 1], [vb, cb, ab] = STOPS[i];
    if (v <= vb) {
      const t = (v - va) / (vb - va);
      return [ca[0] + (cb[0] - ca[0]) * t, ca[1] + (cb[1] - ca[1]) * t, ca[2] + (cb[2] - ca[2]) * t, aa + (ab - aa) * t];
    }
  }
  const [, c, a] = STOPS.at(-1);
  return [...c, a];
}

const mercatorY = (lat) => Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360));
const latFromMercator = (y) => (Math.atan(Math.exp(y)) * 360) / Math.PI - 90;

/** 把 OVATION 1° 网格平滑插值后，按墨卡托投影画成一张整图，白天一侧蒙一层淡淡的亮色 */
function renderOvation(grid, now = Date.now()) {
  // 先做一次 3×3 加权平滑，去掉网格感
  const smooth = new Float32Array(181 * 360);
  for (let lat = -89; lat <= 89; lat++) {
    for (let lon = 0; lon < 360; lon++) {
      let sum = 0;
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          sum += (dx === 0 ? 2 : 1) * (dy === 0 ? 2 : 1) * grid.value(lat + dy, lon + dx);
        }
      }
      smooth[(lat + 90) * 360 + lon] = sum / 16;
    }
  }

  const width = 900;
  const yTop = mercatorY(MAX_LAT), yBottom = mercatorY(-MAX_LAT);
  const height = Math.round((width * (yTop - yBottom)) / (2 * Math.PI));
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext('2d');
  const image = context.createImageData(width, height);
  const px = image.data;

  const [sunLat, sunLon] = subsolarPoint(now);
  const r = Math.PI / 180;
  const sinDec = Math.sin(sunLat * r), cosDec = Math.cos(sunLat * r);
  const cosDeltaLon = new Float32Array(width);
  for (let i = 0; i < width; i++) cosDeltaLon[i] = Math.cos((-180 + ((i + 0.5) * 360) / width - sunLon) * r);

  for (let j = 0; j < height; j++) {
    const lat = latFromMercator(yTop - ((j + 0.5) * (yTop - yBottom)) / height);
    const sinPart = Math.sin(lat * r) * sinDec, cosPart = Math.cos(lat * r) * cosDec;
    const hasAurora = Math.abs(lat) > 30;
    const fy = lat + 90;
    const y0 = Math.min(Math.floor(fy), 179);
    const ty = fy - y0;
    for (let i = 0; i < width; i++) {
      // 白天一侧：−12°（航海晨昏）到 0° 之间渐变
      const sunAlt = Math.asin(Math.min(Math.max(sinPart + cosPart * cosDeltaLon[i], -1), 1)) / r;
      const veil = Math.min(Math.max((sunAlt + 12) / 12, 0), 1) * 0.13;
      let outR = 0.8 * veil, outG = 0.88 * veil, outB = veil, outA = veil;
      if (hasAurora) {
        const lon = -180 + ((i + 0.5) * 360) / width;
        const fx = lon < 0 ? lon + 360 : lon;
        const x0 = Math.floor(fx) % 360, x1 = (x0 + 1) % 360;
        const tx = fx - Math.floor(fx);
        const v = (smooth[y0 * 360 + x0] * (1 - tx) + smooth[y0 * 360 + x1] * tx) * (1 - ty)
          + (smooth[(y0 + 1) * 360 + x0] * (1 - tx) + smooth[(y0 + 1) * 360 + x1] * tx) * ty;
        const c = color(v);
        if (c) {
          // 极光盖在昼夜层上面（预乘 alpha 的 source-over）
          const ca = c[3];
          outR = c[0] * ca + outR * (1 - ca);
          outG = c[1] * ca + outG * (1 - ca);
          outB = c[2] * ca + outB * (1 - ca);
          outA = ca + outA * (1 - ca);
        }
      }
      if (outA <= 0) continue;
      const p = (j * width + i) * 4;
      // ImageData 不是预乘的，除回去
      px[p] = Math.min(outR / outA, 1) * 255;
      px[p + 1] = Math.min(outG / outA, 1) * 255;
      px[p + 2] = Math.min(outB / outA, 1) * 255;
      px[p + 3] = Math.min(outA, 1) * 255;
    }
  }
  context.putImageData(image, 0, 0);
  return canvas.toDataURL('image/png');
}

let map = null;
let auroraLayer = null;
let markerLayer = null;
let shownForecast = null;
let shownPlaceKey = null;
let shownMarkers = '';
/** Esri 深灰底图（免费、不要 key）；地名单独一层，放在极光和光污染图层上面 */
export function addBaseLayers(target) {
  const esri = 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas';
  L.tileLayer(`${esri}/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}`, {
    maxNativeZoom: 16, maxZoom: 19,
    attribution: 'Tiles &copy; Esri &mdash; Esri, HERE, Garmin, &copy; OpenStreetMap contributors',
  }).addTo(target);
  target.createPane('labels');
  target.getPane('labels').style.zIndex = 450;
  target.getPane('labels').style.pointerEvents = 'none';
  L.tileLayer(`${esri}/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}`, {
    maxNativeZoom: 16, maxZoom: 19, pane: 'labels',
  }).addTo(target);
  target.attributionControl.setPrefix(false);
}

export function initMap(container) {
  map = L.map(container, { zoomControl: false, worldCopyJump: true, minZoom: 2, maxZoom: 15, attributionControl: true })
    .setView([65, 15], 3);
  addBaseLayers(map);
  markerLayer = L.layerGroup().addTo(map);

  // 长按（电脑上右键）添加地点
  map.on('contextmenu', (event) => {
    const { lat, lng } = event.latlng;
    const lon = ((lng + 540) % 360) - 180;
    L.popup().setLatLng(event.latlng).setContent(`<div class="popup">
      <b>${lat.toFixed(4)}, ${lon.toFixed(4)}</b>
      <button class="button small" data-action="add-here:${lat.toFixed(5)},${lon.toFixed(5)}">添加为我的地点</button></div>`).openOn(map);
  });
}

export function updateMap() {
  if (!map) return;
  map.invalidateSize();

  const grid = state.ovation;
  if (grid && grid.forecastTime !== shownForecast) {
    shownForecast = grid.forecastTime;
    // 生成图像要几十到几百毫秒，让出这一帧
    setTimeout(() => {
      const url = renderOvation(grid);
      auroraLayer?.remove();
      // 左右各多放一份，地图横向拖动时也能看到
      auroraLayer = L.layerGroup([-360, 0, 360].map((offset) =>
        L.imageOverlay(url, [[-MAX_LAT, -180 + offset], [MAX_LAT, 180 + offset]], { opacity: 1, interactive: false })));
      auroraLayer.addTo(map);
      markerLayer.bringToFront?.();
    }, 30);
  }

  const place = activePlace();
  const placeKey = place ? `${place.id}:${place.latitude.toFixed(3)},${place.longitude.toFixed(3)}` : '';
  if (place && placeKey !== shownPlaceKey) {
    // 往极区方向偏一点，让极光卵进入画面
    const centerLat = Math.min(Math.max(place.latitude + (place.latitude >= 0 ? 6 : -6), -75), 75);
    map.setView([centerLat, place.longitude], 3, { animate: shownPlaceKey != null });
    shownPlaceKey = placeKey;
  }

  const signature = JSON.stringify([placeKey, state.destinations.map((s) => [s.id, Math.floor(s.bestScore)])]);
  if (signature !== shownMarkers) {
    shownMarkers = signature;
    drawMarkers(place);
  }
}

function drawMarkers(place) {
  markerLayer.clearLayers();
  for (const spot of state.destinations) {
    if (spot.id === place?.id) continue;
    const icon = L.divIcon({
      className: 'score-marker',
      html: `<span style="background:${scoreColor(spot.bestScore)}">${Math.floor(spot.bestScore)}</span>`,
      iconSize: [30, 30], iconAnchor: [15, 15],
    });
    const best = spot.best;
    L.marker([spot.place.latitude, spot.place.longitude], { icon }).addTo(markerLayer).bindPopup(`<div class="popup">
      <b>${e(spot.place.name)}</b>
      <span>${best && best.score >= 1 ? `今晚最高 ${Math.floor(best.score)} 分 · ${fmt.time(best.time, spot.timeZone)}` : '今晚希望不大'}</span>
      <button class="button small" data-action="select-go:${e(spot.id)}">切换到这里</button></div>`);
  }

  if (place) {
    const icon = L.divIcon({ className: 'place-marker', html: '<span></span>', iconSize: [18, 18], iconAnchor: [9, 9] });
    L.marker([place.latitude, place.longitude], { icon, zIndexOffset: 1000 }).addTo(markerLayer).bindPopup(`<b>${e(place.name)}</b>`);
  }
}

export function closePopup() {
  map?.closePopup();
}

