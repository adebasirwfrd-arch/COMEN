-- Migration 20260103000003 (v3.4.1): deactivate tanpa ban; mantan user login ulang = akun baru (pending). Fixture mandiri.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(29);

-- p_auth_offset: detik relatif terhadap NOW() transaksi (= sessions_valid_after saat dinonaktifkan di transaksi ini)
CREATE FUNCTION pg_temp.t18_as(p_uid UUID, p_dev TEXT, p_method TEXT DEFAULT 'totp', p_auth_offset INT DEFAULT 0,
                               p_aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers', jsonb_build_object('x-device-id', p_dev)::TEXT, TRUE);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal,
    'session_id', gen_random_uuid(),
    'amr', json_build_array(json_build_object('method', p_method, 'timestamp', extract(epoch FROM now())::INT + p_auth_offset)))::TEXT, TRUE);
  PERFORM set_config('comen.act_as_cache', '', TRUE);
END $$;

-- 01 root · 10/11 user contractor · 12 user WFRD · 13 user contractor (dianonimkan)
INSERT INTO admin_allowlist (email, note) VALUES ('u01@t18.test', 't18 root');
INSERT INTO contractors (id, legal_name, registration_no, tax_id, country, address, primary_contact_name, primary_contact_email,
                         hse_manager_name, hse_manager_email, status, submitted_at)
VALUES ('18000000-0000-4000-8000-0000000000c1', 'PT T18', 'NIB-T18', 'T18-TAX', 'ID', 'Jl. T18', 'Rep', 'rep@t18.test',
        'HSE', 'hse@t18.test', 'asl_approved', NOW());
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('18000000-0000-4000-8000-0000000000' || n)::UUID, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'u' || n || '@t18.test', NOW(), '{}', '{}', NOW(), NOW()
FROM unnest(ARRAY['01','10','11','12','13']) n;
UPDATE profiles SET status = 'active', is_root_admin = TRUE WHERE id = '18000000-0000-4000-8000-000000000001';
UPDATE profiles SET status = 'active', contractor_id = '18000000-0000-4000-8000-0000000000c1'
WHERE id IN ('18000000-0000-4000-8000-000000000010', '18000000-0000-4000-8000-000000000011', '18000000-0000-4000-8000-000000000013');
UPDATE profiles SET status = 'active' WHERE id = '18000000-0000-4000-8000-000000000012';
SELECT _grant_role_internal('18000000-0000-4000-8000-000000000001', (SELECT id FROM roles WHERE key = 'super_admin'), 'global', NULL, NULL, 't18', NULL);
SELECT _grant_role_internal(u::UUID, (SELECT id FROM roles WHERE key = 'contractor_rep'), 'global', NULL, NULL, 't18', NULL)
FROM unnest(ARRAY['18000000-0000-4000-8000-000000000010', '18000000-0000-4000-8000-000000000011', '18000000-0000-4000-8000-000000000013']) u;
SELECT _grant_role_internal('18000000-0000-4000-8000-000000000012', (SELECT id FROM roles WHERE key = 'hse_reviewer'), 'global', NULL, NULL, 't18', NULL);
SELECT _upsert_contractor_level('18000000-0000-4000-8000-000000000010', '18000000-0000-4000-8000-0000000000c1', 'pic', NULL);
INSERT INTO trusted_devices (user_id, device_hash) VALUES ('18000000-0000-4000-8000-000000000001', repeat('1', 64));

-- ── Status: deactivate tidak ban, suspend ban ──
SELECT pg_temp.t18_as('18000000-0000-4000-8000-000000000001', repeat('1', 64));
SELECT is((admin_set_user_status('18000000-0000-4000-8000-000000000010', 'deactivated', 'Resign dari PT T18') ->> 'ban')::BOOLEAN,
          FALSE, 'deactivate tidak mem-ban identitas Auth');
SELECT is((admin_set_user_status('18000000-0000-4000-8000-000000000012', 'suspended', 'Investigasi insiden') ->> 'ban')::BOOLEAN,
          TRUE, 'suspend tetap mem-ban identitas Auth');
SELECT is((admin_set_user_status('18000000-0000-4000-8000-000000000012', 'active', 'Investigasi selesai') ->> 'ban')::BOOLEAN,
          FALSE, 'reactivate meng-unban');
SELECT lives_ok($$SELECT admin_set_user_status('18000000-0000-4000-8000-000000000011', 'deactivated', 'Resign dari PT T18')$$,
                'user kedua dinonaktifkan');
SELECT lives_ok($$SELECT admin_set_user_status('18000000-0000-4000-8000-000000000013', 'deactivated', 'Resign dari PT T18')$$,
                'user ketiga dinonaktifkan');

-- ── Sesi lama (auth_time sebelum dinonaktifkan) tidak memicu gabung ulang ──
SELECT pg_temp.t18_as('18000000-0000-4000-8000-000000000010', repeat('a', 64), 'oauth', -60, 'aal1');
SELECT is(register_device(repeat('a', 64), 'Laptop') ->> 'status', 'deactivated', 'sesi lama: tetap deactivated');
SELECT is((SELECT count(*)::INT FROM user_roles WHERE user_id = '18000000-0000-4000-8000-000000000010'), 1, 'sesi lama: role tetap');

