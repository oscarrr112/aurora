// 去哪看页面上的小地图：观测点（序号和下面的列表对应）、出行范围、极光方向和光污染，可以展开成全屏。
// 页面每次重画都会换掉 HTML，地图本身只建一次，重画后挪进新的占位块里。
/* global L */
import { escapeHTML as e, destination, preciseDirection } from './util.js';
import { auroraBearing } from './geomag.js';
import { ZONES, zoneBlock, ATLAS_ZOOM, ATLAS_TILE_SIZE } from './lightpollution.js';
import { KINDS, durationText } from './spots.js';
import { COLORS, scoreColor } from './charts.js';
import { addBaseLayers } from './map.js';
import { state, activePlace, travelMode } from './model.js';

// MARK: 光污染图层

/** 只把有灯光的地方（4a 以上）用暖色晕开，暗处完全透明，不挡底图 */
const LIGHT_COLORS = ZONES.map((z) => [...z.rgb, z.index < 7 ? 0 : z.index <= 8 ? 90 : z.index <= 10 ? 140 : 185]);
const hasLight = (zones) => zones.some((v) => LIGHT_COLORS[v]?.[3] > 0);

function paint(zones, size) {
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const context = canvas.getContext('2d');
  const image = context.createImageData(size, size);
  for (let i = 0; i < zones.length; i++) {
    const c = LIGHT_COLORS[zones[i]];
    if (!c || c[3] === 0) continue;
    image.data.set(c, i * 4);
  }
  context.putImageData(image, 0, 0);
  return canvas;
}

/** 从地图集 z=6 的瓦片里切出这块 256 像素地图瓦片对应的部分 */
async function renderLightTile(canvas, { x, y, z }) {
  if (z < ATLAS_ZOOM) return;
  const shift = z - ATLAS_ZOOM;
  const tx = x >> shift, ty = y >> shift;
  const span = ATLAS_TILE_SIZE / (1 << shift);
  const x0 = (x - (tx << shift)) * span, y0 = (y - (ty << shift)) * span;
  const out = canvas.width;
  const context = canvas.getContext('2d');

  if (span >= out) {
    // 缩得很小：直接隔点取
    const zones = await zoneBlock(tx, ty, x0, y0, out, span / out);
    if (zones && hasLight(zones)) context.drawImage(paint(zones, out), 0, 0);
    return;
  }

  // 放大：多取 3 像素的边，放大后模糊，把一格一格的台阶晕成平滑的光斑，瓦片之间也接得上
  const margin = 3;
  const bx = Math.floor(x0) - margin, by = Math.floor(y0) - margin;
  const block = Math.ceil(span) + 2 * margin + 1;
  const zones = await zoneBlock(tx, ty, bx, by, block);
  if (!zones || !hasLight(zones)) return;
  const k = out / span;
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = 'high';
  if (span >= 2 && 'filter' in context) context.filter = `blur(${k * 0.9}px)`;
  context.drawImage(paint(zones, block), -(x0 - bx) * k, -(y0 - by) * k, block * k, block * k);
}

const LightLayer = L.GridLayer.extend({
  createTile(coords, done) {
    const canvas = document.createElement('canvas');
    canvas.width = 256;
    canvas.height = 256;
    renderLightTile(canvas, coords).then(() => done(null, canvas), () => done(null, canvas));
    return canvas;
  },
});

// MARK: 地图

let root = null;
let map = null;
let lightLayer = null;
let frameLayer = null;
let spotLayer = null;
let frameKey = '';
let frameBounds = null;
let spotsKey = '';
let lightOn = false;
let expanded = false;

function build(slot) {
  root = document.createElement('div');
  root.className = 'spots-map';
  root.innerHTML = `
    <div class="spots-map-bar">
      <button class="bar-button" data-action="spots-map-expand:off">完成</button>
      <span class="spots-map-title"></span>
      <button class="bar-button light-button" data-action="spots-map-light">💡 光污染</button>
    </div>
    <div class="spots-map-frame">
      <div class="spots-map-canvas"></div>
      <div class="spots-map-buttons">
        <button class="map-button" data-action="spots-map-expand:on" aria-label="全屏">⤢</button>
        <button class="map-button light-button" data-action="spots-map-light" aria-label="光污染">💡</button>
      </div>
    </div>
    <p class="spots-map-legend"></p>`;
  // 先放进页面再建地图，Leaflet 要量尺寸
  slot.replaceChildren(root);

  map = L.map(root.querySelector('.spots-map-canvas'), { zoomControl: false, scrollWheelZoom: false, maxZoom: 17 })
    .setView([0, 0], 2);
  addBaseLayers(map);
  lightLayer = new LightLayer({ opacity: 0.75, minZoom: ATLAS_ZOOM, zIndex: 2 });
  frameLayer = L.layerGroup().addTo(map);
  spotLayer = L.layerGroup().addTo(map);
}

