-- Migration 20260103000001/2 (v3.4): Act As Mode (R37–R45). Fixture mandiri.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(64);

CREATE TEMP TABLE t17_tok (k TEXT PRIMARY KEY, v TEXT);
CREATE FUNCTION pg_temp.tok(p_k TEXT) RETURNS TEXT LANGUAGE sql AS $$ SELECT v FROM t17_tok WHERE k = p_k $$;
CREATE FUNCTION pg_temp.t17_as(p_uid UUID, p_dev TEXT, p_tok TEXT DEFAULT NULL, p_aal TEXT DEFAULT 'aal2',
                               p_sid TEXT DEFAULT '17000000-0000-4000-8000-00000000005e') RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers', (jsonb_build_object('x-device-id', p_dev)
    || CASE WHEN p_tok IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('x-comen-act-as', p_tok) END)::TEXT, TRUE);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal, 'session_id', p_sid,
    'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch FROM now())::INT)))::TEXT, TRUE);
  PERFORM set_config('comen.act_as_cache', '', TRUE);
END $$;

-- 01 root · 02 PO · 03 HSE admin · 04 reviewer · 10 PIC · 11 employee · 12 pending
INSERT INTO admin_allowlist (email, note) VALUES ('u01@t17.test', 't17 root');
INSERT INTO contractors (id, legal_name, registration_no, tax_id, country, address, primary_contact_name, primary_contact_email,
                         hse_manager_name, hse_manager_email, status, submitted_at)
VALUES ('17000000-0000-4000-8000-0000000000c1', 'PT T17', 'NIB-T17', 'T17-TAX', 'ID', 'Jl. T17', 'Rep', 'rep@t17.test',
        'HSE', 'hse@t17.test', 'asl_approved', NOW());
INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('17000000-0000-4000-8000-0000000000' || n)::UUID, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'u' || n || '@t17.test', '{}', '{}', NOW(), NOW()
FROM unnest(ARRAY['01','02','03','04','10','11','12']) n;
UPDATE profiles SET status = 'active', is_root_admin = TRUE WHERE id = '17000000-0000-4000-8000-000000000001';
UPDATE profiles SET status = 'active' WHERE id IN ('17000000-0000-4000-8000-000000000002', '17000000-0000-4000-8000-000000000003',
                                                    '17000000-0000-4000-8000-000000000004');
UPDATE profiles SET status = 'active', contractor_id = '17000000-0000-4000-8000-0000000000c1', full_name = 'Budi PIC'
WHERE id IN ('17000000-0000-4000-8000-000000000010', '17000000-0000-4000-8000-000000000011');
UPDATE profiles SET contractor_id = '17000000-0000-4000-8000-0000000000c1' WHERE id = '17000000-0000-4000-8000-000000000012';
SELECT _grant_role_internal('17000000-0000-4000-8000-000000000001', (SELECT id FROM roles WHERE key = 'super_admin'), 'global', NULL, NULL, 't17', NULL);
SELECT _grant_role_internal('17000000-0000-4000-8000-000000000002', (SELECT id FROM roles WHERE key = 'process_owner'), 'global', NULL, NULL, 't17', NULL);
SELECT _grant_role_internal('17000000-0000-4000-8000-000000000003', (SELECT id FROM roles WHERE key = 'hse_admin'), 'global', NULL, NULL, 't17', NULL);
SELECT _grant_role_internal('17000000-0000-4000-8000-000000000004', (SELECT id FROM roles WHERE key = 'hse_reviewer'), 'global', NULL, NULL, 't17', NULL);
SELECT _grant_role_internal(u::UUID, (SELECT id FROM roles WHERE key = 'contractor_rep'), 'global', NULL, NULL, 't17', NULL)
FROM unnest(ARRAY['17000000-0000-4000-8000-000000000010', '17000000-0000-4000-8000-000000000011']) u;
SELECT _upsert_contractor_level('17000000-0000-4000-8000-000000000010', '17000000-0000-4000-8000-0000000000c1', 'pic', NULL);
INSERT INTO trusted_devices (user_id, device_hash) VALUES
  ('17000000-0000-4000-8000-000000000001', repeat('1', 64)), ('17000000-0000-4000-8000-000000000002', repeat('2', 64)),
  ('17000000-0000-4000-8000-000000000010', repeat('a', 64));
