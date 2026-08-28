const CACHE_NAME = 'trading-journal-v5';
const PRECACHE = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png'];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(PRECACHE)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  event.respondWith(caches.match(event.request).then(cached => {
    if (cached) return cached;
    return fetch(event.request).then(r => {
      if (!r || r.status !== 200) return r;
      const clone = r.clone();
      caches.open(CACHE_NAME).then(c => c.put(event.request, clone));
      return r;
    }).catch(() => { if (event.request.mode === 'navigate') return caches.match('./index.html'); });
  }));
});