-- Migration 20: MFA wajib semua user aktif + admin_assign_doc_type
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(10);

SELECT is(setting('mfa_required_all'), 'true'::jsonb, 'mfa_required_all aktif secara default');
SELECT ok(user_requires_mfa((SELECT id FROM profiles WHERE email = 'rep@maju.dev.local')), 'contractor aktif wajib MFA');
SELECT ok(user_requires_mfa((SELECT id FROM profiles WHERE email = 'reviewer@dev.local')), 'karyawan WFRD non-admin wajib MFA');
SELECT ok(NOT user_requires_mfa((SELECT id FROM profiles WHERE email = 'viewer@maju.dev.local')), 'user pending tidak wajib MFA (registrasi tetap jalan)');

SELECT ok(has_function_privilege('authenticated', 'public.admin_assign_doc_type(text,text,uuid[],text,date,boolean,text,text)', 'EXECUTE'),
          'admin_assign_doc_type executable oleh authenticated');
SELECT ok(NOT has_function_privilege('anon', 'public.admin_assign_doc_type(text,text,uuid[],text,date,boolean,text,text)', 'EXECUTE'),
          'admin_assign_doc_type tidak executable oleh anon');

-- Sesi HSE Admin di perangkat terdaftar
INSERT INTO trusted_devices (user_id, device_hash) SELECT id, repeat('b', 64) FROM profiles WHERE email = 'hse.admin@dev.local';
INSERT INTO trusted_devices (user_id, device_hash) SELECT id, repeat('c', 64) FROM profiles WHERE email = 'rep@maju.dev.local';
SELECT set_config('request.headers', json_build_object('x-device-id', repeat('c', 64))::TEXT, TRUE);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM profiles WHERE email = 'rep@maju.dev.local'),
  'role', 'authenticated', 'aal', 'aal1',
  'amr', json_build_array(json_build_object('method', 'oauth', 'timestamp', extract(epoch FROM now())::INT)))::TEXT, TRUE);
SELECT throws_ok($$SELECT assert_session(FALSE)$$, '42501', 'Verifikasi MFA diperlukan', 'contractor aal1 ditolak');

SELECT set_config('request.headers', json_build_object('x-device-id', repeat('b', 64))::TEXT, TRUE);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM profiles WHERE email = 'hse.admin@dev.local'),
  'role', 'authenticated', 'aal', 'aal2',
  'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch FROM now())::INT)))::TEXT, TRUE);

SELECT is(admin_assign_doc_type('ACTITM', 'vendor', ARRAY(SELECT id FROM contractors ORDER BY legal_name),
            'Update HSE Policy 2027', CURRENT_DATE + 14, FALSE, NULL, 'uji penugasan massal'),
          jsonb_build_object('created', (SELECT count(*) FROM contractors WHERE status IN ('under_review','asl_approved','asl_conditional','asl_expired'))::INT,
                             'skipped', (SELECT count(*) FROM contractors WHERE status NOT IN ('under_review','asl_approved','asl_conditional','asl_expired'))::INT),
          'task dibuat untuk contractor eligible, draft dilewati');
SELECT is((admin_assign_doc_type('ACTITM', 'vendor', ARRAY(SELECT id FROM contractors WHERE status = 'asl_approved'),
            NULL, CURRENT_DATE + 14, FALSE, NULL, 'uji duplikat') ->> 'created')::INT, 0,
          'contractor yang sudah punya task aktif sejenis dilewati');
SELECT throws_ok($$SELECT admin_assign_doc_type('ACTITM', 'vendor', ARRAY[gen_random_uuid()], NULL, CURRENT_DATE - 1, FALSE, NULL, 'due lampau')$$,
                 '22023', 'Due date wajib & tidak boleh lampau', 'due date lampau ditolak');

SELECT * FROM finish();
ROLLBACK;