INSERT INTO contracts (id, contractor_id, title, geozone, risk_class, start_date, end_date, target_mob_date, process_owner_id,
                       hse_reviewer_id, review_mailbox, contract_mode, status)
VALUES ('17000000-0000-4000-8000-0000000000f1', '17000000-0000-4000-8000-0000000000c1', 'T17 Kontrak', 'APAC', 'low', CURRENT_DATE,
        CURRENT_DATE + 365, CURRENT_DATE + 20, '17000000-0000-4000-8000-000000000002', '17000000-0000-4000-8000-000000000004',
        'rev@t17.test', 'mode_1', 'active');
SELECT _notify('17000000-0000-4000-8000-000000000010', 'test', 'Untuk PIC', NULL, '/x');
CREATE TEMP TABLE t17_audit_from AS SELECT COALESCE(max(id), 0) AS id FROM audit_logs;

-- ── Siapa yang boleh memulai (R37/R39) ──
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000002', repeat('2', 64));
SELECT throws_ok($$SELECT act_as_start('17000000-0000-4000-8000-000000000010', NULL, 'Uji akses')$$,
                 '42501', 'Act As hanya untuk Super Admin', 'non super admin ditolak');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), NULL, 'aal1');
SELECT throws_ok($$SELECT act_as_start('17000000-0000-4000-8000-000000000010', NULL, 'Uji akses')$$,
                 '42501', NULL, 'super admin tanpa aal2 ditolak');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64));
SELECT throws_ok($$SELECT act_as_start('17000000-0000-4000-8000-000000000010', NULL, 'abc')$$,
                 '22023', NULL, 'alasan < 5 karakter ditolak');
SELECT throws_ok($$SELECT act_as_start('17000000-0000-4000-8000-000000000001', NULL, 'Uji diri sendiri')$$,
                 '22023', NULL, 'tidak bisa Act As diri sendiri');
SELECT throws_ok($$SELECT act_as_start('17000000-0000-4000-8000-000000000003', NULL, 'Uji admin lain')$$,
                 '42501', NULL, 'tidak bisa Act As sebagai HSE admin');
SELECT throws_ok($$SELECT act_as_start('17000000-0000-4000-8000-000000000012', NULL, 'Uji user pending')$$,
                 '22023', NULL, 'tidak bisa Act As user pending');
SELECT throws_ok($$SELECT act_as_start(NULL, 'super_admin', 'Uji template super')$$,
                 '22023', NULL, 'template super_admin tidak diizinkan');
SELECT throws_ok($$SELECT act_as_start('17000000-0000-4000-8000-000000000010', 'process_owner', 'Uji dua target')$$,
                 '22023', NULL, 'user + role sekaligus ditolak');

SELECT is((SELECT jsonb_array_length(act_as_list_targets() -> 'roles')), 6, 'daftar target: 6 template role WFRD');
SELECT ok((SELECT act_as_list_targets('t17') -> 'users' @> '[{"id":"17000000-0000-4000-8000-000000000010"}]'), 'daftar target memuat PIC aktif');
SELECT ok(NOT (SELECT act_as_list_targets('t17') -> 'users' @> '[{"id":"17000000-0000-4000-8000-000000000003"}]')
          AND NOT (SELECT act_as_list_targets('t17') -> 'users' @> '[{"id":"17000000-0000-4000-8000-000000000012"}]')
          AND NOT (SELECT act_as_list_targets('t17') -> 'users' @> '[{"id":"17000000-0000-4000-8000-000000000001"}]'),
          'daftar target tanpa HSE admin, user pending, dan diri sendiri');

-- ── Mode user ──
INSERT INTO t17_tok SELECT 'u1', act_as_start('17000000-0000-4000-8000-000000000010', NULL, 'Uji alur kontraktor PT T17') ->> 'token';
SELECT ok(pg_temp.tok('u1') ~ '^[A-Za-z0-9_-]{43}$', 'token 256-bit base64url');
SELECT ok(EXISTS (SELECT 1 FROM impersonation_contexts WHERE token_hash = encode(digest(pg_temp.tok('u1'), 'sha256'), 'hex'))
          AND NOT EXISTS (SELECT 1 FROM impersonation_contexts WHERE token_hash = pg_temp.tok('u1')), 'DB hanya menyimpan SHA-256 token');
