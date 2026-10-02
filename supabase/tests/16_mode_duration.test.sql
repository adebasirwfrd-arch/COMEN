-- Migration 21 (v3.3): mode × durasi → access tier, level user contractor. Fixture mandiri.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(43);

CREATE FUNCTION pg_temp.t16_as(p_uid UUID, p_dev TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.headers', json_build_object('x-device-id', p_dev)::TEXT, TRUE);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2',
    'amr', json_build_array(json_build_object('method', 'totp', 'timestamp', extract(epoch FROM now())::INT)))::TEXT, TRUE);
END $$;

INSERT INTO contractors (id, legal_name, registration_no, tax_id, country, address, primary_contact_name, primary_contact_email,
                         hse_manager_name, hse_manager_email, status, submitted_at)
VALUES ('16000000-0000-4000-8000-0000000000c1', 'PT T16', 'NIB-T16', 'T16-TAX', 'ID', 'Jl. T16', 'Rep', 'rep@t16.test',
        'HSE', 'hse@t16.test', 'asl_approved', NOW());

INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('16000000-0000-4000-8000-0000000000' || n)::UUID, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'u' || n || '@t16.test', '{}', '{}', NOW(), NOW()
FROM unnest(ARRAY['01','02','03','10','11','12','13']) n;
UPDATE profiles SET status = 'active' WHERE id IN ('16000000-0000-4000-8000-000000000001', '16000000-0000-4000-8000-000000000002',
                                                    '16000000-0000-4000-8000-000000000003');
UPDATE profiles SET status = 'active', contractor_id = '16000000-0000-4000-8000-0000000000c1'
WHERE id IN ('16000000-0000-4000-8000-000000000010', '16000000-0000-4000-8000-000000000011', '16000000-0000-4000-8000-000000000012');
UPDATE profiles SET contractor_id = '16000000-0000-4000-8000-0000000000c1' WHERE id = '16000000-0000-4000-8000-000000000013';
SELECT _grant_role_internal('16000000-0000-4000-8000-000000000001', (SELECT id FROM roles WHERE key = 'hse_admin'), 'global', NULL, NULL, 't16', NULL);
SELECT _grant_role_internal('16000000-0000-4000-8000-000000000002', (SELECT id FROM roles WHERE key = 'process_owner'), 'global', NULL, NULL, 't16', NULL);
SELECT _grant_role_internal('16000000-0000-4000-8000-000000000003', (SELECT id FROM roles WHERE key = 'hse_reviewer'), 'global', NULL, NULL, 't16', NULL);
SELECT _grant_role_internal(u::UUID, (SELECT id FROM roles WHERE key = 'contractor_rep'), 'global', NULL, NULL, 't16', NULL)
FROM unnest(ARRAY['16000000-0000-4000-8000-000000000010', '16000000-0000-4000-8000-000000000011', '16000000-0000-4000-8000-000000000012']) u;
SELECT _upsert_contractor_level('16000000-0000-4000-8000-000000000010', '16000000-0000-4000-8000-0000000000c1', 'pic', NULL);
SELECT _upsert_contractor_level('16000000-0000-4000-8000-000000000011', '16000000-0000-4000-8000-0000000000c1', 'supervisor', NULL);
SELECT _upsert_contractor_level('16000000-0000-4000-8000-000000000012', '16000000-0000-4000-8000-0000000000c1', 'employee', NULL);
INSERT INTO trusted_devices (user_id, device_hash) VALUES
  ('16000000-0000-4000-8000-000000000001', repeat('1', 64)), ('16000000-0000-4000-8000-000000000002', repeat('2', 64)),
  ('16000000-0000-4000-8000-000000000010', repeat('a', 64)), ('16000000-0000-4000-8000-000000000011', repeat('b', 64)),
  ('16000000-0000-4000-8000-000000000012', repeat('c', 64));

-- kF full · kS streamlined · kM minimal · kV visitor · kA full & active (record operasional)
INSERT INTO contracts (id, contractor_id, title, geozone, risk_class, start_date, end_date, target_mob_date, process_owner_id,
                       hse_reviewer_id, review_mailbox, contract_mode, hse_oversight_notes, status)
SELECT x.id::UUID, '16000000-0000-4000-8000-0000000000c1', x.title, 'APAC', 'low', CURRENT_DATE, CURRENT_DATE + x.days, CURRENT_DATE + 20,
       '16000000-0000-4000-8000-000000000002', '16000000-0000-4000-8000-000000000003', 'rev@t16.test', x.mode::contract_mode, x.notes,
       x.status::contract_status
