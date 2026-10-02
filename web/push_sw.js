// web/push_sw.js — scope /push/, hanya untuk Web Push (tanpa cache, tanpa fetch handler)
self.addEventListener('push', (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (_) {}
  const urgent = d.kind === 'urgent';
  const link = typeof d.link === 'string' && d.link.startsWith('/') && !d.link.startsWith('//') ? d.link : '/chat';
  event.waitUntil(self.registration.showNotification(urgent ? 'Pesan URGENT di COMEN' : 'Pesan baru di COMEN', {
    body: 'Buka COMEN untuk membaca.',                  // tanpa isi pesan (privasi)
    tag: urgent ? 'comen-urgent' : 'comen-message',
    renotify: urgent, requireInteraction: urgent,
    icon: '/icons/Icon-192.png', data: { link },
  }));
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = new URL(event.notification.data?.link ?? '/chat', self.location.origin).href;
  event.waitUntil((async () => {
    const all = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    const tab = all.find((c) => new URL(c.url).origin === self.location.origin);
    if (!tab) return clients.openWindow(url);
    await tab.focus();
    tab.postMessage({ type: 'comen_nav', link: new URL(url).pathname });   // tab tidak dikontrol SW → navigate() tidak bisa
  })());
});