SELECT is(_eff_uid(), '17000000-0000-4000-8000-000000000001'::UUID, 'tanpa header: identitas tetap root (tab lain / realtime tidak terpengaruh)');

SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('u1'));
SELECT is(_eff_uid(), '17000000-0000-4000-8000-000000000010'::UUID, 'identitas efektif = target');
SELECT is(auth.uid(), '17000000-0000-4000-8000-000000000001'::UUID, 'identitas nyata tetap root');
SELECT is(auth_contractor_id(), '17000000-0000-4000-8000-0000000000c1'::UUID, 'auth_contractor_id = perusahaan target');
SELECT ok(NOT auth_is_wfrd(), 'auth_is_wfrd = FALSE saat Act As kontraktor');
SELECT ok(can_view_contract('17000000-0000-4000-8000-0000000000f1'), 'target melihat kontrak perusahaannya');
SELECT is(my_session_state() ->> 'user_id', '17000000-0000-4000-8000-000000000010', 'session: user_id = target');
SELECT is(my_session_state() ->> 'real_user_id', '17000000-0000-4000-8000-000000000001', 'session: real_user_id = root');
SELECT is(my_session_state() #>> '{act_as,kind}', 'user', 'session: act_as.kind = user');
SELECT is(my_session_state() ->> 'is_root_admin', 'false', 'session: is_root_admin FALSE saat Act As');
SELECT ok((my_session_state() -> 'permissions') ? 'company.edit'
          AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(my_session_state() -> 'permissions') x WHERE x LIKE 'admin.%'),
          'session: permission target (PIC), tanpa admin.*');

-- ── Aksi kritis diblokir (R41) ──
SELECT ok(NOT has_permission('admin.users.view'), 'has_permission(admin.*) FALSE saat Act As');
SELECT throws_ok($$SELECT assert_access('admin.users.view', NULL, FALSE)$$, '42501',
                 'Aksi Admin Console tidak tersedia saat mode Act As. Keluar dari Act As terlebih dahulu.', 'assert_access admin.* diblokir');
SELECT throws_ok($$SELECT admin_set_read_only(TRUE, 'uji danger zone')$$, '42501', NULL, 'Danger Zone diblokir saat Act As');
SELECT throws_ok($$SELECT update_my_profile('X', NULL, NULL, 'id')$$, '42501', NULL, 'ubah profil target diblokir');
SELECT throws_ok($$UPDATE trusted_devices SET label = 'x' WHERE user_id = '17000000-0000-4000-8000-000000000010'$$,
                 '42501', NULL, 'perangkat target tidak bisa diubah (R45)');
SELECT throws_ok($$INSERT INTO signatures (entity, entity_id, signer_id, party, method, sig_hash)
                   VALUES ('meeting', gen_random_uuid(), '17000000-0000-4000-8000-000000000010', 'contractor', 'typed_name', repeat('0', 64))$$,
                 '42501', NULL, 'tanda tangan atas nama target diblokir');

-- ── Notifikasi (R43) & chat (R44) ──
SELECT _notify('17000000-0000-4000-8000-000000000010', 'test', 'Aksi act as', NULL, '/x');
SELECT _notify('17000000-0000-4000-8000-000000000011', 'test', 'Untuk rekan', NULL, '/x');
SELECT ok(EXISTS (SELECT 1 FROM notifications WHERE user_id = '17000000-0000-4000-8000-000000000001' AND title = '[Act As] Aksi act as'),
          'notif untuk target dialihkan ke inbox root');
SELECT ok(NOT EXISTS (SELECT 1 FROM notifications WHERE user_id = '17000000-0000-4000-8000-000000000010' AND title LIKE '%Aksi act as%'),
          'target tidak menerima notif atas aksi Act As');
