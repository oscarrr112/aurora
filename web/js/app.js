// 入口：页面切换、事件、导航面板、自动刷新
import { escapeHTML as e, fmt } from './util.js';
import { state, subscribe, refresh, refreshIfStale, setTab, select, addPlace, removePlace, setTravelMode, activePlace } from './model.js';
import { tonightView, spotsView, windView, settingsView, addPlaceSheet, spotRegistry, windState } from './views.js';
import { initMap, updateMap, legendGradient, closePopup } from './map.js';
import { mountSpotsMap, expandSpotsMap, toggleSpotsLight } from './spotsmap.js';
import { TRAVEL_MODES } from './spots.js';

const view = document.getElementById('view');
const mapScreen = document.getElementById('map-screen');
const title = document.getElementById('title');
const refreshButton = document.getElementById('refresh');
const sheet = document.getElementById('sheet');

const TITLES = { tonight: null, spots: '去哪看', map: '极光概率图', wind: '太阳风', settings: '设置' };
const VIEWS = { tonight: tonightView, spots: spotsView, wind: windView, settings: settingsView };

let mapReady = false;
const openDetails = new Set();

function render() {
  const tab = state.tab;
  title.textContent = TITLES[tab] ?? activePlace()?.name ?? '极光预报';
  refreshButton.classList.toggle('busy', state.loading || state.loadingViewing);
  document.querySelectorAll('.tabbar button').forEach((b) => b.classList.toggle('on', b.dataset.action === `tab:${tab}`));
  document.body.dataset.tab = tab;

  if (tab === 'map') {
    view.hidden = true;
    mapScreen.hidden = false;
    if (!mapReady) {
      initMap(document.getElementById('map'));
      mapReady = true;
    }
    updateMap();
    renderLegend();
    return;
  }
  mapScreen.hidden = true;
  view.hidden = false;
  view.innerHTML = VIEWS[tab]();
  // 重画后保持「逐小时明细」这类折叠块的展开状态
  view.querySelectorAll('details').forEach((d, i) => {
    const key = `${tab}:${i}`;
    d.open = openDetails.has(key);
    d.addEventListener('toggle', () => (d.open ? openDetails.add(key) : openDetails.delete(key)));
  });
  if (tab === 'spots') mountSpotsMap(view.querySelector('.spots-map-slot'));
}

function renderLegend() {
  const grid = state.ovation;
  const max = grid?.maxValue ?? 0;
  document.getElementById('legend').innerHTML = `
    <div class="legend-bar" style="background:${legendGradient}"></div>
    <div class="legend-labels"><span>5%</span><span>头顶出现极光的概率</span><span>80%+</span></div>
    ${grid ? `<div class="legend-max" style="color:${max < 20 ? 'var(--dim)' : 'var(--aurora)'}">${max < 20 ? `现在全球极光偏弱（最高 ${max}%）` : `现在全球最高 ${max}%`}</div>` : ''}
    <div class="legend-note">亮的一侧是白天，暗的一侧才看得到极光。圆点是热门目的地今晚的评分，点开可切换。长按地图可以添加地点。</div>
    ${grid ? `<div class="legend-note dim">NOAA OVATION 模型 · 预测时刻 ${fmt.time(grid.forecastTime)}</div>` : ''}`;
}

// MARK: 底部面板（导航、添加地点）

const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

function openSheet(html) {
  sheet.innerHTML = `<div class="sheet-backdrop" data-action="close-sheet"></div><div class="sheet-panel">${html}</div>`;
  sheet.hidden = false;
  requestAnimationFrame(() => sheet.classList.add('open'));
}

function closeSheet() {
  sheet.classList.remove('open');
  setTimeout(() => { sheet.hidden = true; sheet.innerHTML = ''; }, 200);
}

let pendingSpot = null;

function navigationSheet(spot, mode) {
  pendingSpot = spot;
  const { latitude: lat, longitude: lon, name } = spot.place;
  const n = encodeURIComponent(name || '观测点');
  const google = { walk: 'walking', bike: 'bicycling', car: 'driving' }[mode.id];
  const amapType = { walk: 2, bike: 3, car: 0 }[mode.id];
  const links = [];
  if (isIOS) {
    const apple = mode.id === 'bike'
      ? `https://maps.apple.com/directions?destination=${lat},${lon}&mode=cycling`
      : `https://maps.apple.com/?daddr=${lat},${lon}&dirflg=${mode.id === 'walk' ? 'w' : 'd'}`;
    links.push(['苹果地图', apple]);
  }
  links.push(['谷歌地图', `https://www.google.com/maps/dir/?api=1&destination=${lat},${lon}&travelmode=${google}`]);
  links.push(['高德地图', isIOS
    ? `iosamap://path?sourceApplication=aurora&dlat=${lat}&dlon=${lon}&dname=${n}&dev=1&t=${amapType}`
    : `amapuri://route/plan/?dlat=${lat}&dlon=${lon}&dname=${n}&dev=1&t=${amapType}`]);
  if (!isIOS) links.push(['其他地图 App', `geo:${lat},${lon}?q=${lat},${lon}(${n})`]);

  openSheet(`<div class="sheet-body">
    <h3>${e(name || '观测点')}</h3>
    <p class="caption">${lat.toFixed(5)}, ${lon.toFixed(5)} · ${mode.label}</p>
    ${links.map(([label, url]) => `<a class="sheet-option" href="${e(url)}" target="_blank" rel="noopener">${label}</a>`).join('')}
    <button class="sheet-option" data-action="copy-coords">复制坐标</button>
    <button class="sheet-option" data-action="save-spot">保存为我的地点</button>
    <button class="sheet-option cancel" data-action="close-sheet">取消</button>
  </div>`);
}