FROM (VALUES
  ('16000000-0000-4000-8000-0000000000f1', 'T16 Full', 365, 'mode_1', NULL, 'awarded'),
  ('16000000-0000-4000-8000-0000000000f2', 'T16 Streamlined', 60, 'mode_2', NULL, 'awarded'),
  ('16000000-0000-4000-8000-0000000000f3', 'T16 Minimal', 200, 'mode_3', 'Kontraktor memakai HSE-MS ISO 45001 sendiri', 'awarded'),
  ('16000000-0000-4000-8000-0000000000f4', 'T16 Visitor', 30, 'mode_3', 'Kunjungan teknis vendor, didampingi host WFRD', 'awarded'),
  ('16000000-0000-4000-8000-0000000000f5', 'T16 Active', 365, 'mode_1', NULL, 'active')) x(id, title, days, mode, notes, status);
SELECT build_contract_requirements(id) FROM contracts WHERE contractor_id = '16000000-0000-4000-8000-0000000000c1';

-- ── Resolusi tier (25.2) ──
SELECT is(resolve_access_tier('mode_1', 120), 'full'::access_tier, 'M1 + long-term = full');
SELECT is(resolve_access_tier('mode_1', 60), 'streamlined'::access_tier, 'M1 + short-term = streamlined');
SELECT is(resolve_access_tier('mode_2', 365), 'full'::access_tier, 'M2 + long-term = full');
SELECT is(resolve_access_tier('mode_2', 30), 'streamlined'::access_tier, 'M2 + short-term = streamlined');
SELECT is(resolve_access_tier('mode_3', 200), 'minimal'::access_tier, 'M3 + long-term = minimal');
SELECT is(resolve_access_tier('mode_3', 5), 'visitor'::access_tier, 'M3 + short-term = visitor');
SELECT is(resolve_access_tier('mode_1', 90), 'streamlined'::access_tier, 'tepat 90 hari = short-term');

-- ── Kolom turunan (R27/R28) ──
SELECT is((SELECT access_tier || '/' || duration_category || '/' || duration_days FROM contracts WHERE id = '16000000-0000-4000-8000-0000000000f1'),
          'full/long_term/365', 'kolom generated: full / long_term / 365 hari');
SELECT is((SELECT access_tier || '/' || duration_category FROM contracts WHERE id = '16000000-0000-4000-8000-0000000000f4'),
          'visitor/short_term', 'kolom generated: visitor / short_term');
SELECT throws_ok($$UPDATE contracts SET access_tier = 'full' WHERE id = '16000000-0000-4000-8000-0000000000f4'$$,
                 '428C9', NULL, 'access_tier tidak bisa di-set manual');
SELECT throws_ok($$INSERT INTO contracts (contractor_id, title, geozone, risk_class, start_date, end_date, target_mob_date, process_owner_id,
                     hse_reviewer_id, review_mailbox, contract_mode)
                   VALUES ('16000000-0000-4000-8000-0000000000c1', 'x', 'APAC', 'low', CURRENT_DATE, CURRENT_DATE + 10, CURRENT_DATE,
                     '16000000-0000-4000-8000-000000000002', '16000000-0000-4000-8000-000000000003', 'rev@t16.test', 'mode_3')$$,
                 '22023', NULL, 'Mode 3 tanpa catatan HSE oversight ditolak');

-- ── Requirement per tier (R29) ──
SELECT is((SELECT array_agg(doc_type_code ORDER BY doc_type_code) FROM contract_requirements
           WHERE contract_id = '16000000-0000-4000-8000-0000000000f4' AND applicable), ARRAY['VISACK'], 'visitor: hanya VISACK');
SELECT is((SELECT array_agg(doc_type_code ORDER BY doc_type_code) FROM contract_requirements
           WHERE contract_id = '16000000-0000-4000-8000-0000000000f3' AND applicable),
          ARRAY['CNTRCT','HSEPLN','INSCRT','PRMLIC'], 'minimal: 4 dokumen inti (tanpa SUBDOC — R32)');
SELECT is((SELECT array_agg(doc_type_code ORDER BY doc_type_code) FROM contract_requirements
           WHERE contract_id = '16000000-0000-4000-8000-0000000000f2' AND applicable),
          ARRAY['CNTRCT','DMBCHK','EQPCRT','HSEPLN','INSCRT','JRAREG','MANLST','MOBCHK','OPRSLF','PRMLIC','TRNCRT'],
          'streamlined: 8 dokumen spec + checklist mob/demob + OPR');
SELECT is((SELECT reason FROM contract_requirements WHERE contract_id = '16000000-0000-4000-8000-0000000000f2' AND doc_type_code = 'BRDGDC'),
          'not_applicable_tier:streamlined', 'alasan tidak berlaku tercatat');