SELECT ok(EXISTS (SELECT 1 FROM notifications WHERE user_id = '17000000-0000-4000-8000-000000000011' AND title = 'Untuk rekan'),
          'notif ke user lain tetap normal');
SELECT cmp_ok(mark_notifications_read(), '>=', 1, 'mark_notifications_read menandai inbox root');
SELECT ok(EXISTS (SELECT 1 FROM notifications WHERE user_id = '17000000-0000-4000-8000-000000000010' AND title = 'Untuk PIC' AND read_at IS NULL),
          'inbox target tidak tersentuh');
SELECT is(_act_as_chat_actor(), '17000000-0000-4000-8000-000000000001'::UUID, 'pesan chat diberi penanda via_act_as = root');

-- ── Audit (R40) ──
INSERT INTO holidays (holiday_date, name) VALUES ('2099-01-01', 'T17 libur');
SELECT is((SELECT actor_id::TEXT || '/' || act_as_user_id::TEXT FROM audit_logs WHERE table_name = 'holidays' AND new_data ->> 'name' = 'T17 libur'),
          '17000000-0000-4000-8000-000000000001/17000000-0000-4000-8000-000000000010', 'audit: actor = root, act_as_user = target');
SELECT ok((SELECT row_hash = _audit_hash_v2(prev_hash, table_name, record_id, action, old_data, new_data, actor_id, created_at,
                                            act_as_context_id, act_as_user_id, act_as_role_key)
                  AND row_hash <> _audit_hash(prev_hash, table_name, record_id, action, old_data, new_data, actor_id, created_at)
           FROM audit_logs WHERE table_name = 'holidays' AND new_data ->> 'name' = 'T17 libur'),
          'audit: identitas Act As ikut ter-hash (tidak bisa dihapus diam-diam)');

-- ── Token terikat sesi, perangkat, aal2, aktor ──
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('9', 64), pg_temp.tok('u1'));
SELECT throws_ok($$SELECT _eff_uid()$$, '42501', 'Sesi Act As tidak valid', 'token dari perangkat lain ditolak');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('u1'), 'aal2', '17000000-0000-4000-8000-0000000000ff');
SELECT throws_ok($$SELECT _eff_uid()$$, '42501', 'Sesi Act As tidak valid', 'token dari sesi login lain ditolak');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('u1'), 'aal1');
SELECT throws_ok($$SELECT _eff_uid()$$, '42501', 'Act As membutuhkan sesi MFA (aal2)', 'token tanpa aal2 ditolak');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000002', repeat('2', 64), pg_temp.tok('u1'));
SELECT throws_ok($$SELECT _eff_uid()$$, '42501', 'Sesi Act As tidak valid', 'token milik aktor lain ditolak');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), 'bukan-token');
SELECT throws_ok($$SELECT auth_is_active()$$, '42501', 'Sesi Act As tidak valid', 'header rusak → fail-closed (bukan fallback ke root)');

-- ── Refresh, rotasi & batas 2 jam (R38) ──
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('u1'));
INSERT INTO t17_tok SELECT 'u2', act_as_refresh() ->> 'token';
SELECT ok(pg_temp.tok('u2') IS DISTINCT FROM pg_temp.tok('u1'), 'refresh merotasi token');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('u1'));
SELECT is(_eff_uid(), '17000000-0000-4000-8000-000000000010'::UUID, 'token lama masih berlaku selama masa tenggang');
UPDATE impersonation_contexts SET prev_valid_until = NOW() - INTERVAL '1 second' WHERE real_actor_id = '17000000-0000-4000-8000-000000000001' AND closed_at IS NULL;
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('u1'));
SELECT throws_ok($$SELECT _eff_uid()$$, '42501', NULL, 'token lama ditolak setelah masa tenggang');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('u2'));
UPDATE impersonation_contexts SET expires_at = hard_expires_at WHERE real_actor_id = '17000000-0000-4000-8000-000000000001' AND closed_at IS NULL;
SELECT throws_ok($$SELECT act_as_refresh()$$, '22023', NULL, 'tidak bisa diperpanjang melewati 2 jam');

