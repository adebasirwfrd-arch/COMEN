-- Migration 20: MFA wajib semua user aktif + admin_assign_doc_type (fixture mandiri, tidak bergantung dev_users.sh)
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(10);

INSERT INTO contractors (id, legal_name, registration_no, tax_id, country, address, primary_contact_name, primary_contact_email,
                         hse_manager_name, hse_manager_email, status, submitted_at)
VALUES ('15000000-0000-4000-8000-0000000000c1', 'PT T15 Aktif', 'NIB-T15-1', 'T15-TAX-1', 'ID', 'Jl. T15', 'Rep', 'rep@t15.test',
        'HSE', 'hse@t15.test', 'asl_approved', NOW());
INSERT INTO contractors (id, legal_name, status) VALUES ('15000000-0000-4000-8000-0000000000c2', 'PT T15 Draft', 'draft');

INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) VALUES
  ('15000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin@t15.test', '{}', '{}', NOW(), NOW()),
  ('15000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rep@t15.test', '{}', '{}', NOW(), NOW()),
  ('15000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'reviewer@t15.test', '{}', '{}', NOW(), NOW()),
  ('15000000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'pending@t15.test', '{}', '{}', NOW(), NOW());
UPDATE profiles SET status = 'active' WHERE id IN ('15000000-0000-4000-8000-000000000001', '15000000-0000-4000-8000-000000000003');
UPDATE profiles SET status = 'active', contractor_id = '15000000-0000-4000-8000-0000000000c1' WHERE id = '15000000-0000-4000-8000-000000000002';
SELECT _grant_role_internal('15000000-0000-4000-8000-000000000001', (SELECT id FROM roles WHERE key = 'hse_admin'), 'global', NULL, NULL, 't15', NULL);
SELECT _grant_role_internal('15000000-0000-4000-8000-000000000002', (SELECT id FROM roles WHERE key = 'contractor_rep'), 'global', NULL, NULL, 't15', NULL);
SELECT _grant_role_internal('15000000-0000-4000-8000-000000000003', (SELECT id FROM roles WHERE key = 'hse_reviewer'), 'global', NULL, NULL, 't15', NULL);
INSERT INTO trusted_devices (user_id, device_hash) VALUES
  ('15000000-0000-4000-8000-000000000001', repeat('b', 64)),
  ('15000000-0000-4000-8000-000000000002', repeat('c', 64));

SELECT is(setting('mfa_required_all'), 'true'::jsonb, 'mfa_required_all aktif secara default');
SELECT ok(user_requires_mfa('15000000-0000-4000-8000-000000000002'), 'contractor aktif wajib MFA');
SELECT ok(user_requires_mfa('15000000-0000-4000-8000-000000000003'), 'karyawan WFRD non-admin wajib MFA');
SELECT ok(NOT user_requires_mfa('15000000-0000-4000-8000-000000000004'), 'user pending tidak wajib MFA (registrasi tetap jalan)');

SELECT ok(has_function_privilege('authenticated', 'public.admin_assign_doc_type(text,text,uuid[],text,date,boolean,text,text)', 'EXECUTE'),
          'admin_assign_doc_type executable oleh authenticated');
SELECT ok(NOT has_function_privilege('anon', 'public.admin_assign_doc_type(text,text,uuid[],text,date,boolean,text,text)', 'EXECUTE'),
          'admin_assign_doc_type tidak executable oleh anon');

SELECT set_config('request.headers', json_build_object('x-device-id', repeat('c', 64))::TEXT, TRUE);
SELECT set_config('request.jwt.claims', json_build_object('sub', '15000000-0000-4000-8000-000000000002', 'role', 'authenticated', 'aal', 'aal1',
  'amr', json_build_array(json_build_object('method', 'oauth', 'timestamp', extract(epoch FROM now())::INT)))::TEXT, TRUE);
SELECT throws_ok($$SELECT assert_session(FALSE)$$, '42501', 'Verifikasi MFA diperlukan', 'contractor aal1 ditolak');

SELECT set_config('request.headers', json_build_object('x-device-id', repeat('b', 64))::TEXT, TRUE);
SELECT set_config('request.jwt.claims', json_build_object('sub', '15000000-0000-4000-8000-000000000001', 'role', 'authenticated', 'aal', 'aal2',
  'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch FROM now())::INT)))::TEXT, TRUE);

SELECT is(admin_assign_doc_type('ACTITM', 'vendor', ARRAY['15000000-0000-4000-8000-0000000000c1', '15000000-0000-4000-8000-0000000000c2']::UUID[],
            'Update HSE Policy 2027', CURRENT_DATE + 14, FALSE, NULL, 'uji penugasan massal'),
          '{"created": 1, "skipped": 1}'::jsonb, 'task dibuat untuk contractor eligible, draft dilewati');
SELECT is((admin_assign_doc_type('ACTITM', 'vendor', ARRAY['15000000-0000-4000-8000-0000000000c1']::UUID[],
            NULL, CURRENT_DATE + 14, FALSE, NULL, 'uji duplikat') ->> 'created')::INT, 0,
          'contractor yang sudah punya task aktif sejenis dilewati');
SELECT throws_ok($$SELECT admin_assign_doc_type('ACTITM', 'vendor', ARRAY[gen_random_uuid()], NULL, CURRENT_DATE - 1, FALSE, NULL, 'due lampau')$$,
                 '22023', 'Due date wajib & tidak boleh lampau', 'due date lampau ditolak');

SELECT * FROM finish();
ROLLBACK;
