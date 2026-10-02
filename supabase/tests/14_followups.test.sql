-- Migration 18/19: hardening & follow-up review
BEGIN;
SELECT plan(9);

SELECT ok(has_function_privilege('authenticated', 'public.list_contractor_users(uuid)', 'EXECUTE'), 'list_contractor_users executable oleh authenticated');
SELECT ok(NOT has_function_privilege('anon', 'public.list_contractor_users(uuid)', 'EXECUTE'), 'list_contractor_users tidak executable oleh anon');

SELECT ok(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'comen-rekey'), 'job comen-rekey terjadwal');

SELECT ok(pg_get_functiondef('public.admin_export_user_data(uuid,text)'::regprocedure) NOT LIKE '%to_jsonb(v_p)%',
          'DSAR tidak lagi mengekspor seluruh baris profiles');
SELECT ok(pg_get_functiondef('public.admin_export_user_data(uuid,text)'::regprocedure) LIKE '%''dsar:''%',
          'kuota DSAR terpisah dari chat_export');
SELECT ok(pg_get_functiondef('public.list_my_channels()'::regprocedure) LIKE '%thread_root IS NULL%',
          'unread tidak menghitung balasan thread');
SELECT ok(pg_get_functiondef('public.admin_list_channels(text,integer)'::regprocedure) LIKE '%c.topic%',
          'admin_list_channels mengembalikan topic');

SELECT ok((SELECT with_check FROM pg_policies WHERE schemaname = 'realtime' AND tablename = 'messages' AND policyname = 'comen_rt_send') LIKE '%typing%',
          'klien hanya boleh broadcast event typing');

SELECT throws_ok($$SELECT public.finalize_meeting(gen_random_uuid())$$, '22023', 'MoM tidak ditemukan', 'finalize_meeting menolak id tak dikenal');

SELECT * FROM finish();
ROLLBACK;
