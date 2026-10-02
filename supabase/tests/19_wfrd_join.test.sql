-- Migration 20260103000004 (v3.4.2): pendaftaran karyawan Weatherford oleh user pending. Fixture mandiri.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(33);

CREATE FUNCTION pg_temp.t19_as(p_uid UUID, p_dev TEXT, p_aal TEXT DEFAULT 'aal2') RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers', jsonb_build_object('x-device-id', p_dev)::TEXT, TRUE);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal,
    'session_id', '19000000-0000-4000-8000-00000000005e',
    'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch FROM now())::INT)))::TEXT, TRUE);
  PERFORM set_config('comen.act_as_cache', '', TRUE);
END $$;
CREATE FUNCTION pg_temp.t19_req(p_extra JSONB DEFAULT '{}') RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('full_name', 'Budi Santoso', 'employee_id', 'WFT-10234', 'work_email', 'Budi.Santoso@Weatherford.com',
    'job_title', 'HSE Specialist', 'department', 'HSE', 'geozone', 'APAC', 'work_location', 'Balikpapan',
    'line_manager_name', 'Andi Manager', 'line_manager_email', 'andi@weatherford.com', 'phone', '+62 812 1111 2222',
    'requested_role_key', 'hse_reviewer', 'note', 'Pindah dari contractor', 'privacy_accepted', true) || p_extra
$$;

-- 01 root · 20 pending (calon WFRD) · 21 pending dengan draft perusahaan · 22 pending, registrasi terkirim · 23 WFRD aktif
INSERT INTO admin_allowlist (email, note) VALUES ('u01@t19.test', 't19 root');
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('19000000-0000-4000-8000-0000000000' || n)::UUID, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'u' || n || '@t19.test', NOW(), '{}', '{}', NOW(), NOW()
FROM unnest(ARRAY['01','20','21','22','23']) n;
UPDATE profiles SET status = 'active', is_root_admin = TRUE WHERE id = '19000000-0000-4000-8000-000000000001';
UPDATE profiles SET status = 'active' WHERE id = '19000000-0000-4000-8000-000000000023';
SELECT _grant_role_internal('19000000-0000-4000-8000-000000000001', (SELECT id FROM roles WHERE key = 'super_admin'), 'global', NULL, NULL, 't19', NULL);
SELECT _grant_role_internal('19000000-0000-4000-8000-000000000023', (SELECT id FROM roles WHERE key = 'viewer'), 'global', NULL, NULL, 't19', NULL);
INSERT INTO contractors (id, legal_name, registration_no, tax_id, country, address, primary_contact_name, primary_contact_email,
                         hse_manager_name, hse_manager_email, status, submitted_at, registered_by)
VALUES ('19000000-0000-4000-8000-0000000000c2', 'PT T19 Terkirim', 'NIB-T19', 'T19-TAX', 'ID', 'Jl. T19', 'Rep', 'rep@t19.test',
        'HSE', 'hse@t19.test', 'under_review', NOW(), '19000000-0000-4000-8000-000000000022');
UPDATE profiles SET contractor_id = '19000000-0000-4000-8000-0000000000c2' WHERE id = '19000000-0000-4000-8000-000000000022';
INSERT INTO trusted_devices (user_id, device_hash) VALUES
  ('19000000-0000-4000-8000-000000000001', repeat('1', 64)), ('19000000-0000-4000-8000-000000000020', repeat('2', 64)),
  ('19000000-0000-4000-8000-000000000021', repeat('3', 64)), ('19000000-0000-4000-8000-000000000022', repeat('4', 64)),
  ('19000000-0000-4000-8000-000000000023', repeat('5', 64));

-- ── Data form untuk user pending ──
SELECT pg_temp.t19_as('19000000-0000-4000-8000-000000000020', repeat('2', 64), 'aal1');
SELECT is(get_my_wfrd_request() -> 'request', 'null'::jsonb, 'belum ada pengajuan');
SELECT ok(get_my_wfrd_request() -> 'geozones' @> '[{"code":"APAC"}]', 'geozone aktif tersedia untuk user pending');
SELECT ok(NOT (get_my_wfrd_request() -> 'roles' @> '[{"key":"super_admin"}]')
          AND NOT (get_my_wfrd_request() -> 'roles' @> '[{"key":"contractor_rep"}]')
          AND get_my_wfrd_request() -> 'roles' @> '[{"key":"hse_reviewer"}]', 'daftar role: hanya role WFRD tanpa super_admin');

-- ── Validasi ──
SELECT throws_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"employee_id":"x"}'))$$, '22023', NULL, 'employee ID terlalu pendek ditolak');
SELECT throws_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"geozone":"MARS"}'))$$, '22023', 'Geozone tidak valid', 'geozone tidak dikenal ditolak');
SELECT throws_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"requested_role_key":"contractor_rep"}'))$$, '22023',
                 'Role yang diminta tidak valid', 'role contractor tidak bisa diminta');
SELECT throws_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"requested_role_key":"super_admin"}'))$$, '22023',
                 'Role yang diminta tidak valid', 'super_admin tidak bisa diminta');
SELECT throws_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"line_manager_email":"bukan-email"}'))$$, '22023',
                 'Format email tidak valid', 'email atasan wajib valid');
