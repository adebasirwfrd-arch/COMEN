import { handle, json, readJson, requireSecret } from '../_shared/http.ts';
import { serviceClient } from '../_shared/supabase.ts';

type Ev = { event?: string; email?: string; 'message-id'?: string; reason?: string };

Deno.serve(handle(async (req) => {
  requireSecret(req, 'bearer', 'BREVO_WEBHOOK_SECRET');
  const body = await readJson<Ev | Ev[]>(req);
  const db = serviceClient();
  for (const e of [body].flat().slice(0, 500)) {
    if (!e.event || !e['message-id']) continue;
    const { error } = await db.rpc('svc_email_event', {
      p_provider_msg_id: e['message-id'], p_event: e.event, p_email: e.email ?? '', p_reason: e.reason ?? null,
    });
    if (error) throw new Error(`event: ${error.code}`);
  }
  return json({ ok: true });
}));
