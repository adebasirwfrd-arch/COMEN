import { handle, json, readJson, requireSecret } from '../_shared/http.ts';
import { serviceClient } from '../_shared/supabase.ts';

type Inbound = {
  MessageId?: string; Subject?: string; From?: { Address?: string }; RawTextBody?: string; ExtractedMarkdownMessage?: string;
  Attachments?: unknown[]; Headers?: Record<string, string | string[]>;
};
const TASK_RE = /\bCMN-(?:V\d{5}|\d{5}(?:S\d{2})?)-[A-Z0-9]{6}-\d{3}(?:-R\d{1,2})?\b/i;
const CODE_RE = /\bKODE[\s:·#-]*([0-9A-F]{4}-[0-9A-F]{4})\b/i;

function senderAuthenticated(h: Record<string, string | string[]> = {}): boolean {
  const key = Object.keys(h).find((k) => k.toLowerCase() === 'authentication-results');
  const v = key ? [h[key]].flat().join(' ') : '';
  return /\bdmarc=pass\b/i.test(v) || (/\bspf=pass\b/i.test(v) && /\bdkim=pass\b/i.test(v));
}

Deno.serve(handle(async (req) => {
  requireSecret(req, 'bearer', 'BREVO_INBOUND_SECRET');
  const body = await readJson<{ items?: Inbound[] }>(req, 5_000_000);
  const db = serviceClient();
  const results: unknown[] = [];
  for (const m of (body.items ?? []).slice(0, 50)) {
    const subject = (m.Subject ?? '').slice(0, 500);
    const text = (m.RawTextBody ?? m.ExtractedMarkdownMessage ?? '').slice(0, 20_000);
    const taskId = subject.match(TASK_RE)?.[0] ?? text.match(TASK_RE)?.[0];
    const code = subject.match(CODE_RE)?.[1] ?? text.match(CODE_RE)?.[1];
    if (!taskId || !code || !m.MessageId) { results.push({ ok: false, reason: 'unparsed' }); continue; }
    const { data, error } = await db.rpc('verify_confirmation_email_inbound', {
      p_task_id: taskId.toUpperCase(), p_from: m.From?.Address ?? '', p_code: code.toUpperCase(), p_subject: subject,
      p_attachments: (m.Attachments ?? []).length, p_provider_msg_id: m.MessageId, p_sender_auth: senderAuthenticated(m.Headers),
    });
    if (error) throw new Error(`verify: ${error.code}`);     // 500 → Brevo retry; idempotent via provider_msg_id
    results.push(data);
  }
  return json({ results });
}));