// MARK: 事件

document.addEventListener('click', async (event) => {
  const target = event.target.closest('[data-action]');
  if (!target) return;
  const [action, ...rest] = target.dataset.action.split(':');
  const arg = rest.join(':');

  switch (action) {
    case 'tab':
      setTab(arg);
      window.scrollTo(0, 0);
      break;
    case 'refresh':
      refresh();
      break;
    case 'mode':
      setTravelMode(arg);
      break;
    case 'select':
      select(arg);
      break;
    case 'select-go':
      closePopup();
      select(arg);
      setTab('tonight');
      window.scrollTo(0, 0);
      break;
    case 'remove':
      event.stopPropagation();
      if (confirm('删除这个地点？')) removePlace(arg);
      break;
    case 'nav': {
      const entry = spotRegistry.get(arg);
      if (entry) navigationSheet(entry.spot, entry.mode);
      break;
    }
    case 'nav-spot': {
      const spot = state.viewingSpots.find((s) => s.id === arg);
      if (spot) navigationSheet(spot, TRAVEL_MODES[state.travelMode]);
      break;
    }
    case 'copy-coords':
      if (pendingSpot) {
        const text = `${pendingSpot.place.latitude.toFixed(5)}, ${pendingSpot.place.longitude.toFixed(5)}`;
        try {
          await navigator.clipboard.writeText(text);
          target.textContent = '已复制';
        } catch {
          prompt('复制坐标', text);
        }
      }
      break;
    case 'save-spot':
      if (pendingSpot) {
        const name = prompt('名称', pendingSpot.place.name || '我的地点');
        if (name != null) {
          addPlace(name || '我的地点', pendingSpot.place.latitude, pendingSpot.place.longitude);
          closeSheet();
          setTab('tonight');
        }
      }
      break;
    case 'add-place':
      openSheet(addPlaceSheet());
      break;
    case 'add-here': {
      const [lat, lon] = arg.split(',').map(Number);
      const name = prompt('名称', '我的地点');
      if (name != null) {
        closePopup();
        addPlace(name || '我的地点', lat, lon);
        setTab('tonight');
      }
      break;
    }
    case 'close-sheet':
      closeSheet();
      break;
    case 'spots-map-expand':
      expandSpotsMap(arg === 'on');
      break;
    case 'spots-map-light':
      toggleSpotsLight();
      break;
    case 'wind':
      windState.hours = Number(arg);
      render();
      break;
    case 'clear-cache':
      if (confirm('清除本地缓存？保存的地点和设置会保留。')) {
        for (const key of Object.keys(localStorage)) {
          if (key.startsWith('photon:') || key.startsWith('viewing:') || key === 'elevations') localStorage.removeItem(key);
        }
        try { await caches.delete('lightpollution2025'); } catch { /* 不支持就算了 */ }
        location.reload();
      }
      break;
  }
});

document.addEventListener('submit', (event) => {
  const form = event.target.closest('[data-form="add-place"]');
  if (!form) return;
  event.preventDefault();
  const data = new FormData(form);
  const lat = Number(String(data.get('lat')).replace('，', '.').trim());
  const lon = Number(String(data.get('lon')).replace('，', '.').trim());
  if (!Number.isFinite(lat) || lat < -90 || lat > 90 || !Number.isFinite(lon) || lon < -180 || lon > 180 || data.get('lat') === '' || data.get('lon') === '') {
    alert('纬度要在 −90 到 90 之间，经度在 −180 到 180 之间');
    return;
  }
  closeSheet();
  addPlace(String(data.get('name')).trim() || '我的地点', lat, lon);
  setTab('tonight');
});

subscribe(render);

let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(render, 200);
});

// 前台时每 10 分钟自动刷新；切回来时数据超过 5 分钟就刷新
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') refreshIfStale();
});
setInterval(() => {
  if (document.visibilityState === 'visible') refresh();
}, 10 * 60000);

render();
refresh();

if ('serviceWorker' in navigator && location.protocol === 'https:') {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}
