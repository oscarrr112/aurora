// 离线缓存：页面文件先走网络（保证拿到新版本），断网时用缓存；数据接口不经过这里缓存
const VERSION = 'aurora-v2';
const SHELL = [
  './', 'index.html', 'css/app.css', 'manifest.webmanifest',
  'js/app.js', 'js/model.js', 'js/views.js', 'js/map.js', 'js/spotsmap.js', 'js/charts.js', 'js/spots.js', 'js/viewing.js',
  'js/forecaster.js', 'js/lightpollution.js', 'js/data.js', 'js/astro.js', 'js/geomag.js', 'js/util.js',
  'vendor/leaflet/leaflet.js', 'vendor/leaflet/leaflet.css', 'icons/icon-192.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(VERSION).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k.startsWith('aurora-') && k !== VERSION).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin) return;
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(VERSION).then((cache) => cache.put(event.request, copy));
        }
        return response;
      })
      .catch(() => caches.match(event.request).then((hit) => hit ?? caches.match('index.html'))),
  );
});
