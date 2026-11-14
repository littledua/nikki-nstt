/* Service worker chỉ để nhận thông báo đẩy (góp ý mới) cho admin. Không lưu bộ nhớ đệm trang. */
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener('push', function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (er) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Nikki Diary', {
    body: d.body || '', icon: 'img/icon-192.png', badge: 'img/icon-192.png', tag: d.tag || 'nikki', data: { url: d.url || './#admin' }
  }));
});
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || './#admin', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (ws) {
    for (var i = 0; i < ws.length; i++) if (ws[i].url.indexOf(self.registration.scope) === 0 && 'focus' in ws[i]) { ws[i].navigate(url); return ws[i].focus(); }
    return self.clients.openWindow(url);
  }));
});
