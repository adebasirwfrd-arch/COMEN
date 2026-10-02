import { handle, json, requireSecret } from '../_shared/http.ts';
import { serviceClient } from '../_shared/supabase.ts';
import { brevoSend } from '../_shared/brevo.ts';
import { env } from '../_shared/env.ts';

Deno.serve(handle(async (req) => {
  requireSecret(req, 'x-cron-secret', 'CRON_SECRET');
  const { data, error } = await serviceClient().rpc('svc_audit_anchor');
  if (error) throw new Error(`anchor: ${error.code}`);
  const a = data as { last_id: number; last_hash: string; anchored_at: string; rows_24h: number };
  const line = `COMEN audit anchor ${a.anchored_at} last_id=${a.last_id} sha256=${a.last_hash} rows_24h=${a.rows_24h}`;

  // Out-of-band 1: email ke kotak surat di luar sistem (bukan akun COMEN)
  const mail = await brevoSend({
    sender: { email: env('BREVO_SENDER_EMAIL'), name: 'COMEN Audit' },
    to: [{ email: env('AUDIT_ANCHOR_EMAIL') }],
    subject: `[COMEN] Audit anchor ${a.anchored_at.slice(0, 10)}`,
    textContent: line,
  });

  // Out-of-band 2 (opsional): commit ke repo GitHub privat
  let git = 'skipped';
  const repo = env('GITHUB_ANCHOR_REPO', false), token = env('GITHUB_ANCHOR_TOKEN', false);
  if (repo && token) {
    const path = `anchors/${a.anchored_at.slice(0, 10)}.txt`;
    const res = await fetch(`https://api.github.com/repos/${repo}/contents/${path}`, {
      method: 'PUT',
      headers: { authorization: `Bearer ${token}`, accept: 'application/vnd.github+json', 'user-agent': 'comen-anchor' },
      body: JSON.stringify({ message: `anchor ${a.anchored_at}`, content: btoa(line + '\n') }),
      signal: AbortSignal.timeout(10_000),
    });
    git = res.ok ? 'ok' : `failed_${res.status}`;
  }
  return json({ email: mail.ok ? 'ok' : `failed_${mail.status}`, git });
}));