-- ── Login segar setelah dinonaktifkan → akun baru (pending) ──
SELECT pg_temp.t18_as('18000000-0000-4000-8000-000000000010', repeat('a', 64), 'oauth', 60, 'aal1');
SELECT is(register_device(repeat('a', 64), 'Laptop') ->> 'status', 'pending', 'login segar: status pending');
SELECT is((SELECT count(*)::INT FROM user_roles WHERE user_id = '18000000-0000-4000-8000-000000000010'), 0, 'role lama dicabut');
SELECT is((SELECT contractor_id FROM profiles WHERE id = '18000000-0000-4000-8000-000000000010'), NULL, 'perusahaan lama dilepas');
SELECT is((SELECT status_reason FROM profiles WHERE id = '18000000-0000-4000-8000-000000000010'), NULL, 'alasan nonaktif dibersihkan');
SELECT ok(NOT EXISTS (SELECT 1 FROM contractor_users WHERE user_id = '18000000-0000-4000-8000-000000000010' AND is_active),
          'level contractor lama nonaktif');
SELECT ok(NOT EXISTS (SELECT 1 FROM chat_members m JOIN chat_channels c ON c.id = m.channel_id
                      WHERE m.user_id = '18000000-0000-4000-8000-000000000010'
                        AND c.contractor_id = '18000000-0000-4000-8000-0000000000c1' AND c.type <> 'announcement'),
          'keluar dari chat perusahaan lama');
SELECT is((SELECT detail ->> 'previous_reason' FROM security_events
           WHERE user_id = '18000000-0000-4000-8000-000000000010' AND event = 'user_rejoined'),
          'Resign dari PT T18', 'event user_rejoined mencatat alasan lama');
SELECT ok((SELECT detail -> 'previous_roles' FROM security_events
           WHERE user_id = '18000000-0000-4000-8000-000000000010' AND event = 'user_rejoined') @> '["contractor_rep"]',
          'event user_rejoined mencatat role lama');
SELECT ok(EXISTS (SELECT 1 FROM notifications WHERE user_id = '18000000-0000-4000-8000-000000000001'
                  AND title = 'Mantan user mendaftar ulang' AND body = 'u10@t18.test'), 'admin approver diberi notifikasi');
SELECT is(register_device(repeat('a', 64), 'Laptop') ->> 'status', 'pending', 'register ulang idempoten (tetap pending)');
SELECT is((SELECT count(*)::INT FROM security_events WHERE user_id = '18000000-0000-4000-8000-000000000010' AND event = 'user_rejoined'),
          1, 'gabung ulang hanya sekali per login');

-- ── Approve sebagai karyawan WFRD ──
SELECT pg_temp.t18_as('18000000-0000-4000-8000-000000000001', repeat('1', 64));
SELECT lives_ok($$SELECT admin_approve_user('18000000-0000-4000-8000-000000000010', 'hse_reviewer', 'global', NULL, NULL, NULL,
                                           'Direkrut sebagai karyawan WFRD', NULL)$$, 'approve dengan role WFRD');
SELECT is((SELECT status::TEXT FROM profiles WHERE id = '18000000-0000-4000-8000-000000000010'), 'active', 'user aktif kembali');
SELECT ok(EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                  WHERE ur.user_id = '18000000-0000-4000-8000-000000000010' AND r.key = 'hse_reviewer')
          AND NOT EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                          WHERE ur.user_id = '18000000-0000-4000-8000-000000000010' AND NOT r.is_wfrd),
          'hanya role WFRD baru');

-- ── Undang lebih dulu → otomatis aktif saat login ──
SELECT lives_ok($$SELECT admin_create_invite('u11@t18.test', 'hse_reviewer', 'global', NULL, NULL, NULL, NULL,
                                            'Direkrut sebagai karyawan WFRD')$$, 'email mantan user boleh diundang');
SELECT throws_ok($$SELECT admin_create_invite('u12@t18.test', 'hse_reviewer', 'global', NULL, NULL, NULL, NULL, 'Undang user aktif')$$,
                 '22023', 'Email sudah memiliki akun (gunakan Users & Access)', 'email user aktif tetap ditolak');
SELECT is((SELECT status::TEXT FROM profiles WHERE id = '18000000-0000-4000-8000-000000000011'), 'deactivated',
          'undangan tidak mengubah status sebelum user login');
SELECT pg_temp.t18_as('18000000-0000-4000-8000-000000000011', repeat('b', 64), 'oauth', 60, 'aal1');
SELECT is(register_device(repeat('b', 64), 'HP') ->> 'status', 'active', 'login segar + undangan: langsung aktif');
SELECT ok(EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                  WHERE ur.user_id = '18000000-0000-4000-8000-000000000011' AND r.key = 'hse_reviewer')
          AND (SELECT contractor_id FROM profiles WHERE id = '18000000-0000-4000-8000-000000000011') IS NULL,
          'role WFRD dari undangan, tanpa perusahaan');
SELECT ok((SELECT accepted_by FROM user_invites WHERE email = 'u11@t18.test' AND revoked_at IS NULL)
          = '18000000-0000-4000-8000-000000000011', 'undangan tercatat diterima');

-- ── Anonimisasi tetap permanen ──
RESET request.jwt.claims;
UPDATE profiles SET anonymized_at = NOW() WHERE id = '18000000-0000-4000-8000-000000000013';
SELECT pg_temp.t18_as('18000000-0000-4000-8000-000000000013', repeat('c', 64), 'oauth', 60, 'aal1');
SELECT is(register_device(repeat('c', 64), 'HP') ->> 'status', 'deactivated', 'akun teranonimkan tidak bergabung ulang');
SELECT ok(NOT EXISTS (SELECT 1 FROM security_events WHERE user_id = '18000000-0000-4000-8000-000000000013' AND event = 'user_rejoined'),
          'tanpa event user_rejoined untuk akun teranonimkan');

SELECT * FROM finish();
ROLLBACK;