-- ── Target berubah status → konteks gugur ──
UPDATE profiles SET status = 'suspended', status_reason = 'uji t17' WHERE id = '17000000-0000-4000-8000-000000000010';
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('u2'));
SELECT throws_ok($$SELECT _eff_uid()$$, '42501', 'Target Act As tidak lagi valid (status/role berubah)', 'target disuspend → Act As gugur');
UPDATE profiles SET status = 'active', status_reason = NULL WHERE id = '17000000-0000-4000-8000-000000000010';

-- ── Kedaluwarsa & penutupan (R42) ──
UPDATE impersonation_contexts SET expires_at = NOW() - INTERVAL '1 second' WHERE real_actor_id = '17000000-0000-4000-8000-000000000001' AND closed_at IS NULL;
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('u2'));
SELECT throws_ok($$SELECT _eff_uid()$$, '42501', 'Sesi Act As kedaluwarsa', 'token kedaluwarsa ditolak');
SELECT is(act_as_close('user_exit'), 1, 'act_as_close tetap jalan dengan token kedaluwarsa');
SELECT is((SELECT close_reason FROM impersonation_contexts WHERE token_hash = encode(digest(pg_temp.tok('u2'), 'sha256'), 'hex')),
          'expired', 'alasan tutup = expired');

-- ── Mode role template ──
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64));
INSERT INTO t17_tok SELECT 'u3', act_as_start('17000000-0000-4000-8000-000000000011', NULL, 'Uji employee') ->> 'token';
INSERT INTO t17_tok SELECT 'r1', act_as_start(NULL, 'process_owner', 'Uji alur process owner') ->> 'token';
SELECT is((SELECT close_reason FROM impersonation_contexts WHERE token_hash = encode(digest(pg_temp.tok('u3'), 'sha256'), 'hex')),
          'replaced', 'memulai Act As baru menutup konteks lama (replaced)');
SELECT is((SELECT count(*)::INT FROM impersonation_contexts WHERE real_actor_id = '17000000-0000-4000-8000-000000000001' AND closed_at IS NULL),
          1, 'maksimal satu konteks terbuka per aktor');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64), pg_temp.tok('r1'));
SELECT is(_eff_uid(), '17000000-0000-4000-8000-000000000001'::UUID, 'mode role: identitas efektif tetap root');
SELECT is((SELECT array_agg(x ORDER BY x) FROM jsonb_array_elements_text(my_session_state() -> 'permissions') x),
          (SELECT array_agg(DISTINCT rp.permission_key ORDER BY rp.permission_key) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
           WHERE r.key = 'process_owner' AND NOT _act_as_perm_blocked(rp.permission_key)),
          'mode role: permission = template process_owner persis (kuasa super admin tidak bocor)');
SELECT ok(NOT _user_has_role('17000000-0000-4000-8000-000000000001', 'super_admin')
          AND _user_has_role('17000000-0000-4000-8000-000000000001', 'process_owner'), 'mode role: _user_has_role mengikuti template');
SELECT is(my_session_state() #>> '{roles,0,key}', 'process_owner', 'mode role: session roles = template');
SELECT ok(_act_as_chat_actor() IS NULL, 'mode role: pesan chat dikirim sebagai root sendiri (tanpa penanda)');
SELECT throws_ok($$SELECT assert_access('admin.users.view', NULL, FALSE)$$, '42501', NULL, 'mode role: admin.* tetap diblokir');
SELECT is(act_as_close(), 1, 'exit menutup konteks');
SELECT throws_ok($$SELECT _eff_uid()$$, '42501', 'Sesi Act As sudah ditutup', 'token konteks tertutup ditolak');
SELECT pg_temp.t17_as('17000000-0000-4000-8000-000000000001', repeat('1', 64));
SELECT ok(has_permission('admin.users.view'), 'setelah exit: kuasa root kembali normal');

-- ── Jejak ──
SELECT ok((SELECT count(DISTINCT event) FROM impersonation_events WHERE real_actor_id = '17000000-0000-4000-8000-000000000001') = 3,
          'impersonation_events mencatat started/refreshed/closed');
SELECT is((admin_verify_audit_chain((SELECT id + 1 FROM t17_audit_from)) ->> 'ok'), 'true', 'rantai audit tetap valid');

SELECT * FROM finish();
ROLLBACK;
