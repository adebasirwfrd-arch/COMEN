-- Migration 20260103000005: pemulihan MFA lewat kode email (R48) — fixture mandiri
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(29);

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'edge_attest_secret') THEN
    PERFORM vault.create_secret('t20-attest-secret', 'edge_attest_secret');
  END IF;
END $$;

INSERT INTO admin_allowlist (email, note) VALUES ('admin@t20.test', 't20 root');
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) VALUES
  ('20000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'lost@t20.test', NOW(), '{}', '{}', NOW(), NOW()),
  ('20000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'nofactor@t20.test', NOW(), '{}', '{}', NOW(), NOW()),
  ('20000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin@t20.test', NOW(), '{}', '{}', NOW(), NOW());
UPDATE profiles SET status = 'active', full_name = 'User T20'
WHERE id IN ('20000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000003');
UPDATE profiles SET is_root_admin = TRUE WHERE id = '20000000-0000-4000-8000-000000000003';
SELECT _grant_role_internal('20000000-0000-4000-8000-000000000003', (SELECT id FROM roles WHERE key = 'super_admin'), 'global', NULL, NULL, 't20', NULL);
INSERT INTO auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at) VALUES
  ('20000000-0000-4000-8000-0000000000f1', '20000000-0000-4000-8000-000000000001', 'Authenticator', 'totp', 'verified', NOW(), NOW());
INSERT INTO trusted_devices (user_id, device_hash, label) VALUES
  ('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'Chrome · macOS'),
  ('20000000-0000-4000-8000-000000000002', repeat('e', 64), NULL);

-- Sesi user + header attestasi Edge (ts digeser agar tiap panggilan punya tanda tangan unik — NOW() konstan dalam transaksi)
CREATE FUNCTION pg_temp.t20_as(p_uid UUID, p_dev TEXT, p_purpose TEXT, p_shift INT, p_aal TEXT DEFAULT 'aal1') RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE v_ts BIGINT := extract(epoch FROM now())::BIGINT - p_shift; v_hdr JSONB := jsonb_build_object('x-device-id', p_dev);
BEGIN
  IF p_purpose IS NOT NULL THEN
    v_hdr := v_hdr || jsonb_build_object('x-comen-attest', v_ts || '.' ||
      encode(hmac(p_uid::TEXT || '|' || p_purpose || '|' || v_ts, _secret('edge_attest_secret'), 'sha256'), 'hex'));
  END IF;
  PERFORM set_config('request.headers', v_hdr::TEXT, TRUE);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal,
    'amr', json_build_array(json_build_object('method', 'oauth', 'timestamp', extract(epoch FROM now())::INT)))::TEXT, TRUE);
END $$;
CREATE TEMP TABLE t20 (k TEXT PRIMARY KEY, v JSONB);

-- ── Privilege ──
SELECT ok(has_function_privilege('authenticated', 'public.mfa_recovery_request()', 'EXECUTE'), 'mfa_recovery_request executable oleh authenticated (dipanggil Edge atas nama user)');
SELECT ok(NOT has_function_privilege('anon', 'public.mfa_recovery_request()', 'EXECUTE'), 'mfa_recovery_request tidak executable oleh anon');
SELECT ok(NOT has_function_privilege('authenticated', 'public._mfa_recovery_hash(uuid,text)', 'EXECUTE'), '_mfa_recovery_hash tertutup');
SELECT ok(NOT has_table_privilege('authenticated', 'public.mfa_recovery_codes', 'SELECT'), 'tabel kode tidak bisa dibaca client');
SELECT is(setting('mfa_email_recovery_enabled'), 'true'::jsonb, 'pemulihan email aktif secara default');

-- ── Tanpa attestasi: kode tidak pernah bisa diambil langsung dari browser ──
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), NULL, 0);
SELECT throws_ok($$SELECT mfa_recovery_request()$$, '42501', 'Verifikasi manusia diperlukan', 'tanpa attestasi Edge ditolak');
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_verify', 1);
SELECT throws_ok($$SELECT mfa_recovery_request()$$, '42501', 'Verifikasi tidak valid', 'attestasi untuk tujuan lain ditolak');

-- ── Request ──
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_request', 2);
INSERT INTO t20 SELECT 'r1', mfa_recovery_request();
SELECT ok((SELECT v ->> 'code' FROM t20 WHERE k = 'r1') ~ '^\d{6}$', 'kode 6 digit dikembalikan ke Edge');
SELECT is((SELECT v ->> 'email' FROM t20 WHERE k = 'r1'), 'lost@t20.test', 'email tujuan = email auth akun');
SELECT is((SELECT v ->> 'device_label' FROM t20 WHERE k = 'r1'), 'Chrome · macOS', 'label perangkat peminta ikut untuk isi email');
SELECT is((SELECT count(*)::INT FROM mfa_recovery_codes WHERE user_id = '20000000-0000-4000-8000-000000000001' AND used_at IS NULL AND revoked_at IS NULL), 1, 'satu kode aktif tersimpan (hash)');
SELECT ok(NOT EXISTS (SELECT 1 FROM mfa_recovery_codes WHERE code_hash = (SELECT v ->> 'code' FROM t20 WHERE k = 'r1')), 'kode polos tidak disimpan');
SELECT ok(EXISTS (SELECT 1 FROM security_events WHERE user_id = '20000000-0000-4000-8000-000000000001' AND event = 'mfa_recovery_requested'), 'security event permintaan tercatat');

SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_request', 3);
SELECT throws_like($$SELECT mfa_recovery_request()$$, 'Kode baru saja dikirim%', 'jeda 60 detik antar permintaan');

-- ── Verify: salah → hitung percobaan (ter-commit, bukan RAISE) ──
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_verify', 4);
SELECT is(mfa_recovery_verify(CASE WHEN (SELECT v ->> 'code' FROM t20 WHERE k = 'r1') = '000000' THEN '111111' ELSE '000000' END),
          '{"ok": false, "reason": "invalid", "remaining": 4}'::jsonb, 'kode salah → sisa percobaan 4');
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_verify', 5);
SELECT throws_ok($$SELECT mfa_recovery_verify('12ab')$$, '22023', 'Kode harus 6 digit', 'format kode divalidasi');

-- ── Verify: benar → kode habis, event critical, notifikasi user & admin keamanan ──
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_verify', 6);
SELECT is((mfa_recovery_verify((SELECT v ->> 'code' FROM t20 WHERE k = 'r1')) ->> 'ok')::BOOLEAN, TRUE, 'kode benar diterima');
SELECT ok((SELECT used_at IS NOT NULL FROM mfa_recovery_codes WHERE user_id = '20000000-0000-4000-8000-000000000001' ORDER BY created_at DESC LIMIT 1), 'kode ditandai terpakai');
SELECT ok(EXISTS (SELECT 1 FROM security_events WHERE user_id = '20000000-0000-4000-8000-000000000001' AND event = 'mfa_recovery_reset' AND severity = 'critical'), 'event reset bertingkat critical');
SELECT ok(EXISTS (SELECT 1 FROM notifications WHERE user_id = '20000000-0000-4000-8000-000000000001' AND kind = 'security_mfa_reset'), 'user mendapat notifikasi reset');
SELECT ok(EXISTS (SELECT 1 FROM notifications WHERE user_id = '20000000-0000-4000-8000-000000000003' AND kind = 'security_mfa_reset'), 'pemegang admin.security.manage mendapat notifikasi');
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_verify', 7);
SELECT is(mfa_recovery_verify((SELECT v ->> 'code' FROM t20 WHERE k = 'r1')) ->> 'reason', 'expired', 'kode tidak bisa dipakai dua kali');

-- ── Kunci setelah 5 kode salah ──
UPDATE mfa_recovery_codes SET created_at = NOW() - INTERVAL '2 minutes' WHERE user_id = '20000000-0000-4000-8000-000000000001';
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_request', 8);
INSERT INTO t20 SELECT 'r2', mfa_recovery_request();
UPDATE mfa_recovery_codes SET attempts = 4 WHERE user_id = '20000000-0000-4000-8000-000000000001' AND used_at IS NULL AND revoked_at IS NULL;
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_verify', 9);
SELECT is(mfa_recovery_verify(CASE WHEN (SELECT v ->> 'code' FROM t20 WHERE k = 'r2') = '000000' THEN '111111' ELSE '000000' END) ->> 'reason',
          'locked', 'percobaan ke-5 salah → kode dikunci');
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_verify', 10);
SELECT is(mfa_recovery_verify((SELECT v ->> 'code' FROM t20 WHERE k = 'r2')) ->> 'reason', 'expired', 'kode benar pun ditolak setelah terkunci');

-- ── Kedaluwarsa ──
UPDATE mfa_recovery_codes SET created_at = NOW() - INTERVAL '2 minutes' WHERE user_id = '20000000-0000-4000-8000-000000000001';
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_request', 11);
INSERT INTO t20 SELECT 'r3', mfa_recovery_request();
UPDATE mfa_recovery_codes SET expires_at = NOW() - INTERVAL '1 second' WHERE user_id = '20000000-0000-4000-8000-000000000001' AND used_at IS NULL AND revoked_at IS NULL;
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_verify', 12);
SELECT is(mfa_recovery_verify((SELECT v ->> 'code' FROM t20 WHERE k = 'r3')) ->> 'reason', 'expired', 'kode lewat 10 menit ditolak');

-- ── Syarat subjek ──
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_request', 13, 'aal2');
SELECT throws_like($$SELECT mfa_recovery_request()$$, 'Sesi Anda sudah terverifikasi MFA%', 'sesi aal2 tidak perlu pemulihan');
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000002', repeat('e', 64), 'mfa_recovery_request', 14);
SELECT throws_like($$SELECT mfa_recovery_request()$$, 'Tidak ada authenticator terdaftar%', 'tanpa faktor terverifikasi → langsung enroll, bukan pemulihan');
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('f', 64), 'mfa_recovery_request', 15);
SELECT throws_ok($$SELECT mfa_recovery_request()$$, '42501', 'Perangkat atau sesi tidak valid', 'perangkat tidak terdaftar ditolak');
UPDATE app_settings SET value = 'false' WHERE key = 'mfa_email_recovery_enabled';
SELECT pg_temp.t20_as('20000000-0000-4000-8000-000000000001', repeat('d', 64), 'mfa_recovery_request', 16);
SELECT throws_like($$SELECT mfa_recovery_request()$$, 'Pemulihan lewat email dinonaktifkan Admin%', 'setting nonaktif → hubungi Admin');

SELECT * FROM finish();
ROLLBACK;