SELECT throws_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"phone":"abc"}'))$$, '22023', 'Nomor telepon tidak valid', 'telepon wajib valid');
SELECT throws_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"privacy_accepted":false}'))$$, '22023', 'Privacy Notice wajib disetujui',
                 'Privacy Notice wajib disetujui');

-- ── Kirim, kirim ulang, batalkan ──
SELECT is(submit_wfrd_join_request(pg_temp.t19_req()) ->> 'status', 'submitted', 'pengajuan terkirim');
SELECT is(get_my_wfrd_request() -> 'request' ->> 'employee_id', 'WFT-10234', 'pengajuan terbaca kembali');
SELECT is(get_my_wfrd_request() -> 'request' ->> 'phone', '+62 812 1111 2222', 'telepon tersimpan terenkripsi & terbaca pemilik');
SELECT is(get_my_wfrd_request() -> 'request' ->> 'work_email', 'budi.santoso@weatherford.com', 'email kerja dinormalisasi');
SELECT is((SELECT full_name FROM profiles WHERE id = '19000000-0000-4000-8000-000000000020'), 'Budi Santoso', 'nama profil diperbarui');
SELECT lives_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"job_title":"Senior HSE Specialist"}'))$$, 'kirim ulang diizinkan');
SELECT is((SELECT count(*)::INT FROM wfrd_join_requests WHERE user_id = '19000000-0000-4000-8000-000000000020' AND status = 'submitted'),
          1, 'hanya satu pengajuan aktif');
SELECT throws_ok($$SELECT save_registration_draft('{"legal_name":"PT Tidak Boleh"}')$$, '22023', NULL,
                 'registrasi contractor tertutup selama pengajuan WFRD aktif');
SELECT lives_ok($$SELECT withdraw_wfrd_join_request()$$, 'pengajuan bisa dibatalkan');
SELECT throws_ok($$SELECT withdraw_wfrd_join_request()$$, '22023', NULL, 'batal dua kali ditolak');
SELECT lives_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req())$$, 'kirim lagi setelah batal');

-- ── Konflik dengan alur contractor ──
SELECT pg_temp.t19_as('19000000-0000-4000-8000-000000000021', repeat('3', 64), 'aal1');
SELECT lives_ok($$SELECT save_registration_draft('{"legal_name":"PT Draft T19"}')$$, 'user 21 membuat draft perusahaan');
SELECT lives_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"employee_id":"WFT-20001"}'))$$, 'pindah ke alur WFRD dari draft');
SELECT ok((SELECT contractor_id FROM profiles WHERE id = '19000000-0000-4000-8000-000000000021') IS NULL
          AND NOT EXISTS (SELECT 1 FROM contractors WHERE legal_name = 'PT Draft T19'), 'draft perusahaan milik sendiri dilepas & dihapus');
SELECT pg_temp.t19_as('19000000-0000-4000-8000-000000000022', repeat('4', 64), 'aal1');
SELECT throws_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req('{"employee_id":"WFT-20002"}'))$$, '22023', NULL,
                 'registrasi perusahaan yang sudah terkirim memblokir pengajuan WFRD');
SELECT pg_temp.t19_as('19000000-0000-4000-8000-000000000023', repeat('5', 64));
SELECT throws_ok($$SELECT submit_wfrd_join_request(pg_temp.t19_req())$$, '42501', NULL, 'user WFRD aktif tidak bisa mengajukan');

-- ── Admin: antrean, approve, tolak ──
SELECT pg_temp.t19_as('19000000-0000-4000-8000-000000000001', repeat('1', 64));
SELECT is((SELECT e -> 'wfrd_request' ->> 'employee_id' FROM jsonb_array_elements(admin_list_users('pending', 't19', NULL, 50, 0)) e
           WHERE e ->> 'id' = '19000000-0000-4000-8000-000000000020'), 'WFT-10234', 'antrean approval memuat data karyawan WFRD');
SELECT ok(EXISTS (SELECT 1 FROM notifications WHERE user_id = '19000000-0000-4000-8000-000000000001'
                  AND title = 'Karyawan Weatherford minta akses'), 'admin approver diberi notifikasi');
SELECT lives_ok($$SELECT admin_approve_user('19000000-0000-4000-8000-000000000020', 'hse_reviewer', 'global', NULL, NULL, NULL,
                                           'Terverifikasi karyawan WFRD', NULL)$$, 'approve sebagai karyawan WFRD');
SELECT is((SELECT status || ':' || decided_by FROM wfrd_join_requests
           WHERE user_id = '19000000-0000-4000-8000-000000000020' AND status <> 'withdrawn'),
          'approved:19000000-0000-4000-8000-000000000001', 'pengajuan ditandai approved oleh admin');
SELECT is((SELECT job_title || '@' || geozone FROM profiles WHERE id = '19000000-0000-4000-8000-000000000020'),
          'HSE Specialist@APAC', 'jabatan & geozone profil diisi dari pengajuan');
SELECT lives_ok($$SELECT admin_reject_user('19000000-0000-4000-8000-000000000021', 'Employee ID tidak ditemukan di HR')$$, 'tolak pengajuan');
SELECT is((SELECT status || ':' || decision_note FROM wfrd_join_requests
           WHERE user_id = '19000000-0000-4000-8000-000000000021'), 'rejected:Employee ID tidak ditemukan di HR', 'pengajuan ditandai rejected + alasan');

SELECT * FROM finish();
ROLLBACK;
