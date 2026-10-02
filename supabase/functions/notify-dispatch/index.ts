import webpush from 'web-push';
import { handle, json, requireSecret } from '../_shared/http.ts';
import { serviceClient } from '../_shared/supabase.ts';
import { brevoSend } from '../_shared/brevo.ts';
import { env } from '../_shared/env.ts';

type Item = {
  id: number; channel: 'email' | 'push'; template_id: number; brevo_template_id: string | null;
  to_email: string | null; to_name: string | null; locale: string; params: Record<string, unknown>;
  push: { endpoint: string; p256dh: string; auth: string }[] | null;
};

webpush.setVapidDetails(env('VAPID_SUBJECT'), env('VAPID_PUBLIC_KEY'), env('VAPID_PRIVATE_KEY'));
const BUDGET_MS = 12_000;                      // < timeout pg_net 15 s
const CONCURRENCY = 8;

Deno.serve(handle(async (req) => {
  requireSecret(req, 'x-cron-secret', 'CRON_SECRET');
  const db = serviceClient();
  const started = Date.now();
  let processed = 0;

  const mark = (id: number, ok: boolean, msgId: string | null, err: string | null, permanent = false) =>
    db.rpc('svc_mark_outbox', { p_id: id, p_ok: ok, p_provider_msg_id: msgId, p_error: err, p_permanent: permanent });

  async function sendEmail(it: Item) {
    if (!it.to_email) return mark(it.id, false, null, 'no_recipient', true);
    const tpl = Number(it.brevo_template_id);
    if (!it.brevo_template_id || !Number.isInteger(tpl) || tpl <= 0) return mark(it.id, false, null, 'template_unmapped', true);
    const r = await brevoSend({
      templateId: tpl,
      to: [{ email: it.to_email, ...(it.to_name ? { name: it.to_name } : {}) }],
      params: { ...it.params, locale: it.locale },
      tags: [`comen-${it.template_id}`],
      headers: { 'X-COMEN-Outbox': String(it.id) },
    });
    if (r.ok) return mark(it.id, true, r.messageId ?? null, null);
    const permanent = r.status >= 400 && r.status < 500 && r.status !== 429;
    return mark(it.id, false, null, `brevo_${r.status}`, permanent);
  }

  async function sendPush(it: Item) {
    const subs = it.push ?? [];
    if (subs.length === 0) return mark(it.id, true, 'no_subscription', null);
    // Tanpa isi pesan (privasi): service worker menampilkan teks generik + membuka link
    const payload = JSON.stringify({ kind: it.template_id === 6002 ? 'urgent' : 'message', link: `/chat/${it.params.channel ?? ''}` });
    let delivered = 0, transient = 0;
    for (const s of subs) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload,
                                       { TTL: it.template_id === 6002 ? 600 : 3600, urgency: it.template_id === 6002 ? 'high' : 'normal' });
        delivered++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode ?? 0;
        if (code === 404 || code === 410) await db.rpc('svc_delete_push_subscription', { p_endpoint: s.endpoint });
        else transient++;
      }
    }
    if (delivered > 0 || transient === 0) return mark(it.id, true, `push:${delivered}/${subs.length}`, null);
    return mark(it.id, false, null, 'push_transient');
  }

  while (Date.now() - started < BUDGET_MS) {
    const { data, error } = await db.rpc('svc_claim_outbox', { p_limit: 50 });
    if (error) throw new Error(`claim: ${error.code}`);
    const items = (data ?? []) as Item[];
    if (items.length === 0) break;
    for (let i = 0; i < items.length; i += CONCURRENCY) {
      await Promise.allSettled(items.slice(i, i + CONCURRENCY).map((it) => it.channel === 'push' ? sendPush(it) : sendEmail(it)));
    }
    processed += items.length;
    if (items.length < 50) break;
  }
  return json({ processed });
}));
