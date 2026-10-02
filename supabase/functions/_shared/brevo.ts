// _shared/brevo.ts
import { env } from './env.ts';

export async function brevoSend(body: Record<string, unknown>): Promise<{ ok: boolean; status: number; messageId?: string; error?: string }> {
  const res = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: { 'api-key': env('BREVO_API_KEY'), 'content-type': 'application/json', accept: 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  if (res.ok) return { ok: true, status: res.status, messageId: (await res.json()).messageId };
  return { ok: false, status: res.status, error: (await res.text()).slice(0, 300) };
}