SELECT ok((SELECT applicable FROM contract_requirements WHERE contract_id = '16000000-0000-4000-8000-0000000000f1' AND doc_type_code = 'BRDGDC'),
          'full: dokumen lengkap v3.2 tetap berlaku');
SELECT ok(NOT _doc_required('16000000-0000-4000-8000-0000000000f3', 'MOBCHK') AND _doc_required('16000000-0000-4000-8000-0000000000f1', 'MOBCHK'),
          'gate MOBCHK hanya bila berlaku (minimal tanpa MOBCHK — R32)');
SELECT is(generate_contract_tasks('16000000-0000-4000-8000-0000000000f4', 'pre_mobilization'), 1, 'visitor: 1 task dibuat (VISACK)');

-- ── Guard Mode 3 / visitor ──
SELECT throws_ok($$INSERT INTO subcontractors (contract_id, sub_seq, legal_name, scope_of_work)
                   VALUES ('16000000-0000-4000-8000-0000000000f3', 1, 'Sub', 'x')$$, '22023', NULL, 'Mode 3 tidak boleh punya subcontractor');
SELECT throws_ok($$UPDATE contracts SET premob_questionnaire = '{"has_subcontractor": true}' WHERE id = '16000000-0000-4000-8000-0000000000f3'$$,
                 '22023', NULL, 'questionnaire Mode 3 dengan subcontractor ditolak');
SELECT throws_ok($$UPDATE contracts SET premob_questionnaire = '{"has_hot_work": true}' WHERE id = '16000000-0000-4000-8000-0000000000f4'$$,
                 '22023', NULL, 'visitor dengan hot work ditolak');

-- ── Perubahan tier otomatis ──
SELECT generate_contract_tasks('16000000-0000-4000-8000-0000000000f2', 'post_award');
UPDATE contracts SET end_date = CURRENT_DATE + 200 WHERE id = '16000000-0000-4000-8000-0000000000f2';
SELECT is((SELECT access_tier FROM contracts WHERE id = '16000000-0000-4000-8000-0000000000f2'), 'full'::access_tier,
          'perpanjangan > 90 hari → full');
SELECT ok(EXISTS (SELECT 1 FROM tasks WHERE contract_id = '16000000-0000-4000-8000-0000000000f2' AND doc_type_code = 'CVKEYP' AND status = 'open'),
          'tier naik: task fase yang sudah dilewati dilengkapi');

-- ── change_contract_mode (R34) ──
SELECT pg_temp.t16_as('16000000-0000-4000-8000-000000000002', repeat('2', 64));
SELECT is(change_contract_mode('16000000-0000-4000-8000-0000000000f2', 'mode_3', 'Kontraktor independen dengan HSE-MS sendiri', 'uji MOC') ->> 'access_tier',
          'minimal', 'PO ubah mode sebelum pre-mob → tier minimal');
SELECT is((SELECT status::TEXT FROM tasks WHERE contract_id = '16000000-0000-4000-8000-0000000000f2' AND doc_type_code = 'CVKEYP'),
          'cancelled', 'task yang tidak berlaku lagi dibatalkan');
UPDATE contracts SET status = 'pre_mobilization' WHERE id = '16000000-0000-4000-8000-0000000000f1';
SELECT throws_ok($$SELECT change_contract_mode('16000000-0000-4000-8000-0000000000f1', 'mode_2', NULL, 'uji kunci MOC')$$,
                 '42501', NULL, 'mode terkunci setelah pre-mobilization (wajib MOC)');
SELECT throws_ok($$UPDATE contracts SET contract_mode = 'mode_2' WHERE id = '16000000-0000-4000-8000-0000000000f1'$$,
                 '42501', NULL, 'update langsung contract_mode juga terkunci');

-- ── Level user contractor (27.2) ──
SELECT _create_task('contract', '16000000-0000-4000-8000-0000000000c1', '16000000-0000-4000-8000-0000000000f5', NULL, 'INSCRT', NULL, CURRENT_DATE + 7);
SELECT _create_task('contract', '16000000-0000-4000-8000-0000000000c1', '16000000-0000-4000-8000-0000000000f4', NULL, 'HSEPLN', NULL, CURRENT_DATE + 7);

SELECT pg_temp.t16_as('16000000-0000-4000-8000-000000000012', repeat('c', 64));
SELECT throws_ok($$SELECT _assert_task_perm('task.confirm_upload', t) FROM tasks t
                   WHERE t.contract_id = '16000000-0000-4000-8000-0000000000f5' AND t.doc_type_code = 'INSCRT'$$,
                 '42501', 'Hanya PIC dan Supervisor yang bisa konfirmasi upload dokumen/evidence', 'employee tidak bisa konfirmasi dokumen');
