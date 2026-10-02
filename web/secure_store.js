(() => {
  'use strict';
  const DB = 'comen-secure', STORE = 'kv', KEY_ID = '__aes_key_v1__', enc = new TextEncoder(), dec = new TextDecoder();
  let dbP = null, keyP = null;

  const openDb = () => dbP ??= new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE);
    r.onsuccess = () => res(r.result);
    r.onerror = () => { dbP = null; rej(r.error); };
  });

  const tx = async (mode, fn) => {
    const db = await openDb();
    return new Promise((res, rej) => {
      const t = db.transaction(STORE, mode), req = fn(t.objectStore(STORE));
      t.oncomplete = () => res(req ? req.result : undefined);
      t.onerror = t.onabort = () => rej(t.error);
    });
  };

  // Satu kunci per origin; promise di-cache (anti race antar-pemanggilan); add() gagal jika tab lain lebih dulu → pakai milik tab lain
  const getKey = () => keyP ??= (async () => {
    const existing = await tx('readonly', (s) => s.get(KEY_ID));
    if (existing) return existing;
    const fresh = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    try { await tx('readwrite', (s) => s.add(fresh, KEY_ID)); return fresh; }
    catch { return await tx('readonly', (s) => s.get(KEY_ID)); }
  })().catch((e) => { keyP = null; throw e; });

  async function put(name, value) {
    const key = await getKey(), iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: enc.encode(name) }, key, enc.encode(value));
    await tx('readwrite', (s) => s.put({ v: 1, iv, ct: new Uint8Array(ct) }, 'k:' + name));
  }

  async function read(name) {
    const rec = await tx('readonly', (s) => s.get('k:' + name));
    if (!rec) return null;
    try {
      const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: rec.iv, additionalData: enc.encode(name) }, await getKey(), rec.ct);
      return dec.decode(pt);
    } catch { await del(name); return null; }          // rusak/dimanipulasi → buang
  }

  const del = (name) => tx('readwrite', (s) => s.delete('k:' + name));

  async function sha256File(file) {
    if (file.size > 512 * 1024 * 1024) throw new Error('file_too_large');
    const digest = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
  }

  // Sinkron sesi antar-tab (refresh token rotation): tab yang menyimpan sesi baru memberi tahu tab lain
  const bc = 'BroadcastChannel' in self ? new BroadcastChannel('comen-session') : null;
  const listeners = [];
  if (bc) bc.onmessage = (e) => { if (e.data === 'session_updated') listeners.forEach((f) => f()); };
  const notifySession = () => bc && bc.postMessage('session_updated');
  const onSession = (f) => { listeners.push(f); };

  async function subscribePush(vapidKeyB64Url) {
    if (!('serviceWorker' in navigator) || !('PushManager' in self)) return null;
    if ((await Notification.requestPermission()) !== 'granted') return null;
    const reg = await navigator.serviceWorker.register('/push_sw.js', { scope: '/push/' });
    const pad = '='.repeat((4 - (vapidKeyB64Url.length % 4)) % 4);
    const raw = Uint8Array.from(atob((vapidKeyB64Url + pad).replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
    const sub = (await reg.pushManager.getSubscription()) ?? await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: raw });
    const j = sub.toJSON();
    return JSON.stringify({ endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth });
  }

  async function unsubscribePush() {
    const reg = await navigator.serviceWorker?.getRegistration('/push/');
    const sub = await reg?.pushManager.getSubscription();
    if (!sub) return null;
    const endpoint = sub.endpoint; await sub.unsubscribe(); return endpoint;
  }

  // Terima navigasi dari push_sw.js (tab tidak dikontrol SW → navigate() tidak bisa)
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('message', (e) => {
      const l = e.data && e.data.type === 'comen_nav' ? e.data.link : null;
      if (typeof l === 'string' && l.startsWith('/') && !l.startsWith('//')) window.location.assign(l);
    });
  }

  Object.defineProperty(window, 'comenSecure', {
    value: Object.freeze({ ready: () => getKey().then(() => true), put, read, del, sha256File, notifySession, onSession, subscribePush, unsubscribePush }),
    writable: false, configurable: false,
  });
})();
