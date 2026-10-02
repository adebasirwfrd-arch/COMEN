import { handle, json, readJson, HttpError, rpcError } from '../_shared/http.ts';
import { requireUser, userClient } from '../_shared/supabase.ts';
import { attestation } from '../_shared/crypto.ts';
import { env, isProd } from '../_shared/env.ts';

type Body = { turnstile_token?: string; privacy_accepted?: boolean; website_url2?: string; elapsed_ms?: number };

Deno.serve(handle(async (req) => {
  const user = await requireUser(req);
  const b = await readJson<Body>(req);

  // Lapis 5: honeypot + waktu isi minimum
  if ((b.website_url2 ?? '') !== '' || typeof b.elapsed_ms !== 'number' || b.elapsed_ms < 3000) {
    throw new HttpError(400, 'bot_suspected', 'captcha_required');
  }
  if (!b.turnstile_token || b.turnstile_token.length > 2048) throw new HttpError(400, 'captcha_required', 'captcha_required');

  // Lapis 2: Turnstile siteverify (token sekali pakai, ≤ 300 detik)
  const form = new FormData();
  form.append('secret', env('TURNSTILE_SECRET_KEY'));
  form.append('response', b.turnstile_token);
  const ip = (req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim();
  if (ip) form.append('remoteip', ip);
  form.append('idempotency_key', crypto.randomUUID());
  const tv = await (await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
    method: 'POST', body: form, signal: AbortSignal.timeout(8000),
  })).json() as { success: boolean; action?: string; hostname?: string };
  const hosts = env('TURNSTILE_HOSTNAMES', false).split(',').map((s) => s.trim()).filter(Boolean);
  const strictOk = !isProd() || (tv.action === 'registration' && hosts.includes(tv.hostname ?? ''));
  if (!tv.success || !strictOk) throw new HttpError(400, 'captcha_failed', 'captcha_required');

  // Attestasi HMAC → DB (_assert_attestation): RPC tetap dieksekusi sebagai user (assert, device, rate limit berlaku)
  const db = userClient(req, { 'x-comen-attest': await attestation(user.id, 'registration') });
  const { data, error } = await db.rpc('submit_registration', { p_privacy_accepted: b.privacy_accepted === true });
  if (error) throw rpcError(error);
  return json(data);
}, true));