SELECT lives_ok($$SELECT _assert_task_perm('task.confirm_upload', t) FROM tasks t
                  WHERE t.contract_id = '16000000-0000-4000-8000-0000000000f4' AND t.doc_type_code = 'VISACK'$$,
                'employee bisa mengisi checklist');
SELECT lives_ok($$SELECT submit_stop_work('16000000-0000-4000-8000-0000000000f5', NOW(), 'Budi', 'Kondisi tidak aman', 'Area A', NULL, NULL, NULL)$$,
                'Stop Work selalu bisa untuk employee (R31)');
SELECT throws_ok($$SELECT upsert_manning('16000000-0000-4000-8000-0000000000f5', NULL, '{"full_name":"Andi","position":"Rigger"}')$$,
                 '42501', 'Data manning hanya bisa diubah PIC / Supervisor', 'employee tidak bisa mengubah manning');
SELECT is(my_session_state() ->> 'contractor_level', 'employee', 'sesi memuat level employee');

SELECT pg_temp.t16_as('16000000-0000-4000-8000-000000000011', repeat('b', 64));
SELECT lives_ok($$SELECT _assert_task_perm('task.confirm_upload', t) FROM tasks t
                  WHERE t.contract_id = '16000000-0000-4000-8000-0000000000f5' AND t.doc_type_code = 'INSCRT'$$,
                'supervisor bisa konfirmasi dokumen');
SELECT throws_ok($$SELECT update_my_company('{}'::jsonb)$$, '42501', NULL, 'supervisor tidak bisa edit profil perusahaan');
SELECT ok(NOT (my_session_state() -> 'permissions') ? 'company.edit', 'permission company.edit disembunyikan dari sesi supervisor');

SELECT pg_temp.t16_as('16000000-0000-4000-8000-000000000010', repeat('a', 64));
SELECT lives_ok($$SELECT update_my_company('{}'::jsonb)$$, 'PIC bisa edit profil perusahaan');
SELECT throws_ok($$SELECT _assert_task_perm('task.confirm_upload', t) FROM tasks t
                   WHERE t.contract_id = '16000000-0000-4000-8000-0000000000f4' AND t.doc_type_code = 'HSEPLN'$$,
                 '42501', 'Kontrak kategori visitor tidak menerima submission dokumen/form', 'kontrak visitor menolak submission dokumen (R33)');

-- ── Approve user wajib level (R30) ──
SELECT pg_temp.t16_as('16000000-0000-4000-8000-000000000001', repeat('1', 64));
SELECT throws_ok($$SELECT admin_approve_user('16000000-0000-4000-8000-000000000013', 'contractor_rep', 'global', NULL,
                     '16000000-0000-4000-8000-0000000000c1', NULL, 'uji approve', NULL)$$, '22023', NULL, 'approve contractor tanpa level ditolak');
SELECT admin_approve_user('16000000-0000-4000-8000-000000000013', 'contractor_rep', 'global', NULL,
                          '16000000-0000-4000-8000-0000000000c1', NULL, 'uji approve', 'supervisor');
SELECT is(_contractor_level_of('16000000-0000-4000-8000-000000000013'), 'supervisor'::contractor_user_level, 'level tersimpan saat approve');

-- ── SLA & BBS per tier ──
UPDATE tasks SET review_due_at = NOW() + INTERVAL '30 days'
WHERE contract_id = '16000000-0000-4000-8000-0000000000f4' AND doc_type_code = 'VISACK';
SELECT ok((SELECT review_due_at FROM tasks WHERE contract_id = '16000000-0000-4000-8000-0000000000f4' AND doc_type_code = 'VISACK')
          < NOW() + INTERVAL '10 days', 'SLA review dipangkas mengikuti tier visitor (1 hari kerja)');
SELECT is(((_compute_kpi('16000000-0000-4000-8000-0000000000f4', CURRENT_DATE)).metrics -> 'components' ->> 'bbs')::NUMERIC, 100::NUMERIC,
          'visitor: target BBS 0 → komponen BBS tidak menghukum');

-- ── Privilege ──
SELECT ok(NOT has_table_privilege('authenticated', 'public.contractor_users', 'SELECT'), 'contractor_users hanya lewat RPC');
SELECT ok(has_function_privilege('authenticated', 'public.admin_set_contractor_user_level(uuid,uuid,contractor_user_level,text)', 'EXECUTE')
          AND has_function_privilege('authenticated', 'public.change_contract_mode(uuid,contract_mode,text,text)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.change_contract_mode(uuid,contract_mode,text,text)', 'EXECUTE'),
          'RPC baru executable authenticated, tidak untuk anon');

SELECT * FROM finish();
ROLLBACK;