/** 页面重画后调用：把地图挪进新的占位块，按当前地点、出行方式和观测点更新 */
export function mountSpotsMap(slot) {
  const center = activePlace();
  if (!slot || !center) return;
  if (!root) build(slot);
  else if (root.parentNode !== slot) slot.replaceChildren(root);
  map.invalidateSize({ pan: false });
  update(center, travelMode());
}

function update(center, mode) {
  const bearing = auroraBearing(center.latitude, center.longitude);
  root.querySelector('.spots-map-title').textContent = `${mode.label}能到的观测点`;
  root.querySelector('.spots-map-legend').textContent =
    `数字对应下面的列表，点开看路程和导航 · 绿色扇形是极光方向 · 虚线圈是${mode.label} ${mode.radiusKm} km`
    + (lightOn ? ' · 暖色是有灯光的地方，越红越亮' : ' · 💡 显示光污染');
  root.querySelectorAll('.light-button').forEach((b) => b.classList.toggle('on', lightOn));

  // 范围圈、极光方向扇形，地点或出行方式变了才重画
  const key = `${center.latitude.toFixed(4)},${center.longitude.toFixed(4)},${mode.id}`;
  if (key !== frameKey) {
    const hasFramed = frameKey !== '';
    frameKey = key;
    frameLayer.clearLayers();
    const origin = [center.latitude, center.longitude];
    const circle = L.circle(origin, {
      radius: mode.radiusKm * 1000, color: '#fff', opacity: 0.45, weight: 1.5, dashArray: '6 5', fill: false, interactive: false,
    }).addTo(frameLayer);
    const length = mode.radiusKm * 1.35;
    const fan = [origin];
    for (let offset = -25; offset <= 25; offset += 5) fan.push(destination(center.latitude, center.longitude, length, bearing + offset));
    const wedge = L.polygon(fan, {
      color: COLORS.aurora, opacity: 0.7, weight: 1, fillColor: COLORS.aurora, fillOpacity: 0.08, interactive: false,
    }).addTo(frameLayer);
    const tip = destination(center.latitude, center.longitude, length * 0.82, bearing);
    L.marker(tip, {
      interactive: false, keyboard: false,
      icon: L.divIcon({ className: 'direction-label', html: `<span>极光方向 · ${preciseDirection(bearing)}</span>`, iconSize: null }),
    }).addTo(frameLayer);
    L.marker(origin, {
      zIndexOffset: 1000, keyboard: false,
      icon: L.divIcon({ className: 'origin-marker', html: '<span>●</span>', iconSize: [26, 26], iconAnchor: [13, 13] }),
    }).addTo(frameLayer).bindPopup('<b>你在这里</b>');
    frameBounds = circle.getBounds().extend(wedge.getBounds());
    map.fitBounds(frameBounds, { padding: [24, 20], animate: hasFramed });
  }

  const signature = JSON.stringify([mode.id, state.viewingSpots.map((s) => [s.id, s.place.name, Math.floor(s.bestScore)])]);
  if (signature !== spotsKey) {
    spotsKey = signature;
    spotLayer.clearLayers();
    state.viewingSpots.forEach((spot, i) => {
      const kind = KINDS[spot.kind];
      const parts = [durationText(mode, spot.distanceKm ?? 0), `今晚最高 ${Math.floor(spot.bestScore)} 分`];
      if (spot.horizon?.seaView) parts.push('朝海');
      L.marker([spot.place.latitude, spot.place.longitude], {
        zIndexOffset: 500 - i,
        icon: L.divIcon({
          className: 'rank-marker',
          html: `<span style="background:${scoreColor(spot.bestScore)}">${i + 1}</span>`,
          iconSize: [28, 28], iconAnchor: [14, 14],
        }),
      }).addTo(spotLayer).bindPopup(`<div class="popup">
        <b>${e(spot.place.name || kind?.label || '观测点')}</b><span>${kind ? `${kind.label} · ` : ''}${e(parts.join(' · '))}</span>
        <button class="button small" data-action="nav-spot:${e(spot.id)}">导航</button></div>`);
    });
  }
}

export function toggleSpotsLight() {
  if (!map) return;
  lightOn = !lightOn;
  if (lightOn) lightLayer.addTo(map); else lightLayer.remove();
  const center = activePlace();
  if (center) update(center, travelMode());
}

/** 全屏：同一个地图放大铺满屏幕，滚轮可以缩放 */
export function expandSpotsMap(on) {
  if (!map || expanded === on) return;
  expanded = on;
  root.classList.toggle('expanded', on);
  document.body.classList.toggle('map-expanded', on);
  if (on) map.scrollWheelZoom.enable(); else map.scrollWheelZoom.disable();
  map.closePopup();
  // 等布局变了再告诉地图新尺寸，重新框住范围圈和扇形
  requestAnimationFrame(() => {
    map.invalidateSize({ pan: false });
    if (frameBounds) map.fitBounds(frameBounds, { padding: on ? [60, 30] : [24, 20], animate: false });
  });
}
