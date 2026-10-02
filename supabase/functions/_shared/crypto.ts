// _shared/crypto.ts
const enc = new TextEncoder();

export function safeEqual(a: string, b: string): boolean {
  const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(msg)));
  return [...sig].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Format = _assert_attestation (14.9): "<unix_ts 10 digit>.<hex HMAC(uid|purpose|ts)>"
export async function attestation(uid: string, purpose: string): Promise<string> {
  const ts = Math.floor(Date.now() / 1000);
  return `${ts}.${await hmacHex(Deno.env.get('EDGE_ATTEST_SECRET')!, `${uid}|${purpose}|${ts}`)}`;
}
