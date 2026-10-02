import { bearer, handle, json, readJson, HttpError, rpcError } from '../_shared/http.ts';
import { requireUser, serviceClient, userClient } from '../_shared/supabase.ts';
import { attestation } from '../_shared/crypto.ts';
import { brevoSend } from '../_shared/brevo.ts';
import { env } from '../_shared/env.ts';

type Body = { action?: 'send' | 'verify'; code?: string };
type Row = Record<string, unknown>;

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const maskEmail = (e: string) => {
  const [u, d] = e.split('@');
  return `${u.slice(0, Math.min(2, u.length))}${'•'.repeat(Math.max(3, u.length - 2))}@${d}`;
};
const wib = () => new Date().toLocaleString('id-ID', { timeZone: 'Asia/Jakarta', dateStyle: 'medium', timeStyle: 'short' }) + ' WIB';

const shell = (title: string, body: string) => `<!doctype html><html><body style="margin:0;background:#f2f4f7;font-family:Segoe UI,Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:32px 12px">
<table role="presentation" width="100%" style="max-width:520px;background:#fff;border-radius:16px;padding:32px" cellpadding="0" cellspacing="0">
<tr><td style="font-size:20px;font-weight:800;color:#0b1f4d;padding-bottom:4px">COMEN</td></tr>
<tr><td style="font-size:12px;color:#667085;padding-bottom:24px">Contractor Management · WFRD</td></tr>
<tr><td style="font-size:18px;font-weight:700;color:#101828;padding-bottom:12px">${title}</td></tr>
<tr><td style="font-size:14px;line-height:1.6;color:#344054">${body}</td></tr>
</table></td></tr></table></body></html>`;

Deno.serve(handle(async (req) => {
  const user = await requireUser(req);
  if (req.headers.get('x-comen-act-as')) {
    throw new HttpError(403, '42501', 'act_as_blocked', 'Tidak tersedia saat mode Act As.');
  }
  const b = await readJson<Body>(req, 4096);
  const sender = { email: env('BREVO_SENDER_EMAIL'), name: 'COMEN WFRD' };

  // RPC dieksekusi sebagai user (device, aal, rate limit berlaku) + attestasi: hanya Edge yang bisa memanggilnya
  const call = async (fn: string, args: Row = {}) => {
    const db = userClient(req, { 'x-comen-attest': await attestation(user.id, fn) });
    const { data, error } = await db.rpc(fn, args);
    if (error) throw rpcError(error);
    return data as Row;
  };

  switch (b.action) {
    case 'send': {
      const r = await call('mfa_recovery_request');
      const email = String(r.email), code = String(r.code), mins = Number(r.expires_minutes);
      const name = r.full_name ? `Halo ${esc(r.full_name)},` : 'Halo,';
      const device = r.device_label ? ` dari <b>${esc(r.device_label)}</b>` : '';
      const sent = await brevoSend({
        sender,
        to: [{ email }],
        subject: 'Kode pemulihan authenticator COMEN',
        htmlContent: shell('Kode pemulihan authenticator', `${name}<br><br>
Seseorang${device} meminta reset authenticator (MFA) akun COMEN Anda pada ${esc(wib())}. Masukkan kode berikut di halaman verifikasi:
<div style="margin:20px 0;padding:16px;background:#f2f4f7;border-radius:12px;text-align:center;font-size:32px;font-weight:800;letter-spacing:10px;color:#0b1f4d">${esc(code)}</div>
Kode berlaku <b>${mins} menit</b> dan hanya bisa dipakai sekali. Setelah kode benar, authenticator lama dihapus dan Anda wajib memindai QR baru.<br><br>
<b>Bukan Anda?</b> Abaikan email ini, jangan bagikan kodenya kepada siapa pun, dan segera hubungi Admin COMEN.`),
        textContent: `Kode pemulihan authenticator COMEN: ${code}\nBerlaku ${mins} menit, sekali pakai. Bukan Anda? Abaikan email ini dan hubungi Admin COMEN.`,
        tags: ['comen-mfa-recovery'],
      });
      if (!sent.ok) throw new HttpError(424, 'email_failed', undefined, 'Email kode gagal dikirim. Coba lagi beberapa saat lagi.');
      return json({ sent: true, email: maskEmail(email), expires_minutes: mins });
    }
    case 'verify': {
      if (!/^\d{6}$/.test(b.code ?? '')) throw new HttpError(400, '22023', undefined, 'Kode harus 6 digit.');
      const r = await call('mfa_recovery_verify', { p_code: b.code });
      if (r.ok !== true) {
        const msg = {
          expired: 'Kode sudah kedaluwarsa atau tidak berlaku. Minta kode baru.',
          locked: 'Terlalu banyak kode salah. Minta kode baru.',
        }[String(r.reason)] ?? `Kode salah. Sisa percobaan: ${r.remaining}.`;
        throw new HttpError(400, 'invalid_code', undefined, msg);
      }

      const admin = serviceClient().auth.admin;
      const { data, error } = await admin.mfa.listFactors({ userId: user.id });
      if (error) throw new Error('mfa_list_failed');
      for (const f of data.factors) {
        const d = await admin.mfa.deleteFactor({ id: f.id, userId: user.id });
        if (d.error) throw new Error('mfa_delete_failed');
      }
      // Sesi lain (refresh token) dicabut; sesi saat ini tetap untuk mendaftarkan authenticator baru
      const so = await admin.signOut(bearer(req), 'others').catch(() => ({ error: true }));

      await brevoSend({
        sender,
        to: [{ email: String(r.email) }],
        subject: 'Authenticator COMEN Anda telah direset',
        htmlContent: shell('Authenticator direset', `${r.full_name ? `Halo ${esc(r.full_name)},` : 'Halo,'}<br><br>
Authenticator (MFA) akun COMEN Anda direset lewat kode email pada ${esc(wib())}. Semua sesi di perangkat lain telah diakhiri, dan authenticator baru wajib didaftarkan sebelum aplikasi bisa dipakai.<br><br>
<b>Bukan Anda?</b> Segera hubungi Admin COMEN agar akun diamankan.`),
        textContent: 'Authenticator COMEN Anda telah direset lewat kode email. Bukan Anda? Segera hubungi Admin COMEN.',
        tags: ['comen-mfa-recovery'],
      }).catch(() => null);

      return json({ reset: true, others_signed_out: !so.error });
    }
    default:
      throw new HttpError(400, 'invalid_action');
  }
}, true));
