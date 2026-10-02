// _shared/http.ts
import { env } from './env.ts';
import { safeEqual } from './crypto.ts';

const ALLOWED = () => env('APP_ORIGINS').split(',').map((s) => s.trim()).filter(Boolean);

export function corsHeaders(req: Request): Record<string, string> | null {
  const origin = req.headers.get('origin') ?? '';
  if (!ALLOWED().includes(origin)) return null;
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-device-id, x-comen-act-as, x-supabase-api-version, x-region',
    'Access-Control-Max-Age': '600',
    'Vary': 'Origin',
  };
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers },
  });
}

export async function readJson<T>(req: Request, maxBytes = 1_000_000): Promise<T> {
  const len = Number(req.headers.get('content-length') ?? '0');
  if (len > maxBytes) throw new HttpError(413, 'payload_too_large');
  const text = await req.text();
  if (text.length > maxBytes) throw new HttpError(413, 'payload_too_large');
  try { return JSON.parse(text) as T; } catch { throw new HttpError(400, 'invalid_json'); }
}

export class HttpError extends Error {
  constructor(public status: number, public code: string, public hint?: string, public detail?: string) { super(code); }
}

const FRIENDLY: Record<string, string> = {
  bot_suspected: 'Pengiriman terdeteksi otomatis. Isi formulir dengan normal lalu coba lagi.',
  captcha_required: 'Verifikasi manusia (captcha) wajib diselesaikan.',
  captcha_failed: 'Verifikasi captcha gagal atau kedaluwarsa. Ulangi captcha.',
  unauthorized: 'Sesi tidak valid. Silakan masuk ulang.',
  payload_too_large: 'Data terlalu besar.',
  invalid_json: 'Format permintaan tidak valid.',
  origin_not_allowed: 'Asal permintaan tidak diizinkan.',
};

export function bearer(req: Request): string {
  const h = req.headers.get('authorization') ?? '';
  return h.toLowerCase().startsWith('bearer ') ? h.slice(7).trim() : '';
}

export function requireSecret(req: Request, header: 'x-cron-secret' | 'bearer', envKey: string): void {
  const got = header === 'bearer' ? bearer(req) : (req.headers.get(header) ?? '');
  if (!got || !safeEqual(got, env(envKey))) throw new HttpError(401, 'unauthorized');
}

// PostgrestError → HTTP
export function rpcError(e: { code?: string; hint?: string; message?: string }): HttpError {
  const map: Record<string, number> = { '42501': 403, '22023': 400, '23505': 409, 'PT429': 429 };
  const status = map[e.code ?? ''] ?? 500;
  // Pesan RAISE 22023/23505/42501 ditulis untuk pengguna (bahasa Indonesia); 5xx tidak pernah diteruskan.
  return new HttpError(status, e.code ?? 'error', e.hint ?? undefined, status < 500 ? e.message : undefined);
}

export function handle(fn: (req: Request) => Promise<Response>, browser = false) {
  return async (req: Request): Promise<Response> => {
    const cors = browser ? corsHeaders(req) : {};
    if (browser && cors === null) return json({ error: { code: 'origin_not_allowed' } }, 403);
    if (req.method === 'OPTIONS') return browser ? new Response(null, { status: 204, headers: cors! }) : json({}, 405);
    if (req.method !== 'POST') return json({ error: { code: 'method_not_allowed' } }, 405, cors ?? {});
    try {
      const res = await fn(req);
      for (const [k, v] of Object.entries(cors ?? {})) res.headers.set(k, v);
      return res;
    } catch (e) {
      const he = e instanceof HttpError ? e : new HttpError(500, 'internal');
      if (!(e instanceof HttpError)) console.error('[edge]', (e as Error)?.message ?? 'unknown');
      const message = he.status >= 500 ? 'internal' : (he.detail ?? FRIENDLY[he.code] ?? he.code);
      return json({ error: { code: he.code, hint: he.hint ?? null, message } }, he.status, cors ?? {});
    }
  };
}
