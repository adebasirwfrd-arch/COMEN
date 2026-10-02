import { handle, json, readJson, HttpError, rpcError } from '../_shared/http.ts';
import { requireUser, serviceClient, userClient } from '../_shared/supabase.ts';

type Action = 'ban' | 'unban' | 'reset_mfa' | 'suspend' | 'reactivate' | 'deactivate' | 'anonymize';
type Body = { action?: Action; user_id?: string; reason?: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BAN = '876000h';                                     // ±100 tahun

Deno.serve(handle(async (req) => {
  await requireUser(req);
  if (req.headers.get('x-comen-act-as')) {
    throw new HttpError(403, '42501', 'act_as_blocked', 'Aksi Admin Console tidak tersedia saat mode Act As. Keluar dari Act As terlebih dahulu.');
  }
  const b = await readJson<Body>(req);
  if (!b.action || !b.user_id || !UUID.test(b.user_id)) throw new HttpError(400, 'invalid_request');
  const asUser = userClient(req);                           // otorisasi SELALU diputuskan DB atas nama pemanggil
  const admin = serviceClient().auth.admin;

  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await asUser.rpc(fn, args);
    if (error) throw rpcError(error);
    return data as Record<string, unknown>;
  };

  // Langkah Auth Admin API; kegagalan dilaporkan (status DB tetap tersimpan → UI menawarkan "Sinkronkan ulang")
  const authSync = async (op: () => Promise<{ error: unknown }>) => {
    try { const { error } = await op(); return error ? { auth_synced: false } : { auth_synced: true }; }
    catch { return { auth_synced: false }; }
  };
  const ban = (on: boolean) => authSync(() => admin.updateUserById(b.user_id!, { ban_duration: on ? BAN : 'none' }));
  const resetMfa = () => authSync(async () => {
    const { data, error } = await admin.mfa.listFactors({ userId: b.user_id! });
    if (error) return { error };
    for (const f of data.factors) {
      const r = await admin.mfa.deleteFactor({ id: f.id, userId: b.user_id! });
      if (r.error) return { error: r.error };
    }
    return { error: null };
  });

  switch (b.action) {
    case 'ban': case 'unban': case 'reset_mfa': {
      const r = await rpc('admin_authorize_action', { p_action: b.action, p_user: b.user_id, p_reason: b.reason ?? null });
      const s = b.action === 'reset_mfa' ? await resetMfa() : await ban(b.action === 'ban');
      return json({ ...r, ...s });
    }
    case 'suspend': case 'reactivate': case 'deactivate': {
      const status = { suspend: 'suspended', reactivate: 'active', deactivate: 'deactivated' }[b.action];
      const r = await rpc('admin_set_user_status', { p_user: b.user_id, p_status: status, p_reason: b.reason ?? null });
      return json({ ...r, ...(await ban(r.ban === true)) });
    }
    case 'anonymize': {
      const r = await rpc('admin_anonymize_user', { p_user: b.user_id, p_reason: b.reason ?? null });
      const email = (r.auth_email as string) ?? `anon-${b.user_id}@anonymized.invalid`;
      const s1 = await authSync(() => admin.updateUserById(b.user_id!, {
        email, email_confirm: true, user_metadata: {}, ban_duration: BAN,
      }));
      const s2 = await resetMfa();
      return json({ ...r, auth_synced: s1.auth_synced && s2.auth_synced });
    }
    default:
      throw new HttpError(400, 'invalid_action');
  }
}, true));
