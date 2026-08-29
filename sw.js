const CACHE_NAME='trading-journal-v6';
const PRE=['./','/index.html','/manifest.json','/icon-192.png','/icon-512.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE_NAME).then(c=>c.addAll(PRE)).then(()=>self.skipWaiting()));});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==CACHE_NAME).map(x=>caches.delete(x)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{if(e.request.method!=='GET')return;e.respondWith(caches.match(e.request).then(c=>{if(c)return c;return fetch(e.request).then(r=>{if(!r||r.status!==200)return r;const cl=r.clone();caches.open(CACHE_NAME).then(c2=>c2.put(e.request,cl));return r;}).catch(()=>{if(e.request.mode==='navigate')return caches.match('./index.html');});}));});